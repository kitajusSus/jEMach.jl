local M = {}
local config = require("jemach.config")
local repl = require("jemach.repl")
local workspace = require("jemach.workspace")

M.state = {
	last_code_win = nil,
	workflow_mode_active = false,
}

local function save_code_window()
	local current_win = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_win_get_buf(current_win)
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })

	if buftype == "" then
		M.state.last_code_win = current_win
	end
end

function M.focus_repl()
	if not repl.is_repl_running() then
		vim.notify("⚠️ Julia REPL not running. Starting...", vim.log.levels.WARN)
		repl.toggle_repl()
		return
	end

	save_code_window()

	local repl_win = repl.get_repl_window()
	if repl_win then
		vim.api.nvim_set_current_win(repl_win)
		vim.notify("🎯 REPL focused", vim.log.levels.INFO)
	elseif config.options.terminal_type ~= "native" then -- Only toggleterm can be "hidden"
		repl.state.julia_terminal_obj:toggle()
		vim.defer_fn(function()
			local new_repl_win = repl.get_repl_window()
			if new_repl_win then
				vim.api.nvim_set_current_win(new_repl_win)
			end
		end, 100)
	end
end

function M.focus_workspace()
	if not workspace.state.workspace_win_id or not vim.api.nvim_win_is_valid(workspace.state.workspace_win_id) then
		vim.notify("⚠️ Workspace panel not open. Opening...", vim.log.levels.WARN)
		workspace.toggle_workspace_panel()
		return
	end

	save_code_window()
	vim.api.nvim_set_current_win(workspace.state.workspace_win_id)
	vim.notify("🎯 Workspace focused", vim.log.levels.INFO)
end

function M.focus_code()
	if M.state.last_code_win and vim.api.nvim_win_is_valid(M.state.last_code_win) then
		vim.api.nvim_set_current_win(M.state.last_code_win)
		vim.notify("🎯 Code editor focused", vim.log.levels.INFO)
	else
		-- Find a normal buffer window
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local bufnr = vim.api.nvim_win_get_buf(win)
			local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
			if buftype == "" then
				vim.api.nvim_set_current_win(win)
				M.state.last_code_win = win
				vim.notify("🎯 Code editor focused", vim.log.levels.INFO)
				return
			end
		end
		vim.notify("⚠️ No code buffer found", vim.log.levels.WARN)
	end
end

function M.cycle_focus()
	local current_win = vim.api.nvim_get_current_win()
	local repl_win = repl.get_repl_window()

	-- Determine current location and move to next
	if current_win == repl_win then
		-- From REPL -> Workspace
		if workspace.state.workspace_win_id and vim.api.nvim_win_is_valid(workspace.state.workspace_win_id) then
			M.focus_workspace()
		else
			M.focus_code()
		end
	elseif current_win == workspace.state.workspace_win_id then
		-- From Workspace -> Code
		M.focus_code()
	else
		-- From Code -> REPL
		if repl.is_repl_running() then
			M.focus_repl()
		elseif workspace.state.workspace_win_id and vim.api.nvim_win_is_valid(workspace.state.workspace_win_id) then
			M.focus_workspace()
		else
			vim.notify("⚠️ No Julia components active", vim.log.levels.WARN)
		end
	end
end

