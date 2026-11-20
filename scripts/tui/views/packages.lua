local theme = require("tui.theme")
local FG_AQUA = theme.FG_AQUA
local DIM = theme.DIM
local RESET = theme.RESET
local REV = theme.REV
local FG_CYAN = theme.FG_CYAN
local FG_GREEN = theme.FG_GREEN
local FG_YELLOW = theme.FG_YELLOW
local text = require("tui.text")
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible

local M = {}

function M.build(ctx, q)
	local state = ctx.state
	local search_query = ctx.search_query
	local has_filter = q ~= ""
	local display_rows = {}
	if not state or not state.packages then
		display_rows[1] = {
			kind = "msg",
			text = "Waiting for packages state…",
		}
		return display_rows
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
			display_rows[1] = { kind = "empty_search", text = 'No packages matching "' .. search_query .. '".' }
		else
			display_rows[1] = { kind = "msg", text = "No packages in active environment." }
		end
	end
	return display_rows
end

function M.render_row(out_buf, dr, sel, term_cols, ctx)
	if dr.kind == "package" then
		local name_w = math.min(35, math.max(16, term_cols - 20))
		local ver_w = math.max(8, term_cols - name_w - 4)
		local name_col = pad_right(truncate_visible("  📦 " .. dr.name, name_w), name_w)
		local ver_col = pad_right(truncate_visible("v" .. dr.version, ver_w), ver_w)
		if sel then
			table.insert(out_buf, REV .. FG_CYAN .. name_col .. "  " .. FG_GREEN .. ver_col .. RESET)
		else
			table.insert(out_buf, FG_CYAN .. name_col .. "  " .. FG_YELLOW .. ver_col .. RESET)
		end
	end
end

function M.header(term_cols, fcmds, proc_errors_view)
	local col_hdr, hitbox = "", nil
	col_hdr = DIM .. FG_AQUA .. "   PACKAGE                                  VERSION" .. RESET
	return col_hdr, hitbox
end

return M
