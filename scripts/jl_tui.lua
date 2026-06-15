#!/usr/bin/env luajit
-- jl_tui.lua — Standalone Julia Workspace TUI
--
-- Requires: luajit (ships with Neovim on Arch Linux)
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
-- FFI: non-blocking stdin read via select(2) + read(2)
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
]])

local STDIN = 0

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

-- Read a single key-press (or escape sequence) with a timeout in ms.
-- Returns nil if no input arrived within the timeout.
local function read_key(timeout_ms)
	local fds = fd_set_new()
	fd_set_set(fds, STDIN)
	local tv = ffi.new("timeval_t", { tv_sec = 0, tv_usec = (timeout_ms or 100) * 1000 })
	local ready = ffi.C.select(STDIN + 1, fds, nil, nil, tv)
	if ready <= 0 then
		return nil
	end

	local buf = ffi.new("char[8]")
	local n = tonumber(ffi.C.read(STDIN, buf, 8))
	if not n or n <= 0 then
		return nil
	end

	local s = ""
	for i = 0, n - 1 do
		s = s .. string.char(buf[i])
	end
	return s
end

-- ---------------------------------------------------------------------------
-- Terminal control helpers (ANSI/VT100)
-- ---------------------------------------------------------------------------
local ESC = "\27"
local CLEAR = ESC .. "[2J" .. ESC .. "[H"
local HIDE_CUR = ESC .. "[?25l"
local SHOW_CUR = ESC .. "[?25h"
local BOLD = ESC .. "[1m"
local DIM = ESC .. "[2m"
local RESET = ESC .. "[0m"
local REV = ESC .. "[7m" -- reverse video (selection highlight)
local FG_CYAN = ESC .. "[36m"
local FG_GREEN = ESC .. "[32m"
local FG_YELLOW = ESC .. "[33m"
local FG_RED = ESC .. "[31m"
local FG_WHITE = ESC .. "[37m"

local function move(row, col)
	return ESC .. "[" .. row .. ";" .. col .. "H"
end

local function get_terminal_size()
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
local function json_parse(s)
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
local STATE_FILE = "/tmp/jl_tui_state.json"
local REFRESH_MS = 1500 -- state file poll interval (ms)

local repl_pane = arg and arg[1] or "{left-of}"

-- hidden[key] = true  means the item is hidden from view
-- key = "ModuleName" for a module header, "ModuleName/ItemName" for items
local hidden = {}
-- collapsed[module_name] = true
local collapsed = {}

-- Flat list of "display rows" rebuilt each render pass
--   { kind="module", name, row_idx }
--   { kind="item",   module_name, name, item_type, item_kind, value, row_idx }
--   { kind="gap" }
local display_rows = {}
local cursor = 1
local col_cursor = 1 -- 1: Name, 2: Type, 3: Value
local state = nil -- last parsed JSON state
local last_mtime = 0
local last_state_ts = 0

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
	local mt = file_mtime(STATE_FILE)
	if mt == last_mtime then
		return
	end
	last_mtime = mt

	local f = io.open(STATE_FILE, "r")
	if not f then
		return
	end
	local content = f:read("*a")
	f:close()

	local ok, parsed = pcall(json_parse, content)
	if ok and parsed then
		state = parsed
		last_state_ts = os.time()
	end
end

-- ---------------------------------------------------------------------------
-- Build the flat display_rows list from current state + collapsed/hidden sets
-- ---------------------------------------------------------------------------
local function build_display_rows()
	display_rows = {}

	if not state or not state.modules then
		display_rows[1] = {
			kind = "msg",
			text = 'Waiting for Julia watcher…  (include("scripts/jl_watcher.jl"))',
		}
		return
	end

	for _, mod in ipairs(state.modules) do
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
					local iname = item.name or "?"
					local key = mname .. "/" .. iname
					if not hidden[key] then
						table.insert(display_rows, {
							kind = "item",
							module_name = mname,
							name = iname,
							item_kind = item.kind or "variable",
							item_type = item.type or "",
							value = item.value or "",
						})
					end
				end
			end
		end
	end

	if #display_rows == 0 then
		display_rows[1] = { kind = "msg", text = "Workspace is empty." }
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
end

