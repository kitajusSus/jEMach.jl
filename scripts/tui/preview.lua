local theme = require("tui.theme")
local BOLD = theme.BOLD
local DIM = theme.DIM
local ITALIC = theme.ITALIC
local RESET = theme.RESET
local FG_CYAN = theme.FG_CYAN
local FG_AQUA = theme.FG_AQUA
local FG_GREEN = theme.FG_GREEN
local FG_YELLOW = theme.FG_YELLOW
local FG_ORANGE = theme.FG_ORANGE
local FG_RED = theme.FG_RED
local FG_WHITE = theme.FG_WHITE
local FG_LIGHT_GRAY = theme.FG_LIGHT_GRAY
local FG_GRAY = theme.FG_GRAY
local FG_DARK_GRAY = theme.FG_DARK_GRAY
local BG_ERR_LINE = theme.BG_ERR_LINE
local text = require("tui.text")
local strip_ansi = text.strip_ansi
local visible_len = text.visible_len
local truncate_visible = text.truncate_visible
local wrap_text = text.wrap_text
local split_lines = text.split_lines
local highlight_julia_line = require("tui.highlight")
local function apply_bg_to_highlighted(hl, bg, pad_w)
	local body = hl:gsub("\27%[0m", RESET .. bg)
	local fill = math.max(0, pad_w - visible_len(hl))
	return bg .. body .. string.rep(" ", fill) .. RESET
end

local function find_matching_failed_cmd(cmd, state)
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
	if b >= 1073741824 then
		return string.format("%.1fGB", b / 1073741824)
	elseif b >= 1048576 then
		return string.format("%.1fMB", b / 1048576)
	elseif b >= 1024 then
		return string.format("%.1fKB", b / 1024)
	end
	return string.format("%dB", b)
end

local function fmt_delta_badge(dr)
	local prev_ms = tonumber(dr.prev_time_ms) or 0
	local cur_ms = tonumber(dr.time_ms) or 0
	if dr.status ~= "ok" or prev_ms <= 0 or cur_ms <= 0 then
		return ""
	end
	local pct = ((cur_ms - prev_ms) / prev_ms) * 100.0
	local pgen = tonumber(dr.prev_gen) or 0
	local cgen = tonumber(dr.generation) or 1
	local vs = (pgen > 0 and pgen ~= cgen) and (" vs v" .. pgen) or " vs prev"
	local sign = (pct > 0) and "+" or ""
	local clr = (pct <= -2.0) and FG_GREEN or ((pct >= 5.0) and FG_ORANGE or FG_LIGHT_GRAY)
	return clr .. string.format("(%s%.1f%%%s)", sign, pct, vs) .. RESET
end

