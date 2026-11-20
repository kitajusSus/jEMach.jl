local theme = require("tui.theme")
local BOLD = theme.BOLD
local DIM = theme.DIM
local RESET = theme.RESET
local REV = theme.REV
local FG_CYAN = theme.FG_CYAN
local FG_AQUA = theme.FG_AQUA
local FG_YELLOW = theme.FG_YELLOW
local FG_ORANGE = theme.FG_ORANGE
local FG_RED = theme.FG_RED
local FG_WHITE = theme.FG_WHITE
local FG_LIGHT_GRAY = theme.FG_LIGHT_GRAY
local FG_GRAY = theme.FG_GRAY
local FG_DARK_GRAY = theme.FG_DARK_GRAY
local BG_ERR_LINE = theme.BG_ERR_LINE
local BG_PANEL = theme.BG_PANEL
local text = require("tui.text")
local visible_len = text.visible_len
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible
local preview = require("tui.preview")
local fmt_bytes = preview.fmt_bytes

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
		return "●", theme.FG_GREEN, false
	end
end

local function move(row, col)
	return theme.ESC .. "[" .. row .. ";" .. col .. "H"
end

local M = {}

function M.build(ctx, q)
	local state = ctx.state
	local search_query = ctx.search_query
	local proc_errors_view = ctx.proc_errors_view
	local has_filter = q ~= ""
	local display_rows = {}
	local procs = state and state.procedures or {}
	local fcmds = state and state.failed_commands or {}

	if proc_errors_view then
		if #fcmds == 0 then
			display_rows[1] = {
				kind = "msg",
				text = "No failed commands recorded. Press [F] to return to Procedures.",
			}
			return display_rows
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
			display_rows[1] =
				{ kind = "empty_search", text = 'No failed commands matching "' .. search_query .. '".' }
		end
		return display_rows
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
		return display_rows
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
		display_rows[1] = { kind = "empty_search", text = 'No procedures matching "' .. search_query .. '".' }
	end
	return display_rows
end

