local GUIDE_SECTIONS = require("tui.guide")
local function build_display_rows(ctx)
	local state = ctx.state
	local search_query = ctx.search_query
	local active_tab = ctx.active_tab
	local history_selected = ctx.history_selected
	local history_prev_collapsed = ctx.history_prev_collapsed
	local proc_errors_view = ctx.proc_errors_view
	local hidden = ctx.hidden
	local collapsed = ctx.collapsed
	local initialized_items = ctx.initialized_items
	local initialized_modules = ctx.initialized_modules

	local display_rows = {}
	local q = (search_query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local has_filter = (q ~= "")

	-- Tab 5: Guide
	if active_tab == 5 then
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

	-- Tab 4: Packages
	if active_tab == 4 then
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

	-- Tab 2: History (splits Previous Sessions vs Current Session; previous folded by default)
	if active_tab == 2 then
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

	-- Tab 3: Procedures (with separate [F] Failed Commands sub-view)
	if active_tab == 3 then
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

	-- Tab 1: Workspace
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

return build_display_rows
