local theme = require("tui.theme")
local BOLD = theme.BOLD
local DIM = theme.DIM
local RESET = theme.RESET
local REV = theme.REV
local FG_AQUA = theme.FG_AQUA
local FG_GREEN = theme.FG_GREEN
local FG_YELLOW = theme.FG_YELLOW
local FG_RED = theme.FG_RED
local FG_WHITE = theme.FG_WHITE
local FG_LIGHT_GRAY = theme.FG_LIGHT_GRAY
local FG_GRAY = theme.FG_GRAY
local text = require("tui.text")
local visible_len = text.visible_len
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible

local M = {}

function M.build(ctx, q)
	local state = ctx.state
	local search_query = ctx.search_query
	local history_selected = ctx.history_selected
	local history_prev_collapsed = ctx.history_prev_collapsed
	local has_filter = q ~= ""
	local display_rows = {}
	local hist = state and state.history or {}
	local hstat = state and state.history_statuses or {}
	local prev_count = math.min(#hist, math.max(0, tonumber(state and state.history_prev_count) or 0))
	if #hist == 0 then
		display_rows[1] = {
			kind = "msg",
			text = "No REPL commands captured yet in this session.",
		}
		return display_rows
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
			local lbl = has_filter and string.format("Previous Sessions (%d/%d matches)", #matched_prev, prev_count)
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
		display_rows = { { kind = "empty_search", text = 'No commands matching "' .. search_query .. '".' } }
	end
	return display_rows
end

function M.render_row(out_buf, dr, sel, term_cols, ctx)
	local history_selected = ctx.history_selected
	if dr.kind == "hist_section" then
		local icon = dr.collapsed and "▶" or "▼"
		local hint = dr.collapsed and "  [l/↵ expand]" or "  [h collapse]"
		local hdr_txt = string.format("  %s %s", icon, dr.title or "Previous Sessions")
		local line_str = truncate_visible(hdr_txt .. hint, term_cols)
		if sel then
			table.insert(out_buf, REV .. BOLD .. FG_YELLOW .. pad_right(line_str, term_cols) .. RESET)
		else
			table.insert(
				out_buf,
				BOLD .. FG_YELLOW .. truncate_visible(hdr_txt, term_cols) .. DIM .. FG_GRAY .. hint .. RESET
			)
		end
	elseif dr.kind == "section" then
		local sec_title = " ── " .. (dr.text or "") .. " "
		local fill_w = math.max(0, term_cols - visible_len(sec_title))
		table.insert(
			out_buf,
			BOLD .. FG_AQUA .. truncate_visible(sec_title .. string.rep("─", fill_w), term_cols) .. RESET
		)
	elseif dr.kind == "hist_note" then
		table.insert(
			out_buf,
			DIM
				.. FG_GRAY
				.. pad_right(truncate_visible("    " .. (dr.text or ""), term_cols), term_cols)
				.. RESET
		)
	elseif dr.kind == "history" then
		local is_sel = history_selected[dr.idx]
		local check = is_sel and (FG_GREEN .. BOLD .. " [✓] " .. RESET)
			or (DIM .. FG_GRAY .. " [ ] " .. RESET)
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
			local tc = (dr.status == "error") and FG_RED
				or (dr.is_prev and (DIM .. FG_GRAY) or FG_LIGHT_GRAY)
			table.insert(out_buf, check .. st_badge .. num .. tc .. line_text .. RESET)
		end
	end
end

function M.header(term_cols, fcmds, proc_errors_view)
	local col_hdr, hitbox = "", nil
	col_hdr = DIM .. FG_AQUA .. "   SEL  ST   #   COMMAND" .. RESET
	return col_hdr, hitbox
end

return M
