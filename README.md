# jEMach

![zdjęcie](jemachpic.png)

A **Julia Workspace Assistant & REPL Monitor** with an interactive terminal UI for **Ghostty**, **Kitty**, **tmux**, **Zellij**, and **Rex**, plus an optional native Zig accelerator.

Inspect variables, dataframes, matrices, composite structs, and package dependencies alongside your Julia REPL. Turn selected REPL commands into reusable procedures. The Julia package uses only standard libraries; the TUI requires LuaJIT and works independently of Neovim.

---

## Installation

You need Julia 1.10 or newer. Install **LuaJIT** separately to use the terminal UI;
the Julia package itself uses only standard libraries. On Ubuntu/Debian, for example,
run `sudo apt install luajit`; on macOS with Homebrew, run `brew install luajit`.

### In Julia

```julia
julia
]
# pkg>
add https://github.com/kitajusSus/jEMach

# or using Pkg API:
using Pkg
Pkg.add(url="https://github.com/kitajusSus/jEMach")
```

---

## Quick Start (Ghostty / Kitty / tmux / Zellij / Rex)

### Option 1: Automatic Split / Window from Julia REPL (Recommended)

1. Start your Julia REPL in **Ghostty**, **Kitty**, **tmux**, **Zellij**, or **Rex**:
   ```bash
   julia -t auto --project=.
   ```
2. Load `jEMach` and open the TUI:
   ```julia
   using jEMach                   # Starts the background watcher
   jEMach.start()                 # Opens the TUI using the detected terminal
   ```
   You can also press `Alt+j` to toggle the TUI. To choose a backend explicitly,
   use `jEMach.start(backend=:ghostty)` (also `:kitty`, `:tmux`, `:zellij`, or `:rex`).
3. When finished:
   ```julia
   jEMach.stop()                  # Stops the watcher and closes the TUI pane/window automatically
   ```

---

### Option 2: Manual Split or Inline Launch via CLI (`jl-assist`)

Keep the Julia REPL running with `using jEMach`. If you installed the package
with `Pkg.add`, print the launcher's location in that REPL:

```julia
println(joinpath(pkgdir(jEMach), "scripts", "jl-assist"))
```

Run that path from another terminal or split in the same project directory.
The examples below use `./scripts/jl-assist` when working from a clone of this repository.

- **Inside Ghostty / Kitty / Any Native Split**:
  1. Open a split in your terminal (e.g., `Ctrl+Shift+O` in **Ghostty** for `new_split:right`) and run:
     ```bash
     ./scripts/jl-assist          # Auto-attaches inline when a jEMach session is active!
     # or explicitly inline:
     ./scripts/jl-assist -i
     ```
- **Inside tmux / Zellij / Kitty Remote Control / Rex**:
  ```bash
  ./scripts/jl-assist            # Automatically spawns a side split for the detected backend
  ```

### Supported Terminal & Multiplexer Backends

| Backend                   | Auto-Detection                            | Split / Launch Mechanism                                                                                  | Bidirectional REPL Sync                         |
| :------------------------ | :---------------------------------------- | :-------------------------------------------------------------------------------------------------------- | :---------------------------------------------- |
| **`tmux`**                | `$TMUX`                                   | `tmux split-window -h`                                                                                    | UNIX Socket RPC + `send-keys` fallback          |
| **`zellij`**              | `$ZELLIJ` / `$ZELLIJ_SESSION_NAME`        | `zellij run --direction right --close-on-exit`                                                            | UNIX Socket RPC (`LineEdit` + `Main` eval)      |
| **`kitty`**               | `$KITTY_WINDOW_ID` / `xterm-kitty`        | `kitten @ launch --location=vsplit` (or companion window)                                                 | UNIX Socket RPC + `kitten @ send-text` fallback |
| **`ghostty`**             | `$TERM_PROGRAM=ghostty` / `xterm-ghostty` | Companion `ghostty` window (`JEMACH_GHOSTTY_MODE=tab` for tab, or `Ctrl+Shift+O` + `jl-assist`) | UNIX Socket RPC (`LineEdit` + `Main` eval)      |
| **`rex`** _(Ghostty mux)_ | `$REX_SESSION` / `$REX` / `$GHOSTTY_REX`  | `rex pane split` / `rex split-window` / `$JEMACH_REX_SPLIT_CMD`                                           | UNIX Socket RPC + `rex send-keys` fallback      |

### Multiple Julia sessions

Each REPL has a private session directory under `/tmp/jemach-<uid>/session-<random>/`, containing `repl.sock`, `state.json`, and project metadata. Starting or stopping another REPL in the same project does not replace its socket.

