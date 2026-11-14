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
local dirty = true
local state = nil -- last parsed JSON state
local last_mtime = 0
local last_state_ts = 0
local history_selected = {}

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
	local buf = ffi.new("char[65536]")
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
		local buf = ffi.new("char[32]")
		local n = tonumber(ffi.C.read(STDIN, buf, 32))
		if not n or n <= 0 then
			return nil
		end

		local s = ""
		for i = 0, n - 1 do
			s = s .. string.char(buf[i])
		end
		return s
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
	local csi_u_code, csi_u_mod = k:match("^\27%[(%d+);?(%d*)u$")
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
		elseif code >= 32 and code <= 126 and mod == 1 then
			return string.char(code)
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
			local esc_seq = raw:match("^\27%[[%d;]*[a-zA-Z~u]", pos)
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
local UNDERLINE = ESC .. "[4m"
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
local FG_MAGENTA = ESC .. "[38;5;207m"
local FG_RED = ESC .. "[38;5;203m"
local FG_WHITE = ESC .. "[38;5;255m"
local FG_LIGHT_GRAY = ESC .. "[38;5;250m"
local FG_GRAY = ESC .. "[38;5;244m"
local FG_DARK_GRAY = ESC .. "[38;5;238m"

local BG_SEL = ESC .. "[48;5;236m"
local BG_TAB_ACT = ESC .. "[48;5;24m"
local BG_HEADER = ESC .. "[48;5;235m"

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
	local clean = strip_ansi(s)
	local vlen = visible_len(clean)
	if vlen <= max_w then
		return s
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
-- collapsed[module_name] = true
local collapsed = {}
local initialized_modules = { ["Main"] = true }

-- Flat list of "display rows" rebuilt each render pass
--   { kind="module", name, row_idx }
--   { kind="item",   module_name, name, item_type, item_kind, value, row_idx }
--   { kind="gap" }
local active_tab = 1 -- 1: Workspace, 2: History, 3: Procedures, 4: Packages
local TAB_NAMES = { "Workspace", "History", "Procedures", "Packages" }
local tab_cursors = { 1, 1, 1, 1 }
local proc_view_code = false

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

	-- Tab 2: History
	if active_tab == 2 then
		local hist = state and state.history or {}
		if #hist == 0 then
			display_rows[1] = {
				kind = "msg",
				text = "No REPL commands captured yet in this session.",
			}
			return
		end
		for i, cmd in ipairs(hist) do
			if not has_filter or cmd:lower():find(q, 1, true) then
				table.insert(display_rows, {
					kind = "history",
					idx = i,
					cmd = cmd,
					selected = history_selected[i] or false,
				})
			end
		end
		if #display_rows == 0 then
			display_rows[1] = { kind = "empty_search", text = "No commands matching \"" .. search_query .. "\"." }
		end
		return
	end

	-- Tab 3: Procedures
	if active_tab == 3 then
		local procs = state and state.procedures or {}
		if #procs == 0 then
			display_rows[1] = { kind = "empty_proc" }
			return
		end

		for i, p in ipairs(procs) do
			local pname = p.name or ""
			local psig = p.signature or (pname .. "()")
			local pdoc = p.doc or ""
			local pfile = p.file or ""
			local pcode = p.code or ""

			local match = true
			if has_filter then
				match = (pname:lower():find(q, 1, true) ~= nil)
					or (psig:lower():find(q, 1, true) ~= nil)
					or (pdoc:lower():find(q, 1, true) ~= nil)
					or (pfile:lower():find(q, 1, true) ~= nil)
					or (pcode:lower():find(q, 1, true) ~= nil)
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
					time_ms = p.time_ms or 0.0,
					alloc_bytes = p.alloc_bytes or 0,
					status = p.status or "never",
					last_run = p.last_run or "-",
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
-- Clamp cursor to valid range
-- ---------------------------------------------------------------------------
local function clamp_cursor()
	if cursor < 1 then
		cursor = 1
	end
	if cursor > #display_rows then
		cursor = #display_rows
	end
	if cursor < 1 then
		cursor = 1
	end
	tab_cursors[active_tab] = cursor
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

