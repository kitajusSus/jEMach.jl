-- Example configuration for Harper-nvim-julia
-- Place this in your Neovim config (e.g., ~/.config/nvim/lua/plugins/julia.lua for lazy.nvim)

return {
	"kitajusSus/jemach",

	-- Required dependencies
	dependencies = {
		"akinsho/toggleterm.nvim", -- Required for REPL terminal
		"nvim-telescope/telescope.nvim", -- Optional, for command history
	},

	-- Only load for Julia files
	ft = "julia",

	-- Configuration
	config = function()
		require("jemach").setup({
			-- ===== Project Settings =====
			-- Automatically activate Julia project (finds Project.toml)
			activate_project_on_start = true,

			-- Automatically load Revise.jl for hot-reloading
			use_revise = true,

			-- ===== Workspace Panel =====
			-- Width of the workspace sidebar
			workspace_width = 50,

			-- Auto-refresh workspace after sending code
			auto_update_workspace = true,

			-- Display style for workspace
			workspace_style = "detailed",

			-- ===== REPL Terminal =====
			-- Terminal layout: "horizontal", "vertical", or "float"
			terminal_direction = "horizontal",

			-- Size of terminal (height for horizontal, width for vertical)
			terminal_size = 15,

			-- ===== Code Execution =====
			-- Automatically detect code blocks (functions, loops, etc.)
			smart_block_detection = true,

			-- Maximum commands to store in history
			max_history_size = 500,

			-- ===== Keybindings =====
			keybindings = {
				-- Toggle REPL visibility (works in normal and terminal mode)
				toggle_repl = "<C-\\>",

				-- Quick focus switching (Alt+number)
				focus_repl = "<A-1>", -- Jump to REPL
				focus_workspace = "<A-2>", -- Jump to workspace
				focus_code = "<A-3>", -- Jump to code editor

				-- Cycle through all components
				cycle_focus = "<A-Tab>",

				-- Toggle unified workflow mode (opens all panels)
				workflow_mode = "<leader>jw",
			},
		})

		-- ===== Additional Keymaps (Optional) =====
		-- You can add more custom keymaps here
		local opts = { noremap = true, silent = true }

		-- Send code to REPL
		vim.keymap.set(
			"n",
			"<leader>jj",
			":JuliaSendToREPL<CR>",
			vim.tbl_extend("force", opts, { desc = "Send line to Julia REPL" })
		)
		vim.keymap.set(
			"v",
			"<leader>jj",
			":JuliaSendToREPL<CR>",
			vim.tbl_extend("force", opts, { desc = "Send selection to Julia REPL" })
		)

		-- Toggle components
		vim.keymap.set(
			"n",
			"<leader>jr",
			":JuliaToggleREPL<CR>",
			vim.tbl_extend("force", opts, { desc = "Toggle Julia REPL" })
		)
		vim.keymap.set(
			"n",
			"<leader>jw",
			":JuliaToggleWorkspace<CR>",
			vim.tbl_extend("force", opts, { desc = "Toggle Julia Workspace" })
		)

		-- Command history
		vim.keymap.set(
			"n",
			"<leader>jh",
			":JuliaHistory<CR>",
			vim.tbl_extend("force", opts, { desc = "Julia REPL History" })
		)

		-- Terminal layout
		vim.keymap.set(
			"n",
			"<leader>jt",
			":JuliaCycleTerminal<CR>",
			vim.tbl_extend("force", opts, { desc = "Cycle Julia terminal layout" })
		)
	end,
}

-- ===== Alternative Minimal Configuration =====
--[[
-- If you prefer minimal setup with default settings:

return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "akinsho/toggleterm.nvim",
    "nvim-telescope/telescope.nvim",
  },
  ft = "julia",
  config = function()
    require("jemach").setup()
  end,
}
]]

-- ===== Alternative: Different Terminal Layout =====
--[[
-- Example with floating terminal and custom keybindings:

return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "akinsho/toggleterm.nvim",
    "nvim-telescope/telescope.nvim",
  },
  ft = "julia",
  config = function()
    require("jemach").setup({
      terminal_direction = "float",  -- Floating terminal
      use_revise = true,

      keybindings = {
        toggle_repl = "<C-`>",         -- Ctrl+` instead
        focus_repl = "<leader>1",      -- Leader+number instead
        focus_workspace = "<leader>2",
        focus_code = "<leader>3",
        cycle_focus = "<leader><Tab>", -- Leader+Tab instead
        workflow_mode = "<F12>",       -- F12 for workflow
      },
    })
  end,
}
]]

-- ===== Notes =====
--[[
1. Keybinding Conflicts:
   - If Alt+Tab is used by your window manager, change cycle_focus
   - If Ctrl+\ conflicts, change toggle_repl

2. Terminal Layouts:
   - "horizontal": REPL at bottom (default)
   - "vertical": REPL on side
   - "float": Floating window over code

3. Smart Block Detection:
   - Automatically sends entire functions, loops, etc.
   - Works with: function, for, while, if, try, struct, module, etc.
   - Disable with smart_block_detection = false

4. Revise.jl:
   - Highly recommended for interactive development
   - Install with: julia -e 'using Pkg; Pkg.add("Revise")'
   - Auto-reloads code changes without restarting REPL

5. Commands available:
   - :Jr  - Toggle REPL
   - :Js  - Send to REPL
   - :Jw  - Toggle workspace
   - :Jh  - Show history
   - :Jfw - Toggle workflow mode
]]
