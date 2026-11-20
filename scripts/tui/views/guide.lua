local GUIDE_SECTIONS = require("tui.guide")
local theme = require("tui.theme")
local FG_AQUA = theme.FG_AQUA
local DIM = theme.DIM
local BOLD = theme.BOLD
local RESET = theme.RESET
local REV = theme.REV
local FG_CYAN = theme.FG_CYAN
local FG_YELLOW = theme.FG_YELLOW
local FG_WHITE = theme.FG_WHITE
local FG_LIGHT_GRAY = theme.FG_LIGHT_GRAY
local text = require("tui.text")
local visible_len = text.visible_len
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible

local M = {}

function M.build(ctx, q)
	local search_query = ctx.search_query
	local has_filter = q ~= ""
	local display_rows = {}
	for _, sec in ipairs(GUIDE_SECTIONS) do
		local matched_items = {}
		local sec_match = has_filter and (sec.title:lower():find(q, 1, true) ~= nil)
		for _, item in ipairs(sec.items) do
			if
				not has_filter
				or sec_match
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
		display_rows[1] = { kind = "empty_search", text = 'No guide entries matching "' .. search_query .. '".' }
	end
	return display_rows
end

function M.render_row(out_buf, dr, sel, term_cols, ctx)
	if dr.kind == "guide_hdr" then
		local title = " ── " .. (dr.title or "") .. " "
		local fill = string.rep("─", math.max(0, term_cols - visible_len(title)))
		table.insert(out_buf, BOLD .. FG_CYAN .. truncate_visible(title .. fill, term_cols) .. RESET)
	elseif dr.kind == "guide_item" then
		local key_w = math.min(28, math.max(16, math.floor(term_cols * 0.34)))
		local desc_w = math.max(10, term_cols - key_w - 4)
		local kcol = pad_right("  " .. truncate_visible(dr.key or "", key_w), key_w + 3)
		local dcol = pad_right(truncate_visible(dr.desc or "", desc_w), desc_w)
		if sel then
			table.insert(
				out_buf,
				REV .. BOLD .. FG_YELLOW .. kcol .. RESET .. REV .. FG_WHITE .. " " .. dcol .. RESET
			)
		else
			table.insert(
				out_buf,
				BOLD .. FG_YELLOW .. kcol .. RESET .. " " .. FG_LIGHT_GRAY .. dcol .. RESET
			)
		end
	end
end

function M.header(term_cols, fcmds, proc_errors_view)
	local col_hdr, hitbox = "", nil
	col_hdr = DIM .. FG_AQUA .. "   KEY / COMMAND              DESCRIPTION" .. RESET
	return col_hdr, hitbox
end

return M
