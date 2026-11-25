local theme = require("tui.theme")
local BOLD = theme.BOLD
local DIM = theme.DIM
local RESET = theme.RESET
local REV = theme.REV
local FG_CYAN = theme.FG_CYAN
local FG_AQUA = theme.FG_AQUA
local FG_GREEN = theme.FG_GREEN
local FG_YELLOW = theme.FG_YELLOW
local FG_WHITE = theme.FG_WHITE
local FG_LIGHT_GRAY = theme.FG_LIGHT_GRAY
local FG_GRAY = theme.FG_GRAY
local FG_DARK_GRAY = theme.FG_DARK_GRAY
local BG_PANEL = theme.BG_PANEL
local text = require("tui.text")
local visible_len = text.visible_len
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible
local base64_encode = text.base64_encode
local preview = require("tui.preview")
local fmt_bytes = preview.fmt_bytes

local function move(row, col)
	return theme.ESC .. "[" .. row .. ";" .. col .. "H"
end

local function supports_kitty_graphics(backend)
	local force = (os.getenv("JEMACH_GRAPHICS") or ""):lower()
	if force == "none" or force == "0" or force == "off" then
		return false, false
	end
	local in_tmux = (os.getenv("TMUX") or "") ~= ""
	if force == "kitty" or force == "1" or force == "on" then
		return true, in_tmux
	end
	local b = tostring(backend or ""):lower()
	local tp = (os.getenv("TERM_PROGRAM") or ""):lower()
	local term = (os.getenv("TERM") or ""):lower()
	local has_kgp = (b == "kitty" or b == "ghostty")
		or (tp == "kitty" or tp == "ghostty" or tp == "wezterm")
		or (os.getenv("KITTY_WINDOW_ID") ~= nil)
		or (os.getenv("GHOSTTY_RESOURCES_DIR") ~= nil)
		or (term == "xterm-kitty" or term == "xterm-ghostty")
	return has_kgp, (has_kgp and in_tmux)
end

local function wrap_tmux_dcs(seq, use_tmux)
	if not use_tmux then
		return seq
	end
	return "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
end

local function clear_graphics_seq(backend)
	local ok, use_tmux = supports_kitty_graphics(backend)
	if not ok then
		return ""
	end
	return wrap_tmux_dcs("\27_Ga=d,d=A,q=2;\27\\", use_tmux)
end

local M = {
	clear_graphics_seq = clear_graphics_seq,
	supports_kitty_graphics = supports_kitty_graphics,
}

function M.build(ctx, q)
	local state = ctx.state
	local search_query = ctx.search_query
	local has_filter = q ~= ""
	local display_rows = {}
	local plots = state and state.plots or {}

	if #plots == 0 then
		display_rows[1] = { kind = "empty_plots" }
		return display_rows
	end

	for i, pl in ipairs(plots) do
		local ptitle = pl.title or "plot"
		local pts = pl.timestamp or ""
		local ppath = pl.path or ""
		if
			not has_filter
			or ptitle:lower():find(q, 1, true)
			or pts:lower():find(q, 1, true)
			or tostring(pl.id or ""):find(q, 1, true)
		then
			table.insert(display_rows, {
				kind = "plot",
				idx = i,
				id = tonumber(pl.id) or i,
				title = ptitle,
				timestamp = pts,
				path = ppath,
				width = tonumber(pl.width) or 0,
				height = tonumber(pl.height) or 0,
				bytes = tonumber(pl.bytes) or 0,
			})
		end
	end

	if #display_rows == 0 then
		display_rows[1] = { kind = "empty_search", text = 'No plots matching "' .. search_query .. '".' }
	end
	return display_rows
end

