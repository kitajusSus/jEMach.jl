#!/usr/bin/env luajit
-- jl_tui.lua — Standalone Julia Workspace TUI
--
-- Requires: luajit
-- Usage:    luajit scripts/jl_tui.lua [JULIA_PANE_ID]
--
-- JULIA_PANE_ID is the tmux pane target for the Julia REPL
-- (e.g. "%1" or "{left-of}").  Defaults to "{left-of}".
--
-- Keybindings:
--   j / k        — move cursor down / up
--   l / Enter    — expand module node (or print variable in REPL)
--   h            — collapse module node
--   d            — hide item from view (press D to restore all hidden)
--   q / Ctrl-c   — quit

local ffi = require("ffi")

-- ---------------------------------------------------------------------------
-- FFI: non-blocking stdin read via select(2) + read(2) + sockets
-- ---------------------------------------------------------------------------
ffi.cdef([[
  typedef long          ssize_t;
  typedef unsigned long size_t;
  typedef long          time_t;
  typedef long          suseconds_t;

  typedef struct {
    time_t      tv_sec;
    suseconds_t tv_usec;
  } timeval_t;

  typedef struct { unsigned long fds_bits[16]; } fd_set_t;

  int     select(int, fd_set_t *, fd_set_t *, fd_set_t *, timeval_t *);
  ssize_t read  (int, void *, size_t);
  int     gettimeofday(timeval_t *tv, void *tz);

  struct sockaddr_un {
    unsigned short sun_family;
    char           sun_path[108];
  };

  struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
  };

  int     socket(int domain, int type, int protocol);
  int     connect(int sockfd, const struct sockaddr_un *addr, unsigned int addrlen);
  int     close(int fd);
  ssize_t write(int fd, const void *buf, size_t count);
  int     ioctl(int fd, unsigned long request, ...);
]])

local STDIN = 0
local STDOUT = 1
local TIOCGWINSZ = (ffi.os == "OSX") and 0x40087468 or 0x5413

local function fd_set_new()
	local s = ffi.new("fd_set_t")
	for i = 0, 15 do
		s.fds_bits[i] = 0
	end
	return s
end

local function fd_set_set(s, fd)
	local word = math.floor(fd / 64)
	local b = fd % 64
	-- Use math.floor(2^b) to stay in integer range (safe for b < 53)
	s.fds_bits[word] = s.fds_bits[word] + math.floor(2 ^ b)
end

local function fd_set_isset(s, fd)
	local word = math.floor(fd / 64)
	local b = fd % 64
	local mask = math.floor(2 ^ b)
	return (s.fds_bits[word] % (2 * mask)) >= mask
end

local json_parse -- forward declaration

local function get_project_dir()
	local env_proj = os.getenv("JEMACH_PROJ")
	if env_proj and env_proj ~= "" then
		return env_proj
	end
	local handle = io.popen("pwd")
	local cwd = handle:read("*a"):gsub("%s+", "")
	handle:close()
	local dir = cwd
	while dir and dir ~= "" and dir ~= "/" do
		local f = io.open(dir .. "/Project.toml", "r")
		if f then
			f:close()
			return dir
		end
		local parent = dir:match("(.*)/[^/]+$")
		if not parent or parent == dir then
			break
		end
		dir = parent
	end
	return cwd
end

local function get_safe_name(dir)
	local pdir = dir or get_project_dir()
	return pdir:gsub("[^a-zA-Z0-9]", "_")
end

local function find_active_jemach()
	-- Look for the most recently modified jl_tui_state_*.json in /tmp
	local h = io.popen("ls -t /tmp/jl_tui_state_*.json 2>/dev/null | head -n 1")
	if h then
		local latest_file = h:read("*l")
		h:close()
		if latest_file and latest_file ~= "" then
			local sname = latest_file:match("/tmp/jl_tui_state_(.*)%.json$")
			local sock = sname and ("/tmp/jemach_" .. sname .. ".sock") or nil
			return sock, latest_file
		end
	end
	return nil, nil
end

local repl_pane = (arg and arg[1] and arg[1] ~= "") and arg[1] or "{left-of}"

local default_safe_name = get_safe_name()
local socket_path = (arg and arg[2] and arg[2] ~= "") and arg[2]
	or os.getenv("JEMACH_SOCKET")
	or ("/tmp/jemach_" .. default_safe_name .. ".sock")

local STATE_FILE = (arg and arg[3] and arg[3] ~= "") and arg[3]
	or os.getenv("JEMACH_STATE")
	or ("/tmp/jl_tui_state_" .. default_safe_name .. ".json")

local function check_and_discover(force)
	if not force then
		local f = io.open(STATE_FILE, "r")
		if f then
			f:close()
			return
		end
	end
	local auto_sock, auto_state = find_active_jemach()
	if auto_state then
		local af = io.open(auto_state, "r")
		if af then
			af:close()
			STATE_FILE = auto_state
			if auto_sock then
				socket_path = auto_sock
			end
		end
	end
end
check_and_discover(false)

local socket_fd = -1
local last_connect_try = 0
local socket_buffer = ""
local socket_read_buf = ffi.new("char[65536]")
local stdin_buf = ffi.new("char[512]")
local _tv_now = ffi.new("timeval_t")
local dirty = true
local state = nil -- last parsed JSON state
local last_mtime = 0
local last_state_ts = 0
local history_selected = {}

local function now_ms()
	ffi.C.gettimeofday(_tv_now, nil)
	return tonumber(_tv_now.tv_sec) * 1000 + math.floor(tonumber(_tv_now.tv_usec) / 1000)
end

local function realign_history_selection(old_hist, new_hist)
	if not next(history_selected) then
		return
	end
	if type(old_hist) ~= "table" or type(new_hist) ~= "table" or #old_hist == 0 or #new_hist == 0 then
		history_selected = {}
		return
	end
	local n_old = #old_hist
	local n_new = #new_hist
	local matched_s = nil
	for s = 0, n_old - 1 do
		local overlap = math.min(n_old - s, n_new)
		if overlap >= 1 then
			local ok = true
			for k = 1, overlap do
				if old_hist[s + k] ~= new_hist[k] then
					ok = false
					break
				end
			end
			if ok then
				matched_s = s
				break
			end
		end
	end
	if matched_s == nil then
		history_selected = {}
	elseif matched_s > 0 then
		local shifted = {}
		for idx, val in pairs(history_selected) do
			if val and type(idx) == "number" then
				local new_idx = idx - matched_s
				if new_idx >= 1 and new_idx <= n_new then
					shifted[new_idx] = true
				end
			end
		end
		history_selected = shifted
	end
end

local function apply_new_state(parsed)
	local old_hist = state and state.history or nil
	realign_history_selection(old_hist, parsed and parsed.history or nil)
	state = parsed
	last_state_ts = os.time()
	dirty = true
end

local function try_connect_socket()
	if socket_fd >= 0 then
		return
	end

	local now = os.time()
	if now - last_connect_try < 2 then
		return
	end
	last_connect_try = now

	local fd = ffi.C.socket(1, 1, 0) -- AF_UNIX = 1, SOCK_STREAM = 1
	if fd < 0 then
		return
	end

	local addr = ffi.new("struct sockaddr_un")
	addr.sun_family = 1
	ffi.copy(addr.sun_path, socket_path)

	local res = ffi.C.connect(fd, addr, 110)
	if res == 0 then
		socket_fd = fd
		ffi.C.write(socket_fd, "SUB\n", 4)
	else
		ffi.C.close(fd)
		-- If connect failed, try discovering active session and retry immediately
		local old_sock = socket_path
		check_and_discover(true)
		if socket_path ~= old_sock then
			local fd2 = ffi.C.socket(1, 1, 0)
			if fd2 >= 0 then
				ffi.fill(addr, ffi.sizeof(addr))
				addr.sun_family = 1
				ffi.copy(addr.sun_path, socket_path)
				if ffi.C.connect(fd2, addr, 110) == 0 then
					socket_fd = fd2
					ffi.C.write(socket_fd, "SUB\n", 4)
				else
					ffi.C.close(fd2)
				end
			end
		end
	end
end

local function handle_socket_read()
	local buf = socket_read_buf
	while socket_fd >= 0 do
		local n = tonumber(ffi.C.read(socket_fd, buf, 65536))
		if not n or n <= 0 then
			ffi.C.close(socket_fd)
			socket_fd = -1
			return nil
		end

		socket_buffer = socket_buffer .. ffi.string(buf, n)
		if socket_buffer:sub(-1) == "\n" then
			break
		end
		local rfds = fd_set_new()
		fd_set_set(rfds, socket_fd)
		local rtv = ffi.new("timeval_t", { tv_sec = 0, tv_usec = 2000 })
		if ffi.C.select(socket_fd + 1, rfds, nil, nil, rtv) <= 0 then
			break
		end
	end

	local should_quit = false
	while true do
		local nl = socket_buffer:find("\n")
		if not nl then
			break
		end
		local line = socket_buffer:sub(1, nl - 1)
		socket_buffer = socket_buffer:sub(nl + 1)

		local ok, parsed = pcall(json_parse, line)
		if ok and parsed then
			if parsed.action == "close" or parsed.event == "stop" then
				should_quit = true
			else
				apply_new_state(parsed)
			end
		end
	end
	if should_quit then
		return "quit"
	end
	return nil
end

-- Read a single key-press (or escape sequence) with a timeout in ms.
-- Also reads from socket if connected.
-- Returns nil if no input arrived within the timeout.
local function read_key(timeout_ms)
	try_connect_socket()

	local fds = fd_set_new()
	fd_set_set(fds, STDIN)

	local max_fd = STDIN
	if socket_fd >= 0 then
		fd_set_set(fds, socket_fd)
		if socket_fd > max_fd then
			max_fd = socket_fd
		end
	end

	local tv = ffi.new("timeval_t", { tv_sec = 0, tv_usec = (timeout_ms or 100) * 1000 })
	local ready = ffi.C.select(max_fd + 1, fds, nil, nil, tv)
	if ready <= 0 then
		return nil
	end

	if socket_fd >= 0 and fd_set_isset(fds, socket_fd) then
		local sres = handle_socket_read()
		if sres == "quit" then
			return "q"
		end
	end

	if fd_set_isset(fds, STDIN) then
		local n = tonumber(ffi.C.read(STDIN, stdin_buf, 512))
		if not n or n <= 0 then
			return nil
		end

		return ffi.string(stdin_buf, n)
	end

	return nil
end

local input_queue = {}

