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
			meta = meta
				.. string.format(
					"  |  %.2fms  %s  (%s)",
					dr.time_ms or 0,
					fmt_bytes(dr.alloc_bytes or 0),
					dr.last_run or "-"
				)
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
	else
		table.insert(lines, DIM .. FG_GRAY .. "  (No detail preview for this item)" .. RESET)
	end

	return lines
end

return {
	build = build_item_preview_lines,
	fmt_bytes = fmt_bytes,
	ws_col_widths = ws_col_widths,
	origin_glyph_and_color = origin_glyph_and_color,
}
