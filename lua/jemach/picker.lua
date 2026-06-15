local M = {}

M.config = {
    picker = "auto", -- auto, telescope, snacks, select
}

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.detect_picker()
    if M.config.picker ~= "auto" then
        return M.config.picker
    end

    if pcall(require, "snacks") then
        return "snacks"
    elseif pcall(require, "telescope") then
        return "telescope"
    else
        return "select"
    end
end

function M.show_history(history, on_select)
    local picker_type = M.detect_picker()

    if picker_type == "snacks" then
        local snacks = require("snacks")
        local items = {}
        for i, cmd in ipairs(history) do
            table.insert(items, { text = cmd, idx = i })
        end

        snacks.picker.pick({
            title = "Julia History",
            items = items,
            format = "text",
            actions = {
                confirm = function(picker, item)
                    picker:close()
                    if item then
                        on_select(item.text)
                    end
                end
            }
        })

    elseif picker_type == "telescope" then
        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        pickers.new({}, {
            prompt_title = "📜 Julia REPL History",
            finder = finders.new_table({
                results = history,
                entry_maker = function(entry)
                    return {
                        value = entry,
                        display = entry,
                        ordinal = entry,
                    }
                end,
            }),
            sorter = conf.generic_sorter({}),
            attach_mappings = function(prompt_bufnr, map)
                actions.select_default:replace(function()
                    actions.close(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    if selection then
                        on_select(selection.value)
                    end
                end)
                return true
            end,
        }):find()

    else
        vim.ui.select(history, {
            prompt = "📜 Julia REPL History",
        }, function(choice)
            if choice then
                on_select(choice)
            end
        end)
    end
end

function M.show_variables()
	local workspace = require("jemach.workspace")
	local raw_data = workspace.state.cache.raw_data or {}

	if vim.tbl_isempty(raw_data) then
		vim.notify("📭 No variables in cache. Refresh workspace first.", vim.log.levels.WARN)
		return
	end

	local picker_type = M.detect_picker()

	if picker_type == "telescope" then
		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		pickers
			.new({}, {
				prompt_title = "🔍 Julia Workspace Variables",
				finder = finders.new_table({
					results = raw_data,
					entry_maker = function(entry)
						local display_str = string.format("%-15s │ %-15s │ %s", entry.name, entry.type, entry.value)
						return {
							value = entry,
							display = display_str,
							ordinal = entry.name .. " " .. entry.type,
						}
					end,
				}),
				sorter = conf.generic_sorter({}),
				attach_mappings = function(prompt_bufnr, map)
					-- <CR> (Enter): Paste name under cursor
					actions.select_default:replace(function()
						actions.close(prompt_bufnr)
						local selection = action_state.get_selected_entry()
						if selection then
							local var_name = selection.value.name
							vim.api.nvim_put({ var_name }, "c", true, true)
						end
					end)

					-- <C-p>: println(var) in REPL
					map("i", "<C-p>", function()
						local selection = action_state.get_selected_entry()
						if selection then
							local var_name = selection.value.name
							local repl = require("jemach.repl")
							if repl.is_repl_running() then
								repl.send_to_backend("println(" .. var_name .. ")")
								vim.notify("📤 println(" .. var_name .. ")", vim.log.levels.INFO)
							else
								vim.notify("⚠️ REPL not running", vim.log.levels.WARN)
							end
						end
					end)

					-- <C-i>: inspect var in REPL
					map("i", "<C-i>", function()
						local selection = action_state.get_selected_entry()
						if selection then
							local var_name = selection.value.name
							local repl = require("jemach.repl")
							if repl.is_repl_running() then
								repl.send_to_backend(string.format("jEMach.inspect_var(Main, %q)", var_name))
								vim.notify("🔍 Inspecting: " .. var_name, vim.log.levels.INFO)
							else
								vim.notify("⚠️ REPL not running", vim.log.levels.WARN)
							end
						end
					end)

					return true
				end,
			})
			:find()
	else
		-- fallback to standard select
		local choices = {}
		for _, v in ipairs(raw_data) do
			table.insert(choices, string.format("%s (%s): %s", v.name, v.type, v.value))
		end

		vim.ui.select(choices, {
			prompt = "🔍 Julia Workspace Variables",
		}, function(choice)
			if choice then
				local var_name = choice:match("^(%S+)")
				if var_name then
					vim.api.nvim_put({ var_name }, "c", true, true)
				end
			end
		end)
	end
end

return M
