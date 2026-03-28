vim.api.nvim_create_user_command("JuliaToggleREPL", function()
	require("jemach").toggle_repl()
end, {
	desc = "Toggle Julia REPL terminal",
})

vim.api.nvim_create_user_command("JuliaSendToREPL", function()
	require("jemach").send_to_repl()
end, {
	desc = "Send current line/selection/block to Julia REPL",
	range = true,
})

vim.api.nvim_create_user_command("JuliaToggleWorkspace", function()
	require("jemach").toggle_workspace_panel()
end, {
	desc = "Toggle Julia workspace panel",
})

vim.api.nvim_create_user_command("JuliaHistory", function()
	require("jemach").show_history()
end, {
	desc = "Show Julia REPL command history",
})

vim.api.nvim_create_user_command("JuliaRefreshWorkspace", function()
	require("jemach").update_workspace_panel()
end, {
	desc = "Refresh workspace panel",
})

vim.api.nvim_create_user_command("JuliaSetTerminal", function(opts)
	require("jemach").set_terminal_direction(opts.args)
end, {
	desc = "Set Julia terminal direction (float|horizontal|vertical)",
	nargs = 1,
	complete = function()
		return { "float", "horizontal", "vertical" }
	end,
})

vim.api.nvim_create_user_command("JuliaCycleTerminal", function()
	require("jemach").cycle_terminal_direction()
end, {
	desc = "Cycle Julia terminal direction",
})

vim.api.nvim_create_user_command("JuliaSaveWorkspace", function()
	require("jemach").save_workspace()
end, {
	desc = "Save Julia workspace to file (smuggler)",
})

vim.api.nvim_create_user_command("JuliaRestoreWorkspace", function()
	require("jemach").restore_workspace()
end, {
	desc = "Restore Julia workspace from file (smuggler)",
})

vim.api.nvim_create_user_command("JuliaClearSavedWorkspace", function()
	require("jemach").clear_saved_workspace()
end, {
	desc = "Clear saved Julia workspace file",
})

vim.api.nvim_create_user_command("JuliaSetBackend", function(opts)
	require("jemach").set_backend(opts.args)
end, {
	desc = "Set REPL backend (toggleterm|vim-slime|auto)",
	nargs = 1,
	complete = function()
		return { "toggleterm", "vim-slime", "auto" }
	end,
})

vim.api.nvim_create_user_command("JuliaShowBackend", function()
	require("jemach").show_backend()
end, {
	desc = "Show current REPL backend",
})
vim.api.nvim_create_user_command("JuliaTerm", function()
	require("jemach").open_term()
end, {
	desc = "Open Julia in a terminal window",
})

-- Convenient aliases (optional)
vim.api.nvim_create_user_command("Jr", function()
	require("jemach").toggle_repl()
end, {
	desc = "Julia: Toggle REPL (alias)",
})

vim.api.nvim_create_user_command("Js", function()
	require("jemach").send_to_repl()
end, {
	desc = "Julia: Send to REPL (alias)",
	range = true,
})

vim.api.nvim_create_user_command("Jw", function()
	require("jemach").toggle_workspace_panel()
end, {
	desc = "Julia: Toggle Workspace (alias)",
})

vim.api.nvim_create_user_command("Jh", function()
	require("jemach").show_history()
end, {
	desc = "Julia: History (alias)",
})

-- Enhanced tmux integration commands
vim.api.nvim_create_user_command("JuliaTmuxSetup", function(opts)
	local tmux = require("jemach.tmux")
	local layout = opts.args ~= "" and opts.args or "horizontal"
	tmux.setup_workspace({ layout = layout })
end, {
	desc = "Setup Julia tmux workspace",
	nargs = "?",
	complete = function()
		return { "horizontal", "vertical", "grid" }
	end,
})

vim.api.nvim_create_user_command("JuliaTmuxStatus", function()
	require("jemach.tmux").show_status()
end, {
	desc = "Show tmux status and Julia panes",
})

vim.api.nvim_create_user_command("JuliaTmuxFindPanes", function()
	local tmux = require("jemach.tmux")
	local panes = tmux.find_julia_panes()

	if #panes == 0 then
		vim.notify("No Julia panes found", vim.log.levels.INFO)
	else
		local msg = "Julia panes found:\n"
		for _, pane in ipairs(panes) do
			msg = msg .. string.format("  %s - %s\n", pane.id, pane.command)
		end
		vim.notify(msg, vim.log.levels.INFO)
	end
end, {
	desc = "Find Julia REPL panes in tmux",
})

