local theme = require("tui.theme")
local FG_AQUA = theme.FG_AQUA
local DIM = theme.DIM
local BOLD = theme.BOLD
local RESET = theme.RESET
local REV = theme.REV
local FG_CYAN = theme.FG_CYAN
local FG_TEAL = theme.FG_TEAL
local FG_GREEN = theme.FG_GREEN
local FG_YELLOW = theme.FG_YELLOW
local FG_ORANGE = theme.FG_ORANGE
local FG_PURPLE = theme.FG_PURPLE
local FG_WHITE = theme.FG_WHITE
local FG_GRAY = theme.FG_GRAY
local text = require("tui.text")
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible
local function ws_col_widths(cols)
	local name_w = (cols >= 90) and 28 or math.max(14, math.floor(cols * 0.36))
	local type_w = (cols >= 90) and 22 or math.max(11, math.floor(cols * 0.25))
	local val_max = math.max(6, cols - name_w - type_w - 4)
	return name_w, type_w, val_max
end

local M = {}

function M.build(ctx, q)
	local state = ctx.state
	local search_query = ctx.search_query
	local hidden = ctx.hidden
	local collapsed = ctx.collapsed
	local initialized_items = ctx.initialized_items
	local initialized_modules = ctx.initialized_modules
	local has_filter = q ~= ""
	local display_rows = {}
	if not state or (not state.modules and not state.columns) then
		display_rows[1] = {
			kind = "msg",
			text = "Waiting for Julia watcher… (using jEMach)",
		}
		return display_rows
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
			if has_children and not initialized_items[key] then
				initialized_items[key] = true
				collapsed[key] = true
			end
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
				collapsed = is_collapsed,
				icon = icon,
			})

			if has_children and is_collapsed then
				skip_until_depth = depth
			end

			::continue::
		end

		if #display_rows == 0 then
			if has_filter then
				display_rows[1] = { kind = "empty_search", text = 'No variables matching "' .. search_query .. '".' }
			else
				display_rows[1] = { kind = "msg", text = "No variables in workspace." }
			end
		end
		return display_rows
	end

	-- Fallback for legacy state.modules structure
	local function add_item_rows(mname, item, depth, path)
		local iname = item.name or "?"
		local itype = item.type or ""
		local ival = item.value or ""
		local key = path .. "/" .. iname
		if hidden[key] then
			return display_rows
		end

		if has_filter then
			local match = iname:lower():find(q, 1, true)
				or itype:lower():find(q, 1, true)
				or ival:lower():find(q, 1, true)
			if not match then
				return display_rows
			end
		end

		local has_children = item.children and #item.children > 0
		if has_children and not initialized_items[key] then
			initialized_items[key] = true
			collapsed[key] = true
		end
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
			collapsed = is_collapsed,
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
			display_rows[1] = { kind = "empty_search", text = 'No variables matching "' .. search_query .. '".' }
		else
			display_rows[1] = { kind = "msg", text = "Workspace is empty." }
		end
	end
	return display_rows
end

function M.render_row(out_buf, dr, sel, term_cols, ctx)
	local col_cursor = ctx.col_cursor
	if dr.kind == "module" then
		local icon = dr.collapsed and "▶" or "▼"
		local line = string.format("  %s %-20s", icon, dr.name)
		if sel then
			table.insert(
				out_buf,
				REV .. BOLD .. FG_GREEN .. pad_right(truncate_visible(line, term_cols), term_cols) .. RESET
			)
		else
			table.insert(
				out_buf,
				BOLD .. FG_GREEN .. pad_right(truncate_visible(line, term_cols), term_cols) .. RESET
			)
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
		local name_w, type_w, val_max = ws_col_widths(term_cols)
		local name_text = "    " .. indent .. tree_icon .. dr.name
		local name_col = pad_right(truncate_visible(name_text, name_w), name_w)
		local type_col = pad_right(truncate_visible(dr.item_type, type_w), type_w)
		local val_col = pad_right(truncate_visible(dr.value, val_max), val_max)

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
			table.insert(
				out_buf,
				kc .. name_col .. "  " .. FG_GRAY .. type_col .. "  " .. FG_WHITE .. val_col .. RESET
			)
		end
	end
end

function M.header(term_cols, fcmds, proc_errors_view)
	local col_hdr, hitbox = "", nil
	local nw, tw, _ = ws_col_widths(term_cols)
	col_hdr = DIM .. FG_AQUA .. pad_right("    NAME", nw) .. "  " .. pad_right("TYPE", tw) .. "  VALUE" .. RESET
	return col_hdr, hitbox
end

return M