`jl-assist` automatically selects the sole live session for the current project. If several sessions are running, it lists their sockets and requires an explicit selection:

```julia
jEMach.terminal_info()  # :socket_path identifies this REPL
```

```bash
./scripts/jl-assist -i -s /tmp/jemach-1000/session-EXAMPLE/repl.sock
```

The state path is inferred from `repl.sock`; custom socket filenames require `-d STATE`. A TUI stays attached to its chosen session and does not switch to a different project when disconnected. Normal shutdown removes the session files; discovery ignores leftover directories without a live socket.

---

### Auto-Hooking on Startup (Optional)

To automatically start `jEMach` whenever an interactive Julia REPL launches, add this to `~/.julia/config/startup.jl`:

```julia
if isinteractive()
    try
        using jEMach
    catch
    end
end
```

See [docs/src/startup.md](docs/src/startup.md) for advanced configuration.

---

## TUI Tabs & Navigation

The TUI provides 5 dedicated panels accessible via `1`–`5` or `Tab`, plus `[?] Guide`:

- **`[1] Workspace`**: Real-time Data-Oriented tree view of variables, matrices, dataframes, structs, and modules with memory **`SIZE`**, sorting (`o`: default / size / name / type), lazy subtree loading, and an interactive **2D Table / Matrix / Slice Viewer** (`v`).
- **`[2] History`**: REPL session command log separating **Previous Sessions** (folded by default with `h`/`l`/`H`) from the **Current Session**, with pass/fail markers (`✓`/`✗`), multi-select (`Space`), full preview (`v`), and procedure creation (`p`).
- **`[3] Procedures`**: Saved procedures and recent failed REPL commands (`✗ ERR`), with scrollable wrapped code + error/traceback preview (`J`/`K`, `v`), multi-sample benchmarking (`b`) with `v1 → v2` generation deltas, `@testset` file generation (`T`), and REPL/`$EDITOR` editing (`e`/`E`).
- **`[4] Packages`**: Interactive project package manager (`a` add, `d` remove, `u` update).
- **`[5] Plots`**: Automatic PNG session plot gallery (`CairoMakie`, `Plots.jl`, or `jEMach.capture_plot(fig)`) rendered inline via the **Kitty Graphics Protocol** in Ghostty & Kitty (with tmux passthrough), plus one-key PNG export (`s`) and external viewer launch (`o`).
- **`[?] Guide`**: Built-in English quick-reference tab (toggled with `?` or `6`) covering global Julia REPL shortcuts/modes, `jemach>` commands, macros/API functions, and TUI shortcuts.

The header bar also displays live **`⟳ BUSY`** elapsed evaluation timers (with OSC-99/BEL completion notifications for commands running `>= 10s`), **`Revise.jl`** status (`Rev✓` / `Rev⚡` / `Rev✗`), and an interactive **Session Switcher** (`B` or `Ctrl+S`) when multiple Julia REPLs run in the same project.

---

## Reusable Procedures & REPL History

Turn your experimental REPL commands into parameterized, reproducible procedures with automatic AST variable analysis:

### 1. From the Interactive TUI (`jl-assist`)

1. Press `2` to switch to **History**.
2. Press `Space` to toggle `[x]` on the commands you want in your procedure.
3. Press `p` (**Make Procedure**): an inline modal dialog will prompt for the procedure name.
4. Hit `Enter`: `jEMach` extracts free variables, sets default values from your session, generates `procedures/<name>.jl`, and automatically loads it!
5. In **`[3] Procedures`**, hit `Enter` to run with profiling or `e` to edit arguments in the REPL.

### 2. Directly in Julia REPL

`jEMach` also works natively inside the Julia REPL — even without the TUI sidecar:

#### `jemach>` REPL Mode & Shortcuts

- Type **`}`** on an empty prompt (or press **`Alt+m`**) to enter the **`jemach>`** REPL mode (with full **Tab completion** for subcommands, procedure names, and workspace variables; `Backspace` or `Ctrl+C` exits).
- **`Alt+j`**: Open or close the TUI panel.
- **`Alt+r`**: Start or stop procedure recording (prompt dynamically switches to `⏺ [rec: name] julia> ` while recording).
- **`↑` / `↓` history sync**: Commands executed from the TUI sidecar (`Enter` in History/Procedures) are appended to Julia's live in-memory `REPLHistoryProvider`, so pressing `↑` recalls them right away.
- **Lazy on-demand procedures**: Existing `procedures/*.jl` files are indexed (not executed) on `using jEMach` so startup stays instant; run or load a procedure from the TUI (`[↵]` / `[R]`) or via `jEMach.run_procedure` / `jEMach.reload_procedure` to evaluate it on demand (opt into eager startup loading with `ENV["JEMACH_AUTOLOAD"] = "1"`).

