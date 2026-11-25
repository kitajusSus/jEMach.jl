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
local visible_len = text.visible_len
local pad_right = text.pad_right
local truncate_visible = text.truncate_visible

local function fmt_ws_size(b)
	b = tonumber(b)
	if not b or b < 0 then
		return "-"
	elseif b >= 1073741824 then
		return string.format("%.1fGB", b / 1073741824)
	elseif b >= 1048576 then
		return string.format("%.1fMB", b / 1048576)
	elseif b >= 1024 then
		return string.format("%.1fKB", b / 1024)
	end
	return string.format("%dB", b)
end

local function ws_col_widths(cols)
	local show_size = (cols >= 68)
	local size_w = show_size and 8 or 0
	local sep_extra = show_size and 2 or 0
	local name_w = (cols >= 95) and 28 or math.max(14, math.floor(cols * 0.34))
	local type_w = (cols >= 95) and 20 or math.max(10, math.floor(cols * 0.22))
	local val_max = math.max(6, cols - name_w - type_w - size_w - 4 - sep_extra)
	return name_w, type_w, size_w, val_max
end

local function sort_module_groups(groups, sort_mode)
	if not sort_mode or sort_mode == "default" or #groups <= 1 then
		return
	end
	if sort_mode == "size" then
		table.sort(groups, function(a, b)
			local sa = tonumber(a.head.size_bytes) or -1
			local sb = tonumber(b.head.size_bytes) or -1
			if sa ~= sb then
				return sa > sb
			end
			return (a.head.name or "") < (b.head.name or "")
		end)
	elseif sort_mode == "name" then
		table.sort(groups, function(a, b)
			return (a.head.name or ""):lower() < (b.head.name or ""):lower()
		end)
	elseif sort_mode == "type" then
		table.sort(groups, function(a, b)
			local ta = (a.head.item_type or ""):lower()
			local tb = (b.head.item_type or ""):lower()
			if ta ~= tb then
				return ta < tb
			end
			return (a.head.name or ""):lower() < (b.head.name or ""):lower()
		end)
	end
end

local M = { fmt_ws_size = fmt_ws_size }

function M.build(ctx, q)
	local state = ctx.state
	local search_query = ctx.search_query
	local hidden = ctx.hidden
	local collapsed = ctx.collapsed
	local initialized_items = ctx.initialized_items
	local initialized_modules = ctx.initialized_modules
	local sort_mode = ctx.workspace_sort or "default"
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
		local mod_groups = {}
		local active_group = nil

		local function flush_mod_groups()
			if #mod_groups > 0 then
				sort_module_groups(mod_groups, sort_mode)
				for _, g in ipairs(mod_groups) do
					for _, r in ipairs(g.rows) do
						table.insert(display_rows, r)
					end
				end
				mod_groups = {}
				active_group = nil
			end
		end

		for i = 1, count do
			local mname = (cols.modules and cols.modules[i]) or "Main"
			if not initialized_modules[mname] then
				initialized_modules[mname] = true
				collapsed[mname] = true
			end
			if mname ~= current_mod then
				flush_mod_groups()
				current_mod = mname
				skip_until_depth = -1
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
			local isize = (cols.sizes and tonumber(cols.sizes[i])) or -1
			local iexpr = (cols.exprs and cols.exprs[i]) or iname
			local key = current_mod .. "/" .. iexpr
			if hidden[key] then
				if depth == 0 then
					skip_until_depth = 0
				else
					skip_until_depth = depth
				end
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

			local row_entry = {
				kind = "item",
				module_name = current_mod,
				name = iname,
				item_kind = (cols.kinds and cols.kinds[i]) or "variable",
				item_type = itype,
				value = ival,
				size_bytes = isize,
				expr = iexpr,
				depth = depth,
				path = key,
				has_children = has_children,
				collapsed = is_collapsed,
				icon = icon,
			}

			if depth == 0 or not active_group then
				active_group = { head = row_entry, rows = { row_entry } }
				table.insert(mod_groups, active_group)
			else
				table.insert(active_group.rows, row_entry)
			end

			if has_children and is_collapsed then
				skip_until_depth = depth
			end

			::continue::
		end
		flush_mod_groups()

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
			size_bytes = tonumber(item.size_bytes) or -1,
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
	local col_cursor = ctx.col_cursor or 1
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
		local name_w, type_w, size_w, val_max = ws_col_widths(term_cols)
		local name_text = "    " .. indent .. tree_icon .. dr.name
		local name_col = pad_right(truncate_visible(name_text, name_w), name_w)
		local type_col = pad_right(truncate_visible(dr.item_type, type_w), type_w)
		local size_part = ""
		if size_w > 0 then
			local sz_txt = fmt_ws_size(dr.size_bytes)
			size_part = "  " .. DIM .. FG_GRAY .. pad_right(truncate_visible(sz_txt, size_w), size_w) .. RESET
		end
		local val_col = pad_right(truncate_visible(dr.value, val_max), val_max)

		if sel then
			local out_str
			if col_cursor == 1 then
				out_str = REV .. name_col .. RESET .. "  " .. kc .. type_col .. size_part .. "  " .. FG_WHITE .. val_col
			elseif col_cursor == 2 then
				out_str = name_col .. "  " .. REV .. kc .. type_col .. RESET .. size_part .. "  " .. FG_WHITE .. val_col
			else
				out_str = name_col .. "  " .. kc .. type_col .. size_part .. "  " .. REV .. FG_WHITE .. val_col .. RESET
			end
			table.insert(out_buf, kc .. out_str .. RESET)
		else
			table.insert(
				out_buf,
				kc .. name_col .. "  " .. FG_GRAY .. type_col .. size_part .. "  " .. FG_WHITE .. val_col .. RESET
			)
		end
	end
end

function M.header(term_cols, fcmds, proc_errors_view, workspace_sort)
	local nw, tw, sw, _ = ws_col_widths(term_cols)
	local sz_hdr = (sw > 0) and ("  " .. pad_right("SIZE", sw)) or ""
	local left_txt = pad_right("    NAME", nw) .. "  " .. pad_right("TYPE", tw) .. sz_hdr .. "  VALUE"
	local sort_lbl = workspace_sort and workspace_sort ~= "default" and ("[o] Sort:" .. workspace_sort) or "[o] Sort"
	if term_cols >= 72 then
		local rw = visible_len(sort_lbl) + 1
		local lw = math.max(12, term_cols - rw)
		local sort_clr = (workspace_sort and workspace_sort ~= "default") and (BOLD .. FG_YELLOW) or (DIM .. FG_GRAY)
		local col_hdr = DIM
			.. FG_AQUA
			.. pad_right(truncate_visible(left_txt, lw), lw)
			.. RESET
			.. sort_clr
			.. sort_lbl
			.. " "
			.. RESET
		return col_hdr, { x1 = lw + 1, x2 = term_cols, action = "sort" }
	end
	return DIM .. FG_AQUA .. left_txt .. RESET, nil
end

return M
