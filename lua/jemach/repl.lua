local M = {}
local config = require("jemach.config")
local utils = require("jemach.utils")
local ts = require("jemach.treesitter")
local workspace = nil -- Lazy load to avoid circular dependencies

M.state = {
	julia_terminal_id = nil,
	julia_terminal_obj = nil,
	history_file = vim.fn.stdpath("cache") .. "/julia_history.log",
	command_history = {},
	terminal_bufnr = nil,
	terminal_win_id = nil,
}

local repl_monitor = {
	last_line_count = 0,
	autocmd_id = nil,
}

function M.detect_backend()
	local slime_ok, has_slime = pcall(function()
		return vim.g.slime_target ~= nil or vim.fn.exists("*slime#send") == 1
	end)

	if slime_ok and has_slime then
		return "vim-slime"
	end

	local tt_ok = pcall(require, "toggleterm")
	if tt_ok then
		return "toggleterm"
	end

	return "toggleterm"
end

function M.get_active_backend()
	return config.options.backend
end

function M.send_to_backend(code)
	local backend = M.get_active_backend()

	if backend == "vim-slime" then
		if vim.fn.exists("*slime#send") == 1 then
			vim.fn["slime#send"](code .. "\n")
		else
			local target = config.options.slime_target
			if target == "tmux" then
				local c = config.options.slime_default_config
				local socket = c.socket_name or "default"
				local pane = c.target_pane or "{right-of}"

				local cmd = string.format(
					"tmux -L %s send-keys -t %s -l %s",
					vim.fn.shellescape(socket),
					vim.fn.shellescape(pane),
					vim.fn.shellescape(code)
				)
				vim.fn.system(cmd)
				local enter_cmd = string.format(
					"tmux -L %s send-keys -t %s Enter",
					vim.fn.shellescape(socket),
					vim.fn.shellescape(pane)
				)
				vim.fn.system(enter_cmd)
			elseif target == "screen" then
				vim.notify("⚠️ Screen support requires vim-slime plugin", vim.log.levels.WARN)
			end
		end
	elseif backend == "toggleterm" then
		if config.options.terminal_type == "native" then
			M.send_to_native_terminal(code)
		elseif M.state.julia_terminal_obj then
			M.state.julia_terminal_obj:send(code .. "\n")
		end
	end
end

function M.is_repl_running()
	return utils.is_repl_running(M.state)
end

function M.get_repl_window()
	return utils.get_repl_window(M.state)
end

function M.setup_repl_monitor(bufnr)
	if not config.options.auto_update_workspace then
		return
	end

	if not workspace then
		workspace = require("jemach.workspace")
	end

	-- Remove previous autocmd if exists
	if repl_monitor.autocmd_id then
		pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
		repl_monitor.autocmd_id = nil
	end

	-- Monitor buffer changes to detect when Julia prompt appears (command completed)
	repl_monitor.autocmd_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = function()
			if not workspace.state.workspace_bufnr or not vim.api.nvim_buf_is_valid(workspace.state.workspace_bufnr) then
				return
			end

			local line_count = vim.api.nvim_buf_line_count(bufnr)

			-- Only proceed if buffer has new lines
			if line_count <= repl_monitor.last_line_count then
				repl_monitor.last_line_count = line_count
				return
			end

			repl_monitor.last_line_count = line_count

			-- Get the last few lines to check for Julia prompt
			local last_lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, line_count - 3), line_count, false)
			local last_text = table.concat(last_lines, "\n")

			-- Zapobieganie pętli sprzężenia zwrotnego (ignorujemy własny skrypt odpytywania)
			if last_text:find("jemach_workspace") then
				return
			end

			-- Check if Julia prompt is present (julia> or prompt style markers)
			-- This indicates command execution is complete
			if last_text:match("julia>") or last_text:match("@v[%d%.]+%) pkg>") or last_text:match("shell>") then
				-- Debounce workspace updates
				if workspace.state.cache.debounce_timer then
					workspace.state.cache.debounce_timer:close()
					workspace.state.cache.debounce_timer = nil
				end

				workspace.state.cache.debounce_timer = vim.loop.new_timer()
				workspace.state.cache.debounce_timer:start(
					config.options.workspace_update_debounce,
					0,
					vim.schedule_wrap(function()
						workspace.update_workspace_panel()
						if workspace.state.cache.debounce_timer then
							workspace.state.cache.debounce_timer:close()
							workspace.state.cache.debounce_timer = nil
						end
					end)
				)
			end
		end,
	})
