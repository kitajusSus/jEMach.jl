# jemach

![zdjęce](jemachpic.png)

A comprehensive Neovim plugin for Julia development with an integrated REPL, workspace panel, and unified workflow mode for fast and efficient coding.

More info: [Reddit Discussion](https://www.reddit.com/r/Julia/s/keFuc7dhnV)
> later in text you may seen instructions of building native module written in zig and cpp
 forget about it its in my experimental branch

How to install in `julia`

```julia 
julia .
]  
# pkg> 
add https://github.com/kitajusSus/jEMach


```





## Julia Workspace Assistant (tmux TUI)

A standalone terminal UI for monitoring your Julia REPL session from a side tmux pane —
no Neovim required, no external Julia packages needed.

### Quick Start (One-Liner split - Recommended)

If you are already in the terminal where you want to run the workspace:

1. **Split the window and run the TUI** with a single command:
   ```bash
   # If running from the cloned repository:
   tmux split-window -h -l 60 "./scripts/jl-assist"

   # Or if installed via Neovim package manager:
   tmux split-window -h -l 60 "~/.local/share/nvim/site/pack/core/opt/jemach/scripts/jl-assist"
   ```
2. **Start Julia** in the left (original) pane:
   ```bash
   julia -t auto --project=.
   ```
3. **Load the watcher** in the Julia REPL:
   ```julia
   # Load as a package (when running julia --project=.)
   using jEMach

   # Or fallback via include:
   include("scripts/jl_watcher.jl")

   # Or if installed via Neovim (Note: Julia's include() doesn't expand '~', so use homedir()):
   include(joinpath(homedir(), ".local/share/nvim/site/pack/core/opt/jemach/scripts/jl_watcher.jl"))
   ```

### Quick Start (Manual Setup)

1. **Start Julia** in your tmux pane:
   ```bash
   julia -t auto --project=.
   ```
2. **Load the background watcher** in the Julia REPL:
   ```julia
   # Load as a package (when running julia --project=.)
   using jEMach

   # Or fallback via include:
   include("scripts/jl_watcher.jl")
   ```
3. **Split your tmux window** vertically (e.g. press your tmux prefix, usually `Ctrl+b`, then `%`) and launch the TUI in the new pane:
   ```bash
   # From repository:
   ./scripts/jl-assist

   # Or if installed via Neovim:
   ~/.local/share/nvim/site/pack/core/opt/jemach/scripts/jl-assist
   ```

The TUI opens in a new split to the right. It polls the state file every **1.5 s**;
the Julia watcher writes the file every **2 s** — so changes appear within ~3.5 s.

### TUI keybindings

| Key       | Action                                              |
|-----------|-----------------------------------------------------|
| `j` / `k` | Move cursor down / up                               |
| `l` / `↵` | Expand module **or** send `println(var)` to REPL    |
| `h`       | Collapse module node                                |
| `d`       | Hide selected item from view                        |
| `D`       | Restore all hidden items                            |
| `r`       | Force state refresh                                 |
| `q`       | Quit                                                |

### Tree view

```
▼ Main
    x             Int64       42
    greeting      String      "hello"
    myfunc        Function
▶ Revise          [collapsed — press l to expand]
▼ MyPackage
    my_var        Float64     2.718
```

### jl-assist options

```
jl-assist [-p PANE_ID] [-w WIDTH] [-f]

  -p PANE_ID   tmux pane that runs the Julia REPL (auto-detected by default)
  -w WIDTH     width of the TUI pane in columns (default: 60)
  -f           force a new TUI pane even if one is already open
```

### Requirements

- **luajit** — `sudo pacman -S luajit` (Arch Linux)
- **tmux** — running in a tmux session

---

## Features

### 🚀 Core Features
- **Dual REPL Backends**: Support for both toggleterm.nvim and vim-slime (tmux/screen)
- **Smart Code Sending**: Send current line, visual selection, or automatically detected code blocks using **Tree-sitter**
- **Workspace Panel**: Real-time view of variables, their types, and values updated asynchronously via JSON RPC (no text wrapping)
- **Command History**: Track and replay REPL commands using Telescope
- **Workspace Persistence**: Save and restore session state across restarts
- **Project Awareness**: Automatic project activation based on Project.toml files
- **Revise.jl Support**: Optional automatic loading of Revise for interactive development
- **LSP Integration**: Full Language Server Protocol support for IDE features (optional)
- **Advanced tmux Integration**: Intelligent panel management for tmux users

### ✨ Layout Modes
The plugin supports multiple layout configurations:

1. **Vertical Split Mode** (default): Terminal on right, workspace underneath
2. **Unified Buffer Mode**: REPL and workspace in same vertical split
3. **Classic Mode**: Workspace on right, REPL at bottom (toggleterm)

Easy navigation between all three components with configurable keybindings!

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "kitajusSus/jemach",
  dependencies = {
    "akinsho/toggleterm.nvim",  -- Optional, only if using toggleterm mode
    "nvim-telescope/telescope.nvim",  -- Optional, for command history
    "neovim/nvim-lspconfig",  -- Optional, for LSP features
  },
  config = function()
    require("jemach").setup({
      -- REPL backend settings
      backend = "auto",  -- "toggleterm", "vim-slime", or "auto"
      terminal_direction = "horizontal",  -- "horizontal", "vertical", or "float"
      terminal_size = 15,

      -- Optional configuration
      activate_project_on_start = true,
      auto_update_workspace = true,
      workspace_width = 50,
      use_revise = true,
      auto_save_workspace = false,
      save_on_exit = true,

      -- Keybindings (defaults shown)
      keybindings = {
        toggle_repl = "<C-\\>",      -- Toggle REPL visibility
        focus_repl = "<A-1>",        -- Focus REPL window
        focus_workspace = "<A-2>",   -- Focus workspace panel
        focus_code = "<A-3>",        -- Focus code editor
        cycle_focus = "<A-Tab>",     -- Cycle between components
        workflow_mode = "<leader>jw", -- Toggle workflow mode
      },
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "kitajusSus/jemach",
  requires = {
    "akinsho/toggleterm.nvim",
    "nvim-telescope/telescope.nvim",
    "neovim/nvim-lspconfig",
  },
  config = function()
    require("jemach").setup()
  end,
}
```

## Usage

### Commands

#### Main Commands
- `:JuliaToggleREPL` (`:Jr`) - Toggle Julia REPL terminal
- `:JuliaSendToREPL` (`:Js`) - Send current line/selection/block to REPL
- `:JuliaToggleWorkspace` (`:Jw`) - Toggle workspace panel
- `:JuliaHistory` (`:Jh`) - Show command history (requires Telescope)

#### Workflow Commands
- `:JuliaWorkflowMode` (`:Jfw`) - Toggle unified workflow mode
- `:JuliaFocusREPL` - Focus REPL window
- `:JuliaFocusWorkspace` - Focus workspace panel
- `:JuliaFocusCode` - Focus code editor
- `:JuliaCycleFocus` - Cycle focus between components

#### Terminal Direction
- `:JuliaSetTerminal [float|horizontal|vertical]` - Set terminal layout
- `:JuliaCycleTerminal` - Cycle through terminal layouts

#### Workspace Persistence
- `:JuliaSaveWorkspace` - Save workspace variables
- `:JuliaRestoreWorkspace` - Restore workspace from saved state
- `:JuliaClearSavedWorkspace` - Clear saved workspace data

#### LSP Commands
- `:JuliaLspEnable` / `:JuliaLspDisable` - Toggle LSP
- `:JuliaGotoDefinition` - Go to symbol definition
- `:JuliaFindReferences` - Find symbol references
- `:JuliaRename` - Rename symbol
- `:JuliaCodeAction` - Show code actions

### Default Keybindings

When configured with default settings:

| Mode | Key | Action |
|------|-----|--------|
| Normal | `<C-\>` | Toggle REPL visibility |
| Terminal | `<C-\>` | Toggle REPL visibility |
| Normal | `<A-1>` | Focus REPL window |
| Normal | `<A-2>` | Focus workspace panel |
| Normal | `<A-3>` | Focus code editor |
| Normal/Terminal | `<A-Tab>` | Cycle focus between components |
| Normal | `<leader>jw` | Toggle workflow mode |

### Workspace Panel Keybindings

When the workspace panel is focused:

| Key | Action |
|-----|--------|
| `<CR>` | Print variable value in REPL |
| `i` | Inspect variable (show type and size) |
| `d` | Delete variable (after confirmation) |
| `r` | Refresh workspace |
| `q` | Close workspace panel |

## Workflow Examples

### Quick Start Workflow

1. Open a Julia file
2. Press `<leader>jw` to activate workflow mode
3. Everything is automatically set up:
   - Workspace panel on the right
   - REPL at the bottom
   - Your code in the main window

4. Navigate quickly:
   - `<A-1>` to jump to REPL
   - `<A-2>` to check workspace
   - `<A-3>` to return to code
   - `<A-Tab>` to cycle through all

### Code Sending

```lua
-- In normal mode, cursor on line:
:Js  -- Sends current line

-- Visual selection:
-- Select code, then:
:Js  -- Sends selection

-- Smart block detection (when enabled):
-- Cursor inside a function, struct, loop, etc.
:Js  -- Automatically detects and sends the entire block
```

### Variable Inspection

1. Send code to REPL: `:Js`
2. Open workspace: `:Jw`
3. The workspace panel automatically updates when you create or modify variables in the REPL
4. Navigate variables:
   - `<CR>` on a variable to print its value
   - `i` to inspect its type and size
   - `d` to delete it
   - `r` to manually refresh the workspace

**Note**: The workspace panel automatically detects changes when you type commands directly in the Julia REPL (when `auto_update_workspace = true`). It securely communicates asynchronously with Julia using libuv local sockets without blocking your terminal.

## Configuration Options

```lua
require("jemach").setup({
  -- REPL Backend Settings
  backend = "auto",                  -- "toggleterm", "vim-slime", or "auto"
  terminal_direction = "horizontal", -- "horizontal", "vertical", or "float"
  terminal_size = 15,                -- Size for terminal splits

  -- Project Management
  activate_project_on_start = true,  -- Auto-activate Julia project
  use_revise = true,                 -- Auto-load Revise.jl

  -- Workspace Panel
  auto_update_workspace = true,      -- Auto-refresh after code execution
  workspace_width = 50,              -- Workspace panel width
  workspace_update_debounce = 300,   -- Debounce time in milliseconds
  use_cache = true,                  -- Enable workspace caching
  cache_ttl = 5000,                  -- Cache time-to-live in milliseconds

  -- Workspace Persistence
  auto_save_workspace = true,        -- Auto-save workspace on changes
  save_on_exit = true,               -- Save workspace on Neovim exit

  -- Code Execution
  smart_block_detection = true,      -- Auto-detect code blocks
  max_history_size = 500,            -- Max commands in history

  -- LSP Integration
  lsp = {
    enabled = true,                  -- Enable LSP features
    auto_start = true,               -- Auto-start language server
    detect_imports = true,           -- Detect and manage imports
  },

  -- Keybindings
  keybindings = {
    toggle_repl = "<C-\\>",
    focus_repl = "<A-1>",
    focus_workspace = "<A-2>",
    focus_code = "<A-3>",
    cycle_focus = "<A-Tab>",
    workflow_mode = "<leader>jw",
  },
})
```

## REPL Backend Configuration

### Using toggleterm.nvim

```lua
require("jemach").setup({
  backend = "toggleterm",  -- or "auto"
})
```

### Using vim-slime (tmux/screen)

```lua
vim.g.slime_target = "tmux"
vim.g.slime_default_config = {
  socket_name = "default",
  target_pane = "{right-of}",
}

require("jemach").setup({
  backend = "vim-slime",
})
```

## Backend Comparison

### toggleterm.nvim
- **Pros**: Easy setup, automatic REPL management, integrated terminal
- **Cons**: Moderate flexibility, tied to Neovim
- **Best for**: Quick setup, single-window workflows

### vim-slime (tmux/screen)
- **Pros**: Excellent performance, high flexibility, persistent REPL
- **Cons**: Requires tmux/screen, manual configuration
- **Best for**: tmux users, complex workflows, remote development

## Layout Modes

### Vertical Split Mode (default)
- Terminal on the right side
- Workspace panel underneath terminal
- Easy access with keyboard shortcuts

### Unified Buffer Mode
- REPL and workspace in same vertical split
- Compact layout for smaller screens
- Efficient screen usage

### Classic Toggleterm Mode
- Workspace panel on right
- REPL terminal at bottom
- Compatible with toggleterm.nvim features

## Smart Block Detection

The plugin can automatically detect and send entire code blocks using Neovim's Tree-sitter integration:

- Functions (`function ... end`)
- Macros (`macro ... end`)
- Modules (`module ... end`)
- Structs (`struct ... end`, `mutable struct ... end`)
- Blocks (`begin ... end`, `quote ... end`, `let ... end`)
- Control flow (`for ... end`, `while ... end`, `if ... end`, `try ... end`)

When your cursor is inside any of these blocks (even deeply nested), `:Js` will send the outermost top-level block.

## Requirements

- Neovim >= 0.8.0
- Julia >= 1.6
- **Optional**:
  - nvim-treesitter (for Smart Block Detection)
  - toggleterm.nvim (for toggleterm backend)
  - vim-slime (for slime backend)
  - telescope.nvim (for command history)
  - neovim/nvim-lspconfig (for LSP features)

## Tips & Tricks

1. **Fast Switching**: Use `<A-Tab>` to quickly cycle between REPL, workspace, and code
2. **Terminal Mode**: In terminal mode, use `<C-\>` to hide REPL without switching focus
3. **Project Root**: Place a `Project.toml` file in your project root for automatic activation
4. **Revise Workflow**: Enable `use_revise` for hot-reloading during development
5. **Custom Layouts**: Experiment with `terminal_direction` to find your preferred layout
6. **Persistent Sessions**: Use workspace persistence to save your work across sessions

## Troubleshooting

### REPL Doesn't Start
- Check that Julia is in your PATH: `julia --version`
- Ensure toggleterm.nvim is installed (for toggleterm backend)
- For vim-slime: ensure tmux/screen is running

### Workspace Panel is Empty
- Start the REPL first (`:Jr`)
- Execute some code to create variables (`:Js`)
- Manually refresh (press `r` in workspace panel)

### Keybindings Don't Work
- Make sure you called `setup()` in your config
- Check for conflicts with other plugins
- Customize keybindings in the setup options



## Credits

- *My Dad and My Mum*
- My future wife
- Built with [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim)
- Uses [vim-slime](https://github.com/jpalardy/vim-slime) for tmux integration

---
> README is 99% created by vibes
