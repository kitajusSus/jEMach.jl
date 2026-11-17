local GUIDE_SECTIONS = {
	{
		title = "Julia REPL Editing & Navigation Shortcuts",
		items = {
			{ key = "Ctrl+A / Ctrl+E", desc = "Jump cursor to beginning / end of line (Home / End)" },
			{ key = "Alt+B / Alt+F", desc = "Move backward / forward by one word" },
			{ key = "Ctrl+W / Alt+Bksp", desc = "Delete previous word" },
			{ key = "Ctrl+U / Ctrl+K", desc = "Clear text before cursor / to end of line" },
			{ key = "Ctrl+R / Ctrl+S", desc = "Reverse / forward incremental history search" },
			{ key = "Up / Down", desc = "Cycle REPL history (type prefix + Up for prefix match)" },
			{ key = "Tab (x2)", desc = "Autocomplete symbols, methods, file paths & kwargs" },
			{ key = "\\alpha + Tab", desc = "Insert Unicode/LaTeX math symbols (\\alpha, \\sum, \\in)" },
			{ key = "Alt+Enter", desc = "Insert newline inside a multi-line expression" },
			{ key = "Ctrl+L", desc = "Clear REPL terminal screen" },
			{ key = "Ctrl+C / Ctrl+D", desc = "Interrupt running code or cancel / exit REPL on empty line" },
		},
	},
	{
		title = "Julia REPL Modes & Everyday Utilities",
		items = {
			{ key = "?  (at julia>)", desc = "help?> documentation mode (?println, ?Vector)" },
			{ key = ";  (at julia>)", desc = "shell> OS shell mode (;ls, ;git status)" },
			{ key = "]  (at julia>)", desc = "pkg> package manager (status, add Foo, rm, up, activate ., test)" },
			{ key = "} or Alt+m", desc = "Enter jemach> mode (Tab completes, Backspace exits to julia>)" },
			{ key = "Alt+j / Alt+r", desc = "Toggle jEMach TUI split panel / Start-stop live proc recording" },
			{ key = "ans / varinfo()", desc = "Last evaluated value / list variables in current module" },
			{ key = "methods(f)", desc = "List all methods defined for function f" },
			{ key = "@which f(x)", desc = "Show which method & file:line a call dispatches to" },
			{ key = "@edit f(x)", desc = "Open the exact method definition in your editor" },
			{ key = "@time / @allocated", desc = "Measure runtime and heap allocations of an expression" },
			{ key = "using Revise", desc = "Auto-reload edited package & project files without restarting" },
		},
	},
	{
		title = "Using jEMach in REPL (jemach> & Macros)",
		items = {
			{ key = "help | ? | h", desc = "Print jemach> command reference in REPL" },
			{ key = "ui | open | close | clear", desc = "Toggle/open/close TUI panel or clear REPL screen (clear())" },
			{ key = "ws [filter]", desc = "Print workspace variables table with memory sizes" },
			{ key = "ls [q] | find <q>", desc = "List or search saved & live procedures" },
			{
				key = "show <name> | edit <name>",
				desc = "Show procedure card / load clean function into julia> editor",
			},
			{ key = "errors", desc = "List errored procedures & failed commands from this session" },
			{ key = "<name>(args...) | run ...", desc = "Run a procedure with profiling (keeps live in-memory edits)" },
			{ key = "make <name> [N]", desc = "Extract last N commands into procedures/<name>.jl (hoists using)" },
			{ key = "rec [name] | stop", desc = "Start / stop live procedure recording ([rec: name] julia>)" },
			{ key = "inspect <expr> | @inspect", desc = "Deep-inspect variable/function, methods, origin & docstring" },
			{ key = "@jemach [cmd]", desc = "Macro to toggle TUI or invoke jemach commands from julia>" },
			{
				key = "save [<name> [as]] | reload",
				desc = "Save modified/live function to disk / reload from procedures/*.jl",
			},
		},
	},
	{
		title = "jEMach TUI Global Keys & Mouse Navigation",
		items = {
			{ key = "1 / 2 / 3 / 4", desc = "Jump to Workspace / History / Procedures / Packages (or click tab)" },
			{ key = "? (or 5)", desc = "Open or toggle this Guide tab (Esc returns to prior tab)" },
			{ key = "Tab / ] / [", desc = "Cycle forward / backward through TUI tabs" },
			{ key = "/", desc = "Live search & filter current tab (Esc or x clears filter)" },
			{ key = "j / k or Up / Down", desc = "Move cursor down / up (g/G top/bottom, PgUp/PgDn page)" },
			{ key = "Mouse / m", desc = "Click rows & pills, dbl-click edits, wheel scrolls; [m] toggles mouse" },
			{ key = "c / q / Ctrl+C", desc = "Clear REPL screen / Quit TUI panel" },
		},
	},
	{
		title = "jEMach TUI Tab Actions & Live Functions",
		items = {
			{ key = "[1] Workspace", desc = "l/h/Enter fold/eval; i inspect; e edit fn or paste var; d/D hide" },
			{ key = "[2] History", desc = "Previous session folded! h/l/H fold; Space select; p make proc" },
			{ key = "[2] v / e / Enter", desc = "Full cmd+error viewer / paste to REPL / re-run cmd" },
			{
				key = "[3] Procedures (● ⚡ ◆)",
				desc = "● Disk  ⚡ Modified in memory  ◆ Live REPL fn  ○ Unloaded  ✗ Error",
			},
			{ key = "[3] e / E / c", desc = "Edit clean fn in julia> REPL / open $EDITOR -> Main / paste call" },
			{
				key = "[3] R / S / Enter",
				desc = "Reload from disk (reset ⚡) / Save to procedures/ / Run (remembers args)",
			},
			{ key = "[3] F / v / J / K", desc = "Toggle Failed Commands sub-view / Full detail / Scroll preview" },
			{ key = "[4] Packages", desc = "a add package / d remove package / u update packages" },
		},
	},
}

return GUIDE_SECTIONS
