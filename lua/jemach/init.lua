local M = {}

local config = require("jemach.config")
local repl = require("jemach.repl")
local workspace = require("jemach.workspace")
local layout = require("jemach.layout")

-- Make config options accessible directly from M.config (for backward compatibility if anyone accessed it directly)
M.config = config.options

function M.setup(opts)
	config.setup(opts)
	M.config = config.options -- Update local reference
	repl.load_history()

	-- Auto-detect backend if set to "auto"
	if M.config.backend == "auto" then
		M.config.backend = repl.detect_backend()
	end

	-- Setup LSP integration if enabled
	if M.config.lsp and M.config.lsp.enabled then
		local lsp = require("jemach.lsp")
		lsp.config = vim.tbl_deep_extend("force", lsp.config, M.config.lsp)

		if M.config.lsp.auto_start then
			vim.api.nvim_create_autocmd("FileType", {
				pattern = "julia",
				callback = function()
					lsp.setup_lsp(M.config.lsp.lsp_config or {})
				end,
			})
		end
	end

	-- Setup integrations
	M.setup_global_keybindings()

	if M.config.lualine_integration then
		vim.defer_fn(M.setup_lualine, 100)
	end
end

function M.setup_global_keybindings()
	local kb = M.config.keybindings

	vim.keymap.set(
		"n",
		kb.focus_repl,
		layout.focus_repl,
		{ desc = "Focus Julia REPL", noremap = true, silent = true }
	)
	vim.keymap.set(
		"n",
		kb.focus_workspace,
		layout.focus_workspace,
		{ desc = "Focus jEMach Workspace", noremap = true, silent = true }
	)
	vim.keymap.set("n", kb.focus_code, layout.focus_code, { desc = "Focus Code Editor", noremap = true, silent = true })
	vim.keymap.set(
		"n",
		kb.cycle_focus,
		layout.cycle_focus,
		{ desc = "Cycle Julia components", noremap = true, silent = true }
	)
	vim.keymap.set(
		"n",
		kb.workflow_mode,
		layout.toggle_workflow_mode,
		{ desc = "Toggle Julia Workflow Mode", noremap = true, silent = true }
	)

	vim.keymap.set("n", kb.toggle_repl, repl.toggle_repl, { desc = "Toggle Julia REPL", noremap = true, silent = true })

	vim.keymap.set("t", kb.toggle_repl, function()
		if M.config.terminal_type == "native" then
			repl.toggle_repl()
		elseif repl.state.julia_terminal_obj then
			repl.state.julia_terminal_obj:toggle()
		end
	end, { desc = "Toggle Julia REPL", noremap = true, silent = true })

	vim.keymap.set("t", kb.cycle_focus, function()
		vim.cmd("stopinsert")
		vim.schedule(layout.cycle_focus)
	end, { desc = "Cycle Julia components", noremap = true, silent = true })
end

function M.setup_lualine()
	local ok, lualine = pcall(require, "lualine")
	if not ok then
		return
	end

	local lconfig = lualine.get_config()
	if lconfig.sections and lconfig.sections.lualine_x then
		local colors = M.config.lualine_colors or {}
		table.insert(lconfig.sections.lualine_x, 1, {
			layout.get_focus_component,
			color = colors,
		})
		lualine.setup(lconfig)
	end
end

-- Export public API by forwarding to corresponding modules
M.toggle_repl = repl.toggle_repl
M.send_to_repl = repl.send_to_repl
M.toggle_workspace_panel = workspace.toggle_workspace_panel
M.show_history = repl.show_history
M.toggle_workflow_mode = layout.toggle_workflow_mode
M.focus_repl = layout.focus_repl
M.focus_workspace = layout.focus_workspace
M.focus_code = layout.focus_code
M.cycle_focus = layout.cycle_focus
M.set_terminal_direction = repl.set_terminal_direction
M.cycle_terminal_direction = repl.cycle_terminal_direction
M.save_workspace = workspace.save_workspace
M.restore_workspace = workspace.restore_workspace
M.clear_saved_workspace = workspace.clear_saved_workspace
M.show_variables = function()
	require("jemach.picker").show_variables()
end
M.run_testset = function()
	require("jemach.treesitter").run_testset()
end
M.toggle_tui_popup = function()
	require("jemach.tmux").toggle_tui_popup()
end

function M.set_backend(backend)
	local valid_backends = { "toggleterm", "vim-slime", "auto" }
	if not vim.tbl_contains(valid_backends, backend) then
		vim.notify("❌ Invalid backend. Use: toggleterm, vim-slime, or auto", vim.log.levels.ERROR)
		return
	end

	if backend == "auto" then
		M.config.backend = repl.detect_backend()
		vim.notify("🔍 Auto-detected backend: " .. M.config.backend, vim.log.levels.INFO)
	else
		M.config.backend = backend
		vim.notify("🔧 Backend set to: " .. backend, vim.log.levels.INFO)
	end

	-- Clear cache when switching backends
	workspace.state.cache.data = nil
end

function M.show_backend()
	local backend = repl.get_active_backend()
	local backend_info = {
		"Current REPL Backend: " .. backend,
		"",
		"Available backends:",
		"  • toggleterm - Internal terminal (requires toggleterm.nvim)",
		"  • vim-slime  - External REPL via tmux/screen (requires vim-slime)",
		"  • auto       - Auto-detect based on installed plugins",
	}

	if backend == "vim-slime" then
		table.insert(backend_info, "")
		table.insert(backend_info, "vim-slime config:")
		table.insert(backend_info, "  target: " .. M.config.slime_target)
		if M.config.slime_target == "tmux" then
			table.insert(backend_info, "  socket: " .. (M.config.slime_default_config.socket_name or "default"))
			table.insert(backend_info, "  pane: " .. (M.config.slime_default_config.target_pane or "{right-of}"))
		end
	end

	vim.notify(table.concat(backend_info, "\n"), vim.log.levels.INFO)
end

function M.open_term()
	vim.cmd("terminal julia -i")
	vim.cmd("startinsert")
end

M._is_repl_running = repl.is_repl_running

return M
