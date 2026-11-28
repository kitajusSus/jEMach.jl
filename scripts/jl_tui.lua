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

local script_dir = assert(arg[0]:match("^(.*)/[^/]+$"), "launch jl_tui.lua using its path")
package.path = script_dir .. "/?.lua;" .. package.path
local ffi = require("ffi")

local platform = require("tui.platform")
local STDIN = 0
local fd_set_new = platform.fd_set_new
local fd_set_set = platform.fd_set_set
local fd_set_isset = platform.fd_set_isset
local make_timeval = platform.make_timeval
local get_terminal_size = platform.get_terminal_size
local raw_mode_on = platform.raw_mode_on
local raw_mode_off = platform.raw_mode_off

local json_parse -- forward declaration

local sessions = require("tui.sessions")
local repl_pane = (arg and arg[1] and arg[1] ~= "") and arg[1] or "{left-of}"
local socket_path = (arg[2] and arg[2] ~= "") and arg[2] or os.getenv("JEMACH_SOCKET")
local STATE_FILE = (arg[3] and arg[3] ~= "") and arg[3] or os.getenv("JEMACH_STATE")
local session_picker_active = false
local session_list = {}
local session_cursor = 1

if socket_path == "@pick" or not socket_path or socket_path == "" then
	local matches = sessions.discover()
	if #matches == 1 and socket_path ~= "@pick" then
		socket_path = matches[1].socket
		STATE_FILE = STATE_FILE or matches[1].state
	elseif #matches >= 1 then
		socket_path = matches[1].socket
		STATE_FILE = STATE_FILE or matches[1].state
		if #matches > 1 then
			session_list = matches
			session_picker_active = true
		end
	else
		local _, err = sessions.select()
		io.stderr:write((err or "No active jEMach session.") .. "\n")
		os.exit(1)
	end