```julia
using jEMach

# Inside jemach> mode (press '}' on empty prompt or Alt+m):
# jemach> ls                                  # List procedures
# jemach> ws [query]                          # Workspace summary table
# jemach> inspect my_var                      # Variable type, size, fields, methods
# jemach> show check_sample                   # Source code, signature, errors & timings
# jemach> errors                              # Show errored procedures & recent failed commands
# jemach> run check_sample(10)                # Run procedure with args
# jemach> make my_proc 4                      # Package last 4 commands
# jemach> rec my_flow                         # Start/stop recording (or Alt+r)

# Or via macros / functions anywhere in julia>:
@jemach ls
@jemach run check_sample(x)
@inspect my_var
workspace("matrix")

# Option A: Extract last N commands into a parameterized procedure
jEMach.make_procedure(:check_sample, last=4)

# Option B: Record commands interactively
jEMach.record(:verify_matrix)
A = rand(10, 10)
A = A + A'
e = eigen(A)
all(e.values .> -1e-5)
jEMach.record_stop()

# Reload/sync procedures/*.jl manually
jEMach.autoload_procedures!()

# List all discovered procedures (with optional search query)
jEMach.list_procedures()
jEMach.list_procedures("matrix")
jEMach.find_procedures("sample")
```

---

## TUI Keybindings

| Key                      | Context            | Action                                                                        |
| :----------------------- | :----------------- | :---------------------------------------------------------------------------- |
| `/`                      | Global             | **UTF-8 Search & Live Filter** (`Ctrl+U`, `Esc` or `x` clears filter)         |
| `?` (or `6`)             | Global             | Open / toggle **`[?] Guide`** reference tab (REPL & TUI commands)             |
| `1` / `2` / `3` / `4` / `5` | Global          | Jump directly to Workspace / History / Procedures / Packages / Plots          |
| `B` / `Ctrl+S`           | Global             | Open interactive **Julia Session Switcher** across live project REPLs         |
| `Tab` / `]` / `[`        | Global             | Cycle to next / previous tab                                                  |
| `j` / `k` (or `↓` / `↑`) | Global             | Move cursor down / up (`g`/`G` top/bottom, `PgUp`/`PgDn` page)                |
| `Space`                  | History            | Toggle Previous Sessions fold (on header) or command selection `[✓]`          |
| `h` / `l` / `H`          | History            | Collapse / expand Previous Sessions history block                             |
| `a`                      | History            | Toggle select all / clear all                                                 |
| `p`                      | History            | **Make Procedure** from selected commands (opens modal prompt)                |
| `v`                      | History/Procedures | Open **Full Detail Viewer** (complete entered command + error/stacktrace)     |
| `e`                      | History            | Paste highlighted command into REPL for editing                               |
| `↵` (Enter)              | History            | Send highlighted command to REPL (or toggle fold on header)                   |
| `↵` (Enter)              | Procedures         | Run highlighted procedure (prompts if args required) or re-run failed command |
| `J` / `K`                | Procedures         | Scroll split preview pane down / up                                           |
| `e`                      | Procedures         | Paste `<proc_name>()` or failed command into REPL to edit                     |
| `d`                      | Procedures         | Delete procedure file from disk **or** dismiss selected failed command        |
| `D`                      | Procedures         | Clear all captured failed commands                                            |
| `b`                      | Procedures         | Run multi-sample **Benchmark** (records median/min/max & `%` vs prev gen)     |
| `T`                      | Procedures         | Generate reproducible `@testset` file under `test/procedures/`                |
| `r`                      | Procedures         | Reload procedure definitions from disk                                        |
| `v`                      | Workspace          | Open **2D Table / Matrix / Slice Viewer** (`J`/`K` rows, `H`/`L` cols)        |
| `o`                      | Workspace          | Cycle workspace sort order (`default` / `size` / `name` / `type`)             |
| `s` / `o` / `d` / `D`    | Plots              | Export PNG to `./plots/`, open in viewer, remove plot, or clear gallery       |
| `l` / `↵` (Enter)        | Workspace          | Expand node **or** evaluate `println(var)` in REPL                            |
| `h` (or `←`)             | Workspace          | Collapse node / jump to parent                                                |
| `i`                      | Workspace          | Inspect variable details, methods, and creation history                       |
| `e`                      | Workspace          | Insert variable expression directly into REPL command line                    |
| `d`                      | Workspace          | Hide item from view                                                           |
| `D`                      | Workspace          | Restore all hidden items                                                      |
| `s`                      | Workspace          | Save clean reproducible session script                                        |
| `a` / `d` / `u`          | Packages           | Add / Remove / Update package (in-TUI dialogs)                                |
| `c`                      | Global             | Clear REPL screen (`Ctrl-L`)                                                  |
| `q` / `Ctrl-C`           | Global             | Quit assistant                                                                |