local function repl_eval(code, silent, record_history)
	local cmd_type = silent and "eval_silent" or "eval"
	local hist_field = (record_history == false) and ',"history":false' or ""
	local msg = string.format('{"cmd":"%s","code":"%s"%s}', cmd_type, json_escape(code), hist_field)
	if not send_socket_json(msg) then
		fallback_mux_send(code, true)
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
-- Rendering
-- ---------------------------------------------------------------------------
local function render(term_rows, term_cols)
	local out_buf = {}
	table.insert(out_buf, SYNC_START .. HIDE_CUR .. CLEAR)

	-- Row 1: Header / Tab bar
	table.insert(out_buf, move(1, 1))
	local tab_parts = {}
	table.insert(tab_parts, BOLD .. FG_CYAN .. "◆ jEMach" .. RESET)

	for i = 1, 4 do
		local name = TAB_NAMES[i]
		local badge = ""
		if i == 2 and state and state.history and #state.history > 0 then
			badge = " (" .. #state.history .. ")"
		elseif i == 3 and state and state.procedures and #state.procedures > 0 then
			badge = " (" .. #state.procedures .. ")"
		elseif i == 4 and state and state.packages and #state.packages > 0 then
			badge = " (" .. #state.packages .. ")"
		end

		local t_str = " [" .. i .. "] " .. name .. badge .. " "
		if i == active_tab then
			table.insert(tab_parts, BOLD .. FG_WHITE .. BG_TAB_ACT .. t_str .. RESET)
		else
			table.insert(tab_parts, DIM .. FG_WHITE .. t_str .. RESET)
		end
	end

	local match_count = #display_rows
	if #display_rows == 1 and (display_rows[1].kind == "empty_search" or display_rows[1].kind == "empty_proc" or display_rows[1].kind == "msg") then
		match_count = 0
	end

	if search_query ~= "" then
		table.insert(tab_parts, BOLD .. FG_YELLOW .. " 🔍 \"" .. search_query .. "\" (" .. match_count .. ") " .. RESET)
	end

	local left_title = table.concat(tab_parts, " ")

	local right_info
	if toast_msg and os.time() <= toast_expires then
		right_info = REV .. BOLD .. FG_GREEN .. " ⚡ " .. toast_msg .. " " .. RESET
	else
		local sock_icon = (socket_fd >= 0) and (FG_GREEN .. "● ONLINE" .. RESET) or (DIM .. FG_RED .. "○ OFFLINE" .. RESET)
		local ts_str = (last_state_ts > 0) and os.date("%H:%M:%S", last_state_ts) or "--:--:--"
		right_info = DIM .. FG_GRAY .. "[" .. get_backend_badge() .. "] " .. RESET .. sock_icon .. " " .. DIM .. FG_GRAY .. ts_str .. RESET
	end

	local left_len = visible_len(left_title)
	local right_len = visible_len(right_info)
	local spacer_len = math.max(1, term_cols - left_len - right_len)
	table.insert(out_buf, left_title .. string.rep(" ", spacer_len) .. right_info)

	-- Row 2: Top Separator
	table.insert(out_buf, move(2, 1))
	table.insert(out_buf, FG_DARK_GRAY .. string.rep("─", term_cols) .. RESET)

	-- Row 3: Column Headers
	table.insert(out_buf, move(3, 1))
	local col_hdr = ""
	if active_tab == 1 then
		col_hdr = DIM .. FG_AQUA .. "   NAME                       TYPE                 VALUE" .. RESET
	elseif active_tab == 2 then
		col_hdr = DIM .. FG_AQUA .. "   SEL    #   COMMAND" .. RESET
	elseif active_tab == 3 then
		col_hdr = DIM .. FG_AQUA .. "   STATUS  PROCEDURE / SIGNATURE         BENCHMARK / METRICS     FILE" .. RESET
	elseif active_tab == 4 then
		col_hdr = DIM .. FG_AQUA .. "   PACKAGE                                  VERSION" .. RESET
	end
	table.insert(out_buf, pad_right(col_hdr, term_cols))

	-- Row 4: Subtle Header Divider
	table.insert(out_buf, move(4, 1))
	table.insert(out_buf, FG_DARK_GRAY .. string.rep("┄", term_cols) .. RESET)

	local header_rows = 4
	local content_rows = math.max(1, term_rows - header_rows - 2)
	local total = #display_rows

	if active_tab == 3 and total > 0 and display_rows[1].kind == "procedure" then
		-- Split view for procedures: top part list, bottom part code preview
		local list_max_h = math.min(total, math.max(3, math.floor(content_rows * 0.42)))
		local preview_h = math.max(1, content_rows - list_max_h - 1)

		local win_start = 1
		if cursor > list_max_h then
			win_start = cursor - list_max_h + 1
		end

		local row_idx = header_rows + 1
		for i = win_start, math.min(win_start + list_max_h - 1, total) do
			local dr = display_rows[i]
			local sel = (i == cursor)
			table.insert(out_buf, move(row_idx, 1))

			local icon = (dr.status == "ok") and (FG_GREEN .. " ✓ " .. RESET)
				or (dr.status == "error") and (FG_RED .. " ✗ " .. RESET)
				or (DIM .. FG_GRAY .. " ○ " .. RESET)

			local sig_w = 34
			local sig_col = pad_right(dr.signature, sig_w)
			local metrics
			if dr.status ~= "never" then
				metrics = string.format("%6.2fms %6dB  %s", dr.time_ms, dr.alloc_bytes, dr.last_run)
			else
				metrics = "never run"
			end
			metrics = pad_right(metrics, 28)
			local file_w = math.max(0, term_cols - sig_w - 28 - 7)
			local file_col = pad_right(dr.file, file_w)

			local line_content
			if sel then
				line_content = icon .. REV .. BOLD .. FG_CYAN .. sig_col .. RESET .. " " .. FG_YELLOW .. metrics .. RESET .. " " .. DIM .. FG_GRAY .. file_col .. RESET
			else
				line_content = icon .. BOLD .. FG_WHITE .. sig_col .. RESET .. " " .. FG_YELLOW .. metrics .. RESET .. " " .. DIM .. FG_GRAY .. file_col .. RESET
			end
			table.insert(out_buf, line_content)
			row_idx = row_idx + 1
		end

		-- Preview separator
		local split_row = header_rows + 1 + list_max_h
		table.insert(out_buf, move(split_row, 1))
		local sel_proc = display_rows[cursor]
		local preview_title = sel_proc and (" Source: " .. sel_proc.file .. " ") or " Source Preview "
		local fill_w = math.max(0, term_cols - visible_len(preview_title) - 4)
		table.insert(out_buf, FG_AQUA .. "╭─ " .. BOLD .. FG_WHITE .. preview_title .. RESET .. FG_AQUA .. string.rep("─", fill_w) .. "╮" .. RESET)

		-- Preview body
		local preview_row = split_row + 1
		if sel_proc and sel_proc.code and sel_proc.code ~= "" then
			local code_lines = split_lines(sel_proc.code)
			for li = 1, math.min(#code_lines, preview_h) do
				table.insert(out_buf, move(preview_row, 1))
				local gutter = DIM .. FG_YELLOW .. string.format("%3d ", li) .. RESET .. FG_DARK_GRAY .. "│ " .. RESET
				local highlighted = highlight_julia_line(code_lines[li])
				table.insert(out_buf, gutter .. truncate_visible(highlighted, term_cols - 6))
				preview_row = preview_row + 1
			end
		else
			table.insert(out_buf, move(preview_row, 1))
			table.insert(out_buf, DIM .. FG_GRAY .. "    (No source code preview available)" .. RESET)
		end
	else
		-- Full height list for Workspace, History, Packages (and empty states)
		local win_start = 1
		if cursor > content_rows then
			win_start = cursor - content_rows + 1
		end

		local row_idx = header_rows + 1
		for i = win_start, math.min(win_start + content_rows - 1, total) do
			local dr = display_rows[i]
			local sel = (i == cursor)
			table.insert(out_buf, move(row_idx, 1))

			if dr.kind == "module" then
				local color = FG_GREEN
				local icon = dr.collapsed and "▶" or "▼"
				local line = string.format("  %s %-20s", icon, dr.name)
				if sel then
					table.insert(out_buf, REV .. BOLD .. FG_GREEN .. pad_right(line, term_cols) .. RESET)
				else
					table.insert(out_buf, BOLD .. FG_GREEN .. pad_right(line, term_cols) .. RESET)
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
				local name_text = "    " .. indent .. tree_icon .. dr.name
				local name_col = pad_right(name_text, 28)
				local type_col = pad_right(dr.item_type, 20)
				local fixed_w = 28 + 20 + 4
				local val_max = math.max(0, term_cols - fixed_w)
				local val_col = truncate_visible(dr.value, val_max)
				val_col = pad_right(val_col, val_max)

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
			elseif dr.kind == "history" then
				local is_sel = history_selected[dr.idx]
				local check = is_sel and (FG_GREEN .. BOLD .. " [✓] " .. RESET) or (DIM .. FG_GRAY .. " [ ] " .. RESET)
				local num = FG_YELLOW .. string.format("%3d: ", dr.idx) .. RESET
				local cmd_text = dr.cmd:gsub("\n", FG_PURPLE .. " ⏎ " .. RESET)
				local max_w = math.max(10, term_cols - 14)
				local line_text = truncate_visible(cmd_text, max_w)
				line_text = pad_right(line_text, max_w)
				if sel then
					table.insert(out_buf, check .. num .. REV .. line_text .. RESET)
				else
					table.insert(out_buf, check .. num .. line_text)
				end
			elseif dr.kind == "package" then
				local name_col = pad_right("  📦 " .. dr.name, 35)
				local ver_col = pad_right("v" .. dr.version, 15)
				if sel then
					table.insert(out_buf, REV .. FG_CYAN .. name_col .. "  " .. FG_GREEN .. ver_col .. RESET)
				else
					table.insert(out_buf, FG_CYAN .. name_col .. "  " .. FG_YELLOW .. ver_col .. RESET)
				end
			elseif dr.kind == "empty_proc" then
				local box_w = math.min(62, term_cols - 4)
				local pad = string.rep("─", box_w - 4)
				table.insert(out_buf, FG_AQUA .. "  ╭─ " .. BOLD .. "✦ No procedures defined yet " .. RESET .. FG_AQUA .. pad:sub(28) .. "╮" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right("  Quick Start:", box_w - 2) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right("  1. Press [2] for History, select commands with [Space]", box_w - 2) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right("  2. Press [p] to Make Procedure with auto-AST parameters", box_w - 2) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  │" .. RESET .. pad_right("  3. Or in Julia REPL: jEMach.make_procedure(:name, last=4)", box_w - 2) .. FG_AQUA .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_AQUA .. "  ╰" .. string.rep("─", box_w - 2) .. "╯" .. RESET)
			elseif dr.kind == "empty_search" then
				local box_w = math.min(54, term_cols - 4)
				table.insert(out_buf, FG_YELLOW .. "  ╭─ " .. BOLD .. "🔍 Search Filter " .. RESET .. FG_YELLOW .. string.rep("─", box_w - 19) .. "╮" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_YELLOW .. "  │" .. RESET .. pad_right("  " .. (dr.text or "No matches found."), box_w - 2) .. FG_YELLOW .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_YELLOW .. "  │" .. RESET .. DIM .. pad_right("  Press [Esc] or 'x' to clear search filter", box_w - 2) .. RESET .. FG_YELLOW .. "│" .. RESET)
				row_idx = row_idx + 1
				table.insert(out_buf, move(row_idx, 1))
				table.insert(out_buf, FG_YELLOW .. "  ╰" .. string.rep("─", box_w - 2) .. "╯" .. RESET)
			elseif dr.kind == "msg" then
				table.insert(out_buf, DIM .. pad_right("  " .. (dr.text or ""), term_cols) .. RESET)
			end

			row_idx = row_idx + 1
		end
	end

	-- Row term_rows - 1: Search Prompt / Bottom Divider
	table.insert(out_buf, move(term_rows - 1, 1))
	if search_mode then
		local sbar = BOLD .. FG_YELLOW .. " 🔍 Search: " .. RESET .. BOLD .. FG_WHITE .. search_query .. REV .. " " .. RESET .. DIM .. FG_GRAY .. "  [Enter] Confirm filter   [Esc] Clear filter" .. RESET
		table.insert(out_buf, pad_right(sbar, term_cols))
	elseif search_query ~= "" then
		local sbar = DIM .. FG_YELLOW .. " 🔍 Active Filter: \"" .. search_query .. "\" (" .. match_count .. " matches) — Press 'x' or [Esc] to clear" .. RESET
		table.insert(out_buf, pad_right(sbar, term_cols))
	else
		table.insert(out_buf, FG_DARK_GRAY .. string.rep("─", term_cols) .. RESET)
	end

	-- Row term_rows: Shortcut Pills
	table.insert(out_buf, move(term_rows, 1))
	local function pill(k, d)
		return BOLD .. FG_CYAN .. "[" .. k .. "] " .. RESET .. DIM .. FG_LIGHT_GRAY .. d .. "  " .. RESET
	end
	local help = ""
	if active_tab == 1 then
		help = pill("/", "Search") .. pill("1-4", "Tabs") .. pill("j/k", "Nav") .. pill("h/l", "Fold/Col") .. pill("↵", "Eval") .. pill("i", "Inspect") .. pill("s", "Save") .. pill("q", "Quit")
	elseif active_tab == 2 then
		help = pill("/", "Search") .. pill("1-4", "Tabs") .. pill("j/k", "Nav") .. pill("Space", "Select") .. pill("a", "All") .. pill("p", "Make Proc") .. pill("↵", "Send") .. pill("q", "Quit")
	elseif active_tab == 3 then
		help = pill("/", "Search") .. pill("1-4", "Tabs") .. pill("j/k", "Nav") .. pill("↵", "Run") .. pill("e", "Edit") .. pill("d", "Delete") .. pill("r", "Reload") .. pill("q", "Quit")
	elseif active_tab == 4 then
		help = pill("/", "Search") .. pill("1-4", "Tabs") .. pill("j/k", "Nav") .. pill("a", "Add") .. pill("d", "Remove") .. pill("u", "Update") .. pill("q", "Quit")
	end
	table.insert(out_buf, pad_right(" " .. help, term_cols))

	-- Modal popup overlay if active
	if modal_active then
		local box_w = math.min(56, term_cols - 4)
		local box_h = 5
		local top = math.floor((term_rows - box_h) / 2)
		local left = math.floor((term_cols - box_w) / 2)

		local title = " " .. modal_title .. " "
		local fill_w = math.max(0, box_w - 4 - visible_len(title))
		local top_border = "╭─" .. BOLD .. FG_WHITE .. title .. RESET .. FG_CYAN .. string.rep("─", fill_w) .. "╮"
		local bot_border = "╰" .. string.rep("─", box_w - 2) .. "╯"
		local prompt_line = "  Input: " .. BOLD .. FG_YELLOW .. modal_input .. RESET .. REV .. " " .. RESET
		local hint_line = "  " .. FG_GREEN .. "[Enter]" .. RESET .. DIM .. " Confirm   " .. RESET .. FG_RED .. "[Esc]" .. RESET .. DIM .. " Cancel" .. RESET

		table.insert(out_buf, move(top, left) .. BOLD .. FG_CYAN .. top_border .. RESET)
		table.insert(out_buf, move(top + 1, left) .. BOLD .. FG_CYAN .. "│" .. RESET .. pad_right(prompt_line, box_w - 2) .. BOLD .. FG_CYAN .. "│" .. RESET)
		table.insert(out_buf, move(top + 2, left) .. BOLD .. FG_CYAN .. "│" .. RESET .. pad_right(hint_line, box_w - 2) .. BOLD .. FG_CYAN .. "│" .. RESET)
		table.insert(out_buf, move(top + 3, left) .. BOLD .. FG_CYAN .. bot_border .. RESET)
	end

	table.insert(out_buf, SYNC_END)
	io.write(table.concat(out_buf))
	io.flush()
end

-- ---------------------------------------------------------------------------
-- Input handling
-- ---------------------------------------------------------------------------
local function handle_key(key, term_rows, term_cols)
	if not key then
		return
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

	-- Normal mode quit
	if key == "q" then
		return "quit"
	end

	-- Enter search mode
	if key == "/" then
		search_mode = true
		dirty = true
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

	-- Direct tab jump keys
	if key == "1" then switch_tab(1); return end
	if key == "2" then switch_tab(2); return end
	if key == "3" then switch_tab(3); return end
	if key == "4" then switch_tab(4); return end

	-- Tab cycle keys
	if key == "\t" or key == "]" then
		switch_tab((active_tab % 4) + 1)
		return
	elseif key == "[" then
		switch_tab((active_tab == 1) and 4 or (active_tab - 1))
		return
	end

	-- Movement: j / k / Down / Up
	if key == "j" or key == "\27[B" then
		cursor = cursor + 1
		clamp_cursor()
		return
	elseif key == "k" or key == "\27[A" then
		cursor = cursor - 1
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
					if dr.item_kind == "function" then
						repl_insert(dr.expr .. "()", 1)
					else
						repl_insert(dr.expr .. " ", 0)
					end
					set_toast("Inserted " .. dr.expr .. " into REPL")
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
		if key == " " then
			local dr = display_rows[cursor]
			if dr and dr.kind == "history" then
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
			local dr = display_rows[cursor]
			if dr and dr.kind == "history" then
				tmux_send(dr.cmd)
				set_toast("Sent command to REPL")
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
	-- Tab 3: Procedures
	-- -----------------------------------------------------------------------
	elseif active_tab == 3 then
		local dr = display_rows[cursor]
		if key == "\r" or key == "\n" then
			if dr and dr.kind == "procedure" then
				tmux_send(string.format("jEMach.run_procedure(:%s)", dr.name))
				set_toast("▶ Running procedure " .. dr.name .. "...")
			end
		elseif key == "e" then
			if dr and dr.kind == "procedure" then
				repl_insert(dr.name .. "()", 1)
				set_toast("Pasted " .. dr.name .. "() into REPL")
			end
		elseif key == "d" then
			if dr and dr.kind == "procedure" then
				modal_active = true
				modal_title = "Delete procedure '" .. dr.name .. "'? (y/n)"
				modal_input = ""
				modal_callback = function(ans)
					local a = ans:lower():gsub("%s+", "")
					if a == "y" or a == "yes" then
						repl_eval(string.format("rm(joinpath(jEMach._get_project_dir(), %q), force=true); jEMach._load_procedures!(); jEMach.publish_state()", dr.file), true)
						set_toast("Deleted procedure " .. dr.name)
					end
				end
			end
		elseif key == "r" then
			repl_eval("jEMach._load_procedures!(); jEMach.publish_state()", true)
			set_toast("Reloaded procedures")
		elseif key == "c" then
			repl_clear()
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
		end
	end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local function main()
	raw_mode_on()
	io.write(ALT_SCREEN_ON .. HIDE_CUR .. SET_TITLE)
	io.flush()

	-- Ensure terminal is restored on exit
	local function cleanup()
		raw_mode_off()
		io.write(SHOW_CUR .. ALT_SCREEN_OFF)
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