end
STATE_FILE = (STATE_FILE and STATE_FILE ~= "") and STATE_FILE or socket_path:gsub("/repl%.sock$", "/state.json")
-- A chosen session stays pinned, including when its socket becomes unavailable.
assert(#socket_path < 104, "UNIX socket path is too long")

local socket_fd = -1
local last_connect_try = 0
local socket_buffer = ""
local socket_read_buf = ffi.new("char[65536]")
local stdin_buf = ffi.new("char[512]")
local _tv_now = ffi.new("timeval_t")
local dirty = true
local state = nil -- last parsed JSON state
local last_state_ts = 0
local history_selected = {}
local repl_busy = false
local repl_busy_started = 0
local repl_busy_cmd = ""
local notify_threshold_s = tonumber(os.getenv("JEMACH_NOTIFY_SECS")) or 10.0
local sync_expanded_paths -- forward declaration
local emit_desktop_notify -- forward declaration

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
	if ffi.os == "OSX" then
		addr.sun_len = ffi.sizeof(addr)
	end
	ffi.copy(addr.sun_path, socket_path, #socket_path)

	local res = ffi.C.connect(fd, addr, ffi.sizeof(addr))
	if res == 0 then
		socket_fd = fd
		socket_buffer = ""
		ffi.C.write(socket_fd, "SUB\n", 4)
		if sync_expanded_paths then
			sync_expanded_paths()
		end
	else
		ffi.C.close(fd)
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
		local rtv = make_timeval(2)
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
			elseif parsed.event == "busy" then
				if parsed.busy == true then
					repl_busy = true
					repl_busy_started = tonumber(parsed.started_at) or (now_ms() / 1000.0)
					repl_busy_cmd = parsed.cmd or ""
					dirty = true
				else
					local elapsed = tonumber(parsed.elapsed) or 0
					repl_busy = false
					dirty = true
					if elapsed >= notify_threshold_s and emit_desktop_notify then
						emit_desktop_notify(elapsed, parsed.ok ~= false, parsed.cmd or repl_busy_cmd)
					end
				end
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

	local tv = make_timeval(timeout_ms or 100)
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
local keys = require("tui.keys")
local function queue_keys(raw)
	keys.enqueue(raw, input_queue)
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
-- Colors created by Gemini Hydrogen and changed to make it more similar to cyberdream.nvim
-- ---------------------------------------------------------------------------
-- Terminal control helpers (ANSI/VT100 + Synchronized Output Mode 2026)
-- ---------------------------------------------------------------------------
local theme = require("tui.theme")
local ESC = theme.ESC
local CLEAR = theme.CLEAR
local HIDE_CUR = theme.HIDE_CUR
local SHOW_CUR = theme.SHOW_CUR
local ALT_SCREEN_ON = theme.ALT_SCREEN_ON
local ALT_SCREEN_OFF = theme.ALT_SCREEN_OFF
local SYNC_START = theme.SYNC_START
local SYNC_END = theme.SYNC_END
local SET_TITLE = theme.SET_TITLE
local BOLD = theme.BOLD
local DIM = theme.DIM
local RESET = theme.RESET
local REV = theme.REV
local FG_CYAN = theme.FG_CYAN
local FG_AQUA = theme.FG_AQUA
local FG_GREEN = theme.FG_GREEN
local FG_YELLOW = theme.FG_YELLOW
local FG_RED = theme.FG_RED
local FG_WHITE = theme.FG_WHITE
local FG_LIGHT_GRAY = theme.FG_LIGHT_GRAY
local FG_GRAY = theme.FG_GRAY
local FG_DARK_GRAY = theme.FG_DARK_GRAY
local BG_TAB_ACT = theme.BG_TAB_ACT
local MOUSE_ON = theme.MOUSE_ON
local MOUSE_OFF = theme.MOUSE_OFF
local text = require("tui.text")
local visible_len = text.visible_len
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible
local utf8_pop = text.utf8_pop
local is_printable_key = text.is_printable_key

local function move(row, col)
	return ESC .. "[" .. row .. ";" .. col .. "H"
end

-- ---------------------------------------------------------------------------
-- Minimal JSON parser (handles the format emitted by jl_watcher.jl)
-- ---------------------------------------------------------------------------
json_parse = require("tui.json").decode

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
local active_tab = 1 -- 1: Workspace, 2: History, 3: Procedures, 4: Packages, 5: Plots, 6: Guide
local TAB_NAMES = { "Workspace", "History", "Procedures", "Packages", "Plots", "Guide" }
local TAB_SHORT = { "WS", "Hist", "Proc", "Pkg", "Plot", "Guide" }
local tab_cursors = { 1, 1, 1, 1, 1, 1 }
local tab_scrolls = { 1, 1, 1, 1, 1, 1 }
local guide_tab_open = false
local return_tab = 1
local workspace_sort = "default"
local WORKSPACE_SORTS = { "default", "size", "name", "type" }
local inspector_row = 1
local inspector_col = 1
local graphics_dirty_clear = false

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
		and dr.kind ~= "empty_plots"
		and dr.kind ~= "msg"
end

-- ---------------------------------------------------------------------------
-- Read & refresh state
-- ---------------------------------------------------------------------------
local last_file_content = nil

local function load_state()
	if socket_fd >= 0 and last_state_ts > 0 and (os.time() - last_state_ts) < 3 then
		return false
	end

	local f = io.open(STATE_FILE, "r")
	if not f then
		return false
	end
	local content = f:read("*a")
	f:close()
	if content == last_file_content then
		return false
	end

	local ok, parsed = pcall(json_parse, content)
	if ok and parsed then
		last_file_content = content
		apply_new_state(parsed)
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Build the flat display_rows list with search filter
-- ---------------------------------------------------------------------------
local row_views = require("tui.rows")
local build_rows, views = row_views.build, row_views.views
local function build_display_rows()
	display_rows = build_rows({
		state = state,
		search_query = search_query,
		active_tab = active_tab,
		history_selected = history_selected,
		history_prev_collapsed = history_prev_collapsed,
		proc_errors_view = proc_errors_view,
		workspace_sort = workspace_sort,
		hidden = hidden,
		collapsed = collapsed,
		initialized_items = initialized_items,
		initialized_modules = initialized_modules,
	})
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
		if
			cursor > 1 and (display_rows[cursor - 1].kind == "section" or display_rows[cursor - 1].kind == "guide_hdr")
		then
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
	if active_tab == 5 and new_tab ~= 5 then
		graphics_dirty_clear = true
	end
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
	elseif
		(os.getenv("TERM_PROGRAM") or ""):lower() == "ghostty"
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

local json_escape = require("tui.json").escape

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
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%$", "\\$"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
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

sync_expanded_paths = function()
	if socket_fd < 0 then
		return
	end
	local paths = {}
	for k, is_init in pairs(initialized_items) do
		if is_init and not collapsed[k] then
			paths[#paths + 1] = k
		end
	end
	table.sort(paths)
	send_socket_json('{"cmd":"set_expanded","paths":"' .. json_escape(table.concat(paths, "\n")) .. '"}')
end

local function request_inspector_slice(dr, r1, c1, term_rows)
	if not dr or dr.kind ~= "item" then
		return
	end
	local max_r = math.max(10, (tonumber(term_rows) or 30) - 10)
	local msg = string.format(
		'{"cmd":"inspect_slice","mod":"%s","expr":"%s","row":%d,"col":%d,"max_rows":%d,"max_cols":8}',
		json_escape(dr.module_name or "Main"),
		json_escape(dr.expr or dr.name or ""),
		math.max(1, tonumber(r1) or 1),
		math.max(1, tonumber(c1) or 1),
		max_r
	)
	send_socket_json(msg)
end

emit_desktop_notify = function(elapsed, ok, cmd_txt)
	local status_s = ok and "✓ Completed" or "✗ Failed"
	local msg = string.format("%s in %.1fs: %s", status_s, elapsed, (cmd_txt and cmd_txt ~= "") and cmd_txt or "REPL")
	set_toast(msg, 5)
	local b = detect_backend()
	local tp = (os.getenv("TERM_PROGRAM") or ""):lower()
	if b == "kitty" or b == "ghostty" or tp == "kitty" or tp == "ghostty" then
		local clean_body = msg:gsub("[\1-\31\127]", " ")
		io.write("\27]99;i=jemach:d=0;jEMach REPL\27\\\27]99;i=jemach:p=body;" .. clean_body .. "\27\\")
		io.flush()
	else
		io.write("\7")
		io.flush()
	end
end

local function attach_to_session(sess)
	if not sess or not sess.socket then
		return
	end
	if socket_fd >= 0 then
		ffi.C.close(socket_fd)
		socket_fd = -1
	end
	socket_path = sess.socket
	STATE_FILE = sess.state or socket_path:gsub("/repl%.sock$", "/state.json")
	socket_buffer = ""
	last_connect_try = 0
	last_file_content = nil
	state = nil
	repl_busy = false
	history_selected = {}
	graphics_dirty_clear = true
	try_connect_socket()
	load_state()
	build_display_rows()
	clamp_cursor()
	set_toast("⇄ Attached to " .. (sess.pid ~= "" and ("PID " .. sess.pid) or sess.name))
	dirty = true
end

-- ---------------------------------------------------------------------------
-- Preview builder (shared by Tab 3 split preview & full-screen detail viewer)
-- ---------------------------------------------------------------------------
local preview = require("tui.preview")
local function build_item_preview_lines(dr, max_w, compact)
	return preview.build(dr, max_w, compact, state)
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
	local compact_tabs = (term_cols <= 105)
	local tab_labels = compact_tabs and TAB_SHORT or TAB_NAMES
	local max_tab_idx = guide_tab_open and 6 or 5

	local tab_parts = {}
	local lead = BOLD .. FG_CYAN .. (compact_tabs and "◆" or "◆ jEMach") .. RESET
	table.insert(tab_parts, lead)
	local sep = compact_tabs and "" or " "
	local cur_tab_x = visible_len(lead) + 1 + #sep

	for i = 1, max_tab_idx do
		local name = tab_labels[i]
		local key_lbl = (i == 6) and "?" or tostring(i)
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
					badge = " ("
						.. #procs
						.. " "
						.. FG_RED
						.. BOLD
						.. "✗"
						.. total_err_count
						.. RESET
						.. (active_tab == 3 and (BOLD .. FG_WHITE .. BG_TAB_ACT) or (DIM .. FG_WHITE))
						.. ")"
				end
				badge_colored = true
			elseif mod_proc_count > 0 then
				if compact_tabs then
					badge = " " .. FG_YELLOW .. BOLD .. "⚡" .. mod_proc_count .. RESET
				else
					badge = " ("
						.. #procs
						.. " "
						.. FG_YELLOW
						.. BOLD
						.. "⚡"
						.. mod_proc_count
						.. RESET
						.. (active_tab == 3 and (BOLD .. FG_WHITE .. BG_TAB_ACT) or (DIM .. FG_WHITE))
						.. ")"
				end
				badge_colored = true
			elseif #procs > 0 and not compact_tabs then
				badge = " (" .. #procs .. ")"
			end
		elseif i == 4 and state and state.packages and #state.packages > 0 then
			if not compact_tabs then
				badge = " (" .. #state.packages .. ")"
			end
		elseif i == 5 and state and state.plots and #state.plots > 0 then
			if compact_tabs then
				badge = " " .. FG_GREEN .. #state.plots .. RESET
				badge_colored = true
			else
				badge = " (" .. #state.plots .. ")"
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
	if
		#display_rows == 1
		and (
			display_rows[1].kind == "empty_search"
			or display_rows[1].kind == "empty_proc"
			or display_rows[1].kind == "msg"
		)
	then
		match_count = 0
	end

	if search_query ~= "" then
		table.insert(tab_parts, BOLD .. FG_YELLOW .. ' 🔍 "' .. search_query .. '" (' .. match_count .. ") " .. RESET)
	end

	local left_title = table.concat(tab_parts, compact_tabs and "" or " ")
	local right_info
	local busy_elapsed = repl_busy and math.max(0.0, (now_ms() / 1000.0) - repl_busy_started) or 0.0
	local rev_tag = ""
	if state and state.revise and state.revise ~= "" and not compact_tabs then
		if state.revise == "error" then
			rev_tag = FG_RED .. BOLD .. "Rev✗ " .. RESET
		elseif state.revise == "pending" then
			rev_tag = FG_YELLOW .. "Rev⚡ " .. RESET
		else
			rev_tag = FG_GREEN .. "Rev✓ " .. RESET
		end
	end
	if toast_msg and os.time() <= toast_expires then
		right_info = REV
			.. BOLD
			.. FG_GREEN
			.. " ⚡ "
			.. truncate_visible(toast_msg, math.max(10, term_cols - 20))
			.. " "
			.. RESET
	elseif repl_busy then
		right_info = rev_tag .. BOLD .. FG_YELLOW .. string.format("⟳ BUSY %.1fs", busy_elapsed) .. RESET
	else
		if compact_tabs then
			local sock_dot = (socket_fd >= 0) and (FG_GREEN .. "●" .. RESET) or (DIM .. FG_RED .. "○" .. RESET)
			local ts_str = (last_state_ts > 0) and os.date("%H:%M", last_state_ts) or "--:--"
			right_info = sock_dot .. " " .. DIM .. FG_GRAY .. ts_str .. RESET
		else
			local sock_icon = (socket_fd >= 0) and (FG_GREEN .. "● ONLINE" .. RESET)
				or (DIM .. FG_RED .. "○ OFFLINE" .. RESET)
			local ts_str = (last_state_ts > 0) and os.date("%H:%M:%S", last_state_ts) or "--:--:--"
			right_info = rev_tag
				.. DIM
				.. FG_GRAY
				.. "["
				.. get_backend_badge()
				.. "] "
				.. RESET
				.. sock_icon
				.. " "
				.. DIM
				.. FG_GRAY
				.. ts_str
				.. RESET
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

	local item_label = detail_item.name
		or (detail_item.id and ("Failed #" .. detail_item.id))
		or (detail_item.idx and ("History #" .. detail_item.idx))
		or "Item"
	local scroll_tag = string.format(
		"[%d-%d/%d]",
		math.min(total_lines, detail_scroll + 1),
		math.min(total_lines, detail_scroll + view_h),
		total_lines
	)
	local dtitle = " Detail: " .. truncate_visible(item_label, math.max(8, box_w - 28)) .. " " .. scroll_tag .. " "
	local dfill = math.max(0, box_w - visible_len(dtitle) - 4)
	table.insert(out_buf, move(2, 1))
	table.insert(
		out_buf,
		FG_AQUA
			.. "╭─"
			.. BOLD
			.. FG_WHITE
			.. dtitle
			.. RESET
			.. FG_AQUA
			.. string.rep("─", dfill)
			.. "─╮"
			.. RESET
	)

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
	table.insert(
		out_buf,
		FG_AQUA
			.. "╰"
			.. string.rep("─", bfill)
			.. DIM
			.. FG_LIGHT_GRAY
			.. bot_vis
			.. RESET
			.. FG_AQUA
			.. "─╯"
			.. RESET
	)

	table.insert(out_buf, move(term_rows, 1))
	local function pill(k, d)
		return BOLD .. FG_CYAN .. "[" .. k .. "]" .. RESET .. DIM .. FG_LIGHT_GRAY .. d .. " " .. RESET
	end
	local help = pill("j/k", "Scroll")
		.. pill("PgUp/Dn", "Page")
		.. pill("↵", "Run")
		.. pill("e", "Edit")
		.. pill("E", "$ED")
		.. pill("c", "Call")
		.. pill("v/Esc", "Close")
		.. pill("q", "Quit")
	table.insert(out_buf, pad_right(" " .. truncate_visible(help, math.max(1, term_cols - 1)), term_cols))
end

local function render_footer_pills(out_buf, term_rows, term_cols)
	table.insert(out_buf, move(term_rows, 1))
	local pills = {}
	if active_tab == 1 then
		pills = {
			{ k = "/", d = "Find", act = "/" },
			{ k = "v", d = "Slice", act = "v" },
			{ k = "o", d = "Sort", act = "o" },
			{ k = "h/l", d = "Fold", act = "l" },
			{ k = "↵", d = "Eval", act = "\r" },
			{ k = "e", d = "Use", act = "e" },
			{ k = "i", d = "Insp", act = "i" },
			{ k = "B", d = "Sess", act = "B" },
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
				{ k = "b", d = "Bench", act = "b" },
				{ k = "T", d = "Test", act = "T" },
				{ k = "e", d = "Edit", act = "e" },
				{ k = "E", d = "$ED", act = "E" },
				{ k = "c", d = "Call", act = "c" },
				{ k = "S", d = "Save", act = "S" },
				{ k = "R", d = "Load", act = "R" },
				{ k = "F", d = "Err", act = "F" },
				{ k = "v", d = "View", act = "v" },
				{ k = "d", d = "Del", act = "d" },
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
			{ k = "s", d = "Export", act = "s" },
			{ k = "o", d = "Open", act = "o" },
			{ k = "d", d = "Rm", act = "d" },
			{ k = "D", d = "Clr", act = "D" },
			{ k = "?", d = "Guide", act = "?" },
			{ k = "q", d = "Quit", act = "q" },
		}
	elseif active_tab == 6 then
		pills = {
			{ k = "/", d = "Find", act = "/" },
			{ k = "j/k", d = "Nav", act = "j" },
			{ k = "1-5", d = "Tabs", act = "1" },
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
	local prompt_line = "  Input: "
		.. BOLD
		.. FG_YELLOW
		.. truncate_visible(modal_input, math.max(4, inner - 11))
		.. RESET
		.. REV
		.. " "
		.. RESET
	local hint_line = "  "
		.. FG_GREEN
		.. "[↵]"
		.. RESET
		.. DIM
		.. " OK  "
		.. RESET
		.. FG_YELLOW
		.. "[C-u]"
		.. RESET
		.. DIM
		.. " Clr  "
		.. RESET
		.. FG_RED
		.. "[Esc]"
		.. RESET
		.. DIM
		.. " Cancel"
		.. RESET

	table.insert(out_buf, move(top, left) .. BOLD .. FG_CYAN .. top_border .. RESET)
	table.insert(
		out_buf,
		move(top + 1, left)
			.. BOLD
			.. FG_CYAN
			.. "│"
			.. RESET
			.. pad_right(prompt_line, inner)
			.. BOLD
			.. FG_CYAN
			.. "│"
			.. RESET
	)
	table.insert(
		out_buf,
		move(top + 2, left)
			.. BOLD
			.. FG_CYAN
			.. "│"
			.. RESET
			.. pad_right(truncate_visible(hint_line, inner), inner)
			.. BOLD
			.. FG_CYAN
			.. "│"
			.. RESET
	)
	table.insert(out_buf, move(top + 3, left) .. BOLD .. FG_CYAN .. bot_border .. RESET)
end

local function render_session_picker(out_buf, term_rows, term_cols)
	local n = #session_list
	local box_w = math.max(30, math.min(68, term_cols - 4))
	local inner = math.max(16, box_w - 2)
	local vis_n = math.max(1, math.min(n, term_rows - 8))
	local box_h = vis_n + 4
	local top = math.max(2, math.floor((term_rows - box_h) / 2))
	local left = math.max(1, math.floor((term_cols - box_w) / 2))

	local title = " Select Julia REPL Session (" .. n .. ") "
	local fill_w = math.max(0, box_w - 4 - visible_len(title))
	table.insert(
		out_buf,
		move(top, left)
			.. BOLD
			.. FG_CYAN
			.. "╭─"
			.. FG_WHITE
			.. title
			.. FG_CYAN
			.. string.rep("─", fill_w)
			.. "╮"
			.. RESET
	)
	for i = 1, vis_n do
		local s = session_list[i]
		local r = top + i
		table.insert(out_buf, move(r, left))
		if s then
			local is_cur = (s.socket == socket_path)
			local is_sel = (i == session_cursor)
			local pid_s = (s.pid and s.pid ~= "") and ("PID " .. s.pid) or s.name
			local st_s = (s.started and s.started ~= "") and (" · " .. s.started) or ""
			local cur_s = is_cur and " [attached]" or ""
			local txt = string.format(" %s %d. %s%s  (%s)%s", is_sel and "▸" or " ", i, pid_s, st_s, s.name, cur_s)
			local padded = pad_right(truncate_visible(txt, inner), inner)
			if is_sel then
				table.insert(out_buf, BOLD .. FG_CYAN .. "│" .. RESET .. REV .. FG_YELLOW .. padded .. RESET .. BOLD .. FG_CYAN .. "│" .. RESET)
			else
				local clr = is_cur and FG_GREEN or FG_WHITE
				table.insert(out_buf, BOLD .. FG_CYAN .. "│" .. RESET .. clr .. padded .. RESET .. BOLD .. FG_CYAN .. "│" .. RESET)
			end
		else
			table.insert(
				out_buf,
				BOLD .. FG_CYAN .. "│" .. RESET .. pad_right("  No live sessions found.", inner) .. BOLD .. FG_CYAN .. "│" .. RESET
			)
		end
	end
	local hint = "  [j/k] Move   [↵] Attach   [r] Rescan   [Esc] Cancel"
	table.insert(
		out_buf,
		move(top + vis_n + 1, left)
			.. BOLD
			.. FG_CYAN
			.. "│"
			.. RESET
			.. DIM
			.. FG_LIGHT_GRAY
			.. pad_right(truncate_visible(hint, inner), inner)
			.. RESET
			.. BOLD
			.. FG_CYAN
			.. "│"
			.. RESET
	)
	table.insert(out_buf, move(top + vis_n + 2, left) .. BOLD .. FG_CYAN .. "╰" .. string.rep("─", inner) .. "╯" .. RESET)
end

local function render(term_rows, term_cols)
	local out_buf = {}
	table.insert(out_buf, SYNC_START .. HIDE_CUR .. CLEAR)
	if graphics_dirty_clear or detail_view_active or modal_active or session_picker_active or active_tab ~= 5 then
		local clr_seq = views[5].clear_graphics_seq(detect_backend())
		if clr_seq ~= "" and (graphics_dirty_clear or detail_view_active or modal_active or session_picker_active) then
			table.insert(out_buf, clr_seq)
		end
		graphics_dirty_clear = false
	end
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
		local col_hdr
		col_hdr, header_err_hitbox = views[active_tab].header(term_cols, fcmds, proc_errors_view, workspace_sort)
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
		local is_plots_split = (
			active_tab == 5
			and total > 0
			and display_rows[1].kind ~= "empty_plots"
			and display_rows[1].kind ~= "empty_search"
			and display_rows[1].kind ~= "msg"
		)

		if is_proc_split then
			proc_preview_scroll, last_proc_preview_key, preview_split_row = views[3].render_split({
				out_buf = out_buf, display_rows = display_rows, row_hitboxes = row_hitboxes,
				term_rows = term_rows, term_cols = term_cols, header_rows = header_rows,
				content_rows = content_rows, total = total, cursor = cursor,
				preview_scroll = proc_preview_scroll, preview_key = last_proc_preview_key,
				compute_win_start = compute_win_start, state = state,
			})
		elseif is_plots_split then
			preview_split_row = views[5].render_split({
				out_buf = out_buf, display_rows = display_rows, row_hitboxes = row_hitboxes,
				term_rows = term_rows, term_cols = term_cols, header_rows = header_rows,
				content_rows = content_rows, total = total, cursor = cursor,
				compute_win_start = compute_win_start, backend = detect_backend(),
			})
		else
			-- Full height list for Workspace, History, Packages, Guide (and empty states)
			local win_start = compute_win_start(total, content_rows)
			local view = views[active_tab]
			local row_ctx = { col_cursor = col_cursor, history_selected = history_selected }

			local row_idx = header_rows + 1
			for i = win_start, math.min(win_start + content_rows - 1, total) do
				local dr = display_rows[i]
				local sel = (i == cursor)
				row_hitboxes[row_idx] = i
				table.insert(out_buf, move(row_idx, 1))

				if
					view.render_row
					and dr.kind ~= "empty_proc"
					and dr.kind ~= "empty_plots"
					and dr.kind ~= "empty_search"
					and dr.kind ~= "msg"
				then
					view.render_row(out_buf, dr, sel, term_cols, row_ctx)
				elseif dr.kind == "empty_proc" then
					row_idx = views[3].render_empty(out_buf, row_idx, term_cols)
				elseif dr.kind == "empty_plots" then
					row_idx = views[5].render_empty(out_buf, row_idx, term_cols)
				elseif dr.kind == "empty_search" then
					local box_w = math.max(24, math.min(54, term_cols - 4))
					local inner = math.max(10, box_w - 2)
					table.insert(
						out_buf,
						FG_YELLOW
							.. "  ╭─ "
							.. BOLD
							.. "🔍 Search Filter "
							.. RESET
							.. FG_YELLOW
							.. string.rep("─", math.max(0, box_w - 22))
							.. "╮"
							.. RESET
					)
					row_idx = row_idx + 1
					table.insert(out_buf, move(row_idx, 1))
					table.insert(
						out_buf,
						FG_YELLOW
							.. "  │"
							.. RESET
							.. pad_right(truncate_visible("  " .. (dr.text or "No matches found."), inner), inner)
							.. FG_YELLOW
							.. "│"
							.. RESET
					)
					row_idx = row_idx + 1
					table.insert(out_buf, move(row_idx, 1))
					table.insert(
						out_buf,
						FG_YELLOW
							.. "  │"
							.. RESET
							.. DIM
							.. pad_right(truncate_visible("  Press [Esc] or 'x' to clear search filter", inner), inner)
							.. RESET
							.. FG_YELLOW
							.. "│"
							.. RESET
					)
					row_idx = row_idx + 1
					table.insert(out_buf, move(row_idx, 1))
					table.insert(out_buf, FG_YELLOW .. "  ╰" .. string.rep("─", inner) .. "╯" .. RESET)
				elseif dr.kind == "msg" then
					table.insert(
						out_buf,
						DIM .. pad_right(truncate_visible("  " .. (dr.text or ""), term_cols), term_cols) .. RESET
					)
				end

				row_idx = row_idx + 1
			end
		end

		-- Row term_rows - 1: Search Prompt / Bottom Divider
		table.insert(out_buf, move(term_rows - 1, 1))
		if search_mode then
			local sbar = BOLD
				.. FG_YELLOW
				.. " 🔍 Search: "
				.. RESET
				.. BOLD
				.. FG_WHITE
				.. search_query
				.. REV
				.. " "
				.. RESET
				.. DIM
				.. FG_GRAY
				.. "  [Enter] Confirm   [Esc] Clear"
				.. RESET
			table.insert(out_buf, pad_right(truncate_visible(sbar, term_cols), term_cols))
		elseif search_query ~= "" then
			local sbar = DIM
				.. FG_YELLOW
				.. ' 🔍 Filter: "'
				.. search_query
				.. '" ('
				.. match_count
				.. ") — 'x' or [Esc] clear"
				.. RESET
			table.insert(out_buf, pad_right(truncate_visible(sbar, term_cols), term_cols))
		else
			table.insert(out_buf, FG_DARK_GRAY .. string.rep("─", term_cols) .. RESET)
		end

		-- Row term_rows: Shortcut Pills (adaptive width + mouse hitboxes)
		render_footer_pills(out_buf, term_rows, term_cols)
	end

	-- Modal popup overlay if active
	if session_picker_active then
		render_session_picker(out_buf, term_rows, term_cols)
	elseif modal_active then
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

	io.write((mouse_enabled and MOUSE_OFF or "") .. ALT_SCREEN_OFF .. SHOW_CUR)
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

local function prompt_or_invoke_procedure(dr, helper_fn, verb_lbl)
	if not dr or dr.kind ~= "procedure" then
		return
	end
	helper_fn = helper_fn or "run_procedure"
	verb_lbl = verb_lbl or "▶ Running procedure "
	if dr.needs_args then
		modal_active = true
		modal_title = "Args for " .. (dr.signature or dr.name)
		modal_input = (last_modal_args[dr.name] and last_modal_args[dr.name] ~= "") and last_modal_args[dr.name]
			or (dr.last_args or "")
		modal_callback = function(ans)
			local a = (ans or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if a ~= "" then
				last_modal_args[dr.name] = a
			end
			if a == "" then
				tmux_send(string.format("jEMach.%s(:%s)", helper_fn, dr.name))
			elseif a:sub(1, 1) == ";" then
				tmux_send(string.format("jEMach.%s(:%s%s)", helper_fn, dr.name, a))
			else
				tmux_send(string.format("jEMach.%s(:%s, %s)", helper_fn, dr.name, a))
			end
			set_toast(verb_lbl .. dr.name .. "...")
		end
		dirty = true
	else
		tmux_send(string.format("jEMach.%s(:%s)", helper_fn, dr.name))
		set_toast(verb_lbl .. dr.name .. "...")
	end
end

local function prompt_or_run_procedure(dr)
	return prompt_or_invoke_procedure(dr, "run_procedure", "▶ Running procedure ")
end

local function prompt_or_bench_procedure(dr)
	return prompt_or_invoke_procedure(dr, "benchmark_procedure", "⏱ Benchmarking ")
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
	if modal_active or search_mode or session_picker_active then
		return nil
	end

	-- Tab bar click (Row 1)
	if my == 1 then
		for _, hb in ipairs(tab_hitboxes) do
			if mx >= hb.x1 and mx <= hb.x2 then
				if detail_view_active then
					detail_view_active = false
					detail_item = nil
					send_socket_json('{"cmd":"clear_inspector"}')
				end
				if hb.tab == 6 then
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
			send_socket_json('{"cmd":"clear_inspector"}')
		end
		return nil
	end

	-- Row 3 header badge click ([F] Errors in Tab 3, [o] Sort in Tab 1)
	if my == 3 and header_err_hitbox and mx >= header_err_hitbox.x1 and mx <= header_err_hitbox.x2 then
		if active_tab == 3 then
			return handle_key("F", term_rows, term_cols)
		elseif active_tab == 1 then
			return handle_key("o", term_rows, term_cols)
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

	-- Interactive Session Switcher interception
	if session_picker_active then
		if key == "\27" or key == "q" or key == "B" or key == "\19" then
			session_picker_active = false
			dirty = true
			return
		elseif key == "j" or key == "\27[B" then
			if #session_list > 0 then
				session_cursor = math.min(#session_list, session_cursor + 1)
				dirty = true
			end
			return
		elseif key == "k" or key == "\27[A" then
			if #session_list > 0 then
				session_cursor = math.max(1, session_cursor - 1)
				dirty = true
			end
			return
		elseif key == "r" then
			session_list = sessions.discover()
			session_cursor = math.max(1, math.min(session_cursor, #session_list))
			dirty = true
			return
		elseif key == "\r" or key == "\n" then
			local chosen = session_list[session_cursor]
			session_picker_active = false
			if chosen then
				attach_to_session(chosen)
			end
			dirty = true
			return
		end
		return
	end

	-- Modal input interception (full UTF-8 + CSI-u Unicode support)
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
		elseif key == "\127" or key == "\8" then -- UTF-8 safe Backspace
			if #modal_input > 0 then
				modal_input = utf8_pop(modal_input)
				dirty = true
			end
			return
		elseif is_printable_key(key) then
			modal_input = modal_input .. key
			dirty = true
			return
		end
		return
	end

	-- Search mode interception (full UTF-8 + fixed Ctrl+U clear)
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
		elseif key == "\21" then -- Ctrl+U clear search query
			search_query = ""
			build_display_rows()
			clamp_cursor()
			dirty = true
			return
		elseif key == "\127" or key == "\8" then -- UTF-8 safe Backspace
			if #search_query > 0 then
				search_query = utf8_pop(search_query)
				build_display_rows()
				clamp_cursor()
				dirty = true
			end
			return
		elseif is_printable_key(key) then
			search_query = search_query .. key
			build_display_rows()
			clamp_cursor()
			dirty = true
			return
		end
		return
	end

	-- Full-screen detail / error / 2D slice viewer interception
	if detail_view_active then
		local page = math.max(1, (term_rows or 24) - 6)
		local is_ws_item = (detail_item and detail_item.kind == "item")
		local insp = (is_ws_item and state and type(state.inspector) == "table" and state.inspector.expr == detail_item.expr)
				and state.inspector
			or nil
		local slice_step = math.max(10, (term_rows or 30) - 10)
		if key == "q" then
			return "quit"
		elseif key == "v" or key == "\27" then
			detail_view_active = false
			detail_item = nil
			if is_ws_item then
				send_socket_json('{"cmd":"clear_inspector"}')
			end
			dirty = true
			return
		elseif is_ws_item and insp and (key == "J" or key == "\27[6~") then
			local tot_r = math.max(1, tonumber(insp.total_rows) or 1)
			inspector_row = math.min(tot_r, inspector_row + slice_step)
			detail_scroll = 0
			request_inspector_slice(detail_item, inspector_row, inspector_col, term_rows)
			dirty = true
			return
		elseif is_ws_item and insp and (key == "K" or key == "\27[5~") then
			inspector_row = math.max(1, inspector_row - slice_step)
			detail_scroll = 0
			request_inspector_slice(detail_item, inspector_row, inspector_col, term_rows)
			dirty = true
			return
		elseif is_ws_item and insp and (key == "L" or key == "l" or key == "\27[C") then
			local tot_c = math.max(1, tonumber(insp.total_cols) or 1)
			if tot_c > 1 then
				inspector_col = math.min(tot_c, inspector_col + 1)
				request_inspector_slice(detail_item, inspector_row, inspector_col, term_rows)
				dirty = true
			end
			return
		elseif is_ws_item and insp and (key == "H" or key == "h" or key == "\27[D") then
			if inspector_col > 1 then
				inspector_col = math.max(1, inspector_col - 1)
				request_inspector_slice(detail_item, inspector_row, inspector_col, term_rows)
				dirty = true
			end
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
			if is_ws_item and insp and inspector_row > 1 then
				inspector_row = 1
				request_inspector_slice(detail_item, inspector_row, inspector_col, term_rows)
			end
			detail_scroll = 0
			dirty = true
			return
		elseif key == "G" then
			if is_ws_item and insp and (tonumber(insp.total_rows) or 0) > slice_step then
				inspector_row = math.max(1, (tonumber(insp.total_rows) or 1) - slice_step + 1)
				request_inspector_slice(detail_item, inspector_row, inspector_col, term_rows)
				detail_scroll = 0
			else
				detail_scroll = 999999
			end
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
					local edit_src = (detail_item.edit_code and detail_item.edit_code ~= "") and detail_item.edit_code
						or (detail_item.code or "")
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

	-- Open interactive Julia Session Switcher (Ctrl+S or B)
	if key == "\19" or key == "B" then
		session_list = sessions.discover()
		session_cursor = 1
		for i, s in ipairs(session_list) do
			if s.socket == socket_path then
				session_cursor = i
				break
			end
		end
		session_picker_active = true
		dirty = true
		return
	end

	-- Open / toggle Guide tab (?)
	if key == "?" then
		if guide_tab_open and active_tab == 6 then
			guide_tab_open = false
			local target = (return_tab >= 1 and return_tab <= 5) and return_tab or 1
			switch_tab(target)
		else
			if active_tab ~= 6 then
				return_tab = active_tab
			end
			guide_tab_open = true
			switch_tab(6)
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
	if key == "\27" and active_tab == 6 and guide_tab_open then
		guide_tab_open = false
		local target = (return_tab >= 1 and return_tab <= 5) and return_tab or 1
		switch_tab(target)
		return
	end

	-- Direct tab jump keys
	if key == "1" then
		switch_tab(1)
		return
	end
	if key == "2" then
		switch_tab(2)
		return
	end
	if key == "3" then
		switch_tab(3)
		return
	end
	if key == "4" then
		switch_tab(4)
		return
	end
	if key == "5" then
		switch_tab(5)
		return
	end
	if key == "6" then
		if active_tab ~= 6 then
			return_tab = active_tab
		end
		guide_tab_open = true
		switch_tab(6)
		return
	end

	-- Tab cycle keys
	local max_tabs = guide_tab_open and 6 or 5
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
						sync_expanded_paths()
					else
						local parent_path = dr.path:match("(.*)/[^/]+$")
						if parent_path and parent_path ~= dr.module_name then
							collapsed[parent_path] = true
							sync_expanded_paths()
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
						sync_expanded_paths()
						build_display_rows()
						clamp_cursor()
					elseif col_cursor < 3 then
						col_cursor = col_cursor + 1
					end
				end
			end
		elseif key == "v" then
			local dr = display_rows[cursor]
			if dr and dr.kind == "item" then
				detail_view_active = true
				detail_item = dr
				detail_scroll = 0
				inspector_row = 1
				inspector_col = 1
				request_inspector_slice(dr, 1, 1, term_rows)
				dirty = true
			end
		elseif key == "o" then
			local next_idx = 1
			for idx, m in ipairs(WORKSPACE_SORTS) do
				if m == workspace_sort then
					next_idx = (idx % #WORKSPACE_SORTS) + 1
					break
				end
			end
			workspace_sort = WORKSPACE_SORTS[next_idx]
			build_display_rows()
			clamp_cursor()
			set_toast("Sort Workspace: " .. workspace_sort)
			dirty = true
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
			sync_expanded_paths()
			repl_eval("jEMach.publish_state()", true, false)
			set_toast("↻ Refreshed workspace")
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
			set_toast(
				history_prev_collapsed and "Previous session history folded" or "Previous session history expanded"
			)
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
				if history_selected[i] then
					any = true
					break
				end
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
				if name == "" then
					return
				end
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
				local cmd =
					string.format("jEMach.make_procedure(:%s; commands=String[%s])", name, table.concat(sel_cmds, ", "))
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
		elseif key == "b" then
			if dr and dr.kind == "procedure" then
				prompt_or_bench_procedure(dr)
			end
		elseif key == "T" then
			if dr and dr.kind == "procedure" then
				repl_eval(string.format("jEMach.generate_procedure_test(:%s)", dr.name), false, false)
				set_toast("✓ Generated @testset in test/procedures/")
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
				local a = (last_modal_args[dr.name] and last_modal_args[dr.name] ~= "") and last_modal_args[dr.name]
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
						repl_eval(
							string.format("jEMach.save_procedure(:%s; as_name=:%s)", dr.name, target),
							true,
							false
						)
					end
					set_toast("💾 Saved to procedures/" .. target .. ".jl")
				end
			end
		elseif key == "d" then
			if dr and dr.kind == "procedure" then
				modal_active = true
				modal_title = (dr.file and dr.file ~= "") and ("Delete '" .. dr.name .. "' (" .. dr.file .. ")? (y/n)")
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
	-- Tab 5: Plots (Kitty Graphics Gallery)
	-- -----------------------------------------------------------------------
	elseif active_tab == 5 then
		local dr = display_rows[cursor]
		if key == "s" then
			if dr and dr.kind == "plot" then
				modal_active = true
				modal_title = "Export Plot #" .. tostring(dr.id) .. " to ./plots/"
				modal_input = string.format("plot_%d.png", dr.id)
				modal_callback = function(fname)
					fname = (fname or ""):gsub("^%s+", ""):gsub("%s+$", "")
					repl_eval(string.format("jEMach._export_plot(%d, %q)", dr.id, fname), true, false)
					set_toast("💾 Exported to ./plots/" .. (fname ~= "" and fname or ("plot_" .. dr.id .. ".png")))
				end
			end
		elseif key == "o" or key == "\r" or key == "\n" then
			if dr and dr.kind == "plot" and dr.path and dr.path ~= "" then
				local opener = (ffi.os == "OSX") and "open" or "xdg-open"
				os.execute(string.format("nohup %s '%s' >/dev/null 2>&1 &", opener, dr.path:gsub("'", "'\\''")))
				set_toast("Opened Plot #" .. tostring(dr.id))
			end
		elseif key == "d" then
			if dr and dr.kind == "plot" then
				graphics_dirty_clear = true
				repl_eval(string.format("jEMach._delete_plot!(%d)", dr.id), true, false)
				set_toast("Removed Plot #" .. tostring(dr.id))
			end
		elseif key == "D" then
			graphics_dirty_clear = true
			repl_eval("jEMach._clear_plots!()", true, false)
			set_toast("Cleared plot gallery")
		elseif key == "c" then
			repl_clear()
		end

	-- -----------------------------------------------------------------------
	-- Tab 6: Guide
	-- -----------------------------------------------------------------------
	elseif active_tab == 6 then
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
		local clr_seq = views[5].clear_graphics_seq(detect_backend())
		io.write(clr_seq .. MOUSE_OFF .. ALT_SCREEN_OFF .. SHOW_CUR)
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

			if repl_busy then
				dirty = true
			end

			if dirty then
				build_display_rows()
				clamp_cursor()
				render(term_rows, term_cols)
				dirty = false
			end

			local wait_ms = repl_busy and 250 or REFRESH_MS
			local key = get_next_key(wait_ms)
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