---

## Tree & Complex Type Introspection

`jEMach` includes specialized introspection extractors for:

- **DataFrames & Tables.jl**: Column names, row counts, and column types.
- **1D Arrays & 2D Matrices**: Dimensions, element types, and value slices.
- **Dictionaries & Sets**: Key-value pairs and entry expressions.
- **Tuples & NamedTuples**: Indexed and named member access.
- **Composite Structs**: Real-time field resolution via `fieldnames(T)` and chained accessors.

```
▼ Main
    df            DataFrame (100 rows)   100×2 DataFrame
    ├─ :colA      Vector{Int64} (100 rows) [1, 2, 3...]
    └─ :colB      Vector{Float64} (100 rows) [1.0, 2.0...]
    x             Int64                  42
    my_func       Function               (2 methods)
▶ LoadedPackage   Module                 [collapsed — press l to expand]
```

---

## CLI Options (`jl-assist`)

```
./scripts/jl-assist [-b BACKEND] [-i] [-p PANE_ID] [-w WIDTH] [-s SOCKET] [-d STATE] [-f]

  -b BACKEND   Backend override: auto, tmux, zellij, kitty, ghostty, rex, inline (default: auto)
  -i           Run TUI inline directly in the current terminal/split
  -p PANE_ID   Target pane/window running Julia (auto-detected by default)
  -w WIDTH     Width of the TUI pane/window in columns (default: 65)
  -s SOCKET    Custom UNIX socket path
  -d STATE     Custom state JSON file path
  -f           Force a new TUI pane/window even if one is already open
```

---

## Architecture Overview

`jEMach` stores workspace snapshots in a **Struct-of-Arrays (SoA)** table and sends updates when the serialized state changes:

- **Julia engine (`src/`)**: Background introspection into `WorkspaceTable`, procedure generation and lifecycle, and a full-duplex UNIX socket for REPL evaluation and `LineEdit` input editing. Procedure responsibilities live in `src/procedures/`; snapshot encoding, REPL commands and socket transport live in `src/ipc/`.
- **Terminal UI (`scripts/jl_tui.lua`, `scripts/tui/`)**: LuaJIT UI with separate modules for each view, session discovery, JSON, previews, key normalization, text formatting, syntax highlighting and theme. Supports synchronized output, alternate screen, CSI-u keyboards and FFI resize detection.
- **Optional Zig components (`zig/`)**: Native JSON escaping and history/source scanning, with Julia fallbacks. A standalone experimental `jemach-broker` is also included; the default Julia-to-TUI path connects directly to Julia.

Snapshot collection and serialization allocate memory. Julia checks for changes every 0.5 seconds while a TUI subscriber is connected; without subscribers it skips collection. CPU usage and latency depend on the workspace and terminal. See [performance measurements](docs/src/performance.md) for a reproducible benchmark and its limits.

---

## Native Zig Accelerator & Broker (`zig/`)

`jEMach` includes a native Zig shared library (`libjemach_native`) for JSON string escaping and `repl_history.jl` block parsing, with automatic pure-Julia fallback if the native library is unavailable. The separate experimental IPC broker (`jemach-broker`) is not required to run the assistant. The minimum Zig compiler version is recorded in `zig/build.zig.zon`.

```bash
# Built automatically when Zig is installed via Julia:
julia -e 'using Pkg; Pkg.build("jEMach")'

# Or directly in zig/:
cd zig
zig build test                       # Runs Zig DoD & native accelerator unit tests
zig build -Doptimize=ReleaseFast     # Builds libjemach_native + jemach-broker
```

---

## Development checks

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
luajit "$PWD/test/tui.lua"
bash -n scripts/jl-assist
julia --startup-file=no --project=. scripts/benchmark.jl
```

`Pkg.test()` covers procedure behavior, JSON validation, repeated start/stop, and independent Julia processes in one project. With LuaJIT installed it also checks discovery and TUI modules. CI installs LuaJIT on Linux and macOS. See [the source map](docs/src/development.md) before extending the implementation.

## System Requirements

- **Julia** >= 1.10
- **Operating system**: Linux or macOS (UNIX domain sockets; Windows is not currently supported)
- **luajit** (`sudo pacman -S luajit` on Arch Linux, `sudo apt install luajit` on Ubuntu/Debian)
- **Terminal / Multiplexer**: Any of **Ghostty**, **Kitty**, **tmux** (>= 3.0), **Zellij**, **Rex**, or any ANSI/VT100 terminal emulator