-- Normalize Ghostty / Kitty CSI-u & SS3 application cursor keys to standard keys
local function normalize_key(k)
	if not k then
		return nil
	end
	-- Application cursor keys (SS3)
	if k == "\27OA" then return "\27[A" end
	if k == "\27OB" then return "\27[B" end
	if k == "\27OC" then return "\27[C" end
	if k == "\27OD" then return "\27[D" end
	if k == "\27OM" then return "\r" end

	-- Kitty keyboard protocol / CSI-u sequences (\27[<codepoint>;<modifiers>u)
	local csi_u_code, csi_u_mod = k:match("^\27%[(%d+)[:%d]*;?(%d*)[:%d]*u$")
	if csi_u_code then
		local code = tonumber(csi_u_code)
		local mod = tonumber(csi_u_mod) or 1
		if code == 27 then
			return "\27"
		elseif code == 13 then
			return "\r"
		elseif code == 9 then
			return "\t"
		elseif code == 127 or code == 8 then
			return "\127"
		elseif code == 99 and (mod == 5 or mod == 6) then -- Ctrl+C in CSI-u
			return "\3"
		elseif code >= 32 and code <= 126 then
			if mod == 1 then
				return string.char(code)
			elseif mod == 2 then -- Shift in CSI-u (e.g. ?, J, K, D)
				if code >= 97 and code <= 122 then
					return string.char(code - 32)
				elseif code == 47 then
					return "?"
				else
					return string.char(code)
				end
			end
		end
	end

	-- Extended cursor keys with modifiers (\27[1;...A)
	local arrow_dir = k:match("^\27%[1;%d+([ABCD])$")
	if arrow_dir then
		return "\27[" .. arrow_dir
	end

	return k
end

local function queue_keys(raw)
	local pos = 1
	local len = #raw
	while pos <= len do
		if raw:sub(pos, pos) == "\27" then
			local esc_seq = raw:match("^\27%[<[%d;]+[Mm]", pos)
				or raw:match("^\27%[[%d;]*[a-zA-Z~u]", pos)
				or raw:match("^\27O[a-zA-Z]", pos)
			if esc_seq then
				table.insert(input_queue, normalize_key(esc_seq))
				pos = pos + #esc_seq
			else
				table.insert(input_queue, "\27")
				pos = pos + 1
			end
		else
			table.insert(input_queue, raw:sub(pos, pos))
			pos = pos + 1
		end
	end
end

local function get_next_key(timeout_ms)
	if #input_queue > 0 then
		return table.remove(input_queue, 1)
	end
	local raw = read_key(timeout_ms)
	if not raw or raw == "" then
		return nil
	end
	queue_keys(raw)
	return table.remove(input_queue, 1)
end

-- ---------------------------------------------------------------------------
-- Terminal control helpers (ANSI/VT100 + Synchronized Output Mode 2026)
-- ---------------------------------------------------------------------------
local ESC = "\27"
local CLEAR = ESC .. "[2J" .. ESC .. "[H"
local HIDE_CUR = ESC .. "[?25l"
local SHOW_CUR = ESC .. "[?25h"
local ALT_SCREEN_ON = ESC .. "[?1049h"
local ALT_SCREEN_OFF = ESC .. "[?1049l"
local SYNC_START = ESC .. "[?2026h"
local SYNC_END = ESC .. "[?2026l"
local SET_TITLE = ESC .. "]2;jEMach — Julia Workspace\7"
local BOLD = ESC .. "[1m"
local DIM = ESC .. "[2m"
local ITALIC = ESC .. "[3m"
local RESET = ESC .. "[0m"
local REV = ESC .. "[7m" -- reverse video (selection highlight)

-- Modern 256-color palette
local FG_CYAN = ESC .. "[38;5;51m"
local FG_AQUA = ESC .. "[38;5;45m"
local FG_TEAL = ESC .. "[38;5;37m"
local FG_GREEN = ESC .. "[38;5;84m"
local FG_YELLOW = ESC .. "[38;5;221m"
local FG_ORANGE = ESC .. "[38;5;215m"
local FG_PURPLE = ESC .. "[38;5;141m"
local FG_RED = ESC .. "[38;5;203m"
local FG_WHITE = ESC .. "[38;5;255m"
local FG_LIGHT_GRAY = ESC .. "[38;5;250m"
local FG_GRAY = ESC .. "[38;5;244m"
local FG_DARK_GRAY = ESC .. "[38;5;238m"

local BG_TAB_ACT = ESC .. "[48;5;24m"
local BG_ERR_LINE = ESC .. "[48;5;52m"
local BG_PANEL = ESC .. "[48;5;235m"
local MOUSE_ON = ESC .. "[?1000h" .. ESC .. "[?1006h"
local MOUSE_OFF = ESC .. "[?1000l" .. ESC .. "[?1006l"

local function strip_ansi(s)
	return tostring(s or ""):gsub("\27%[[%d;]*[a-zA-Z]", "")
end

local function visible_len(s)
	local clean = strip_ansi(s)
	local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
	return count
end

local function pad_right(s, width)
	s = tostring(s or "")
	local vlen = visible_len(s)
	if vlen >= width then
		return s
	end
	return s .. string.rep(" ", width - vlen)
end

local function truncate_visible(s, max_w)
	s = tostring(s or "")
	if max_w <= 0 then
		return ""
	end
	local clean = strip_ansi(s)
	local vlen = visible_len(clean)
	if vlen <= max_w then
		return s
	end
	if max_w == 1 then
		return "…"
	end
	local cur_w = 0
	local res = {}
	for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if cur_w >= max_w - 1 then
			table.insert(res, "…")
			break
		end
		table.insert(res, c)
		cur_w = cur_w + 1
	end
	return table.concat(res)
end

local function wrap_text(s, max_w)
	s = tostring(s or "")
	if max_w <= 1 then
		return { s }
	end
	local chars = {}
	for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(chars, c)
	end
	if #chars == 0 then
		return { "" }
	end
	local lines = {}
	local i = 1
	while i <= #chars do
		local j = math.min(#chars, i + max_w - 1)
		if j < #chars then
			local min_break = i + math.floor(max_w * 0.65)
			for k = j, min_break, -1 do
				if chars[k] == " " or chars[k] == "\t" then
					j = k
					break
				end
			end
		end
		local chunk = {}
		for k = i, j do
			table.insert(chunk, chars[k])
		end
		local line_str = table.concat(chunk)
		if j < #chars and (chars[j] == " " or chars[j] == "\t") then
			line_str = line_str:gsub("%s+$", "")
		end
		table.insert(lines, line_str)
		i = j + 1
	end
	return lines
end

local JL_KEYWORDS = {
	["function"] = true, ["end"] = true, ["return"] = true, ["if"] = true, ["else"] = true,
	["elseif"] = true, ["for"] = true, ["while"] = true, ["in"] = true, ["let"] = true,
	["begin"] = true, ["try"] = true, ["catch"] = true, ["finally"] = true, ["using"] = true,
	["import"] = true, ["export"] = true, ["struct"] = true, ["mutable"] = true, ["const"] = true,
	["global"] = true, ["local"] = true, ["macro"] = true, ["module"] = true, ["baremodule"] = true,
	["quote"] = true, ["do"] = true
}
local JL_TYPES = {
	["Int"] = true, ["Int64"] = true, ["Int32"] = true, ["Int16"] = true, ["Int8"] = true,
	["UInt"] = true, ["UInt64"] = true, ["UInt32"] = true, ["UInt16"] = true, ["UInt8"] = true,
	["Float64"] = true, ["Float32"] = true, ["String"] = true, ["Char"] = true,
	["Vector"] = true, ["Matrix"] = true, ["Array"] = true, ["DataFrame"] = true,
	["Bool"] = true, ["Dict"] = true, ["Set"] = true, ["Symbol"] = true, ["Any"] = true,
	["Nothing"] = true, ["Missing"] = true, ["Tuple"] = true, ["NamedTuple"] = true,
	["Union"] = true, ["Number"] = true, ["Real"] = true, ["Integer"] = true, ["Ref"] = true
}
local JL_LITERALS = {
	["true"] = true, ["false"] = true, ["nothing"] = true, ["missing"] = true, ["undef"] = true
}

local function highlight_julia_line(line)
	local out = {}
	local pos = 1
	local len = #line

	while pos <= len do
		local c = line:sub(pos, pos)
		if c == "#" then
			table.insert(out, FG_GRAY .. ITALIC .. line:sub(pos) .. RESET)
			break
		elseif c == "\"" or c == "'" then
			local quote = c
			local end_pos = pos + 1
			while end_pos <= len do
				local ch = line:sub(end_pos, end_pos)
				if ch == "\\" then
					end_pos = end_pos + 2
				elseif ch == quote then
					end_pos = end_pos + 1
					break
				else
					end_pos = end_pos + 1
				end
			end
			table.insert(out, FG_GREEN .. line:sub(pos, end_pos - 1) .. RESET)
			pos = end_pos
		elseif c == ":" and pos < len and line:sub(pos + 1, pos + 1):match("[%a_]") then
			local sym_end = pos + 1
			while sym_end <= len and line:sub(sym_end, sym_end):match("[%w_!]") do
				sym_end = sym_end + 1
			end
			table.insert(out, FG_AQUA .. line:sub(pos, sym_end - 1) .. RESET)
			pos = sym_end
		elseif c == "@" and pos < len and line:sub(pos + 1, pos + 1):match("[%a_]") then
			local mac_end = pos + 1
			while mac_end <= len and line:sub(mac_end, mac_end):match("[%w_!]") do
				mac_end = mac_end + 1
			end
			table.insert(out, FG_PURPLE .. line:sub(pos, mac_end - 1) .. RESET)
			pos = mac_end
		elseif c:match("[%a_]") then
			local word_end = pos + 1
			while word_end <= len and line:sub(word_end, word_end):match("[%w_!]") do
				word_end = word_end + 1
			end
			local w = line:sub(pos, word_end - 1)
			if JL_KEYWORDS[w] then
				table.insert(out, BOLD .. FG_PURPLE .. w .. RESET)
			elseif JL_TYPES[w] then
				table.insert(out, BOLD .. FG_CYAN .. w .. RESET)
			elseif JL_LITERALS[w] then
				table.insert(out, FG_ORANGE .. w .. RESET)
			else
				table.insert(out, FG_WHITE .. w .. RESET)
			end
			pos = word_end
		elseif c:match("%d") then
			local num_end = pos + 1
			while num_end <= len and line:sub(num_end, num_end):match("[%d%.eExXa-fA-F_]") do
				num_end = num_end + 1
			end
			table.insert(out, FG_YELLOW .. line:sub(pos, num_end - 1) .. RESET)
			pos = num_end
		elseif c:match("[%[%]%{%}%(%),;]") then
			table.insert(out, FG_LIGHT_GRAY .. c .. RESET)
			pos = pos + 1
		elseif c:match("[%+%-*%/%^=<>!&|~]") then
			table.insert(out, FG_AQUA .. c .. RESET)
			pos = pos + 1
		else
			table.insert(out, c)
			pos = pos + 1
		end
	end
	return table.concat(out)
end

local function move(row, col)
	return ESC .. "[" .. row .. ";" .. col .. "H"
end

local winsize_buf = ffi.new("struct winsize")

local function get_terminal_size()
	-- Fast path: zero-fork ioctl(TIOCGWINSZ) on STDOUT or STDIN
	if ffi.C.ioctl(STDOUT, TIOCGWINSZ, winsize_buf) == 0 and winsize_buf.ws_row > 0 and winsize_buf.ws_col > 0 then
		return tonumber(winsize_buf.ws_row), tonumber(winsize_buf.ws_col)
	end
	if ffi.C.ioctl(STDIN, TIOCGWINSZ, winsize_buf) == 0 and winsize_buf.ws_row > 0 and winsize_buf.ws_col > 0 then
		return tonumber(winsize_buf.ws_row), tonumber(winsize_buf.ws_col)
	end
	-- Fallback to tput
	local handle = io.popen("tput lines && tput cols 2>/dev/null")
	if not handle then
		return 24, 80
	end
	local lines = tonumber(handle:read("*l")) or 24
	local cols = tonumber(handle:read("*l")) or 80
	handle:close()
	return lines, cols
end

local function raw_mode_on()
	os.execute("stty raw -echo 2>/dev/null")
end

local function raw_mode_off()
	os.execute("stty sane 2>/dev/null")
end

-- ---------------------------------------------------------------------------
-- Minimal JSON parser (handles the format emitted by jl_watcher.jl)
-- ---------------------------------------------------------------------------
json_parse = function(s)
	local pos = 1

	local function skip_ws()
		while pos <= #s and s:sub(pos, pos):match("%s") do
			pos = pos + 1
		end
	end

	local parse_value -- forward declaration

	local function parse_string()
		assert(s:sub(pos, pos) == '"', "expected '\"' at pos " .. pos)
		pos = pos + 1
		local buf = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				break
			end
			if c == "\\" then
				pos = pos + 1
				local esc = s:sub(pos, pos)
				if esc == '"' then
					buf[#buf + 1] = '"'
				elseif esc == "\\" then
					buf[#buf + 1] = "\\"
				elseif esc == "n" then
					buf[#buf + 1] = "\n"
				elseif esc == "r" then
					buf[#buf + 1] = "\r"
				elseif esc == "t" then
					buf[#buf + 1] = "\t"
				elseif esc == "b" then
					buf[#buf + 1] = "\b"
				elseif esc == "f" then
					buf[#buf + 1] = "\f"
				elseif esc == "u" then
					local hex = s:sub(pos + 1, pos + 4)
					local cp = tonumber(hex, 16)
					if cp and cp < 128 then
						buf[#buf + 1] = string.char(cp)
					end
					pos = pos + 4
				else
					buf[#buf + 1] = esc
				end
			else
				buf[#buf + 1] = c
			end
			pos = pos + 1
		end
		return table.concat(buf)
	end

	local function parse_number()
		local start = pos
		if s:sub(pos, pos) == "-" then
			pos = pos + 1
		end
		while pos <= #s and s:sub(pos, pos):match("[%d%.eE+%-]") do
			pos = pos + 1
		end
		return tonumber(s:sub(start, pos - 1))
	end

	local function parse_object()
		assert(s:sub(pos, pos) == "{", "expected '{' at pos " .. pos)
		pos = pos + 1
		local obj = {}
		skip_ws()
		if s:sub(pos, pos) == "}" then
			pos = pos + 1
			return obj
		end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			assert(s:sub(pos, pos) == ":", "expected ':' at pos " .. pos)
			pos = pos + 1
			skip_ws()
			obj[key] = parse_value()
			skip_ws()
			local sep = s:sub(pos, pos)
			if sep == "}" then
				pos = pos + 1
				break
			end
			assert(sep == ",", "expected ',' or '}' at pos " .. pos)
			pos = pos + 1
		end
		return obj
	end

	local function parse_array()
		assert(s:sub(pos, pos) == "[", "expected '[' at pos " .. pos)
		pos = pos + 1
		local arr = {}
		skip_ws()
		if s:sub(pos, pos) == "]" then
			pos = pos + 1
			return arr
		end
		while true do
			skip_ws()
			arr[#arr + 1] = parse_value()
			skip_ws()
			local sep = s:sub(pos, pos)
			if sep == "]" then
				pos = pos + 1
				break
			end
			assert(sep == ",", "expected ',' or ']' at pos " .. pos)
			pos = pos + 1
		end
		return arr
	end

	parse_value = function()
		skip_ws()
		local c = s:sub(pos, pos)
		if c == '"' then
			return parse_string()
		elseif c == "{" then
			return parse_object()
		elseif c == "[" then
			return parse_array()
		elseif c == "t" then
			pos = pos + 4
			return true
		elseif c == "f" then
			pos = pos + 5
			return false
		elseif c == "n" then
			pos = pos + 4
			return nil
		else
			return parse_number()
		end
	end

	skip_ws()
	return parse_value()
end

-- ---------------------------------------------------------------------------
-- State management
-- ---------------------------------------------------------------------------
local REFRESH_MS = 1500 -- state file poll interval (ms)

-- hidden[key] = true  means the item is hidden from view
-- key = "ModuleName" for a module header, "ModuleName/ItemName" for items
local hidden = {}
-- collapsed[module_name_or_item_path] = true
local collapsed = {}
local initialized_modules = { ["Main"] = true }
local initialized_items = {}

-- Flat list of "display rows" rebuilt each render pass
local active_tab = 1 -- 1: Workspace, 2: History, 3: Procedures, 4: Packages, 5: Guide
local TAB_NAMES = { "Workspace", "History", "Procedures", "Packages", "Guide" }
local TAB_SHORT = { "WS", "Hist", "Proc", "Pkg", "Guide" }
local tab_cursors = { 1, 1, 1, 1, 1 }
local tab_scrolls = { 1, 1, 1, 1, 1 }
local guide_tab_open = false
local return_tab = 1

-- Procedures split preview scroll & Full-screen detail viewer
local proc_preview_scroll = 0
local last_proc_preview_key = nil
local detail_view_active = false
local detail_scroll = 0
local detail_item = nil
local history_prev_collapsed = true
local proc_errors_view = false
local mouse_enabled = true
local last_modal_args = {}
local tab_hitboxes = {}
local row_hitboxes = {}
local action_hitboxes = {}
local header_err_hitbox = nil
local preview_split_row = 0
local last_click_row = 0
local last_click_ms = 0

local GUIDE_SECTIONS = {
	{
		title = "Julia REPL Editing & Navigation Shortcuts",
		items = {
			{ key = "Ctrl+A / Ctrl+E", desc = "Jump cursor to beginning / end of line (Home / End)" },
			{ key = "Alt+B / Alt+F", desc = "Move backward / forward by one word" },
			{ key = "Ctrl+W / Alt+Bksp", desc = "Delete previous word" },
			{ key = "Ctrl+U / Ctrl+K", desc = "Clear text before cursor / to end of line" },
			{ key = "Ctrl+R / Ctrl+S", desc = "Reverse / forward incremental history search" },
			{ key = "Up / Down", desc = "Cycle REPL history (type prefix + Up for prefix match)" },
			{ key = "Tab (x2)", desc = "Autocomplete symbols, methods, file paths & kwargs" },
			{ key = "\\alpha + Tab", desc = "Insert Unicode/LaTeX math symbols (\\alpha, \\sum, \\in)" },
			{ key = "Alt+Enter", desc = "Insert newline inside a multi-line expression" },
			{ key = "Ctrl+L", desc = "Clear REPL terminal screen" },
			{ key = "Ctrl+C / Ctrl+D", desc = "Interrupt running code or cancel / exit REPL on empty line" },
		},
	},
	{
		title = "Julia REPL Modes & Everyday Utilities",
		items = {
			{ key = "?  (at julia>)", desc = "help?> documentation mode (?println, ?Vector)" },
			{ key = ";  (at julia>)", desc = "shell> OS shell mode (;ls, ;git status)" },
			{ key = "]  (at julia>)", desc = "pkg> package manager (status, add Foo, rm, up, activate ., test)" },
			{ key = "} or Alt+m", desc = "Enter jemach> mode (Tab completes, Backspace exits to julia>)" },
			{ key = "Alt+j / Alt+r", desc = "Toggle jEMach TUI split panel / Start-stop live proc recording" },
			{ key = "ans / varinfo()", desc = "Last evaluated value / list variables in current module" },
			{ key = "methods(f)", desc = "List all methods defined for function f" },
			{ key = "@which f(x)", desc = "Show which method & file:line a call dispatches to" },
			{ key = "@edit f(x)", desc = "Open the exact method definition in your editor" },
			{ key = "@time / @allocated", desc = "Measure runtime and heap allocations of an expression" },
			{ key = "using Revise", desc = "Auto-reload edited package & project files without restarting" },
		},
	},
	{
		title = "Using jEMach in REPL (jemach> & Macros)",
		items = {
			{ key = "help | ? | h", desc = "Print jemach> command reference in REPL" },
			{ key = "ui | open | close | clear", desc = "Toggle/open/close TUI panel or clear REPL screen (clear())" },
			{ key = "ws [filter]", desc = "Print workspace variables table with memory sizes" },
			{ key = "ls [q] | find <q>", desc = "List or search saved & live procedures" },
			{ key = "show <name> | edit <name>", desc = "Show procedure card / load clean function into julia> editor" },
			{ key = "errors", desc = "List errored procedures & failed commands from this session" },
			{ key = "<name>(args...) | run ...", desc = "Run a procedure with profiling (keeps live in-memory edits)" },
			{ key = "make <name> [N]", desc = "Extract last N commands into procedures/<name>.jl (hoists using)" },
			{ key = "rec [name] | stop", desc = "Start / stop live procedure recording ([rec: name] julia>)" },
			{ key = "inspect <expr> | @inspect", desc = "Deep-inspect variable/function, methods, origin & docstring" },
			{ key = "@jemach [cmd]", desc = "Macro to toggle TUI or invoke jemach commands from julia>" },
			{ key = "save [<name> [as]] | reload", desc = "Save modified/live function to disk / reload from procedures/*.jl" },
		},
	},
	{
		title = "jEMach TUI Global Keys & Mouse Navigation",
		items = {
			{ key = "1 / 2 / 3 / 4", desc = "Jump to Workspace / History / Procedures / Packages (or click tab)" },
			{ key = "? (or 5)", desc = "Open or toggle this Guide tab (Esc returns to prior tab)" },
			{ key = "Tab / ] / [", desc = "Cycle forward / backward through TUI tabs" },
			{ key = "/", desc = "Live search & filter current tab (Esc or x clears filter)" },
			{ key = "j / k or Up / Down", desc = "Move cursor down / up (g/G top/bottom, PgUp/PgDn page)" },
			{ key = "Mouse / m", desc = "Click rows & pills, dbl-click edits, wheel scrolls; [m] toggles mouse" },
			{ key = "c / q / Ctrl+C", desc = "Clear REPL screen / Quit TUI panel" },
		},
	},
	{
		title = "jEMach TUI Tab Actions & Live Functions",
		items = {
			{ key = "[1] Workspace", desc = "l/h/Enter fold/eval; i inspect; e edit fn or paste var; d/D hide" },
			{ key = "[2] History", desc = "Previous session folded! h/l/H fold; Space select; p make proc" },
			{ key = "[2] v / e / Enter", desc = "Full cmd+error viewer / paste to REPL / re-run cmd" },
			{ key = "[3] Procedures (● ⚡ ◆)", desc = "● Disk  ⚡ Modified in memory  ◆ Live REPL fn  ○ Unloaded  ✗ Error" },
			{ key = "[3] e / E / c", desc = "Edit clean fn in julia> REPL / open $EDITOR -> Main / paste call" },
			{ key = "[3] R / S / Enter", desc = "Reload from disk (reset ⚡) / Save to procedures/ / Run (remembers args)" },
			{ key = "[3] F / v / J / K", desc = "Toggle Failed Commands sub-view / Full detail / Scroll preview" },
			{ key = "[4] Packages", desc = "a add package / d remove package / u update packages" },
		},
	},
}

-- Search & Filter state
local search_mode = false
local search_query = ""

-- Modal dialog state
local modal_active = false
local modal_title = ""
local modal_input = ""
local modal_callback = nil

-- Toast notifications
local toast_msg = nil
local toast_expires = 0

local function set_toast(msg, duration)
	toast_msg = msg
	toast_expires = os.time() + (duration or 3)
	dirty = true
end

local function split_lines(s)
	local lines = {}
	for line in (s .. "\n"):gmatch("(.-)\r?\n") do
		table.insert(lines, line)
	end
	return lines
end

local display_rows = {}
local cursor = 1
local col_cursor = 1 -- 1: Name, 2: Type, 3: Value

local function is_selectable_row(dr)
	if not dr then
		return false
	end
	return dr.kind ~= "section"
		and dr.kind ~= "hist_note"
		and dr.kind ~= "guide_hdr"
		and dr.kind ~= "empty_search"
		and dr.kind ~= "empty_proc"
		and dr.kind ~= "msg"
end

-- ---------------------------------------------------------------------------
-- Read & refresh state
-- ---------------------------------------------------------------------------
local function file_mtime(path)
	local h = io.popen("stat -c %Y " .. path .. " 2>/dev/null")
	if not h then
		return 0
	end
	local v = tonumber(h:read("*l")) or 0
	h:close()
	return v
end

local function load_state()
	if socket_fd >= 0 and last_state_ts > 0 and (os.time() - last_state_ts) < 3 then
		return false
	end

	local mt = file_mtime(STATE_FILE)
	if mt == 0 then
		check_and_discover()
		mt = file_mtime(STATE_FILE)
	end
	if mt == 0 or mt == last_mtime then
		return false
	end
	last_mtime = mt

	local f = io.open(STATE_FILE, "r")
	if not f then
		return false
	end
	local content = f:read("*a")
	f:close()

	local ok, parsed = pcall(json_parse, content)
	if ok and parsed then
		apply_new_state(parsed)
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Build the flat display_rows list with search filter
-- ---------------------------------------------------------------------------
local function build_display_rows()
	display_rows = {}
	local q = (search_query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local has_filter = (q ~= "")

	-- Tab 5: Guide
	if active_tab == 5 then
		for _, sec in ipairs(GUIDE_SECTIONS) do
			local matched_items = {}
			local sec_match = has_filter and (sec.title:lower():find(q, 1, true) ~= nil)
			for _, item in ipairs(sec.items) do
				if not has_filter or sec_match
					or item.key:lower():find(q, 1, true)
					or item.desc:lower():find(q, 1, true)
				then
					table.insert(matched_items, item)
				end
			end
			if #matched_items > 0 then
				table.insert(display_rows, {
					kind = "guide_hdr",
					title = sec.title,
				})
				for _, item in ipairs(matched_items) do
					table.insert(display_rows, {
						kind = "guide_item",
						key = item.key,
						desc = item.desc,
					})
				end
			end
		end
		if #display_rows == 0 then
			display_rows[1] = { kind = "empty_search", text = "No guide entries matching \"" .. search_query .. "\"." }
		end
		return
	end

	-- Tab 4: Packages
	if active_tab == 4 then
		if not state or not state.packages then
			display_rows[1] = {
				kind = "msg",
				text = "Waiting for packages state…",
			}
			return
		end

		for _, pkg in ipairs(state.packages) do
			local pname = pkg.name or ""
			local pver = pkg.version or ""
			if not has_filter or pname:lower():find(q, 1, true) or pver:lower():find(q, 1, true) then
				table.insert(display_rows, {
					kind = "package",
					name = pname,
					version = pver,
				})
			end
		end

		if #display_rows == 0 then
			if has_filter then
				display_rows[1] = { kind = "empty_search", text = "No packages matching \"" .. search_query .. "\"." }
			else
				display_rows[1] = { kind = "msg", text = "No packages in active environment." }
			end
		end
		return
	end

	-- Tab 2: History (splits Previous Sessions vs Current Session; previous folded by default)
	if active_tab == 2 then
		local hist = state and state.history or {}
		local hstat = state and state.history_statuses or {}
		local prev_count = math.min(#hist, math.max(0, tonumber(state and state.history_prev_count) or 0))
		if #hist == 0 then
			display_rows[1] = {
				kind = "msg",
				text = "No REPL commands captured yet in this session.",
			}
			return
		end

		local matched_prev = {}
		local matched_curr = {}
		for i, cmd in ipairs(hist) do
			if not has_filter or cmd:lower():find(q, 1, true) then
				local entry = {
					kind = "history",
					idx = i,
					cmd = cmd,
					status = hstat[i] or "",
					is_prev = (i <= prev_count),
					selected = history_selected[i] or false,
				}
				if i <= prev_count then
					table.insert(matched_prev, entry)
				else
					table.insert(matched_curr, entry)
				end
			end
		end

		if prev_count > 0 then
			local is_collapsed = history_prev_collapsed and not has_filter
			if not has_filter or #matched_prev > 0 then
				local lbl = has_filter
					and string.format("Previous Sessions (%d/%d matches)", #matched_prev, prev_count)
					or string.format("Previous Sessions (%d)", prev_count)
				table.insert(display_rows, {
					kind = "hist_section",
					sec_id = "prev",
					title = lbl,
					collapsed = is_collapsed,
					count = prev_count,
				})
				if not is_collapsed then
					for _, r in ipairs(matched_prev) do
						table.insert(display_rows, r)
					end
				end
			end

			table.insert(display_rows, {
				kind = "section",
				text = string.format("Current Session (%d)", #matched_curr),
			})
			if #matched_curr > 0 then
				for _, r in ipairs(matched_curr) do
					table.insert(display_rows, r)
				end
			elseif not has_filter then
				table.insert(display_rows, {
					kind = "hist_note",
					text = "No commands executed in this session yet (run code in julia> or press [l] above).",
				})
			end
		else
			for _, r in ipairs(matched_curr) do
				table.insert(display_rows, r)
			end
		end

		if #display_rows == 0 or (has_filter and #matched_prev == 0 and #matched_curr == 0) then
			display_rows = { { kind = "empty_search", text = "No commands matching \"" .. search_query .. "\"." } }
		end
		return
	end

	-- Tab 3: Procedures (with separate [F] Failed Commands sub-view)
	if active_tab == 3 then
		local procs = state and state.procedures or {}
		local fcmds = state and state.failed_commands or {}

		if proc_errors_view then
			if #fcmds == 0 then
				display_rows[1] = {
					kind = "msg",
					text = "No failed commands recorded. Press [F] to return to Procedures.",
				}
				return
			end
			for i, fc in ipairs(fcmds) do
				local fcmd = fc.cmd or ""
				local ferr = fc.error or ""
				local fdet = fc.error_detail or ""
				local fstmt = fc.failed_stmt or ""
				local match = true
				if has_filter then
					match = (fcmd:lower():find(q, 1, true) ~= nil)
						or (ferr:lower():find(q, 1, true) ~= nil)
						or (fdet:lower():find(q, 1, true) ~= nil)
						or (fstmt:lower():find(q, 1, true) ~= nil)
				end
				if match then
					table.insert(display_rows, {
						kind = "failed_cmd",
						idx = i,
						id = tonumber(fc.id) or i,
						cmd = fcmd,
						source = fc.source or "repl",
						proc_name = fc.proc_name or "",
						error = ferr,
						error_detail = fdet,
						error_line = tonumber(fc.error_line) or 0,
						failed_stmt = fstmt,
						timestamp = fc.timestamp or "",
					})
				end
			end
			if #display_rows == 0 then
				display_rows[1] = { kind = "empty_search", text = "No failed commands matching \"" .. search_query .. "\"." }
			end
			return
		end

		if #procs == 0 then
			if #fcmds > 0 then
				display_rows[1] = {
					kind = "msg",
					text = "No procedures yet. " .. #fcmds .. " failed REPL command(s) — press [F] to inspect.",
				}
			else
				display_rows[1] = { kind = "empty_proc" }
			end
			return
		end

		for i, p in ipairs(procs) do
			local pname = p.name or ""
			local psig = p.signature or (pname .. "()")
			local pdoc = p.doc or ""
			local pfile = p.file or ""
			local pcode = p.code or ""
			local perr = p.last_error or ""
			local pcmd = p.last_run_cmd or ""

			local match = true
			if has_filter then
				match = (pname:lower():find(q, 1, true) ~= nil)
					or (psig:lower():find(q, 1, true) ~= nil)
					or (pdoc:lower():find(q, 1, true) ~= nil)
					or (pfile:lower():find(q, 1, true) ~= nil)
					or (pcode:lower():find(q, 1, true) ~= nil)
					or (perr:lower():find(q, 1, true) ~= nil)
					or (pcmd:lower():find(q, 1, true) ~= nil)
			end

			if match then
				table.insert(display_rows, {
					kind = "procedure",
					idx = i,
					name = pname,
					signature = psig,
					file = pfile,
					doc = pdoc,
					code = pcode,
					edit_code = p.edit_code or "",
					origin = p.origin or ((pfile ~= "") and "disk" or "live"),
					generation = tonumber(p.generation) or 1,
					func_start_line = tonumber(p.func_start_line) or 1,
					last_args = p.last_args or "",
					time_ms = p.time_ms or 0.0,
					alloc_bytes = p.alloc_bytes or 0,
					status = p.status or "never",
					last_run = p.last_run or "-",
					last_run_cmd = pcmd,
					last_error = perr,
					last_error_detail = p.last_error_detail or "",
					last_error_line = tonumber(p.last_error_line) or 0,
					last_error_cmd = p.last_error_cmd or "",
					needs_args = p.needs_args or false,
				})
			end
		end

		if #display_rows == 0 then
			display_rows[1] = { kind = "empty_search", text = "No procedures matching \"" .. search_query .. "\"." }
		end
		return
	end

	-- Tab 1: Workspace
	if not state or (not state.modules and not state.columns) then
		display_rows[1] = {
			kind = "msg",
			text = "Waiting for Julia watcher… (using jEMach)",
		}
		return
	end

	if state.columns then
		local cols = state.columns
		local count = #(cols.names or {})
		local skip_until_depth = -1
		local current_mod = nil

		for i = 1, count do
			local mname = (cols.modules and cols.modules[i]) or "Main"
			if not initialized_modules[mname] then
				initialized_modules[mname] = true
				collapsed[mname] = true
			end
			if mname ~= current_mod then
				current_mod = mname
				if not hidden[mname] then
					local is_collapsed = collapsed[mname] and not has_filter
					local icon = is_collapsed and "▶" or "▼"
					table.insert(display_rows, {
						kind = "module",
						name = mname,
						collapsed = is_collapsed,
						icon = icon,
					})
				end
			end

			if hidden[current_mod] or (collapsed[current_mod] and not has_filter) then
				goto continue
			end

			local depth = (cols.depths and cols.depths[i]) or 0
			if skip_until_depth >= 0 then
				if depth > skip_until_depth then
					goto continue
				else
					skip_until_depth = -1
				end
			end

			local iname = cols.names[i] or "?"
			local itype = (cols.types and cols.types[i]) or ""
			local ival = (cols.values and cols.values[i]) or ""
			local key = current_mod .. "/" .. ((cols.exprs and cols.exprs[i]) or iname)
			if hidden[key] then
				goto continue
			end

			if has_filter then
				local match = iname:lower():find(q, 1, true)
					or itype:lower():find(q, 1, true)
					or ival:lower():find(q, 1, true)
					or current_mod:lower():find(q, 1, true)
				if not match then
					goto continue
				end
			end

			local has_children = cols.has_children and cols.has_children[i] or false
			if has_children and not initialized_items[key] then
				initialized_items[key] = true
				collapsed[key] = true
			end
			local is_collapsed = collapsed[key]
			local icon = ""
			if has_children then
				icon = is_collapsed and "▶" or "▼"
			end

			table.insert(display_rows, {
				kind = "item",
				module_name = current_mod,
				name = iname,
				item_kind = (cols.kinds and cols.kinds[i]) or "variable",
				item_type = itype,
				value = ival,
				expr = (cols.exprs and cols.exprs[i]) or iname,
				depth = depth,
				path = key,
				has_children = has_children,
				collapsed = is_collapsed,
				icon = icon,
			})

			if has_children and is_collapsed then
				skip_until_depth = depth
			end

			::continue::
		end

		if #display_rows == 0 then
			if has_filter then
				display_rows[1] = { kind = "empty_search", text = "No variables matching \"" .. search_query .. "\"." }
			else
				display_rows[1] = { kind = "msg", text = "No variables in workspace." }
			end
		end
		return
	end

	-- Fallback for legacy state.modules structure
	local function add_item_rows(mname, item, depth, path)
		local iname = item.name or "?"
		local itype = item.type or ""
		local ival = item.value or ""
		local key = path .. "/" .. iname
		if hidden[key] then return end

		if has_filter then
			local match = iname:lower():find(q, 1, true)
				or itype:lower():find(q, 1, true)
				or ival:lower():find(q, 1, true)
			if not match then return end
		end

		local has_children = item.children and #item.children > 0
		if has_children and not initialized_items[key] then
			initialized_items[key] = true
			collapsed[key] = true
		end
		local is_collapsed = collapsed[key]
		local icon = ""
		if has_children then
			icon = is_collapsed and "▶" or "▼"
		end

		table.insert(display_rows, {
			kind = "item",
			module_name = mname,
			name = iname,
			item_kind = item.kind or "variable",
			item_type = itype,
			value = ival,
			expr = item.expr or iname,
			depth = depth,
			path = key,
			has_children = has_children,
			collapsed = is_collapsed,
			icon = icon,
		})

		if has_children and not is_collapsed then
			for _, child in ipairs(item.children) do
				add_item_rows(mname, child, depth + 1, key)
			end
		end
	end

	for _, mod in ipairs(state.modules or {}) do
		local mname = mod.name or "?"
		if not hidden[mname] then
			local is_collapsed = collapsed[mname]
			local icon = is_collapsed and "▶" or "▼"
			table.insert(display_rows, {
				kind = "module",
				name = mname,
				collapsed = is_collapsed,
				icon = icon,
			})

			if not is_collapsed and mod.items then
				for _, item in ipairs(mod.items) do
					add_item_rows(mname, item, 0, mname)
				end
			end
		end
	end

	if #display_rows == 0 then
		if has_filter then
			display_rows[1] = { kind = "empty_search", text = "No variables matching \"" .. search_query .. "\"." }
		else
			display_rows[1] = { kind = "msg", text = "Workspace is empty." }
		end
	end
end

-- ---------------------------------------------------------------------------
-- Clamp cursor & smooth scroll helpers
-- ---------------------------------------------------------------------------
local function clamp_cursor()
	local n = #display_rows
	if n == 0 then
		cursor = 1
		tab_cursors[active_tab] = cursor
		return
	end
	if cursor < 1 then
		cursor = 1
	elseif cursor > n then
		cursor = n
	end
	if not is_selectable_row(display_rows[cursor]) then
		local found = nil
		for i = cursor, n do
			if is_selectable_row(display_rows[i]) then
				found = i
				break
			end
		end
		if not found then
			for i = cursor - 1, 1, -1 do
				if is_selectable_row(display_rows[i]) then
					found = i
					break
				end
			end
		end
		cursor = found or 1
	end
	tab_cursors[active_tab] = cursor
end

local function move_cursor(delta)
	local n = #display_rows
	if n == 0 then
		return
	end
	local step = (delta >= 0) and 1 or -1
	local i = cursor + step
	while i >= 1 and i <= n do
		if is_selectable_row(display_rows[i]) then
			cursor = i
			tab_cursors[active_tab] = cursor
			return
		end
		i = i + step
	end
end

local function compute_win_start(total, view_h)
	local ws = tab_scrolls[active_tab] or 1
	if ws < 1 then
		ws = 1
	end
	if cursor < ws then
		ws = cursor
		if cursor > 1 and (display_rows[cursor - 1].kind == "section" or display_rows[cursor - 1].kind == "guide_hdr") then
			ws = cursor - 1
		end
	elseif cursor > ws + view_h - 1 then
		ws = cursor - view_h + 1
	end
	local max_ws = math.max(1, total - view_h + 1)
	if ws > max_ws then
		ws = max_ws
	end
	if ws < 1 then
		ws = 1
	end
	tab_scrolls[active_tab] = ws
	return ws
end

local function switch_tab(new_tab)
	tab_cursors[active_tab] = cursor
	active_tab = new_tab
	build_display_rows()
	cursor = tab_cursors[active_tab] or 1
	clamp_cursor()
	dirty = true
end

-- ---------------------------------------------------------------------------
-- Multi-Terminal & Multiplexer Backend + Bidirectional Socket RPC
-- (Supports: Ghostty, Kitty, tmux, Zellij, Rex, and Standalone terminals)
-- ---------------------------------------------------------------------------
local function detect_backend()
	local env_b = os.getenv("JEMACH_BACKEND")
	if env_b and env_b ~= "" and env_b ~= "auto" then
		return env_b:lower()
	end
	if os.getenv("REX_SESSION") or os.getenv("REX") or os.getenv("REX_PANE_ID") or os.getenv("GHOSTTY_REX") then
		return "rex"
	elseif os.getenv("ZELLIJ") or os.getenv("ZELLIJ_SESSION_NAME") then
		return "zellij"
	elseif os.getenv("TMUX") and os.getenv("TMUX") ~= "" then
		return "tmux"
	elseif os.getenv("KITTY_WINDOW_ID") or os.getenv("KITTY_PID") or os.getenv("TERM") == "xterm-kitty" then
		return "kitty"
	elseif (os.getenv("TERM_PROGRAM") or ""):lower() == "ghostty"
		or os.getenv("GHOSTTY_RESOURCES_DIR")
		or os.getenv("TERM") == "xterm-ghostty"
	then
		return "ghostty"
	elseif state and state.backend and state.backend ~= "" then
		return tostring(state.backend)
	end
	return "standalone"
end

local function get_backend_badge()
	local b = detect_backend()
	if b == "tmux" and repl_pane and repl_pane:match("^%%%d+$") then
		return "tmux:" .. repl_pane
	elseif b == "kitty" and repl_pane and repl_pane:match("^%d+$") then
		return "kitty:" .. repl_pane
	end
	return b
end

local function json_escape(s)
	s = tostring(s or "")
	return (s:gsub("\\", "\\\\")
		:gsub('"', '\\"')
		:gsub("\n", "\\n")
		:gsub("\r", "\\r")
		:gsub("\t", "\\t"))
end

local function send_socket_json(json_line)
	try_connect_socket()
	if socket_fd < 0 then
		return false
	end
	local payload = json_line .. "\n"
	local written = tonumber(ffi.C.write(socket_fd, payload, #payload))
	if not written or written <= 0 then
		ffi.C.close(socket_fd)
		socket_fd = -1
		return false
	end
	return true
end

local function fallback_mux_send(code, enter)
	local b = detect_backend()
	local escaped = code:gsub("'", "'\\''")
	if b == "tmux" then
		if enter == false then
			os.execute(string.format("tmux send-keys -t '%s' '%s' 2>/dev/null", repl_pane, escaped))
		else
			os.execute(string.format("tmux send-keys -t '%s' '%s' Enter 2>/dev/null", repl_pane, escaped))
		end
	elseif b == "kitty" then
		local suffix = (enter == false) and "" or "\\r"
		local m = (repl_pane and repl_pane:match("^%d+$")) and ("--match id:" .. repl_pane) or ""
		os.execute(string.format("kitten @ send-text %s '%s%s' 2>/dev/null", m, escaped, suffix))
	elseif b == "zellij" then
		os.execute(string.format("zellij action write-chars '%s' 2>/dev/null", escaped))
	elseif b == "rex" then
		local rex_bin = os.getenv("JEMACH_REX_BIN") or "rex"
		os.execute(string.format("%s send-keys -t '%s' '%s' Enter 2>/dev/null", rex_bin, repl_pane, escaped))
	end
end

local function julia_quote_str(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	     :gsub('"', '\\"')
	     :gsub("%$", "\\$")
	     :gsub("\n", "\\n")
	     :gsub("\r", "\\r")
	     :gsub("\t", "\\t")
	return '"' .. s .. '"'
end

local function repl_eval(code, silent, record_history, filename, proc_name)
	local cmd_type = silent and "eval_silent" or "eval"
	local extra = ""
	if record_history == false then
		extra = extra .. ',"history":false'
	end
	if filename and filename ~= "" then
		extra = extra .. ',"filename":"' .. json_escape(filename) .. '"'
	end
	if proc_name and proc_name ~= "" then
		extra = extra .. ',"proc_name":"' .. json_escape(proc_name) .. '"'
	end
	local msg = string.format('{"cmd":"%s","code":"%s"%s}', cmd_type, json_escape(code), extra)
	if not send_socket_json(msg) then
		fallback_mux_send(code, true)
	end
end

local function focus_repl_pane()
	local b = detect_backend()
	if b == "tmux" and repl_pane and repl_pane ~= "" then
		os.execute(string.format("tmux select-pane -t '%s' 2>/dev/null", repl_pane:gsub("'", "'\\''")))
	elseif b == "kitty" and repl_pane and repl_pane:match("^%d+$") then
		os.execute(string.format("kitten @ focus-window --match id:%s 2>/dev/null", repl_pane))
	end
end

local function repl_replace_input(text, move_left)
	local ml = tonumber(move_left) or 0
	local msg = string.format('{"cmd":"replace_input","text":"%s","move_left":%d}', json_escape(text), ml)
	if not send_socket_json(msg) then
		fallback_mux_send(text, false)
	end
end

local function repl_insert(text, move_left)
	local ml = tonumber(move_left) or 0
	local msg = string.format('{"cmd":"insert","text":"%s","move_left":%d}', json_escape(text), ml)
	if not send_socket_json(msg) then
		local b = detect_backend()
		if b == "tmux" and ml == 1 then
			local escaped = text:gsub("'", "'\\''")
			os.execute(string.format("tmux send-keys -t '%s' '%s' Left 2>/dev/null", repl_pane, escaped))
		else
			fallback_mux_send(text, false)
		end
	end
end

local function repl_clear()
	local msg = '{"cmd":"clear"}'
	if not send_socket_json(msg) then
		local b = detect_backend()
		if b == "tmux" then
			os.execute(string.format("tmux send-keys -t '%s' C-l 2>/dev/null", repl_pane))
		end
	end
end

local function tmux_send(code)
	repl_eval(code, false)
end

-- ---------------------------------------------------------------------------
-- Preview builder (shared by Tab 3 split preview & full-screen detail viewer)
-- ---------------------------------------------------------------------------
local function apply_bg_to_highlighted(hl, bg, pad_w)
	local body = hl:gsub("\27%[0m", RESET .. bg)
	local fill = math.max(0, pad_w - visible_len(hl))
	return bg .. body .. string.rep(" ", fill) .. RESET
end

local function find_matching_failed_cmd(cmd)
	if not state or not state.failed_commands or not cmd or cmd == "" then
		return nil
	end
	local norm = cmd:gsub("^%s+", ""):gsub("%s+$", "")
	for i = #state.failed_commands, 1, -1 do
		local fc = state.failed_commands[i]
		local fnorm = (fc.cmd or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if fc.cmd == cmd or fnorm == norm then
			return fc
		end
	end
	return nil
end

local function fmt_bytes(b)
	b = tonumber(b) or 0
	if b >= 1048576 then
		return string.format("%.1fMB", b / 1048576)
	elseif b >= 1024 then
		return string.format("%.1fKB", b / 1024)
	end
	return string.format("%dB", b)
end

local function ws_col_widths(cols)
	local name_w = (cols >= 90) and 28 or math.max(14, math.floor(cols * 0.36))
	local type_w = (cols >= 90) and 22 or math.max(11, math.floor(cols * 0.25))
	local val_max = math.max(6, cols - name_w - type_w - 4)
	return name_w, type_w, val_max
end

local function origin_glyph_and_color(origin, status)
	if status == "error" then
		return "✗", FG_RED .. BOLD, false
	elseif origin == "modified" then
		return "◈", FG_YELLOW .. BOLD, false
	elseif origin == "live" then
		return "◆", FG_CYAN .. BOLD, false
	elseif origin == "unloaded" then
		return "○", DIM .. FG_GRAY, false
	else
		return "●", FG_GREEN, false
	end
end

local function build_item_preview_lines(dr, max_w, compact)
	local lines = {}
	if not dr then
		return { DIM .. FG_GRAY .. "  (Nothing selected)" .. RESET }
	end
	local w = math.max(20, max_w)

	local function add_section_title(color, title)
		table.insert(lines, color .. BOLD .. "  " .. truncate_visible(title, w - 2) .. RESET)
	end

	local function add_wrapped_lines(text, color, indent_str, highlight_jl)
		indent_str = indent_str or "    "
		local iw = visible_len(indent_str)
		local cw = math.max(10, w - iw)
		for _, raw_line in ipairs(split_lines(tostring(text or ""))) do
			local wrapped = wrap_text(raw_line, cw)
			for _, sub in ipairs(wrapped) do
				if highlight_jl then
					table.insert(lines, indent_str .. highlight_julia_line(sub))
				elseif color then
					table.insert(lines, indent_str .. color .. sub .. RESET)
				else
					table.insert(lines, indent_str .. sub)
				end
			end
		end
	end

	local function add_code_block(code_str, err_line)
		local raw_lines = split_lines(code_str)
		local gutter_w = (#raw_lines >= 100) and 7 or 6
		local code_w = math.max(8, w - gutter_w)
		for li, raw_line in ipairs(raw_lines) do
			local is_err = (err_line and err_line > 0 and li == err_line)
			local wrapped = wrap_text(raw_line, code_w)
			for wi, sub in ipairs(wrapped) do
				local gutter
				if wi == 1 then
					if is_err then
						local fmt = (gutter_w == 7) and "✗%3d │ " or "✗%2d │ "
						gutter = FG_RED .. BOLD .. string.format(fmt, li) .. RESET
					else
						local fmt = (gutter_w == 7) and "%4d " or "%3d "
						gutter = DIM .. FG_YELLOW .. string.format(fmt, li) .. RESET .. FG_DARK_GRAY .. "│ " .. RESET
					end
				else
					local sp = string.rep(" ", gutter_w - 4)
					if is_err then
						gutter = FG_RED .. sp .. "↪ │ " .. RESET
					else
						gutter = DIM .. FG_GRAY .. sp .. "↪ │ " .. RESET
					end
				end
				local hl = highlight_julia_line(sub)
				if is_err then
					table.insert(lines, gutter .. apply_bg_to_highlighted(hl, BG_ERR_LINE, code_w))
				else
					table.insert(lines, gutter .. hl)
				end
			end
		end
	end

	if dr.kind == "procedure" then
		if compact then
			if dr.code and dr.code ~= "" then
				add_code_block(dr.code, dr.last_error_line)
			else
				table.insert(lines, DIM .. FG_GRAY .. "    (No source code preview available)" .. RESET)
			end
			if dr.last_error_detail and dr.last_error_detail ~= "" then
				table.insert(lines, "")
				add_section_title(FG_ORANGE, "Stacktrace / Error Detail (scroll down or [v] full):")
				add_wrapped_lines(dr.last_error_detail, FG_LIGHT_GRAY, "  ", false)
			end
			return lines
		end

		local st_badge
		if dr.status == "ok" then
			st_badge = FG_GREEN .. BOLD .. "✓ OK" .. RESET
		elseif dr.status == "error" then
			st_badge = FG_RED .. BOLD .. "✗ ERROR" .. RESET
		else
			st_badge = DIM .. FG_GRAY .. "○ NEVER RUN" .. RESET
		end
		local orig = dr.origin or "disk"
		local orig_badge = (orig == "modified") and (FG_YELLOW .. BOLD .. "⚡ MOD v" .. tostring(dr.generation or 1) .. RESET)
			or (orig == "live") and (FG_CYAN .. BOLD .. "◆ LIVE" .. RESET)
			or (orig == "unloaded") and (DIM .. FG_GRAY .. "○ UNLOADED" .. RESET)
			or (FG_GREEN .. "● DISK" .. RESET)
		local hdr = "  " .. BOLD .. FG_CYAN .. (dr.signature or dr.name or "") .. RESET .. "  " .. orig_badge .. "  " .. st_badge
		table.insert(lines, truncate_visible(hdr, w) == strip_ansi(hdr) and hdr or ("  " .. truncate_visible(strip_ansi(hdr), w - 2)))

		local loc_str = (dr.file and dr.file ~= "") and dr.file or "(REPL memory — press [S] to save)"
		local meta = "File: " .. loc_str
		if dr.status ~= "never" then
			meta = meta .. string.format("  |  %.2fms  %s  (%s)", dr.time_ms or 0, fmt_bytes(dr.alloc_bytes or 0), dr.last_run or "-")
		end
		add_wrapped_lines(meta, DIM .. FG_GRAY, "  ", false)

		if dr.doc and dr.doc ~= "" then
			add_wrapped_lines(dr.doc, ITALIC .. FG_LIGHT_GRAY, "  ", false)
		end

		if dr.last_run_cmd and dr.last_run_cmd ~= "" then
			table.insert(lines, "")
			add_section_title(FG_AQUA, "▶ Last Call / Entered Command:")
			add_wrapped_lines(dr.last_run_cmd, nil, "    ", true)
		end

		if dr.status == "error" or (dr.last_error and dr.last_error ~= "") then
			table.insert(lines, "")
			local line_tag = (dr.last_error_line and dr.last_error_line > 0) and (" (line " .. dr.last_error_line .. ")") or ""
			add_section_title(FG_RED, "✗ Error" .. line_tag .. ":")
			add_wrapped_lines(dr.last_error ~= "" and dr.last_error or "(Error captured)", FG_RED .. BOLD, "    ", false)

			if dr.last_error_cmd and dr.last_error_cmd ~= "" and dr.last_error_cmd ~= dr.last_run_cmd then
				add_section_title(FG_ORANGE, "✗ Failing Statement:")
				add_wrapped_lines(dr.last_error_cmd, nil, "    ", true)
			end
		end

		table.insert(lines, "")
		add_section_title(FG_WHITE, "Source Code:")
		if dr.code and dr.code ~= "" then
			add_code_block(dr.code, dr.last_error_line)
		else
			table.insert(lines, DIM .. FG_GRAY .. "    (No source code preview available)" .. RESET)
		end

		if dr.last_error_detail and dr.last_error_detail ~= "" then
			table.insert(lines, "")
			add_section_title(FG_ORANGE, "Stacktrace / Error Detail:")
			add_wrapped_lines(dr.last_error_detail, FG_LIGHT_GRAY, "    ", false)
		end

	elseif dr.kind == "failed_cmd" then
		local src_tag = (dr.source and dr.source ~= "") and ("[" .. dr.source .. "] ") or ""
		local ts_tag = (dr.timestamp and dr.timestamp ~= "") and ("  " .. dr.timestamp) or ""
		local hdr = FG_RED .. BOLD .. "  ✗ FAILED COMMAND #" .. tostring(dr.id or "") .. RESET
			.. "  " .. FG_YELLOW .. src_tag .. RESET .. DIM .. FG_GRAY .. ts_tag .. RESET
		table.insert(lines, hdr)

		table.insert(lines, "")
		local line_tag = (dr.error_line and dr.error_line > 0) and (" (line " .. dr.error_line .. ")") or ""
		add_section_title(FG_RED, "✗ Error" .. line_tag .. ":")
		add_wrapped_lines(dr.error ~= "" and dr.error or "(Error)", FG_RED .. BOLD, "    ", false)

		if dr.failed_stmt and dr.failed_stmt ~= "" then
			table.insert(lines, "")
			add_section_title(FG_ORANGE, "✗ Failing Statement:")
			add_wrapped_lines(dr.failed_stmt, nil, "    ", true)
		end

		table.insert(lines, "")
		add_section_title(FG_AQUA, "▶ Full Entered Command:")
		if dr.cmd and dr.cmd ~= "" then
			add_code_block(dr.cmd, dr.error_line)
		else
			table.insert(lines, DIM .. FG_GRAY .. "    (empty command)" .. RESET)
		end

		if dr.error_detail and dr.error_detail ~= "" then
			table.insert(lines, "")
			add_section_title(FG_ORANGE, "Stacktrace / Error Detail:")
			add_wrapped_lines(dr.error_detail, FG_LIGHT_GRAY, "    ", false)
		end

	elseif dr.kind == "history" then
		local st_badge
		if dr.status == "error" then
			st_badge = FG_RED .. BOLD .. "✗ ERROR" .. RESET
		elseif dr.status == "ok" then
			st_badge = FG_GREEN .. BOLD .. "✓ OK" .. RESET
		else
			st_badge = DIM .. FG_GRAY .. "○ UNKNOWN" .. RESET
		end
		table.insert(lines, "  " .. FG_YELLOW .. BOLD .. "History #" .. tostring(dr.idx or "") .. RESET .. "  " .. st_badge)

		local matched_fc = find_matching_failed_cmd(dr.cmd)
		local err_line = matched_fc and tonumber(matched_fc.error_line) or 0

		table.insert(lines, "")
		add_section_title(FG_AQUA, "▶ Full Entered Command:")
		add_code_block(dr.cmd or "", err_line)

		if matched_fc then
			table.insert(lines, "")
			local line_tag = (err_line > 0) and (" (line " .. err_line .. ")") or ""
			add_section_title(FG_RED, "✗ Error" .. line_tag .. ":")
			add_wrapped_lines(matched_fc.error or "(Error)", FG_RED .. BOLD, "    ", false)
			if matched_fc.failed_stmt and matched_fc.failed_stmt ~= "" then
				table.insert(lines, "")
				add_section_title(FG_ORANGE, "✗ Failing Statement:")
				add_wrapped_lines(matched_fc.failed_stmt, nil, "    ", true)
			end
			if matched_fc.error_detail and matched_fc.error_detail ~= "" then
				table.insert(lines, "")
				add_section_title(FG_ORANGE, "Stacktrace / Error Detail:")
				add_wrapped_lines(matched_fc.error_detail, FG_LIGHT_GRAY, "    ", false)
			end
		elseif dr.status == "error" then
			table.insert(lines, "")
			add_section_title(FG_RED, "✗ Command ended with an error (details no longer in recent error buffer).")
		end
	else
		table.insert(lines, DIM .. FG_GRAY .. "  (No detail preview for this item)" .. RESET)
	end

	return lines
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
local function render_tab_bar(out_buf, term_cols, procs, fcmds)
	local err_proc_count = 0
	local mod_proc_count = 0
	for _, p in ipairs(procs) do
		if p.status == "error" then
			err_proc_count = err_proc_count + 1
		end
		if p.origin == "modified" or p.origin == "live" then
			mod_proc_count = mod_proc_count + 1
		end
	end
	local total_err_count = err_proc_count + #fcmds

	table.insert(out_buf, move(1, 1))
	local compact_tabs = (term_cols <= 85)
	local tab_labels = compact_tabs and TAB_SHORT or TAB_NAMES
	local max_tab_idx = guide_tab_open and 5 or 4

	local tab_parts = {}
	local lead = BOLD .. FG_CYAN .. (compact_tabs and "◆" or "◆ jEMach") .. RESET
	table.insert(tab_parts, lead)
	local sep = compact_tabs and "" or " "
	local cur_tab_x = visible_len(lead) + 1 + #sep

	for i = 1, max_tab_idx do
		local name = tab_labels[i]
		local key_lbl = (i == 5) and "?" or tostring(i)
		local badge = ""
		local badge_colored = false

		if i == 2 and state and state.history and #state.history > 0 then
			if not compact_tabs then
				badge = " (" .. #state.history .. ")"
			end
		elseif i == 3 then
			if total_err_count > 0 then
				if compact_tabs then
					badge = " " .. FG_RED .. BOLD .. "✗" .. total_err_count .. RESET
				else
					badge = " (" .. #procs .. " " .. FG_RED .. BOLD .. "✗" .. total_err_count .. RESET .. (active_tab == 3 and (BOLD .. FG_WHITE .. BG_TAB_ACT) or (DIM .. FG_WHITE)) .. ")"
				end
				badge_colored = true
			elseif mod_proc_count > 0 then
				if compact_tabs then
					badge = " " .. FG_YELLOW .. BOLD .. "⚡" .. mod_proc_count .. RESET
				else
					badge = " (" .. #procs .. " " .. FG_YELLOW .. BOLD .. "⚡" .. mod_proc_count .. RESET .. (active_tab == 3 and (BOLD .. FG_WHITE .. BG_TAB_ACT) or (DIM .. FG_WHITE)) .. ")"
				end
				badge_colored = true
			elseif #procs > 0 and not compact_tabs then
				badge = " (" .. #procs .. ")"
			end
		elseif i == 4 and state and state.packages and #state.packages > 0 then
			if not compact_tabs then
				badge = " (" .. #state.packages .. ")"
			end
		end

		local t_str
		if badge_colored then
			if i == active_tab then
				t_str = BOLD .. FG_WHITE .. BG_TAB_ACT .. " [" .. key_lbl .. "] " .. name .. badge .. " " .. RESET
			else
				t_str = DIM .. FG_WHITE .. " [" .. key_lbl .. "] " .. name .. badge .. " " .. RESET
			end
			table.insert(tab_parts, t_str)
		else
			local raw_t = " [" .. key_lbl .. "] " .. name .. badge .. " "
			if i == active_tab then
				t_str = BOLD .. FG_WHITE .. BG_TAB_ACT .. raw_t .. RESET
			else
				t_str = DIM .. FG_WHITE .. raw_t .. RESET
			end
			table.insert(tab_parts, t_str)
		end
		local t_w = visible_len(t_str)
		table.insert(tab_hitboxes, { x1 = cur_tab_x, x2 = cur_tab_x + t_w - 1, tab = i })
		cur_tab_x = cur_tab_x + t_w + #sep
	end

	local match_count = #display_rows
	if #display_rows == 1 and (display_rows[1].kind == "empty_search" or display_rows[1].kind == "empty_proc" or display_rows[1].kind == "msg") then
		match_count = 0
	end

	if search_query ~= "" then
		table.insert(tab_parts, BOLD .. FG_YELLOW .. " 🔍 \"" .. search_query .. "\" (" .. match_count .. ") " .. RESET)
	end

	local left_title = table.concat(tab_parts, compact_tabs and "" or " ")
	local right_info
	if toast_msg and os.time() <= toast_expires then
		right_info = REV .. BOLD .. FG_GREEN .. " ⚡ " .. truncate_visible(toast_msg, math.max(10, term_cols - 20)) .. " " .. RESET
	else
		if compact_tabs then
			local sock_dot = (socket_fd >= 0) and (FG_GREEN .. "●" .. RESET) or (DIM .. FG_RED .. "○" .. RESET)
			local ts_str = (last_state_ts > 0) and os.date("%H:%M", last_state_ts) or "--:--"
			right_info = sock_dot .. " " .. DIM .. FG_GRAY .. ts_str .. RESET
		else
			local sock_icon = (socket_fd >= 0) and (FG_GREEN .. "● ONLINE" .. RESET) or (DIM .. FG_RED .. "○ OFFLINE" .. RESET)
			local ts_str = (last_state_ts > 0) and os.date("%H:%M:%S", last_state_ts) or "--:--:--"
			right_info = DIM .. FG_GRAY .. "[" .. get_backend_badge() .. "] " .. RESET .. sock_icon .. " " .. DIM .. FG_GRAY .. ts_str .. RESET
		end
	end

	local left_len = visible_len(left_title)
	local right_len = visible_len(right_info)
	if left_len + right_len + 1 > term_cols then
		local avail_left = math.max(8, term_cols - right_len - 1)
		left_title = truncate_visible(left_title, avail_left)
		left_len = visible_len(left_title)
	end
	local spacer_len = math.max(1, term_cols - left_len - right_len)
	table.insert(out_buf, left_title .. string.rep(" ", spacer_len) .. right_info)
	return match_count
end

local function render_detail_view(out_buf, term_rows, term_cols)
	local box_w = math.max(20, term_cols)
	local inner_w = math.max(14, box_w - 4)
	local view_h = math.max(1, term_rows - 4)

	local preview_lines = build_item_preview_lines(detail_item, inner_w)
	local total_lines = #preview_lines
	local max_scroll = math.max(0, total_lines - view_h)
	if detail_scroll > max_scroll then
		detail_scroll = max_scroll
	end
	if detail_scroll < 0 then
		detail_scroll = 0
	end

	local item_label = detail_item.name or (detail_item.id and ("Failed #" .. detail_item.id)) or (detail_item.idx and ("History #" .. detail_item.idx)) or "Item"
	local scroll_tag = string.format("[%d-%d/%d]", math.min(total_lines, detail_scroll + 1), math.min(total_lines, detail_scroll + view_h), total_lines)
	local dtitle = " Detail: " .. truncate_visible(item_label, math.max(8, box_w - 28)) .. " " .. scroll_tag .. " "
	local dfill = math.max(0, box_w - visible_len(dtitle) - 4)
	table.insert(out_buf, move(2, 1))
	table.insert(out_buf, FG_AQUA .. "╭─" .. BOLD .. FG_WHITE .. dtitle .. RESET .. FG_AQUA .. string.rep("─", dfill) .. "─╮" .. RESET)

	for ri = 1, view_h do
		local row = 2 + ri
		local lidx = detail_scroll + ri
		table.insert(out_buf, move(row, 1))
		local lstr = preview_lines[lidx] or ""
		if visible_len(lstr) > inner_w then
			lstr = truncate_visible(lstr, inner_w)
		end
		table.insert(out_buf, FG_AQUA .. "│ " .. RESET .. pad_right(lstr, inner_w) .. FG_AQUA .. " │" .. RESET)
	end

	local bot_hint = " [j/k] Scroll  [↵] Run  [e] Edit REPL  [E] $EDITOR  [c] Call  [v/Esc] Close "
	local bot_vis = truncate_visible(bot_hint, math.max(0, box_w - 4))
	local bfill = math.max(0, box_w - visible_len(bot_vis) - 3)
	table.insert(out_buf, move(term_rows - 1, 1))
	table.insert(out_buf, FG_AQUA .. "╰" .. string.rep("─", bfill) .. DIM .. FG_LIGHT_GRAY .. bot_vis .. RESET .. FG_AQUA .. "─╯" .. RESET)

	table.insert(out_buf, move(term_rows, 1))
	local function pill(k, d)
		return BOLD .. FG_CYAN .. "[" .. k .. "]" .. RESET .. DIM .. FG_LIGHT_GRAY .. d .. " " .. RESET
	end
	local help = pill("j/k", "Scroll") .. pill("PgUp/Dn", "Page") .. pill("↵", "Run") .. pill("e", "Edit") .. pill("E", "$ED") .. pill("c", "Call") .. pill("v/Esc", "Close") .. pill("q", "Quit")
	table.insert(out_buf, pad_right(" " .. truncate_visible(help, math.max(1, term_cols - 1)), term_cols))
end

local function render_footer_pills(out_buf, term_rows, term_cols)
	table.insert(out_buf, move(term_rows, 1))
	local pills = {}
	if active_tab == 1 then
		pills = {
			{ k = "/", d = "Find", act = "/" },
			{ k = "h/l", d = "Fold", act = "l" },
			{ k = "↵", d = "Eval", act = "\r" },
			{ k = "e", d = "Edit/Use", act = "e" },
			{ k = "i", d = "Insp", act = "i" },
			{ k = "m", d = mouse_enabled and "Ms" or "Ms∅", act = "m" },
			{ k = "?", d = "Guide", act = "?" },
			{ k = "q", d = "Quit", act = "q" },
		}
	elseif active_tab == 2 then
		pills = {
			{ k = "Spc", d = "Sel", act = " " },
			{ k = "h/l", d = "Fold", act = "H" },
			{ k = "p", d = "Proc", act = "p" },
			{ k = "e", d = "Paste", act = "e" },
			{ k = "↵", d = "Run", act = "\r" },
			{ k = "v", d = "View", act = "v" },
			{ k = "?", d = "Guide", act = "?" },
			{ k = "q", d = "Quit", act = "q" },
		}
	elseif active_tab == 3 then
		if proc_errors_view then
			pills = {
				{ k = "F", d = "Procs", act = "F" },
				{ k = "↵", d = "Retry", act = "\r" },
				{ k = "e", d = "Edit", act = "e" },
				{ k = "d", d = "Del", act = "d" },
				{ k = "D", d = "Clr", act = "D" },
				{ k = "v", d = "View", act = "v" },
				{ k = "m", d = mouse_enabled and "Ms" or "Ms∅", act = "m" },
				{ k = "q", d = "Quit", act = "q" },
			}
		else
			pills = {
				{ k = "↵", d = "Run", act = "\r" },
				{ k = "e", d = "Edit", act = "e" },
				{ k = "E", d = "$ED", act = "E" },
				{ k = "c", d = "Call", act = "c" },
				{ k = "S", d = "Save", act = "S" },
				{ k = "R", d = "Load", act = "R" },
				{ k = "F", d = "Err", act = "F" },
				{ k = "v", d = "View", act = "v" },
				{ k = "d", d = "Del", act = "d" },
				{ k = "m", d = mouse_enabled and "Ms" or "Ms∅", act = "m" },
				{ k = "?", d = "Guide", act = "?" },
				{ k = "q", d = "Quit", act = "q" },
			}
		end
	elseif active_tab == 4 then
		pills = {
			{ k = "/", d = "Find", act = "/" },
			{ k = "a", d = "Add", act = "a" },
			{ k = "d", d = "Rm", act = "d" },
			{ k = "u", d = "Upd", act = "u" },
			{ k = "?", d = "Guide", act = "?" },
			{ k = "q", d = "Quit", act = "q" },
		}
	elseif active_tab == 5 then
		pills = {
			{ k = "/", d = "Find", act = "/" },
			{ k = "j/k", d = "Nav", act = "j" },
			{ k = "1-4", d = "Tabs", act = "1" },
			{ k = "?/Esc", d = "Close", act = "?" },
			{ k = "q", d = "Quit", act = "q" },
		}
	end

	local pill_parts = { " " }
	local cur_x = 2
	for _, p in ipairs(pills) do
		local kpart = "[" .. p.k .. "]"
		local lpart = p.d .. " "
		local pw = visible_len(kpart) + visible_len(lpart)
		if cur_x + pw > term_cols then
			break
		end
		table.insert(action_hitboxes, { x1 = cur_x, x2 = cur_x + pw - 2, key = p.act })
		table.insert(pill_parts, BOLD .. FG_CYAN .. kpart .. RESET .. DIM .. FG_LIGHT_GRAY .. lpart .. RESET)
		cur_x = cur_x + pw
	end
	table.insert(out_buf, pad_right(table.concat(pill_parts), term_cols))
end

local function render_modal(out_buf, term_rows, term_cols)
	local box_w = math.max(24, math.min(56, term_cols - 4))
	local inner = math.max(10, box_w - 2)
	local box_h = 5
	local top = math.max(2, math.floor((term_rows - box_h) / 2))
	local left = math.max(1, math.floor((term_cols - box_w) / 2))

	local title = " " .. truncate_visible(modal_title, math.max(6, box_w - 8)) .. " "
	local fill_w = math.max(0, box_w - 4 - visible_len(title))
	local top_border = "╭─" .. BOLD .. FG_WHITE .. title .. RESET .. FG_CYAN .. string.rep("─", fill_w) .. "╮"
	local bot_border = "╰" .. string.rep("─", inner) .. "╯"
	local prompt_line = "  Input: " .. BOLD .. FG_YELLOW .. truncate_visible(modal_input, math.max(4, inner - 11)) .. RESET .. REV .. " " .. RESET
	local hint_line = "  " .. FG_GREEN .. "[↵]" .. RESET .. DIM .. " OK  " .. RESET .. FG_YELLOW .. "[C-u]" .. RESET .. DIM .. " Clr  " .. RESET .. FG_RED .. "[Esc]" .. RESET .. DIM .. " Cancel" .. RESET

	table.insert(out_buf, move(top, left) .. BOLD .. FG_CYAN .. top_border .. RESET)
	table.insert(out_buf, move(top + 1, left) .. BOLD .. FG_CYAN .. "│" .. RESET .. pad_right(prompt_line, inner) .. BOLD .. FG_CYAN .. "│" .. RESET)
	table.insert(out_buf, move(top + 2, left) .. BOLD .. FG_CYAN .. "│" .. RESET .. pad_right(truncate_visible(hint_line, inner), inner) .. BOLD .. FG_CYAN .. "│" .. RESET)
	table.insert(out_buf, move(top + 3, left) .. BOLD .. FG_CYAN .. bot_border .. RESET)
end

local function render(term_rows, term_cols)
	local out_buf = {}
	table.insert(out_buf, SYNC_START .. HIDE_CUR .. CLEAR)
	tab_hitboxes = {}
	row_hitboxes = {}
	action_hitboxes = {}
	header_err_hitbox = nil
	preview_split_row = 0

	local procs = state and state.procedures or {}
	local fcmds = state and state.failed_commands or {}

	-- Row 1: Header / Tab bar
	local match_count = render_tab_bar(out_buf, term_cols, procs, fcmds)

	if detail_view_active and detail_item then
		render_detail_view(out_buf, term_rows, term_cols)
	else

	-- Row 2: Top Separator
	table.insert(out_buf, move(2, 1))
	table.insert(out_buf, FG_DARK_GRAY .. string.rep("─", term_cols) .. RESET)

	-- Row 3: Column Headers
	table.insert(out_buf, move(3, 1))
	local col_hdr = ""
	if active_tab == 1 then
		local nw, tw, _ = ws_col_widths(term_cols)
		col_hdr = DIM .. FG_AQUA .. pad_right("    NAME", nw) .. "  " .. pad_right("TYPE", tw) .. "  VALUE" .. RESET
	elseif active_tab == 2 then
		col_hdr = DIM .. FG_AQUA .. "   SEL  ST   #   COMMAND" .. RESET
	elseif active_tab == 3 then
		if proc_errors_view then
			local right_tag = "[F] ← Procs"
			local rw = #right_tag + 1
			local left_w = math.max(10, term_cols - rw)
			local left_hdr = pad_right("   ST  FAILED COMMAND / ERROR", left_w)
			header_err_hitbox = { x1 = left_w + 1, x2 = term_cols }
			col_hdr = DIM .. FG_RED .. truncate_visible(left_hdr, left_w) .. RESET .. BOLD .. FG_CYAN .. right_tag .. " " .. RESET
		else
			local right_tag = (#fcmds > 0) and ("[F] Err:" .. #fcmds) or "[● Disk ⚡Mem ◆Live]"
			local right_clr = (#fcmds > 0) and (BOLD .. FG_RED) or (DIM .. FG_GRAY)
			local rw = visible_len(right_tag) + 1
			local left_w = math.max(10, term_cols - rw)
			local left_txt = (term_cols >= 90)
				and "   ST  FUNCTION / SIGNATURE           STATUS / STATS           ORIGIN / FILE"
				or "   ST  FUNCTION               STATUS / STATE"
			header_err_hitbox = (#fcmds > 0) and { x1 = left_w + 1, x2 = term_cols } or nil
			col_hdr = DIM .. FG_AQUA .. pad_right(truncate_visible(left_txt, left_w), left_w) .. RESET .. right_clr .. right_tag .. " " .. RESET
		end
	elseif active_tab == 4 then
		col_hdr = DIM .. FG_AQUA .. "   PACKAGE                                  VERSION" .. RESET
	elseif active_tab == 5 then
		col_hdr = DIM .. FG_AQUA .. "   KEY / COMMAND              DESCRIPTION" .. RESET
	end
	table.insert(out_buf, pad_right(truncate_visible(col_hdr, term_cols), term_cols))

	-- Row 4: Subtle Header Divider
	table.insert(out_buf, move(4, 1))
	table.insert(out_buf, FG_DARK_GRAY .. string.rep("┄", term_cols) .. RESET)

	local header_rows = 4
	local content_rows = math.max(1, term_rows - header_rows - 2)
	local total = #display_rows

	local is_proc_split = (
		active_tab == 3
		and total > 0
		and display_rows[1].kind ~= "empty_proc"
		and display_rows[1].kind ~= "empty_search"
		and display_rows[1].kind ~= "msg"
	)

	if is_proc_split then
		-- Split view for procedures / failed commands: top list, bottom clean panel preview
		local list_max_h = math.min(total, math.max(3, math.floor(content_rows * 0.36)))
		local preview_h = math.max(2, content_rows - list_max_h - 1)
		local win_start = compute_win_start(total, list_max_h)

		local row_idx = header_rows + 1
		for i = win_start, math.min(win_start + list_max_h - 1, total) do
			local dr = display_rows[i]
			local sel = (i == cursor)
			row_hitboxes[row_idx] = i
			table.insert(out_buf, move(row_idx, 1))

			if dr.kind == "section" then
				local sec_color = dr.is_error and FG_RED or FG_AQUA
				local sec_title = " ── " .. (dr.text or "") .. " "
				local fill_w = math.max(0, term_cols - visible_len(sec_title))
				table.insert(out_buf, BOLD .. sec_color .. sec_title .. FG_DARK_GRAY .. string.rep("─", fill_w) .. RESET)
			elseif dr.kind == "procedure" then
				local glyph, gclr, gwide = origin_glyph_and_color(dr.origin, dr.status)
				local sel_bar = sel and (FG_CYAN .. BOLD .. "▸" .. RESET) or " "
				local icon = sel_bar .. gclr .. glyph .. (gwide and "" or " ") .. RESET

				local avail = math.max(10, term_cols - 3)
				local metrics
				if dr.status == "error" then
					local err_short = (dr.last_error or "Error"):gsub("%s+", " ")
					local ltag = (dr.last_error_line and dr.last_error_line > 0) and ("L" .. dr.last_error_line .. " ") or ""
					local mod_tag = (dr.origin == "modified") and ("⚡v" .. tostring(dr.generation or 1) .. " ") or ""
					metrics = mod_tag .. "✗ " .. ltag .. err_short
				elseif dr.origin == "modified" then
					if dr.status ~= "never" then
						metrics = string.format("⚡v%d  %.1fms %s", dr.generation or 1, dr.time_ms, fmt_bytes(dr.alloc_bytes))
					else
						metrics = string.format("⚡v%d  in memory", dr.generation or 1)
					end
				elseif dr.origin == "live" then
					if dr.status ~= "never" then
						metrics = string.format("◆ live  %.1fms %s", dr.time_ms, fmt_bytes(dr.alloc_bytes))
					else
						metrics = "◆ live (memory)"
					end
				elseif dr.origin == "unloaded" then
					metrics = "○ on disk"
				elseif dr.status ~= "never" then
					metrics = string.format("%.1fms %s %s", dr.time_ms, fmt_bytes(dr.alloc_bytes), dr.last_run)
				else
					metrics = "never run"
				end

				local show_file = (term_cols >= 90)
				local sig_w = show_file and 32 or math.max(14, math.floor(avail * 0.48))
				local met_w = show_file and 25 or math.max(10, avail - sig_w - 1)
				local file_w = show_file and math.max(0, avail - sig_w - met_w - 2) or 0

				local sig_col = pad_right(truncate_visible(dr.signature, sig_w), sig_w)
				local met_col = pad_right(truncate_visible(metrics, met_w), met_w)
				local file_txt = (dr.file and dr.file ~= "") and dr.file or "(REPL memory)"
				local file_col = show_file and (" " .. DIM .. FG_GRAY .. pad_right(truncate_visible(file_txt, file_w), file_w) .. RESET) or ""

				local met_color = (dr.status == "error") and (FG_RED .. BOLD)
					or (dr.origin == "modified") and FG_YELLOW
					or (dr.origin == "live") and FG_CYAN
					or FG_YELLOW
				local name_color = (dr.status == "error") and FG_RED
					or (dr.origin == "modified") and FG_YELLOW
					or (dr.origin == "live") and FG_CYAN
					or FG_WHITE

				if sel then
					local sel_bg = (dr.status == "error") and FG_RED
						or (dr.origin == "modified") and FG_YELLOW
						or FG_CYAN
					table.insert(out_buf, icon .. REV .. BOLD .. sel_bg .. sig_col .. RESET .. " " .. met_color .. met_col .. RESET .. file_col)
				else
					table.insert(out_buf, icon .. BOLD .. name_color .. sig_col .. RESET .. " " .. met_color .. met_col .. RESET .. file_col)
				end
			elseif dr.kind == "failed_cmd" then
				local sel_bar = sel and (FG_RED .. BOLD .. "▸" .. RESET) or " "
				local icon = sel_bar .. FG_RED .. BOLD .. "✗ " .. RESET
				local avail = math.max(10, term_cols - 3)
				local cmd_one = (dr.cmd or ""):gsub("%s+", " ")
				local err_short = (dr.error or "Error"):gsub("%s+", " ")
				local cmd_w = math.max(12, math.floor(avail * 0.52))
				local err_w = math.max(8, avail - cmd_w - 1)

				local cmd_col = pad_right(truncate_visible(cmd_one, cmd_w), cmd_w)
				local err_col = pad_right(truncate_visible(err_short, err_w), err_w)
				if sel then
					table.insert(out_buf, icon .. REV .. BOLD .. FG_RED .. cmd_col .. RESET .. " " .. FG_ORANGE .. err_col .. RESET)
				else
					table.insert(out_buf, icon .. FG_WHITE .. cmd_col .. RESET .. " " .. FG_RED .. err_col .. RESET)
				end
			end
			row_idx = row_idx + 1
		end

		local sel_proc = display_rows[cursor]
		local cur_pkey = ""
		if sel_proc then
			if sel_proc.kind == "procedure" then
				cur_pkey = "p:" .. (sel_proc.name or "")
			elseif sel_proc.kind == "failed_cmd" then
				cur_pkey = "f:" .. tostring(sel_proc.id or "")
			end
		end

		local has_sticky_err = sel_proc and sel_proc.kind == "procedure" and sel_proc.status == "error"
			and preview_h >= 4 and (sel_proc.last_error or "") ~= ""
		local err_strip_h = has_sticky_err and 1 or 0
		local code_view_h = math.max(1, preview_h - err_strip_h)

		-- Build compact preview lines before separator to compute accurate line range & auto-scroll
		local preview_lines = build_item_preview_lines(sel_proc, term_cols, true)
		if cur_pkey ~= last_proc_preview_key then
			last_proc_preview_key = cur_pkey
			if sel_proc and sel_proc.kind == "procedure" then
				if sel_proc.last_error_line and sel_proc.last_error_line > 0 then
					proc_preview_scroll = math.max(0, sel_proc.last_error_line - math.max(2, math.floor(code_view_h / 2)))
				else
					proc_preview_scroll = math.max(0, (sel_proc.func_start_line or 1) - 1)
				end
			else
				proc_preview_scroll = 0
			end
		end

		local max_pscroll = math.max(0, #preview_lines - code_view_h)
		if proc_preview_scroll > max_pscroll then
			proc_preview_scroll = max_pscroll
		end
		if proc_preview_scroll < 0 then
			proc_preview_scroll = 0
		end

		-- Clean full-width BG_PANEL preview header bar (no broken floating corners)
		local split_row = header_rows + 1 + list_max_h
		preview_split_row = split_row
		table.insert(out_buf, move(split_row, 1))
		local p_left = " Preview"
		if sel_proc and sel_proc.kind == "procedure" then
			local glyph, gclr = origin_glyph_and_color(sel_proc.origin, sel_proc.status)
			local orig_lbl = (sel_proc.origin == "modified") and ("⚡v" .. tostring(sel_proc.generation or 1))
				or (sel_proc.origin == "live") and "◆ LIVE"
				or (sel_proc.origin == "unloaded") and "○ DISK"
				or "● DISK"
			local fname_short = (sel_proc.file and sel_proc.file ~= "") and (sel_proc.file:match("[^/]+$") or sel_proc.file) or ""
			local file_part = (fname_short ~= "" and fname_short ~= ((sel_proc.name or "") .. ".jl")) and (" · " .. fname_short) or ""
			local stat_part = (sel_proc.status ~= "never")
				and string.format(" · %.1fms %s", sel_proc.time_ms or 0, fmt_bytes(sel_proc.alloc_bytes or 0))
				or ""
			p_left = " " .. gclr .. glyph .. RESET .. " "
				.. BOLD .. FG_WHITE .. (sel_proc.name or "proc") .. RESET
				.. DIM .. FG_GRAY .. " [" .. orig_lbl .. file_part .. stat_part .. "]" .. RESET
		elseif sel_proc and sel_proc.kind == "failed_cmd" then
			p_left = " " .. FG_RED .. BOLD .. "✗ Failed Cmd #" .. tostring(sel_proc.id or "") .. RESET
				.. DIM .. FG_GRAY .. " [" .. (sel_proc.source or "repl") .. "]" .. RESET
		end

		local scroll_info = (#preview_lines > code_view_h)
			and string.format(" [L%d-%d/%d J/K] ", proc_preview_scroll + 1, math.min(#preview_lines, proc_preview_scroll + code_view_h), #preview_lines)
			or " [v full] "
		local max_pleft_w = math.max(8, term_cols - visible_len(scroll_info) - 1)
		local pleft_vis = truncate_visible(p_left, max_pleft_w)
		local fill_sp = math.max(0, term_cols - visible_len(pleft_vis) - visible_len(scroll_info))
		local hdr_line = pleft_vis .. string.rep(" ", fill_sp) .. DIM .. FG_LIGHT_GRAY .. scroll_info .. RESET
		table.insert(out_buf, BG_PANEL .. hdr_line:gsub("\27%[0m", RESET .. BG_PANEL) .. RESET)

		local preview_row = split_row + 1
		if has_sticky_err and preview_row <= term_rows - 2 then
			table.insert(out_buf, move(preview_row, 1))
			local ltag = (sel_proc.last_error_line and sel_proc.last_error_line > 0) and ("L" .. sel_proc.last_error_line .. ": ") or ""
			local err_txt = " ✗ " .. ltag .. ((sel_proc.last_error or ""):gsub("%s+", " "))
			if sel_proc.last_run_cmd and sel_proc.last_run_cmd ~= "" then
				err_txt = err_txt .. "  (" .. sel_proc.last_run_cmd:gsub("%s+", " ") .. ")"
			end
			local etrunc = truncate_visible(err_txt, term_cols)
			local epad = math.max(0, term_cols - visible_len(etrunc))
			table.insert(out_buf, BG_ERR_LINE .. FG_RED .. BOLD .. etrunc .. string.rep(" ", epad) .. RESET)
			preview_row = preview_row + 1
		end

		-- Preview body (scrollable + wrapped source code)
		for li = 1, code_view_h do
			if preview_row > term_rows - 2 then
				break
			end
			local pline = preview_lines[proc_preview_scroll + li]
			if not pline then
				break
			end
			table.insert(out_buf, move(preview_row, 1))
			if visible_len(pline) > term_cols then
				pline = truncate_visible(pline, term_cols)
			end
			table.insert(out_buf, pline)
			preview_row = preview_row + 1
		end
	else
		-- Full height list for Workspace, History, Packages, Guide (and empty states)
		local win_start = compute_win_start(total, content_rows)

		local row_idx = header_rows + 1
		for i = win_start, math.min(win_start + content_rows - 1, total) do
			local dr = display_rows[i]
			local sel = (i == cursor)
			row_hitboxes[row_idx] = i
			table.insert(out_buf, move(row_idx, 1))

			if dr.kind == "module" then
				local icon = dr.collapsed and "▶" or "▼"
				local line = string.format("  %s %-20s", icon, dr.name)
				if sel then
					table.insert(out_buf, REV .. BOLD .. FG_GREEN .. pad_right(truncate_visible(line, term_cols), term_cols) .. RESET)
				else
					table.insert(out_buf, BOLD .. FG_GREEN .. pad_right(truncate_visible(line, term_cols), term_cols) .. RESET)
				end
			elseif dr.kind == "item" then
				local kind_icon = "▪ "
				local kc = FG_WHITE
				if dr.item_kind == "function" then
					kind_icon = "λ "
					kc = FG_CYAN
				elseif dr.item_kind == "module" then
					kind_icon = "◆ "
					kc = FG_GREEN
				elseif dr.item_kind == "type" then
					kind_icon = "◇ "
					kc = FG_PURPLE
				elseif dr.item_type:find("DataFrame") or dr.item_type:find("Matrix") then
					kind_icon = "▦ "
					kc = FG_YELLOW
				elseif dr.item_type:find("Vector") or dr.item_type:find("Array") then
					kind_icon = "▤ "
					kc = FG_ORANGE
				elseif dr.item_type:find("Dict") or dr.item_type:find("Set") then
					kind_icon = "⚿ "
					kc = FG_TEAL
				end

				local indent = string.rep("  ", dr.depth or 0)
				local tree_icon = dr.has_children and (dr.icon ~= "" and dr.icon .. " " or "  ") or kind_icon
				local name_w, type_w, val_max = ws_col_widths(term_cols)
				local name_text = "    " .. indent .. tree_icon .. dr.name
				local name_col = pad_right(truncate_visible(name_text, name_w), name_w)
				local type_col = pad_right(truncate_visible(dr.item_type, type_w), type_w)
				local val_col = pad_right(truncate_visible(dr.value, val_max), val_max)

				if sel then
					local out_str
					if col_cursor == 1 then
						out_str = REV .. name_col .. RESET .. "  " .. kc .. type_col .. "  " .. FG_WHITE .. val_col
					elseif col_cursor == 2 then
						out_str = name_col .. "  " .. REV .. kc .. type_col .. RESET .. "  " .. FG_WHITE .. val_col
					else
						out_str = name_col .. "  " .. kc .. type_col .. "  " .. REV .. FG_WHITE .. val_col .. RESET
					end
					table.insert(out_buf, kc .. out_str .. RESET)
				else
					table.insert(out_buf, kc .. name_col .. "  " .. FG_GRAY .. type_col .. "  " .. FG_WHITE .. val_col .. RESET)
				end
			elseif dr.kind == "hist_section" then
				local icon = dr.collapsed and "▶" or "▼"
				local hint = dr.collapsed and "  [l/↵ expand]" or "  [h collapse]"
				local hdr_txt = string.format("  %s %s", icon, dr.title or "Previous Sessions")
				local line_str = truncate_visible(hdr_txt .. hint, term_cols)
				if sel then
					table.insert(out_buf, REV .. BOLD .. FG_YELLOW .. pad_right(line_str, term_cols) .. RESET)
				else
					table.insert(out_buf, BOLD .. FG_YELLOW .. truncate_visible(hdr_txt, term_cols) .. DIM .. FG_GRAY .. hint .. RESET)
				end
			elseif dr.kind == "section" then
				local sec_title = " ── " .. (dr.text or "") .. " "
				local fill_w = math.max(0, term_cols - visible_len(sec_title))
				table.insert(out_buf, BOLD .. FG_AQUA .. truncate_visible(sec_title .. string.rep("─", fill_w), term_cols) .. RESET)
			elseif dr.kind == "hist_note" then
				table.insert(out_buf, DIM .. FG_GRAY .. pad_right(truncate_visible("    " .. (dr.text or ""), term_cols), term_cols) .. RESET)
			elseif dr.kind == "history" then
				local is_sel = history_selected[dr.idx]
				local check = is_sel and (FG_GREEN .. BOLD .. " [✓] " .. RESET) or (DIM .. FG_GRAY .. " [ ] " .. RESET)
				local st_badge
				if dr.status == "error" then
					st_badge = FG_RED .. BOLD .. "✗ " .. RESET
				elseif dr.status == "ok" then
					st_badge = FG_GREEN .. "✓ " .. RESET
				else
					st_badge = DIM .. FG_GRAY .. "· " .. RESET
				end
				local num = (dr.is_prev and DIM or "") .. FG_YELLOW .. string.format("%3d: ", dr.idx) .. RESET
				local cmd_text = dr.cmd:gsub("\r?\n", " ⏎ ")
				local max_w = math.max(10, term_cols - 13)
				local line_text = pad_right(truncate_visible(cmd_text, max_w), max_w)
				if sel then
					local sc = (dr.status == "error") and FG_RED or FG_WHITE
					table.insert(out_buf, check .. st_badge .. num .. REV .. sc .. line_text .. RESET)
				else
					local tc = (dr.status == "error") and FG_RED or (dr.is_prev and (DIM .. FG_GRAY) or FG_LIGHT_GRAY)
					table.insert(out_buf, check .. st_badge .. num .. tc .. line_text .. RESET)
				end
			elseif dr.kind == "package" then
				local name_w = math.min(35, math.max(16, term_cols - 20))
				local ver_w = math.max(8, term_cols - name_w - 4)
				local name_col = pad_right(truncate_visible("  📦 " .. dr.name, name_w), name_w)
				local ver_col = pad_right(truncate_visible("v" .. dr.version, ver_w), ver_w)
				if sel then
					table.insert(out_buf, REV .. FG_CYAN .. name_col .. "  " .. FG_GREEN .. ver_col .. RESET)
				else
					table.insert(out_buf, FG_CYAN .. name_col .. "  " .. FG_YELLOW .. ver_col .. RESET)
				end
			elseif dr.kind == "guide_hdr" then
				local title = " ── " .. (dr.title or "") .. " "
				local fill = string.rep("─", math.max(0, term_cols - visible_len(title)))
				table.insert(out_buf, BOLD .. FG_CYAN .. truncate_visible(title .. fill, term_cols) .. RESET)
			elseif dr.kind == "guide_item" then
				local key_w = math.min(28, math.max(16, math.floor(term_cols * 0.34)))
				local desc_w = math.max(10, term_cols - key_w - 4)
				local kcol = pad_right("  " .. truncate_visible(dr.key or "", key_w), key_w + 3)
				local dcol = pad_right(truncate_visible(dr.desc or "", desc_w), desc_w)
				if sel then
					table.insert(out_buf, REV .. BOLD .. FG_YELLOW .. kcol .. RESET .. REV .. FG_WHITE .. " " .. dcol .. RESET)
				else
					table.insert(out_buf, BOLD .. FG_YELLOW .. kcol .. RESET .. " " .. FG_LIGHT_GRAY .. dcol .. RESET)
				end
			elseif dr.kind == "empty_proc" then
				local box_w = math.max(24, math.min(62, term_cols - 4))
				local inner = math.max(10, box_w - 2)
				local title_fill = math.max(0, box_w - 31)
				table.insert(out_buf, FG_AQUA .. "  ╭─ " .. BOLD .. "✦ No procedures or errors " .. RESET .. FG_AQUA .. string.rep("─", title_fill) .. "╮" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right(truncate_visible("  Quick Start:", inner), inner) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right(truncate_visible("  1. Press [2] for History, select commands with [Space]", inner), inner) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right(truncate_visible("  2. Press [p] to Make Procedure with auto-AST parameters", inner), inner) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right(truncate_visible("  3. REPL errors appear here with full code + traceback", inner), inner) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  ╰" .. string.rep("─", inner) .. "╯" .. RESET)
			elseif dr.kind == "empty_search" then
				local box_w = math.max(24, math.min(54, term_cols - 4))
				local inner = math.max(10, box_w - 2)
				table.insert(out_buf, FG_YELLOW .. "  ╭─ " .. BOLD .. "🔍 Search Filter " .. RESET .. FG_YELLOW .. string.rep("─", math.max(0, box_w - 22)) .. "╮" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_YELLOW .. "  │" .. RESET .. pad_right(truncate_visible("  " .. (dr.text or "No matches found."), inner), inner) .. FG_YELLOW .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_YELLOW .. "  │" .. RESET .. DIM .. pad_right(truncate_visible("  Press [Esc] or 'x' to clear search filter", inner), inner) .. RESET .. FG_YELLOW .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_YELLOW .. "  ╰" .. string.rep("─", inner) .. "╯" .. RESET)
			elseif dr.kind == "msg" then
				table.insert(out_buf, DIM .. pad_right(truncate_visible("  " .. (dr.text or ""), term_cols), term_cols) .. RESET)
			end

			row_idx = row_idx + 1
		end
	end

	-- Row term_rows - 1: Search Prompt / Bottom Divider
	table.insert(out_buf, move(term_rows - 1, 1))
	if search_mode then
		local sbar = BOLD .. FG_YELLOW .. " 🔍 Search: " .. RESET .. BOLD .. FG_WHITE .. search_query .. REV .. " " .. RESET .. DIM .. FG_GRAY .. "  [Enter] Confirm   [Esc] Clear" .. RESET
		table.insert(out_buf, pad_right(truncate_visible(sbar, term_cols), term_cols))
	elseif search_query ~= "" then
		local sbar = DIM .. FG_YELLOW .. " 🔍 Filter: \"" .. search_query .. "\" (" .. match_count .. ") — 'x' or [Esc] clear" .. RESET
		table.insert(out_buf, pad_right(truncate_visible(sbar, term_cols), term_cols))
	else
		table.insert(out_buf, FG_DARK_GRAY .. string.rep("─", term_cols) .. RESET)
	end

	-- Row term_rows: Shortcut Pills (adaptive width + mouse hitboxes)
	render_footer_pills(out_buf, term_rows, term_cols)
	end

	-- Modal popup overlay if active
	if modal_active then
		render_modal(out_buf, term_rows, term_cols)
	end

	table.insert(out_buf, SYNC_END)
	io.write(table.concat(out_buf))
	io.flush()
end

-- ---------------------------------------------------------------------------
-- Input handling
-- ---------------------------------------------------------------------------
local function pick_editor()
	for _, var in ipairs({ "VISUAL", "EDITOR" }) do
		local v = os.getenv(var)
		if v and v ~= "" then
			return v
		end
	end
	for _, ed in ipairs({ "nano", "nvim", "vim", "vi" }) do
		local h = io.popen("command -v " .. ed .. " 2>/dev/null")
		if h then
			local res = h:read("*l")
			h:close()
			if res and res ~= "" then
				return ed
			end
		end
	end
	return "vi"
end

local function open_in_external_editor(dr)
	if not dr or dr.kind ~= "procedure" then
		return
	end
	local src = (dr.edit_code and dr.edit_code ~= "") and dr.edit_code or (dr.code or "")
	if src == "" then
		src = "function " .. (dr.signature or (dr.name .. "()")) .. "\n    \nend\n"
	end
	local tmp_path = string.format("/tmp/jemach_edit_%s_%d.jl", dr.name:gsub("[^%w_]", "_"), os.time())
	local wf = io.open(tmp_path, "w")
	if not wf then
		set_toast("✗ Cannot create temp file")
		return
	end
	wf:write(src)
	if src:sub(-1) ~= "\n" then
		wf:write("\n")
	end
	wf:close()

	io.write((mouse_enabled and MOUSE_OFF or "") .. SHOW_CUR .. ALT_SCREEN_OFF)
	io.flush()
	raw_mode_off()

	local ed = pick_editor()
	os.execute(string.format("%s '%s'", ed, tmp_path:gsub("'", "'\\''")))

	raw_mode_on()
	io.write(ALT_SCREEN_ON .. HIDE_CUR .. (mouse_enabled and MOUSE_ON or ""))
	io.flush()

	local rf = io.open(tmp_path, "r")
	local edited = rf and rf:read("*a") or ""
	if rf then
		rf:close()
	end
	os.remove(tmp_path)

	local trimmed = edited:gsub("^%s+", ""):gsub("%s+$", "")
	local orig_trimmed = src:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed ~= "" and trimmed ~= orig_trimmed then
		repl_eval(trimmed, true, false, "jEMach:" .. dr.name, dr.name)
		set_toast("⚡ Applied '" .. dr.name .. "' in Main memory")
	else
		set_toast("Edit cancelled (no changes)")
	end
end

local function prompt_or_run_procedure(dr)
	if not dr or dr.kind ~= "procedure" then
		return
	end
	if dr.needs_args then
		modal_active = true
		modal_title = "Args for " .. (dr.signature or dr.name)
		modal_input = (last_modal_args[dr.name] and last_modal_args[dr.name] ~= "")
			and last_modal_args[dr.name]
			or (dr.last_args or "")
		modal_callback = function(ans)
			local a = (ans or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if a ~= "" then
				last_modal_args[dr.name] = a
			end
			if a == "" then
				tmux_send(string.format("jEMach.run_procedure(:%s)", dr.name))
			elseif a:sub(1, 1) == ";" then
				tmux_send(string.format("jEMach.run_procedure(:%s%s)", dr.name, a))
			else
				tmux_send(string.format("jEMach.run_procedure(:%s, %s)", dr.name, a))
			end
			set_toast("▶ Running procedure " .. dr.name .. "...")
		end
		dirty = true
	else
		tmux_send(string.format("jEMach.run_procedure(:%s)", dr.name))
		set_toast("▶ Running procedure " .. dr.name .. "...")
	end
end

local handle_key -- forward declaration for mouse dispatcher

local function handle_mouse(seq, term_rows, term_cols)
	local btn_s, col_s, row_s, kind = seq:match("^\27%[<(%d+);(%d+);(%d+)([Mm])$")
	if not btn_s then
		return nil
	end
	local btn = tonumber(btn_s)
	local mx = tonumber(col_s)
	local my = tonumber(row_s)

	-- Wheel up / down
	if btn == 64 or btn == 68 or btn == 72 then
		if detail_view_active then
			detail_scroll = math.max(0, detail_scroll - 3)
		elseif active_tab == 3 and preview_split_row > 0 and my > preview_split_row then
			proc_preview_scroll = math.max(0, proc_preview_scroll - 3)
		else
			move_cursor(-3)
		end
		return nil
	elseif btn == 65 or btn == 69 or btn == 73 then
		if detail_view_active then
			detail_scroll = detail_scroll + 3
		elseif active_tab == 3 and preview_split_row > 0 and my > preview_split_row then
			proc_preview_scroll = proc_preview_scroll + 3
		else
			move_cursor(3)
		end
		return nil
	end

	-- Only react to left button press (btn == 0, kind == "M")
	if btn ~= 0 or kind ~= "M" then
		return nil
	end
	if modal_active or search_mode then
		return nil
	end

	-- Tab bar click (Row 1)
	if my == 1 then
		for _, hb in ipairs(tab_hitboxes) do
			if mx >= hb.x1 and mx <= hb.x2 then
				if detail_view_active then
					detail_view_active = false
					detail_item = nil
				end
				if hb.tab == 5 then
					return handle_key("?", term_rows, term_cols)
				else
					guide_tab_open = false
					switch_tab(hb.tab)
					return nil
				end
			end
		end
		return nil
	end

	if detail_view_active then
		if my >= term_rows - 1 then
			detail_view_active = false
			detail_item = nil
		end
		return nil
	end

	-- Tab 3 [F] Errors / Back header badge click (Row 3)
	if my == 3 and active_tab == 3 and header_err_hitbox then
		if mx >= header_err_hitbox.x1 and mx <= header_err_hitbox.x2 then
			return handle_key("F", term_rows, term_cols)
		end
	end

	-- Bottom footer pill click
	if my == term_rows then
		for _, ab in ipairs(action_hitboxes) do
			if mx >= ab.x1 and mx <= ab.x2 then
				return handle_key(ab.key, term_rows, term_cols)
			end
		end
		return nil
	end

	-- Row selection + double-click action
	local idx = row_hitboxes[my]
	if idx and display_rows[idx] then
		local dr = display_rows[idx]
		local t_now = now_ms()
		local is_dbl = (last_click_row == idx) and ((t_now - last_click_ms) < 420)
		last_click_row = idx
		last_click_ms = t_now

		if is_selectable_row(dr) then
			cursor = idx
			tab_cursors[active_tab] = idx
			if is_dbl then
				if active_tab == 3 then
					return handle_key("e", term_rows, term_cols)
				elseif active_tab == 1 then
					if dr.kind == "module" or dr.has_children then
						local key_k = dr.collapsed and "l" or "h"
						return handle_key(key_k, term_rows, term_cols)
					elseif dr.kind == "item" and dr.item_kind == "function" then
						return handle_key("e", term_rows, term_cols)
					end
				elseif active_tab == 2 then
					if dr.kind == "hist_section" then
						return handle_key(" ", term_rows, term_cols)
					elseif dr.kind == "history" then
						return handle_key("e", term_rows, term_cols)
					end
				end
			end
		end
	end
	return nil
end

handle_key = function(key, term_rows, term_cols)
	if not key then
		return
	end

	-- Mouse SGR sequences (\27[<btn;col;row[Mm])
	if key:sub(1, 3) == "\27[<" then
		return handle_mouse(key, term_rows, term_cols)
	end

	-- Global Quit
	if key == "\3" then -- Ctrl-C
		return "quit"
	end

	-- Modal input interception
	if modal_active then
		if key == "\27" then -- ESC
			modal_active = false
			dirty = true
			return
		elseif key == "\r" or key == "\n" then -- Enter
			local cb = modal_callback
			local val = modal_input
			modal_active = false
			dirty = true
			if cb then
				cb(val)
			end
			return
		elseif key == "\21" then -- Ctrl+U clear
			modal_input = ""
			dirty = true
			return
		elseif key == "\127" or key == "\8" then -- Backspace
			if #modal_input > 0 then
				modal_input = modal_input:sub(1, #modal_input - 1)
				dirty = true
			end
			return
		elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
			modal_input = modal_input .. key
			dirty = true
			return
		end
		return
	end

	-- Search mode interception
	if search_mode then
		if key == "\27" then -- ESC
			search_mode = false
			search_query = ""
			build_display_rows()
			clamp_cursor()
			dirty = true
			return
		elseif key == "\r" or key == "\n" then -- Enter (keeps active filter)
			search_mode = false
			build_display_rows()
			clamp_cursor()
			dirty = true
			return
		elseif key == "\21" then -- Ctrl+U clear
			modal_input = ""
			dirty = true
			return
		elseif key == "\127" or key == "\8" then -- Backspace
			if #search_query > 0 then
				search_query = search_query:sub(1, #search_query - 1)
				build_display_rows()
				clamp_cursor()
				dirty = true
			end
			return
		elseif #key == 1 and key:byte(1) >= 32 and key:byte(1) <= 126 then
			search_query = search_query .. key
			build_display_rows()
			clamp_cursor()
			dirty = true
			return
		end
		return
	end

	-- Full-screen detail / error viewer interception
	if detail_view_active then
		local page = math.max(1, (term_rows or 24) - 6)
		if key == "q" then
			return "quit"
		elseif key == "v" or key == "\27" then
			detail_view_active = false
			detail_item = nil
			dirty = true
			return
		elseif key == "j" or key == "\27[B" then
			detail_scroll = detail_scroll + 1
			dirty = true
			return
		elseif key == "k" or key == "\27[A" then
			detail_scroll = math.max(0, detail_scroll - 1)
			dirty = true
			return
		elseif key == "\27[6~" then -- PageDown
			detail_scroll = detail_scroll + page
			dirty = true
			return
		elseif key == "\27[5~" then -- PageUp
			detail_scroll = math.max(0, detail_scroll - page)
			dirty = true
			return
		elseif key == "g" then
			detail_scroll = 0
			dirty = true
			return
		elseif key == "G" then
			detail_scroll = 999999
			dirty = true
			return
		elseif key == "\r" or key == "\n" then
			if detail_item then
				if detail_item.kind == "procedure" then
					prompt_or_run_procedure(detail_item)
				elseif detail_item.kind == "failed_cmd" or detail_item.kind == "history" then
					tmux_send(detail_item.cmd)
					set_toast("Sent command to REPL")
				end
			end
			return
		elseif key == "e" then
			if detail_item then
				if detail_item.kind == "procedure" then
					local edit_src = (detail_item.edit_code and detail_item.edit_code ~= "") and detail_item.edit_code or (detail_item.code or "")
					edit_src = edit_src:gsub("^%s+", ""):gsub("%s+$", "")
					repl_replace_input(edit_src, 0)
					focus_repl_pane()
					detail_view_active = false
					detail_item = nil
					set_toast("✎ Loaded '" .. detail_item.name .. "' in REPL")
				elseif detail_item.kind == "failed_cmd" or detail_item.kind == "history" then
					repl_replace_input(detail_item.cmd or "", 0)
					focus_repl_pane()
					set_toast("Pasted command into REPL")
				end
			end
			return
		elseif key == "E" then
			if detail_item and detail_item.kind == "procedure" then
				open_in_external_editor(detail_item)
			end
			return
		elseif key == "c" then
			if detail_item and detail_item.kind == "procedure" then
				local a = (detail_item.last_args and detail_item.last_args ~= "") and detail_item.last_args or ""
				if a ~= "" then
					repl_insert(detail_item.name .. "(" .. a .. ")", 0)
				else
					repl_insert(detail_item.name .. "()", 1)
				end
				focus_repl_pane()
				set_toast("Inserted " .. detail_item.name .. "() call")
			end
			return
		end
		return
	end

	-- Normal mode quit
	if key == "q" then
		return "quit"
	end

	-- Toggle SGR mouse tracking (allows easy native text selection without holding Shift)
	if key == "m" then
		mouse_enabled = not mouse_enabled
		io.write(mouse_enabled and MOUSE_ON or MOUSE_OFF)
		io.flush()
		set_toast(mouse_enabled and "Mouse ON (click & scroll)" or "Mouse OFF (drag to copy)")
		return
	end

	-- Global screen clear (Ctrl+L)
	if key == "\12" then
		repl_clear()
		set_toast("Cleared REPL screen")
		return
	end

	-- Enter search mode
	if key == "/" then
		search_mode = true
		dirty = true
		return
	end

	-- Open / toggle Guide tab (?)
	if key == "?" then
		if guide_tab_open and active_tab == 5 then
			guide_tab_open = false
			local target = (return_tab >= 1 and return_tab <= 4) and return_tab or 1
			switch_tab(target)
		else
			if active_tab ~= 5 then
				return_tab = active_tab
			end
			guide_tab_open = true
			switch_tab(5)
		end
		return
	end

	-- Clear active search filter with ESC or x
	if (key == "\27" or key == "x") and search_query ~= "" then
		search_query = ""
		build_display_rows()
		clamp_cursor()
		set_toast("Search filter cleared")
		dirty = true
		return
	end

	-- Close Guide tab with ESC when no search filter is active
	if key == "\27" and active_tab == 5 and guide_tab_open then
		guide_tab_open = false
		local target = (return_tab >= 1 and return_tab <= 4) and return_tab or 1
		switch_tab(target)
		return
	end

	-- Direct tab jump keys
	if key == "1" then switch_tab(1); return end
	if key == "2" then switch_tab(2); return end
	if key == "3" then switch_tab(3); return end
	if key == "4" then switch_tab(4); return end
	if key == "5" then
		if active_tab ~= 5 then
			return_tab = active_tab
		end
		guide_tab_open = true
		switch_tab(5)
		return
	end

	-- Tab cycle keys
	local max_tabs = guide_tab_open and 5 or 4
	if key == "\t" or key == "]" then
		switch_tab((active_tab % max_tabs) + 1)
		return
	elseif key == "[" then
		switch_tab((active_tab == 1) and max_tabs or (active_tab - 1))
		return
	end

	-- Movement: j / k / Down / Up / PgUp / PgDn / g / G
	if key == "j" or key == "\27[B" then
		move_cursor(1)
		return
	elseif key == "k" or key == "\27[A" then
		move_cursor(-1)
		return
	elseif key == "\27[6~" then
		for _ = 1, 10 do
			move_cursor(1)
		end
		return
	elseif key == "\27[5~" then
		for _ = 1, 10 do
			move_cursor(-1)
		end
		return
	elseif key == "g" then
		cursor = 1
		clamp_cursor()
		return
	elseif key == "G" then
		cursor = math.max(1, #display_rows)
		clamp_cursor()
		return
	end

	-- -----------------------------------------------------------------------
	-- Tab 1: Workspace
	-- -----------------------------------------------------------------------
	if active_tab == 1 then
		if key == "h" or key == "\27[D" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" then
					collapsed[dr.name] = true
				elseif dr.kind == "item" then
					if col_cursor > 1 then
						col_cursor = col_cursor - 1
					elseif dr.has_children and not collapsed[dr.path] then
						collapsed[dr.path] = true
					else
						local parent_path = dr.path:match("(.*)/[^/]+$")
						if parent_path and parent_path ~= dr.module_name then
							collapsed[parent_path] = true
							build_display_rows()
							for i, r in ipairs(display_rows) do
								if r.kind == "item" and r.path == parent_path then
									cursor = i
									break
								end
							end
						else
							collapsed[dr.module_name] = true
							build_display_rows()
							for i, r in ipairs(display_rows) do
								if r.kind == "module" and r.name == dr.module_name then
									cursor = i
									break
								end
							end
						end
					end
				end
				build_display_rows()
				clamp_cursor()
			end
		elseif key == "l" or key == "\27[C" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" then
					if dr.collapsed then
						collapsed[dr.name] = nil
						build_display_rows()
						clamp_cursor()
					end
				elseif dr.kind == "item" then
					if dr.has_children and collapsed[dr.path] then
						collapsed[dr.path] = nil
						build_display_rows()
						clamp_cursor()
					elseif col_cursor < 3 then
						col_cursor = col_cursor + 1
					end
				end
			end
		elseif key == "\r" or key == "\n" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" and dr.collapsed then
					collapsed[dr.name] = nil
					build_display_rows()
					clamp_cursor()
				elseif dr.kind == "item" then
					if dr.expr:match("^[%a_][%w_!%.%[%]%s%\"%:%']*$") then
						local code
						if col_cursor == 1 then
							code = "println(" .. dr.expr .. ")"
						elseif col_cursor == 2 then
							code = "typeof(" .. dr.expr .. ")"
						else
							code = "dump(" .. dr.expr .. ")"
						end
						repl_eval(code, false, false)
					end
				end
			end
		elseif key == "i" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "item" then
				if dr.expr:match("^[%a_][%w_!%.%[%]%s%\"%:%']*$") then
					local code = string.format("jEMach.inspect_var(%s, %q)", dr.module_name, dr.expr)
					repl_eval(code, false, false)
				end
			end
		elseif key == "c" then
			repl_clear()
		elseif key == "s" then
			repl_eval("jEMach.save_clean_session()", false, false)
		elseif key == "e" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "item" then
				if dr.expr:match("^[%a_][%w_!%.%[%]%s%\"%:%']*$") then
					if dr.item_kind == "function" and not dr.expr:find("%.") then
						repl_eval(string.format("jEMach.edit_procedure(:%s)", dr.name), true, false)
						focus_repl_pane()
						set_toast("✎ Loaded '" .. dr.name .. "' in REPL")
					elseif dr.item_kind == "function" then
						repl_insert(dr.expr .. "()", 1)
						focus_repl_pane()
						set_toast("Inserted " .. dr.expr .. "() into REPL")
					else
						repl_insert(dr.expr .. " ", 0)
						set_toast("Inserted " .. dr.expr .. " into REPL")
					end
				end
			end
		elseif key == "d" then
			local dr = display_rows[cursor]
			if dr then
				if dr.kind == "module" then
					hidden[dr.name] = true
				elseif dr.kind == "item" then
					hidden[dr.path] = true
				end
				build_display_rows()
				if cursor > #display_rows then
					cursor = #display_rows
				end
				clamp_cursor()
			end
		elseif key == "D" then
			hidden = {}
			build_display_rows()
			clamp_cursor()
		elseif key == "r" then
			last_mtime = 0
		end

	-- -----------------------------------------------------------------------
	-- Tab 2: History
	-- -----------------------------------------------------------------------
	elseif active_tab == 2 then
		local dr = display_rows[cursor]
		if key == "h" or key == "\27[D" then
			if not history_prev_collapsed then
				history_prev_collapsed = true
				build_display_rows()
				for i, row in ipairs(display_rows) do
					if row.kind == "hist_section" then
						cursor = i
						break
					end
				end
				clamp_cursor()
				dirty = true
			end
		elseif key == "l" or key == "\27[C" then
			if dr and dr.kind == "hist_section" and history_prev_collapsed then
				history_prev_collapsed = false
				build_display_rows()
				clamp_cursor()
				dirty = true
			end
		elseif key == "H" or key == "z" then
			history_prev_collapsed = not history_prev_collapsed
			build_display_rows()
			clamp_cursor()
			set_toast(history_prev_collapsed and "Previous session history folded" or "Previous session history expanded")
		elseif key == " " then
			if dr and dr.kind == "hist_section" then
				history_prev_collapsed = not history_prev_collapsed
				build_display_rows()
				clamp_cursor()
			elseif dr and dr.kind == "history" then
				history_selected[dr.idx] = not history_selected[dr.idx]
				build_display_rows()
			end
		elseif key == "a" then
			local any = false
			local hist = state and state.history or {}
			for i = 1, #hist do
				if history_selected[i] then any = true; break end
			end
			for i = 1, #hist do
				history_selected[i] = not any
			end
			build_display_rows()
		elseif key == "\r" or key == "\n" then
			if dr and dr.kind == "hist_section" then
				history_prev_collapsed = not history_prev_collapsed
				build_display_rows()
				clamp_cursor()
			elseif dr and dr.kind == "history" then
				tmux_send(dr.cmd)
				set_toast("Sent command to REPL")
			end
		elseif key == "e" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "history" then
				repl_insert(dr.cmd, 0)
				set_toast("Pasted command into REPL")
			end
		elseif key == "v" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "history" then
				detail_view_active = true
				detail_item = dr
				detail_scroll = 0
				dirty = true
			end
		elseif key == "p" then
			local default_name = "proc_" .. tostring(#(state and state.procedures or {}) + 1)
			modal_active = true
			modal_title = "Create Procedure"
			modal_input = default_name
			modal_callback = function(name)
				name = name:gsub("%s+", "")
				if name == "" then return end
				local sel_cmds = {}
				local hist = state and state.history or {}
				for i = 1, #hist do
					if history_selected[i] then
						table.insert(sel_cmds, julia_quote_str(hist[i]))
					end
				end
				if #sel_cmds == 0 and display_rows[cursor] and display_rows[cursor].idx then
					local cmd_str = hist[display_rows[cursor].idx] or display_rows[cursor].cmd
					if cmd_str and cmd_str ~= "" then
						table.insert(sel_cmds, julia_quote_str(cmd_str))
					end
				end
				if #sel_cmds == 0 then
					set_toast("No history commands selected!")
					return
				end
				local cmd = string.format("jEMach.make_procedure(:%s; commands=String[%s])", name, table.concat(sel_cmds, ", "))
				repl_eval(cmd, false, false)
				history_selected = {}
				set_toast("✓ Generated procedure '" .. name .. "'!")
				switch_tab(3)
			end
		elseif key == "c" then
			repl_clear()
		end

	-- -----------------------------------------------------------------------
	-- Tab 3: Procedures & Failed Commands
	-- -----------------------------------------------------------------------
	elseif active_tab == 3 then
		local dr = display_rows[cursor]
		if key == "v" then
			if dr and (dr.kind == "procedure" or dr.kind == "failed_cmd") then
				detail_view_active = true
				detail_item = dr
				detail_scroll = 0
				dirty = true
			end
		elseif key == "J" then
			proc_preview_scroll = proc_preview_scroll + 3
			dirty = true
		elseif key == "K" then
			proc_preview_scroll = math.max(0, proc_preview_scroll - 3)
			dirty = true
		elseif key == "F" then
			proc_errors_view = not proc_errors_view
			build_display_rows()
			clamp_cursor()
			set_toast(proc_errors_view and "Failed Commands sub-view" or "Procedures view")
		elseif key == "\r" or key == "\n" then
			if dr and dr.kind == "procedure" then
				prompt_or_run_procedure(dr)
			elseif dr and dr.kind == "failed_cmd" then
				tmux_send(dr.cmd)
				set_toast("↻ Re-running command in REPL")
			end
		elseif key == "e" then
			if dr and dr.kind == "procedure" then
				local edit_src = (dr.edit_code and dr.edit_code ~= "") and dr.edit_code or (dr.code or "")
				edit_src = edit_src:gsub("^%s+", ""):gsub("%s+$", "")
				if edit_src ~= "" then
					repl_replace_input(edit_src, 0)
				else
					repl_eval(string.format("jEMach.edit_procedure(:%s)", dr.name), true, false)
				end
				focus_repl_pane()
				set_toast("✎ Loaded '" .. dr.name .. "' in REPL (Enter applies)")
			elseif dr and dr.kind == "failed_cmd" then
				repl_replace_input(dr.cmd, 0)
				focus_repl_pane()
				set_toast("Loaded failed command into REPL")
			end
		elseif key == "E" then
			if dr and dr.kind == "procedure" then
				open_in_external_editor(dr)
			end
		elseif key == "c" then
			if dr and dr.kind == "procedure" then
				local a = (last_modal_args[dr.name] and last_modal_args[dr.name] ~= "")
					and last_modal_args[dr.name]
					or (dr.last_args or "")
				if dr.origin == "unloaded" then
					if a ~= "" then
						repl_insert("jEMach.run_procedure(:" .. dr.name .. ", " .. a .. ")", 0)
					else
						repl_insert("jEMach.run_procedure(:" .. dr.name .. ")", 1)
					end
				elseif a ~= "" then
					repl_insert(dr.name .. "(" .. a .. ")", 0)
				else
					repl_insert(dr.name .. "()", 1)
				end
				focus_repl_pane()
				set_toast("Inserted " .. dr.name .. "(...) call")
			else
				repl_clear()
			end
		elseif key == "R" then
			if dr and dr.kind == "procedure" then
				if dr.file and dr.file ~= "" then
					repl_eval(string.format("jEMach.reload_procedure(:%s)", dr.name), true, false)
					set_toast("↺ Reloaded '" .. dr.name .. "' from disk")
				else
					set_toast("Live function only — press [S] to save to disk")
				end
			else
				repl_eval("jEMach.autoload_procedures!(; force=true); jEMach.publish_state()", true, false)
				set_toast("↺ Reloaded all disk procedures")
			end
		elseif key == "S" then
			if dr and dr.kind == "procedure" then
				modal_active = true
				modal_title = "Save '" .. dr.name .. "' as (procedures/<name>.jl)"
				modal_input = dr.name
				modal_callback = function(ans)
					local target = (ans or ""):gsub("%s+", "")
					if target == "" then
						target = dr.name
					end
					if target == dr.name then
						repl_eval(string.format("jEMach.save_procedure(:%s)", dr.name), true, false)
					else
						repl_eval(string.format("jEMach.save_procedure(:%s; as_name=:%s)", dr.name, target), true, false)
					end
					set_toast("💾 Saved to procedures/" .. target .. ".jl")
				end
			end
		elseif key == "d" then
			if dr and dr.kind == "procedure" then
				modal_active = true
				modal_title = (dr.file and dr.file ~= "")
					and ("Delete '" .. dr.name .. "' (" .. dr.file .. ")? (y/n)")
					or ("Remove live '" .. dr.name .. "' from list? (y/n)")
				modal_input = ""
				modal_callback = function(ans)
					local a = ans:lower():gsub("%s+", "")
					if a == "y" or a == "yes" then
						repl_eval(string.format("jEMach._delete_procedure!(:%s)", dr.name), true, false)
						set_toast("Removed procedure " .. dr.name)
					end
				end
			elseif dr and dr.kind == "failed_cmd" then
				repl_eval(string.format("jEMach._dismiss_failed_command!(%d)", dr.id), true, false)
				set_toast("Dismissed failed command #" .. dr.id)
			end
		elseif key == "D" then
			repl_eval("jEMach._clear_failed_commands!()", true, false)
			set_toast("Cleared failed commands list")
		elseif key == "r" then
			repl_eval("jEMach._load_procedures!(); jEMach.publish_state()", true, false)
			set_toast("Refreshed procedures")
		end

	-- -----------------------------------------------------------------------
	-- Tab 4: Packages
	-- -----------------------------------------------------------------------
	elseif active_tab == 4 then
		local dr = display_rows[cursor]
		if key == "a" then
			modal_active = true
			modal_title = "Add Julia Package"
			modal_input = ""
			modal_callback = function(pkg_name)
				pkg_name = pkg_name:gsub("%s+", "")
				if pkg_name ~= "" then
					tmux_send(string.format("import Pkg; Pkg.add(%q)", pkg_name))
					set_toast("Adding package " .. pkg_name .. "...")
				end
			end
		elseif key == "d" then
			if dr and dr.kind == "package" then
				modal_active = true
				modal_title = "Remove package '" .. dr.name .. "'? (y/n)"
				modal_input = ""
				modal_callback = function(ans)
					local a = ans:lower():gsub("%s+", "")
					if a == "y" or a == "yes" then
						tmux_send(string.format("import Pkg; Pkg.rm(%q)", dr.name))
						set_toast("Removing package " .. dr.name .. "...")
					end
				end
			end
		elseif key == "u" then
			if dr and dr.kind == "package" then
				tmux_send(string.format("import Pkg; Pkg.update(%q)", dr.name))
				set_toast("Updating " .. dr.name .. "...")
			else
				tmux_send("import Pkg; Pkg.update()")
				set_toast("Updating all packages...")
			end
		elseif key == "c" then
			repl_clear()
		end

	-- -----------------------------------------------------------------------
	-- Tab 5: Guide
	-- -----------------------------------------------------------------------
	elseif active_tab == 5 then
		if key == "c" then
			repl_clear()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local function main()
	raw_mode_on()
	io.write(ALT_SCREEN_ON .. HIDE_CUR .. (mouse_enabled and MOUSE_ON or "") .. SET_TITLE)
	io.flush()

	-- Ensure terminal is restored on exit
	local function cleanup()
		raw_mode_off()
		io.write(MOUSE_OFF .. SHOW_CUR .. ALT_SCREEN_OFF)
		io.flush()
	end

	-- Run cleanup on normal exit or Lua error
	local ok, err = pcall(function()
		local term_rows, term_cols = get_terminal_size()

		load_state()
		build_display_rows()
		clamp_cursor()
		render(term_rows, term_cols)
		dirty = false

		while true do
			-- Zero-fork ioctl size check on every cycle for instant resize in Ghostty/Kitty/Zellij/tmux/Rex
			local new_rows, new_cols = get_terminal_size()
			if new_rows ~= term_rows or new_cols ~= term_cols then
				term_rows, term_cols = new_rows, new_cols
				dirty = true
			end

			if load_state() then
				dirty = true
			end

			if dirty then
				build_display_rows()
				clamp_cursor()
				render(term_rows, term_cols)
				dirty = false
			end

			local key = get_next_key(REFRESH_MS)
			if key then
				dirty = true
				local result = handle_key(key, term_rows, term_cols)
				if result == "quit" then
					break
				end
			end
		end
	end)

	cleanup()

	if not ok then
		io.stderr:write("jl_tui error: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

main()