end

local function start_native_terminal()
	if M.state.terminal_bufnr and vim.api.nvim_buf_is_valid(M.state.terminal_bufnr) then
		return true
	end

	M.state.terminal_bufnr = vim.api.nvim_create_buf(false, true)

	local ok, _ = pcall(function()
		vim.bo[M.state.terminal_bufnr].bufhidden = "hide"
	end)
	if not ok then
		vim.notify("❌ Failed to configure terminal buffer", vim.log.levels.ERROR)
		return false
	end

	local cmd_parts = { "julia", "-t", "auto" }
	if config.options.activate_project_on_start then
		local project_root = utils.find_project_root()
		if project_root then
			table.insert(cmd_parts, string.format("--project=%s", project_root))
		else
			table.insert(cmd_parts, "--project=.")
		end
	end
	table.insert(cmd_parts, "-i")
	if config.options.use_revise then
		table.insert(cmd_parts, '-e "try using Revise catch; end"')
	end

	return M.state.terminal_bufnr, table.concat(cmd_parts, " ")
end

local function open_terminal_in_window(bufnr, cmd)
	vim.api.nvim_win_set_buf(0, bufnr)

	local job_id = vim.fn.termopen(cmd, {
		on_exit = function()
			M.state.terminal_bufnr = nil
			M.state.terminal_win_id = nil
			if repl_monitor.autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
				repl_monitor.autocmd_id = nil
			end
		end,
	})

	if job_id <= 0 then
		vim.notify("❌ Failed to start Julia terminal", vim.log.levels.ERROR)
		return false
	end

	-- Setup monitoring for workspace auto-update
	vim.defer_fn(function()
		M.setup_repl_monitor(bufnr)
	end, 1000)

	return true
end

function M.send_to_native_terminal(text)
	if not M.is_repl_running() then
		return false
	end

	local ok, chan = pcall(function()
		return vim.bo[M.state.terminal_bufnr].channel
	end)
	if not ok or not chan or chan <= 0 then
		vim.notify("⚠️ Terminal channel not available", vim.log.levels.WARN)
		return false
	end

	local send_ok, _ = pcall(vim.api.nvim_chan_send, chan, text .. "\n")
	if not send_ok then
		vim.notify("❌ Failed to send to terminal", vim.log.levels.ERROR)
		return false
	end

	return true
end