function M.toggle_workflow_mode()
	if M.state.workflow_mode_active then
		if workspace.state.workspace_win_id and vim.api.nvim_win_is_valid(workspace.state.workspace_win_id) then
			vim.api.nvim_win_close(workspace.state.workspace_win_id, true)
			workspace.state.workspace_win_id = nil
			workspace.state.workspace_bufnr = nil
		end

		if repl.state.terminal_win_id and vim.api.nvim_win_is_valid(repl.state.terminal_win_id) then
			vim.api.nvim_win_close(repl.state.terminal_win_id, false)
			repl.state.terminal_win_id = nil
		end

		if repl.state.julia_terminal_obj and repl.is_repl_running() and config.options.terminal_type ~= "native" then
			repl.state.julia_terminal_obj:close()
		end

		M.state.workflow_mode_active = false
		vim.notify("📴 Workflow mode deactivated", vim.log.levels.INFO)
	else
		M.state.workflow_mode_active = true
		vim.notify("📡 Activating Julia Workflow...", vim.log.levels.INFO)

		save_code_window()

		if config.options.layout_mode == "vertical_split" then
			local bufnr, cmd
			if not repl.is_repl_running() then
				-- Toggle repl will handle starting if needed
				repl.toggle_repl()
				vim.defer_fn(function()
					if repl.state.terminal_win_id and vim.api.nvim_win_is_valid(repl.state.terminal_win_id) then
						vim.api.nvim_set_current_win(repl.state.terminal_win_id)

						workspace.create_workspace_buffer()

						vim.cmd("split")
						workspace.state.workspace_win_id = vim.api.nvim_get_current_win()
						vim.api.nvim_win_set_buf(workspace.state.workspace_win_id, workspace.state.workspace_bufnr)
						vim.wo[workspace.state.workspace_win_id].wrap = false
						vim.wo[workspace.state.workspace_win_id].number = false

						workspace.setup_workspace_keymaps(workspace.state.workspace_bufnr)

						if repl.is_repl_running() then
							workspace.update_workspace_panel()
						end

						M.focus_code()
						vim.notify(
							"✅ Julia Workflow active! Use " .. config.options.keybindings.cycle_focus .. " to cycle focus",
							vim.log.levels.INFO
						)
					end
				end, 200)
			else
				vim.cmd("vsplit")
				repl.state.terminal_win_id = vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_buf(repl.state.terminal_win_id, repl.state.terminal_bufnr)
				vim.cmd("wincmd L")

				vim.defer_fn(function()
					if repl.state.terminal_win_id and vim.api.nvim_win_is_valid(repl.state.terminal_win_id) then
						vim.api.nvim_set_current_win(repl.state.terminal_win_id)

						workspace.create_workspace_buffer()

						vim.cmd("split")
						workspace.state.workspace_win_id = vim.api.nvim_get_current_win()
						vim.api.nvim_win_set_buf(workspace.state.workspace_win_id, workspace.state.workspace_bufnr)
						vim.wo[workspace.state.workspace_win_id].wrap = false
						vim.wo[workspace.state.workspace_win_id].number = false

						workspace.setup_workspace_keymaps(workspace.state.workspace_bufnr)

						if repl.is_repl_running() then
							workspace.update_workspace_panel()
						end

						M.focus_code()
						vim.notify(
							"✅ Julia Workflow active! Use " .. config.options.keybindings.cycle_focus .. " to cycle focus",
							vim.log.levels.INFO
						)
					end
				end, 200)
			end
		elseif config.options.layout_mode == "unified_buffer" then
			local bufnr, cmd
			if not repl.is_repl_running() then
				repl.toggle_repl()
				vim.defer_fn(function()
					if repl.state.terminal_win_id and vim.api.nvim_win_is_valid(repl.state.terminal_win_id) then
						vim.api.nvim_set_current_win(repl.state.terminal_win_id)

						workspace.create_workspace_buffer()

						vim.cmd("split")
						workspace.state.workspace_win_id = vim.api.nvim_get_current_win()
						vim.api.nvim_win_set_buf(workspace.state.workspace_win_id, workspace.state.workspace_bufnr)
						vim.wo[workspace.state.workspace_win_id].wrap = false
						vim.wo[workspace.state.workspace_win_id].number = false

						workspace.setup_workspace_keymaps(workspace.state.workspace_bufnr)

						if repl.is_repl_running() then
							workspace.update_workspace_panel()
						end

						M.focus_code()
						vim.notify(
							"✅ Julia Workflow active! Use " .. config.options.keybindings.cycle_focus .. " to cycle focus",
							vim.log.levels.INFO
						)
					end
				end, 200)
			else
				vim.cmd("vsplit")
				repl.state.terminal_win_id = vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_buf(repl.state.terminal_win_id, repl.state.terminal_bufnr)
				vim.cmd("wincmd L")

				vim.defer_fn(function()
					if repl.state.terminal_win_id and vim.api.nvim_win_is_valid(repl.state.terminal_win_id) then
						vim.api.nvim_set_current_win(repl.state.terminal_win_id)

						workspace.create_workspace_buffer()

						vim.cmd("split")
						workspace.state.workspace_win_id = vim.api.nvim_get_current_win()
						vim.api.nvim_win_set_buf(workspace.state.workspace_win_id, workspace.state.workspace_bufnr)
						vim.wo[workspace.state.workspace_win_id].wrap = false
						vim.wo[workspace.state.workspace_win_id].number = false

						workspace.setup_workspace_keymaps(workspace.state.workspace_bufnr)

						if repl.is_repl_running() then
							workspace.update_workspace_panel()
						end

						M.focus_code()
						vim.notify(
							"✅ Julia Workflow active! Use " .. config.options.keybindings.cycle_focus .. " to cycle focus",
							vim.log.levels.INFO
						)
					end
				end, 200)
			end
		else
			if not workspace.state.workspace_win_id or not vim.api.nvim_win_is_valid(workspace.state.workspace_win_id) then
				workspace.toggle_workspace_panel()
			end

			vim.defer_fn(function()
				if not repl.is_repl_running() then
					local saved_direction = config.options.terminal_direction
					config.options.terminal_direction = "horizontal"
					repl.toggle_repl()
					vim.defer_fn(function()
						config.options.terminal_direction = saved_direction
					end, 100)
				end

				vim.defer_fn(function()
					M.focus_code()
					vim.notify(
						"✅ Julia Workflow active! Use " .. config.options.keybindings.cycle_focus .. " to cycle focus",
						vim.log.levels.INFO
					)
				end, 400)
			end, 200)
		end
	end
end

function M.get_focus_component()
	if not M.state.workflow_mode_active then
		return ""
	end

	local current_win = vim.api.nvim_get_current_win()
	if not current_win or not vim.api.nvim_win_is_valid(current_win) then
		return ""
	end

	local repl_win = repl.get_repl_window()

	if current_win == repl_win then
		return "󰨞 REPL"
	elseif current_win == workspace.state.workspace_win_id then
		return "workspace"
	else
		local ok, bufnr = pcall(vim.api.nvim_win_get_buf, current_win)
		if ok and bufnr then
			local buftype_ok, buftype = pcall(function()
				return vim.bo[bufnr].buftype
			end)
			if buftype_ok and buftype == "" then
				return "Code"
			end
		end
	end

	return ""
end

return M