local function render_inspector_grid(lines, insp, max_w)
	local headers = insp.headers or {}
	local rows = insp.rows or {}
	local ncols = #headers
	if ncols == 0 then
		return
	end

	local col_w = {}
	local max_cell_cap = (ncols <= 3) and math.max(16, math.floor(max_w * 0.50)) or 24
	for c = 1, ncols do
		col_w[c] = math.min(max_cell_cap, math.max(4, visible_len(tostring(headers[c] or ""))))
	end
	for _, r in ipairs(rows) do
		for c = 1, ncols do
			local vlen = visible_len(tostring(r[c] or ""))
			if vlen > col_w[c] then
				col_w[c] = math.min(max_cell_cap, vlen)
			end
		end
	end

	-- Shrink widest columns proportionally if total exceeds available width
	local sep_w = 3
	local total_w = 2
	for c = 1, ncols do
		total_w = total_w + col_w[c] + ((c < ncols) and sep_w or 0)
	end
	while total_w > max_w do
		local widest_c, widest_v = 1, col_w[1]
		for c = 2, ncols do
			if col_w[c] > widest_v then
				widest_c, widest_v = c, col_w[c]
			end
		end
		if widest_v <= 6 then
			break
		end
		col_w[widest_c] = widest_v - 1
		total_w = total_w - 1
	end

	local hdr_parts = { "  " }
	local div_parts = { "  " }
	for c = 1, ncols do
		local htxt = truncate_visible(tostring(headers[c] or ""), col_w[c])
		local pad_n = math.max(0, col_w[c] - visible_len(htxt))
		local hclr = (c == 1) and (BOLD .. FG_YELLOW) or (BOLD .. FG_AQUA)
		table.insert(hdr_parts, hclr .. htxt .. string.rep(" ", pad_n) .. RESET)
		table.insert(div_parts, FG_DARK_GRAY .. string.rep("─", col_w[c]) .. RESET)
		if c < ncols then
			table.insert(hdr_parts, FG_DARK_GRAY .. " │ " .. RESET)
			table.insert(div_parts, FG_DARK_GRAY .. "─┼─" .. RESET)
		end
	end
	table.insert(lines, table.concat(hdr_parts))
	table.insert(lines, table.concat(div_parts))

	for _, r in ipairs(rows) do
		local r_parts = { "  " }
		for c = 1, ncols do
			local cell = truncate_visible(tostring(r[c] or ""), col_w[c])
			local pad_n = math.max(0, col_w[c] - visible_len(cell))
			local cclr = (c == 1) and (DIM .. FG_YELLOW)
				or ((ncols == 3 and c == 2) and FG_CYAN or FG_WHITE)
			table.insert(r_parts, cclr .. cell .. string.rep(" ", pad_n) .. RESET)
			if c < ncols then
				table.insert(r_parts, FG_DARK_GRAY .. " │ " .. RESET)
			end
		end
		table.insert(lines, table.concat(r_parts))
	end
end