function M.render_split(ctx)
	local out_buf, display_rows, row_hitboxes = ctx.out_buf, ctx.display_rows, ctx.row_hitboxes
	local term_rows, term_cols = ctx.term_rows, ctx.term_cols
	local header_rows, content_rows, total, cursor = ctx.header_rows, ctx.content_rows, ctx.total, ctx.cursor
	local compute_win_start = ctx.compute_win_start
	local backend = ctx.backend or "standalone"

	local list_max_h = math.min(total, math.max(3, math.floor(content_rows * 0.30)))
	local preview_h = math.max(3, content_rows - list_max_h - 1)
	local win_start = compute_win_start(total, list_max_h)

	local row_idx = header_rows + 1
	for i = win_start, math.min(win_start + list_max_h - 1, total) do
		local dr = display_rows[i]
		local sel = (i == cursor)
		row_hitboxes[row_idx] = i
		table.insert(out_buf, move(row_idx, 1))

		local sel_bar = sel and (FG_CYAN .. BOLD .. "▸" .. RESET) or " "
		local badge = FG_GREEN .. "◈ " .. RESET
		local id_s = string.format("#%-3d ", dr.id or i)
		local dims_s = (dr.width > 0 and dr.height > 0) and string.format("%dx%d", dr.width, dr.height) or "PNG"
		local meta_s = string.format("%s  %s  %s", dims_s, fmt_bytes(dr.bytes or 0), dr.timestamp or "")
		local avail = math.max(12, term_cols - 9)
		local meta_w = math.min(28, math.max(12, #meta_s))
		local title_w = math.max(8, avail - meta_w - 2)
		local title_col = pad_right(truncate_visible(dr.title or "plot", title_w), title_w)
		local meta_col = pad_right(truncate_visible(meta_s, meta_w), meta_w)

		if sel then
			table.insert(
				out_buf,
				sel_bar
					.. badge
					.. FG_YELLOW
					.. id_s
					.. RESET
					.. REV
					.. BOLD
					.. FG_CYAN
					.. title_col
					.. RESET
					.. "  "
					.. FG_LIGHT_GRAY
					.. meta_col
					.. RESET
			)
		else
			table.insert(
				out_buf,
				sel_bar
					.. badge
					.. DIM
					.. FG_YELLOW
					.. id_s
					.. RESET
					.. FG_WHITE
					.. title_col
					.. RESET
					.. "  "
					.. DIM
					.. FG_GRAY
					.. meta_col
					.. RESET
			)
		end
		row_idx = row_idx + 1
	end

	local split_row = header_rows + 1 + list_max_h
	table.insert(out_buf, move(split_row, 1))
	local sel_pl = display_rows[cursor]
	local p_left = " Plot Preview"
	if sel_pl and sel_pl.kind == "plot" then
		local res_lbl = (sel_pl.width > 0 and sel_pl.height > 0)
				and string.format("%dx%d · ", sel_pl.width, sel_pl.height)
			or ""
		p_left = " "
			.. FG_GREEN
			.. "◈"
			.. RESET
			.. " "
			.. BOLD
			.. FG_WHITE
			.. "Plot #"
			.. tostring(sel_pl.id or 1)
			.. RESET
			.. DIM
			.. FG_GRAY
			.. " ["
			.. res_lbl
			.. fmt_bytes(sel_pl.bytes or 0)
			.. "]"
			.. RESET
	end
	local right_hint = " [s export PNG · o open] "
	local max_left = math.max(8, term_cols - visible_len(right_hint) - 1)
	local left_vis = truncate_visible(p_left, max_left)
	local sp = math.max(0, term_cols - visible_len(left_vis) - visible_len(right_hint))
	local hdr_line = left_vis .. string.rep(" ", sp) .. DIM .. FG_LIGHT_GRAY .. right_hint .. RESET
	table.insert(out_buf, BG_PANEL .. hdr_line:gsub("\27%[0m", RESET .. BG_PANEL) .. RESET)

	local img_top = split_row + 1
	local img_rows = math.max(2, math.min(preview_h, term_rows - 2 - split_row))
	local img_cols = math.max(10, term_cols - 4)

	local has_kgp, use_tmux = supports_kitty_graphics(backend)
	local file_exists = false
	if sel_pl and sel_pl.path and sel_pl.path ~= "" then
		local f = io.open(sel_pl.path, "rb")
		if f then
			file_exists = true
			f:close()
		end
	end

	if has_kgp and file_exists and img_rows >= 3 then
		local b64_path = base64_encode(sel_pl.path)
		local del_cmd = "\27_Ga=d,d=A,q=2;\27\\"
		local draw_cmd = string.format("\27_Ga=T,i=42,f=100,t=f,c=%d,r=%d,C=1,q=2;%s\27\\", img_cols, img_rows, b64_path)
		table.insert(out_buf, wrap_tmux_dcs(del_cmd, use_tmux))
		table.insert(out_buf, move(img_top, 3) .. wrap_tmux_dcs(draw_cmd, use_tmux))
	else
		if has_kgp then
			table.insert(out_buf, wrap_tmux_dcs("\27_Ga=d,d=A,q=2;\27\\", use_tmux))
		end
		local info_lines = {
			BOLD .. FG_CYAN .. "  Command:    " .. RESET .. FG_WHITE .. ((sel_pl and sel_pl.title) or "-"),
			BOLD
				.. FG_CYAN
				.. "  Resolution: "
				.. RESET
				.. FG_YELLOW
				.. (
					(sel_pl and sel_pl.width > 0) and (sel_pl.width .. " × " .. sel_pl.height .. " px")
					or "PNG image"
				)
				.. "  ("
				.. fmt_bytes((sel_pl and sel_pl.bytes) or 0)
				.. ")",
			BOLD .. FG_CYAN .. "  File:       " .. RESET .. DIM .. FG_LIGHT_GRAY .. ((sel_pl and sel_pl.path) or "-"),
			"",
			DIM
				.. FG_GRAY
				.. "  Tip: Ghostty & Kitty render plots inline automatically (or set JEMACH_GRAPHICS=kitty)."
				.. RESET,
			DIM .. FG_GRAY .. "  Press [s] to export PNG into ./plots/ or [o] to open in system viewer." .. RESET,
		}
		for li = 1, math.min(#info_lines, img_rows) do
			table.insert(out_buf, move(img_top + li - 1, 1) .. truncate_visible(info_lines[li], term_cols))
		end
	end
	return split_row
end

function M.render_empty(out_buf, row_idx, term_cols)
	local box_w = math.max(24, math.min(64, term_cols - 4))
	local inner = math.max(10, box_w - 2)
	local title_fill = math.max(0, box_w - 24)
	table.insert(
		out_buf,
		FG_AQUA .. "  ╭─ " .. BOLD .. "◈ Plot Gallery " .. RESET .. FG_AQUA .. string.rep("─", title_fill) .. "╮" .. RESET
	)
	local body = {
		"  Plots returned in REPL (CairoMakie, Plots.jl, etc.) are",
		"  captured automatically as PNGs into this session gallery.",
		"  • Inline preview via Kitty Graphics in Ghostty & Kitty",
		"  • Or call jEMach.capture_plot(fig) inside loops/scripts",
		"  • Press [s] to export PNG to ./plots/ or [o] to open",
	}
	for _, ln in ipairs(body) do
		row_idx = row_idx + 1
		table.insert(out_buf, move(row_idx, 1))
		table.insert(
			out_buf,
			FG_AQUA .. "  │" .. RESET .. pad_right(truncate_visible(ln, inner), inner) .. FG_AQUA .. "│" .. RESET
		)
	end
	row_idx = row_idx + 1
	table.insert(out_buf, move(row_idx, 1))
	table.insert(out_buf, FG_AQUA .. "  ╰" .. string.rep("─", inner) .. "╯" .. RESET)
	return row_idx
end

function M.header(term_cols, fcmds, proc_errors_view)
	local col_hdr = DIM .. FG_AQUA .. "   ID     PLOT / EXPRESSION                        RESOLUTION & SIZE" .. RESET
	return col_hdr, nil
end

return M