function M.render_split(ctx)
	local out_buf, display_rows, row_hitboxes = ctx.out_buf, ctx.display_rows, ctx.row_hitboxes
	local term_rows, term_cols = ctx.term_rows, ctx.term_cols
	local header_rows, content_rows, total, cursor = ctx.header_rows, ctx.content_rows, ctx.total, ctx.cursor
	local proc_preview_scroll, last_proc_preview_key = ctx.preview_scroll, ctx.preview_key
	local compute_win_start = ctx.compute_win_start
	local function build_item_preview_lines(dr, width, compact)
		return preview.build(dr, width, compact, ctx.state)
	end
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
			table.insert(
				out_buf,
				BOLD .. sec_color .. sec_title .. FG_DARK_GRAY .. string.rep("─", fill_w) .. RESET
			)
		elseif dr.kind == "procedure" then
			local glyph, gclr, gwide = origin_glyph_and_color(dr.origin, dr.status)
			local sel_bar = sel and (FG_CYAN .. BOLD .. "▸" .. RESET) or " "
			local icon = sel_bar .. gclr .. glyph .. (gwide and "" or " ") .. RESET

			local avail = math.max(10, term_cols - 3)
			local metrics
			if dr.status == "error" then
				local err_short = (dr.last_error or "Error"):gsub("%s+", " ")
				local ltag = (dr.last_error_line and dr.last_error_line > 0)
						and ("L" .. dr.last_error_line .. " ")
					or ""
				local mod_tag = (dr.origin == "modified") and ("⚡v" .. tostring(dr.generation or 1) .. " ")
					or ""
				metrics = mod_tag .. "✗ " .. ltag .. err_short
			elseif dr.origin == "modified" then
				if dr.status ~= "never" then
					metrics = string.format(
						"⚡v%d  %.1fms %s",
						dr.generation or 1,
						dr.time_ms,
						fmt_bytes(dr.alloc_bytes)
					)
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
			local file_col = show_file
					and (" " .. DIM .. FG_GRAY .. pad_right(truncate_visible(file_txt, file_w), file_w) .. RESET)
				or ""

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
				table.insert(
					out_buf,
					icon
						.. REV
						.. BOLD
						.. sel_bg
						.. sig_col
						.. RESET
						.. " "
						.. met_color
						.. met_col
						.. RESET
						.. file_col
				)
			else
				table.insert(
					out_buf,
					icon
						.. BOLD
						.. name_color
						.. sig_col
						.. RESET
						.. " "
						.. met_color
						.. met_col
						.. RESET
						.. file_col
				)
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
				table.insert(
					out_buf,
					icon .. REV .. BOLD .. FG_RED .. cmd_col .. RESET .. " " .. FG_ORANGE .. err_col .. RESET
				)
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

	local has_sticky_err = sel_proc
		and sel_proc.kind == "procedure"
		and sel_proc.status == "error"
		and preview_h >= 4
		and (sel_proc.last_error or "") ~= ""
	local err_strip_h = has_sticky_err and 1 or 0
	local code_view_h = math.max(1, preview_h - err_strip_h)

	-- Build compact preview lines before separator to compute accurate line range & auto-scroll
	local preview_lines = build_item_preview_lines(sel_proc, term_cols, true)
	if cur_pkey ~= last_proc_preview_key then
		last_proc_preview_key = cur_pkey
		if sel_proc and sel_proc.kind == "procedure" then
			if sel_proc.last_error_line and sel_proc.last_error_line > 0 then
				proc_preview_scroll =
					math.max(0, sel_proc.last_error_line - math.max(2, math.floor(code_view_h / 2)))
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
	local preview_split_row = split_row
	table.insert(out_buf, move(split_row, 1))
	local p_left = " Preview"
	if sel_proc and sel_proc.kind == "procedure" then
		local glyph, gclr = origin_glyph_and_color(sel_proc.origin, sel_proc.status)
		local orig_lbl = (sel_proc.origin == "modified") and ("⚡v" .. tostring(sel_proc.generation or 1))
			or (sel_proc.origin == "live") and "◆ LIVE"
			or (sel_proc.origin == "unloaded") and "○ DISK"
			or "● DISK"
		local fname_short = (sel_proc.file and sel_proc.file ~= "")
				and (sel_proc.file:match("[^/]+$") or sel_proc.file)
			or ""
		local file_part = (fname_short ~= "" and fname_short ~= ((sel_proc.name or "") .. ".jl"))
				and (" · " .. fname_short)
			or ""
		local stat_part = (sel_proc.status ~= "never")
				and string.format(" · %.1fms %s", sel_proc.time_ms or 0, fmt_bytes(sel_proc.alloc_bytes or 0))
			or ""
		p_left = " "
			.. gclr
			.. glyph
			.. RESET
			.. " "
			.. BOLD
			.. FG_WHITE
			.. (sel_proc.name or "proc")
			.. RESET
			.. DIM
			.. FG_GRAY
			.. " ["
			.. orig_lbl
			.. file_part
			.. stat_part
			.. "]"
			.. RESET
	elseif sel_proc and sel_proc.kind == "failed_cmd" then
		p_left = " "
			.. FG_RED
			.. BOLD
			.. "✗ Failed Cmd #"
			.. tostring(sel_proc.id or "")
			.. RESET
			.. DIM
			.. FG_GRAY
			.. " ["
			.. (sel_proc.source or "repl")
			.. "]"
			.. RESET
	end

	local scroll_info = (#preview_lines > code_view_h)
			and string.format(
				" [L%d-%d/%d J/K] ",
				proc_preview_scroll + 1,
				math.min(#preview_lines, proc_preview_scroll + code_view_h),
				#preview_lines
			)
		or " [v full] "
	local max_pleft_w = math.max(8, term_cols - visible_len(scroll_info) - 1)
	local pleft_vis = truncate_visible(p_left, max_pleft_w)
	local fill_sp = math.max(0, term_cols - visible_len(pleft_vis) - visible_len(scroll_info))
	local hdr_line = pleft_vis .. string.rep(" ", fill_sp) .. DIM .. FG_LIGHT_GRAY .. scroll_info .. RESET
	table.insert(out_buf, BG_PANEL .. hdr_line:gsub("\27%[0m", RESET .. BG_PANEL) .. RESET)

	local preview_row = split_row + 1
	if has_sticky_err and preview_row <= term_rows - 2 then
		table.insert(out_buf, move(preview_row, 1))
		local ltag = (sel_proc.last_error_line and sel_proc.last_error_line > 0)
				and ("L" .. sel_proc.last_error_line .. ": ")
			or ""
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
	return proc_preview_scroll, last_proc_preview_key, preview_split_row
end

function M.header(term_cols, fcmds, proc_errors_view)
	local col_hdr, hitbox = "", nil
	if proc_errors_view then
		local right_tag = "[F] ← Procs"
		local rw = #right_tag + 1
		local left_w = math.max(10, term_cols - rw)
		local left_hdr = pad_right("   ST  FAILED COMMAND / ERROR", left_w)
		hitbox = { x1 = left_w + 1, x2 = term_cols }
		col_hdr = DIM
			.. FG_RED
			.. truncate_visible(left_hdr, left_w)
			.. RESET
			.. BOLD
			.. FG_CYAN
			.. right_tag
			.. " "
			.. RESET
	else
		local right_tag = (#fcmds > 0) and ("[F] Err:" .. #fcmds) or "[● Disk ⚡Mem ◆Live]"
		local right_clr = (#fcmds > 0) and (BOLD .. FG_RED) or (DIM .. FG_GRAY)
		local rw = visible_len(right_tag) + 1
		local left_w = math.max(10, term_cols - rw)
		local left_txt = (term_cols >= 90)
				and "   ST  FUNCTION / SIGNATURE           STATUS / STATS           ORIGIN / FILE"
			or "   ST  FUNCTION               STATUS / STATE"
		hitbox = (#fcmds > 0) and { x1 = left_w + 1, x2 = term_cols } or nil
		col_hdr = DIM
			.. FG_AQUA
			.. pad_right(truncate_visible(left_txt, left_w), left_w)
			.. RESET
			.. right_clr
			.. right_tag
			.. " "
			.. RESET
	end
	return col_hdr, hitbox
end

function M.render_empty(out_buf, row_idx, term_cols)
	local box_w = math.max(24, math.min(62, term_cols - 4))
	local inner = math.max(10, box_w - 2)
	local title_fill = math.max(0, box_w - 31)
	table.insert(
		out_buf,
		FG_AQUA
			.. "  ╭─ "
			.. BOLD
			.. "✦ No procedures or errors "
			.. RESET
			.. FG_AQUA
			.. string.rep("─", title_fill)
			.. "╮"
			.. RESET
	)
	row_idx = row_idx + 1
	table.insert(out_buf, move(row_idx, 1))
	table.insert(
		out_buf,
		FG_AQUA
			.. "  │"
			.. RESET
			.. pad_right(truncate_visible("  Quick Start:", inner), inner)
			.. FG_AQUA
			.. "│"
			.. RESET
	)
	row_idx = row_idx + 1
	table.insert(out_buf, move(row_idx, 1))
	table.insert(
		out_buf,
		FG_AQUA
			.. "  │"
			.. RESET
			.. pad_right(
				truncate_visible("  1. Press [2] for History, select commands with [Space]", inner),
				inner
			)
			.. FG_AQUA
			.. "│"
			.. RESET
	)
	row_idx = row_idx + 1
	table.insert(out_buf, move(row_idx, 1))
	table.insert(
		out_buf,
		FG_AQUA
			.. "  │"
			.. RESET
			.. pad_right(
				truncate_visible("  2. Press [p] to Make Procedure with auto-AST parameters", inner),
				inner
			)
			.. FG_AQUA
			.. "│"
			.. RESET
	)
	row_idx = row_idx + 1
	table.insert(out_buf, move(row_idx, 1))
	table.insert(
		out_buf,
		FG_AQUA
			.. "  │"
			.. RESET
			.. pad_right(
				truncate_visible("  3. REPL errors appear here with full code + traceback", inner),
				inner
			)
			.. FG_AQUA
			.. "│"
			.. RESET
	)
	row_idx = row_idx + 1
	table.insert(out_buf, move(row_idx, 1))
	table.insert(out_buf, FG_AQUA .. "  ╰" .. string.rep("─", inner) .. "╯" .. RESET)

	return row_idx
end

return M