-- ---------------------------------------------------------------------------
-- tmux send-keys to Julia REPL
-- ---------------------------------------------------------------------------
local function tmux_send(code)
	-- Escape single-quotes for shell
	local escaped = code:gsub("'", "'\\''")
	os.execute(string.format("tmux send-keys -t '%s' '%s' Enter", repl_pane, escaped))
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
local function pad_right(s, width)
	s = tostring(s or "")
	if #s >= width then
		return s:sub(1, width)
	end
	return s .. string.rep(" ", width - #s)
end

local KIND_COLOR = {
	["function"] = FG_CYAN,
	["type"] = FG_YELLOW,
	["variable"] = FG_WHITE,
	["module"] = FG_GREEN,
}

local function render(term_rows, term_cols)
	io.write(HIDE_CUR .. CLEAR)

	-- Title bar
	local title = " jEMach Panel C-a +l/+h to enter/quit  [" .. repl_pane .. "]"
	if last_state_ts > 0 then
		title = title .. "  ✓ " .. os.date("%H:%M:%S", last_state_ts)
	end
	io.write(move(1, 1))
	io.write(BOLD .. FG_GREEN .. pad_right(title, term_cols) .. RESET)

	io.write(move(2, 1))
	io.write(DIM .. string.rep("─", term_cols) .. RESET)

	local content_rows = term_rows - 4 -- top 2 lines + bottom 2 lines reserved
	local total = #display_rows

	local win_start = 1
	if cursor > content_rows then
		win_start = cursor - content_rows + 1
	end

	local row_idx = 3
	for i = win_start, math.min(win_start + content_rows - 1, total) do
		local dr = display_rows[i]
		local sel = (i == cursor)

		io.write(move(row_idx, 1))

		if dr.kind == "module" then
			local color = FG_GREEN
			local line = string.format("  %s %-20s", dr.icon, dr.name)
			if sel then
				io.write(REV .. BOLD .. pad_right(line, term_cols) .. RESET)
			else
				io.write(color .. BOLD .. pad_right(line, term_cols) .. RESET)
			end
		elseif dr.kind == "item" then
			local kc = KIND_COLOR[dr.item_kind] or FG_WHITE
			local name_col = pad_right("    " .. dr.name, 26)
			local type_col = pad_right(dr.item_type, 18)
			local val_col = dr.value
			-- fit value inside remaining space
			local fixed_w = 26 + 18 + 4
			local val_max = math.max(0, term_cols - fixed_w - 1)
			if #val_col > val_max then
				val_col = val_col:sub(1, val_max - 1) .. "…"
			end
			val_col = pad_right(val_col, term_cols - 26 - 18 - 4)

			if sel then
				local out_str
				if col_cursor == 1 then
					out_str = REV .. name_col .. RESET .. kc .. "  " .. type_col .. "  " .. val_col
				elseif col_cursor == 2 then
					out_str = name_col .. "  " .. REV .. type_col .. RESET .. kc .. "  " .. val_col
				else
					out_str = name_col .. "  " .. type_col .. "  " .. REV .. val_col .. RESET
				end
				io.write(kc .. out_str .. RESET)
			else
				io.write(kc .. name_col .. "  " .. type_col .. "  " .. val_col .. RESET)
			end
		elseif dr.kind == "msg" then
			io.write(DIM .. pad_right("  " .. (dr.text or ""), term_cols) .. RESET)
		end

		row_idx = row_idx + 1
	end

	-- Bottom separator + help line
	io.write(move(term_rows - 1, 1))
	io.write(DIM .. string.rep("─", term_cols) .. RESET)

	io.write(move(term_rows, 1))
	local help = "  j/k:move  h/l:col/fold  ↵:eval  i:inspect  c:clear REPL  d:hide  q:quit"
	io.write(DIM .. pad_right(help, term_cols) .. RESET)

	io.flush()
end

-- ---------------------------------------------------------------------------
-- Input handling
-- ---------------------------------------------------------------------------
local function handle_key(key, term_rows, term_cols)
	if not key then
		return
	end

	-- Quit
	if key == "q" or key == "\3" then -- q or Ctrl-C
		return "quit"
	end

	-- Movement
	if key == "j" or key == "\27[B" then -- j or Down arrow
		cursor = cursor + 1
		clamp_cursor()
	elseif key == "k" or key == "\27[A" then -- k or Up arrow
		cursor = cursor - 1
		clamp_cursor()

	-- Collapse (h)
	elseif key == "h" or key == "\27[D" then
		local dr = display_rows[cursor]
		if dr then
			if dr.kind == "module" then
				collapsed[dr.name] = true
			elseif dr.kind == "item" then
				if col_cursor > 1 then
					col_cursor = col_cursor - 1
				else
					-- jump to parent and collapse
					collapsed[dr.module_name] = true
					-- re-position cursor to parent module row
					for i, r in ipairs(display_rows) do
						if r.kind == "module" and r.name == dr.module_name then
							cursor = i
							break
						end
					end
				end
			end
			build_display_rows()
			clamp_cursor()
		end

	-- Expand / print (l or Enter)
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
				if col_cursor < 3 then
					col_cursor = col_cursor + 1
				end
			end
		end

	-- Enter key
	elseif key == "\r" or key == "\n" then
		local dr = display_rows[cursor]
		if dr then
			if dr.kind == "module" and dr.collapsed then
				collapsed[dr.name] = nil
				build_display_rows()
				clamp_cursor()
			elseif dr.kind == "item" then
				-- Validate name to prevent injection
				if dr.name:match("^[%a_][%w_!]*$") then
					local code
					if col_cursor == 1 then
						code = "println(" .. dr.name .. ")"
					elseif col_cursor == 2 then
						code = "typeof(" .. dr.name .. ")"
					else
						code = "dump(" .. dr.name .. ")"
					end
					tmux_send(code)
				end
			end
		end

	-- Inspect (i)
	elseif key == "i" then
		local dr = display_rows[cursor]
		if dr and dr.kind == "item" then
			if dr.name:match("^[%a_][%w_!]*$") then
				local code = string.format("jEMach.inspect_var(%s, %q)", dr.module_name, dr.name)
				tmux_send(code)
			end
		end

	-- Clear REPL (c)
	elseif key == "c" then
		os.execute(string.format("tmux send-keys -t '%s' C-l", repl_pane))

	-- Hide (d)
	elseif key == "d" then
		local dr = display_rows[cursor]
		if dr then
			if dr.kind == "module" then
				hidden[dr.name] = true
			elseif dr.kind == "item" then
				hidden[dr.module_name .. "/" .. dr.name] = true
			end
			build_display_rows()
			if cursor > #display_rows then
				cursor = #display_rows
			end
			clamp_cursor()
		end
	elseif key == "P" then
		local dr = display_rows[cursor]
		if dr then
			if dr.kind == "module" then
				print("Module: " .. dr.name)
			elseif dr.kind == "item" then
				print(string.format("Item: %s  Type: %s  Value: %s", dr.name, dr.item_type, dr.value))
			end
		end

	-- Restore all hidden (D)
	elseif key == "D" then
		hidden = {}
		build_display_rows()
		clamp_cursor()

	-- Force refresh (r)
	elseif key == "r" then
		last_mtime = 0 -- force reload on next poll
	end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local function main()
	raw_mode_on()

	-- Ensure terminal is restored on exit
	local function cleanup()
		raw_mode_off()
		io.write(SHOW_CUR .. CLEAR)
		io.flush()
	end

	-- Run cleanup on normal exit or Lua error
	local ok, err = pcall(function()
		local last_render_key = 0
		local term_rows, term_cols = get_terminal_size()
		local resize_counter = 0

		load_state()
		build_display_rows()
		clamp_cursor()

		while true do
			-- Poll terminal size every ~20 cycles (~2s)
			resize_counter = resize_counter + 1
			if resize_counter >= 20 then
				resize_counter = 0
				term_rows, term_cols = get_terminal_size()
			end

			load_state()
			build_display_rows()
			clamp_cursor()

			render(term_rows, term_cols)

			local key = read_key(REFRESH_MS)
			local result = handle_key(key, term_rows, term_cols)
			if result == "quit" then
				break
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