function M.toggle_repl()
	if not workspace then
		workspace = require("jemach.workspace")
	end

	if config.options.terminal_type == "native" then
		if M.state.terminal_win_id and vim.api.nvim_win_is_valid(M.state.terminal_win_id) then
			vim.api.nvim_win_close(M.state.terminal_win_id, false)
			M.state.terminal_win_id = nil
			return
		end

		local bufnr, cmd
		if not M.is_repl_running() then
			bufnr, cmd = start_native_terminal()
			if not bufnr then
				return
			end
		else
			bufnr = M.state.terminal_bufnr
		end

		if config.options.layout_mode == "vertical_split" then
			vim.cmd("vsplit")
			M.state.terminal_win_id = vim.api.nvim_get_current_win()
			if cmd then
				open_terminal_in_window(bufnr, cmd)
			else
				vim.api.nvim_win_set_buf(M.state.terminal_win_id, bufnr)
				-- Setup monitor for existing terminal
				vim.defer_fn(function()
					M.setup_repl_monitor(bufnr)
				end, 100)
			end
			vim.cmd("wincmd L")
		else
			vim.cmd("split")
			M.state.terminal_win_id = vim.api.nvim_get_current_win()
			if cmd then
				open_terminal_in_window(bufnr, cmd)
			else
				vim.api.nvim_win_set_buf(M.state.terminal_win_id, bufnr)
				-- Setup monitor for existing terminal
				vim.defer_fn(function()
					M.setup_repl_monitor(bufnr)
				end, 100)
			end
		end

		-- Start workspace server silently if needed
		workspace.start_server_if_needed()
		return
	end

	local tt_ok, toggleterm = pcall(require, "toggleterm")
	if not tt_ok then
		vim.notify("❌ Toggleterm.nvim not installed", vim.log.levels.ERROR)
		return
	end

	local term_mod_ok, terminal_module = pcall(require, "toggleterm.terminal")
	if not term_mod_ok or not terminal_module.Terminal then
		vim.notify("❌ Error loading toggleterm.terminal", vim.log.levels.ERROR)
		return
	end

	if M.state.julia_terminal_obj and M.is_repl_running() then
		M.state.julia_terminal_obj:toggle()
		return
	end

	local cmd_parts = { "julia", "-t", "auto" }

	if config.options.activate_project_on_start then
		local project_root = utils.find_project_root()
		if project_root then
			table.insert(cmd_parts, string.format("--project=%s", vim.fn.shellescape(project_root)))
			vim.notify("📂 Project: " .. project_root, vim.log.levels.INFO)
		else
			table.insert(cmd_parts, "--project=.")
		end
	end

	table.insert(cmd_parts, "-i")

	if config.options.use_revise then
		table.insert(cmd_parts, '-e "try using Revise catch; end"')
	end

	local cmd = table.concat(cmd_parts, " ")

	local term_config = {
		cmd = cmd,
		direction = config.options.terminal_direction,
		on_open = function(t)
			M.state.julia_terminal_id = t.id
			vim.notify("✅ Julia REPL started", vim.log.levels.INFO)

			vim.keymap.set("t", "<C-\\>", function()
				if M.state.julia_terminal_obj then
					M.state.julia_terminal_obj:toggle()
				end
			end, { buffer = t.bufnr, desc = "Toggle Julia REPL" })

			-- Setup monitoring for workspace auto-update
			vim.defer_fn(function()
				M.setup_repl_monitor(t.bufnr)
				workspace.start_server_if_needed()
			end, 1000)

			if config.options.auto_save_workspace then
				vim.defer_fn(function()
					if vim.fn.filereadable(workspace.state.workspace_save_file) == 1 then
						workspace.restore_workspace()
					end
				end, 1000)
			end
		end,
		on_close = function(_)
			-- Cleanup monitor
			if repl_monitor.autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
				repl_monitor.autocmd_id = nil
			end

			if config.options.save_on_exit then
				workspace.save_workspace()
				vim.defer_fn(function()
					M.state.julia_terminal_id = nil
					M.state.julia_terminal_obj = nil
				end, 1000)
			else
				M.state.julia_terminal_id = nil
				M.state.julia_terminal_obj = nil
			end

			vim.notify("⚠️ Julia REPL closed", vim.log.levels.WARN)
		end,
		on_exit = function(_)
			-- Cleanup monitor
			if repl_monitor.autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
				repl_monitor.autocmd_id = nil
			end

			M.state.julia_terminal_id = nil
			M.state.julia_terminal_obj = nil
			workspace.stop_server()
		end,
	}

	if config.options.terminal_direction == "float" then
		term_config.float_opts = {
			border = "rounded",
			width = math.floor(vim.o.columns * 0.8),
			height = math.floor(vim.o.lines * 0.8),
		}
	elseif config.options.terminal_direction == "horizontal" then
		term_config.size = config.options.terminal_size
	elseif config.options.terminal_direction == "vertical" then
		term_config.size = math.floor(vim.o.columns * 0.4)
	end

	local Terminal = terminal_module.Terminal
	M.state.julia_terminal_obj = Terminal:new(term_config)
	M.state.julia_terminal_obj:open()