vim.api.nvim_create_user_command("JuliaNativeInfo", function()
	local native = require("jemach.native")
	local info = native.get_info()

	local msg = string.format(
		"Native Module Info:\n  Backend: %s\n  FFI Available: %s\n  Native Available: %s",
		info.backend,
		tostring(info.ffi_available),
		tostring(info.has_native)
	)

	vim.notify(msg, vim.log.levels.INFO)
end, {
	desc = "Show native module information",
})

-- LSP integration commands
vim.api.nvim_create_user_command("JuliaLspEnable", function()
	require("jemach.lsp").enable()
end, {
	desc = "Enable Julia LSP integration",
})

vim.api.nvim_create_user_command("JuliaLspDisable", function()
	require("jemach.lsp").disable()
end, {
	desc = "Disable Julia LSP integration",
})

vim.api.nvim_create_user_command("JuliaLspStatus", function()
	local lsp = require("jemach.lsp")
	local status = lsp.get_status()

	local msg = string.format(
		"Julia LSP Status:\n  Enabled: %s\n  LSP Running: %s\n  lspconfig Available: %s\n  LanguageServer.jl Available: %s\n  Imports Detected: %d",
		tostring(status.enabled),
		tostring(status.lsp_running),
		tostring(status.has_lspconfig),
		tostring(status.languageserver_available),
		status.imports_detected
	)

	vim.notify(msg, vim.log.levels.INFO)
end, {
	desc = "Show Julia LSP status",
})

vim.api.nvim_create_user_command("JuliaShowImports", function()
	require("jemach.lsp").show_import_status()
end, {
	desc = "Show detected Julia imports",
})

vim.api.nvim_create_user_command("JuliaInstallPackage", function(opts)
	local package_name = opts.args
	if package_name == "" then
		vim.notify("Please provide a package name", vim.log.levels.ERROR)
		return
	end

	require("jemach.lsp").install_package(package_name)
end, {
	desc = "Install Julia package",
	nargs = 1,
})

vim.api.nvim_create_user_command("JuliaPackageInfo", function(opts)
	local package_name = opts.args
	if package_name == "" then
		vim.notify("Please provide a package name", vim.log.levels.ERROR)
		return
	end

	local lsp = require("jemach.lsp")
	local info = lsp.get_package_info(package_name)

	if info then
		vim.notify(string.format("%s: version %s", info.name, info.version), vim.log.levels.INFO)
	else
		vim.notify(string.format("Package %s not found or not installed", package_name), vim.log.levels.WARN)
	end
end, {
	desc = "Show Julia package information",
	nargs = 1,
})

-- LSP navigation commands
vim.api.nvim_create_user_command("JuliaGotoDefinition", function()
	require("jemach.lsp").goto_definition()
end, {
	desc = "Go to definition (LSP)",
})

vim.api.nvim_create_user_command("JuliaFindReferences", function()
	require("jemach.lsp").find_references()
end, {
	desc = "Find references (LSP)",
})

vim.api.nvim_create_user_command("JuliaHover", function()
	require("jemach.lsp").hover_doc()
end, {
	desc = "Show hover documentation (LSP)",
})

vim.api.nvim_create_user_command("JuliaRename", function()
	require("jemach.lsp").rename_symbol()
end, {
	desc = "Rename symbol (LSP)",
})

vim.api.nvim_create_user_command("JuliaCodeAction", function()
	require("jemach.lsp").code_action()
end, {
	desc = "Show code actions (LSP)",
})

vim.api.nvim_create_user_command("JuliaFormat", function()
	require("jemach.lsp").format_buffer()
end, {
	desc = "Format buffer (LSP)",
})

-- Unified workflow commands
vim.api.nvim_create_user_command("JuliaWorkflowMode", function()
	require("jemach").toggle_workflow_mode()
end, {
	desc = "Toggle Julia unified workflow mode (Terminal+REPL+Workspace)",
})

vim.api.nvim_create_user_command("JuliaFocusREPL", function()
	require("jemach").focus_repl()
end, {
	desc = "Focus Julia REPL window",
})

vim.api.nvim_create_user_command("JuliaFocusWorkspace", function()
	require("jemach").focus_workspace()
end, {
	desc = "Focus Julia workspace panel",
})

vim.api.nvim_create_user_command("JuliaFocusCode", function()
	require("jemach").focus_code()
end, {
	desc = "Focus code editor window",
})

vim.api.nvim_create_user_command("JuliaCycleFocus", function()
	require("jemach").cycle_focus()
end, {
	desc = "Cycle focus between Julia components",
})

-- Short aliases for workflow
vim.api.nvim_create_user_command("Jfw", function()
	require("jemach").toggle_workflow_mode()
end, {
	desc = "Julia: Toggle Workflow Mode (alias)",
})