local function build_item_preview_lines(dr, max_w, compact, state)
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
		local orig_badge = (orig == "modified")
				and (FG_YELLOW .. BOLD .. "⚡ MOD v" .. tostring(dr.generation or 1) .. RESET)
			or (orig == "live") and (FG_CYAN .. BOLD .. "◆ LIVE" .. RESET)
			or (orig == "unloaded") and (DIM .. FG_GRAY .. "○ UNLOADED" .. RESET)
			or (FG_GREEN .. "● DISK" .. RESET)
		local hdr = "  "
			.. BOLD
			.. FG_CYAN
			.. (dr.signature or dr.name or "")
			.. RESET
			.. "  "
			.. orig_badge
			.. "  "
			.. st_badge
		table.insert(
			lines,
			truncate_visible(hdr, w) == strip_ansi(hdr) and hdr or ("  " .. truncate_visible(strip_ansi(hdr), w - 2))
		)

		local loc_str = (dr.file and dr.file ~= "") and dr.file or "(REPL memory — press [S] to save)"
		local meta = "File: " .. loc_str
		if dr.status ~= "never" then
			local b_samples = tonumber(dr.bench_samples) or 0
			local sample_tag = (b_samples > 1)
					and string.format(
						" [median of %d: %.2f..%.2fms]",
						b_samples,
						tonumber(dr.min_time_ms) or dr.time_ms or 0,
						tonumber(dr.max_time_ms) or dr.time_ms or 0
					)
				or ""
			meta = meta
				.. string.format(
					"  |  %.2fms%s  %s  (%s)",
					dr.time_ms or 0,
					sample_tag,
					fmt_bytes(dr.alloc_bytes or 0),
					dr.last_run or "-"
				)
		end
		add_wrapped_lines(meta, DIM .. FG_GRAY, "  ", false)
		local delta_line = fmt_delta_badge(dr)
		if delta_line ~= "" then
			table.insert(lines, "  " .. BOLD .. FG_AQUA .. "Benchmark Delta: " .. RESET .. delta_line)
		end

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
			local line_tag = (dr.last_error_line and dr.last_error_line > 0)
					and (" (line " .. dr.last_error_line .. ")")
				or ""
			add_section_title(FG_RED, "✗ Error" .. line_tag .. ":")
			add_wrapped_lines(
				dr.last_error ~= "" and dr.last_error or "(Error captured)",
				FG_RED .. BOLD,
				"    ",
				false
			)

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
		local hdr = FG_RED
			.. BOLD
			.. "  ✗ FAILED COMMAND #"
			.. tostring(dr.id or "")
			.. RESET
			.. "  "
			.. FG_YELLOW
			.. src_tag
			.. RESET
			.. DIM
			.. FG_GRAY
			.. ts_tag
			.. RESET
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
		table.insert(
			lines,
			"  " .. FG_YELLOW .. BOLD .. "History #" .. tostring(dr.idx or "") .. RESET .. "  " .. st_badge
		)

		local matched_fc = find_matching_failed_cmd(dr.cmd, state)
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
	elseif dr.kind == "item" then
		local full_name = ((dr.module_name and dr.module_name ~= "Main") and (dr.module_name .. ".") or "")
			.. (dr.expr or dr.name or "item")
		local sz_b = tonumber(dr.size_bytes) or -1
		local insp = (state and type(state.inspector) == "table" and state.inspector.expr == dr.expr) and state.inspector
			or nil
		if insp and tonumber(insp.size_bytes) and tonumber(insp.size_bytes) >= 0 then
			sz_b = tonumber(insp.size_bytes)
		end
		local sz_lbl = (sz_b >= 0) and ("  ·  " .. FG_GREEN .. fmt_bytes(sz_b) .. RESET) or ""
		local tp_lbl = (insp and insp.type and insp.type ~= "") and insp.type or (dr.item_type or "")
		local dims_lbl = (insp and insp.dims and insp.dims ~= "") and ("  (" .. insp.dims .. ")") or ""

		table.insert(
			lines,
			"  "
				.. BOLD
				.. FG_CYAN
				.. truncate_visible(full_name, math.max(12, w - 6))
				.. RESET
		)
		table.insert(
			lines,
			"  "
				.. FG_YELLOW
				.. truncate_visible(tp_lbl, math.max(12, w - 24))
				.. RESET
				.. DIM
				.. FG_LIGHT_GRAY
				.. dims_lbl
				.. RESET
				.. sz_lbl
		)
		table.insert(lines, "")

		if insp and insp.ok == false then
			add_section_title(FG_RED, "✗ Could not inspect expression:")
			add_wrapped_lines(insp.error or "Evaluation failed", FG_RED, "    ", false)
		elseif insp and insp.headers and #insp.headers > 0 then
			local r1 = tonumber(insp.row) or 1
			local nrows = #(insp.rows or {})
			local r2 = math.max(r1, r1 + nrows - 1)
			local tot_r = tonumber(insp.total_rows) or nrows
			local c1 = tonumber(insp.col) or 1
			local tot_c = tonumber(insp.total_cols) or 1
			local nav_info
			if insp.kind == "table" or insp.kind == "matrix" then
				local shown_c = math.max(1, #insp.headers - 1)
				local c2 = math.min(tot_c, c1 + shown_c - 1)
				nav_info = string.format(
					"Rows %d–%d of %d  ·  Cols %d–%d of %d   [J/K rows · H/L cols]",
					math.min(r1, tot_r),
					math.min(r2, tot_r),
					tot_r,
					math.min(c1, tot_c),
					c2,
					tot_c
				)
			else
				nav_info = string.format(
					"Showing %d–%d of %d   [J/K page rows]",
					math.min(r1, tot_r),
					math.min(r2, tot_r),
					tot_r
				)
			end
			add_section_title(FG_AQUA, nav_info)
			table.insert(lines, "")
			render_inspector_grid(lines, insp, w)
		elseif insp and insp.text and insp.text ~= "" then
			add_wrapped_lines(insp.text, FG_LIGHT_GRAY, "  ", false)
		else
			add_section_title(FG_AQUA, "Value Preview:")
			add_wrapped_lines(dr.value or "(loading slice…)", FG_WHITE, "    ", false)
		end
	else
		table.insert(lines, DIM .. FG_GRAY .. "  (No detail preview for this item)" .. RESET)
	end

	return lines
end

return {
	build = build_item_preview_lines,
	fmt_bytes = fmt_bytes,
	fmt_delta_badge = fmt_delta_badge,
}