end

function M.save_history()
	local file = io.open(M.state.history_file, "w")
	if file then
		for _, cmd in ipairs(M.state.command_history) do
			file:write(cmd .. "\n")
		end
		file:close()
	end
end

function M.load_history()
	M.state.command_history = {}
	local file = io.open(M.state.history_file, "r")
	if file then
		for line in file:lines() do
			if line ~= "" then
				table.insert(M.state.command_history, line)
			end
		end
		file:close()
	end
end

local function add_to_history(code)
	if code == "" or code:match("^%s*$") then
		return
	end

	if M.state.command_history[#M.state.command_history] == code then
		return
	end

	table.insert(M.state.command_history, code)

	if #M.state.command_history > config.options.max_history_size then
		table.remove(M.state.command_history, 1)
	end

	M.save_history()
end

function M.send_to_repl()
	if not workspace then
		workspace = require("jemach.workspace")
	end

	local backend = M.get_active_backend()

	if (backend == "toggleterm" or config.options.terminal_type == "native") and not M.is_repl_running() then
		vim.notify("🔄 Starting Julia REPL...", vim.log.levels.WARN)
		M.toggle_repl()

		vim.defer_fn(function()
			if M.is_repl_running() then
				M.send_to_repl()
			else
				vim.notify("❌ Failed to start REPL", vim.log.levels.ERROR)
			end
		end, 1000)
		return
	end

	local code = ts.get_code_to_send()
	if code == "" then
		return
	end

	add_to_history(code)

	M.send_to_backend(code)

	if config.options.auto_update_workspace and workspace.state.workspace_bufnr and vim.api.nvim_buf_is_valid(workspace.state.workspace_bufnr) then
		if workspace.state.cache.debounce_timer then
			workspace.state.cache.debounce_timer:close()
			workspace.state.cache.debounce_timer = nil
		end
		workspace.state.cache.debounce_timer = vim.loop.new_timer()
		workspace.state.cache.debounce_timer:start(
			config.options.workspace_update_debounce,
			0,
			vim.schedule_wrap(function()
				workspace.update_workspace_panel()
				if workspace.state.cache.debounce_timer then
					workspace.state.cache.debounce_timer:close()
					workspace.state.cache.debounce_timer = nil
				end
			end)
		)
	end
end

function M.show_history()
	local has_telescope, telescope = pcall(require, "telescope")
	if not has_telescope then
		vim.notify("❌ Telescope.nvim not installed", vim.log.levels.ERROR)
		return
	end

	if #M.state.command_history == 0 then
		vim.notify("📭 History is empty", vim.log.levels.INFO)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "📜 Julia REPL History",
			finder = finders.new_table({
				results = M.state.command_history,
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
					if selection and M.is_repl_running() then
						M.send_to_backend(selection.value)
						vim.notify("📤 Sent from history", vim.log.levels.INFO)
					elseif selection then
						vim.notify("⚠️ REPL not running", vim.log.levels.WARN)
					end
				end)
				return true
			end,
		})
		:find()
end

function M.set_terminal_direction(direction)
	local valid_directions = { "float", "horizontal", "vertical" }
	if not vim.tbl_contains(valid_directions, direction) then
		vim.notify("❌ Invalid direction. Use: float, horizontal, vertical", vim.log.levels.ERROR)
		return
	end

	config.options.terminal_direction = direction

	if M.state.julia_terminal_obj and M.is_repl_running() then
		M.state.julia_terminal_obj:close()
		vim.defer_fn(function()
			M.toggle_repl()
		end, 200)
	end

	vim.notify("📐 Terminal direction: " .. direction, vim.log.levels.INFO)
end

function M.cycle_terminal_direction()
	local directions = { "horizontal", "vertical", "float" }
	local current_idx = 1

	for i, dir in ipairs(directions) do
		if dir == config.options.terminal_direction then
			current_idx = i
			break
		end
	end

	local next_idx = (current_idx % #directions) + 1
	M.set_terminal_direction(directions[next_idx])
end

return M
