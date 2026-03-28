local M = {}

M.defaults = {
	activate_project_on_start = true,
	auto_update_workspace = true,
	workspace_width = 50,
	max_history_size = 500,
	smart_block_detection = true,
	use_revise = true,
	terminal_direction = "horizontal",
	terminal_size = 15,
	workspace_style = "detailed",
	auto_save_workspace = false,
	save_on_exit = true,
	backend = "auto",
	slime_target = "tmux",
	slime_default_config = {
		socket_name = "default",
		target_pane = "{right-of}",
	},
	workspace_update_debounce = 300,
	use_cache = true,
	cache_ttl = 5000,
	lsp = {
		enabled = false,
		auto_start = true,
		detect_imports = true,
		show_import_status = true,
	},
	layout_mode = "vertical_split",
	terminal_type = "native",
	lualine_integration = true,
	lualine_colors = nil,

	keybindings = {
		toggle_repl = "<C-\\>",
		focus_repl = "<A-1>",
		focus_workspace = "<A-2>",
		focus_code = "<A-3>",
		cycle_focus = "<A-Tab>",
		workflow_mode = "<leader>jw",
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
