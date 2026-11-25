# Source map and development

The public Julia API remains in the `jEMach` module. The small `procedures.jl`
and `ipc.jl` entry points include implementation files in dependency order;
these files do not introduce extra Julia modules or change exported names.

| Location | Responsibility |
| --- | --- |
| `src/config.jl` | Project paths and optional native library loading |
| `src/session.jl` | Private session directory, metadata and cleanup |
| `src/json.jl` | Snapshot string encoding and strict flat RPC parsing |
| `src/workspace.jl` | Workspace table, reflection, inspection and session export |
| `src/history.jl` | History parsing and live REPL history |
| `src/procedures/types.jl` | Procedure metadata and registry state |
| `src/procedures/diagnostics.jl` | Error formatting, outcomes and failed commands |
| `src/procedures/discovery.jl` | Source scanning, disk indexing and loading |
| `src/procedures/analysis.jl` | AST scopes, free variables and imports |
| `src/procedures/generation.jl` | Generate procedures from selected commands |
| `src/procedures/execution.jl` | Record, run, benchmark, generate `@testset`, search and list procedures |
| `src/procedures/lifecycle.jl` | Capture live functions, edit, reload, save and delete |
| `src/plots.jl` | Session PNG plot capture, IHDR dimensions and export |
| `src/ipc/state.jl` | Shared socket state, lazy expansion paths and publication locks |
| `src/ipc/serialization.jl` | Snapshot JSON columns and metadata |
| `src/ipc/repl.jl` | REPL evaluation and input editing |
| `src/ipc/server.jl` | Subscribers, socket lifecycle and publication |
| `src/backends.jl` | Terminal launch/close and watcher lifecycle |
| `src/repl_mode.jl` | Commands, macros, completion and keybindings |

The Lua entry point handles terminal IO, navigation, shared state and overlays.
The five modules in `scripts/tui/views/` own the rows, headers and rendering for
Workspace, History, Procedures, Packages and Guide. `rows.lua` maps tab numbers
to those modules and passes the snapshot and UI state to the selected view.
Workspace updates the supplied collapse and initialization tables; the
procedures split returns its preview scroll position and mouse hitbox. The view
modules do not depend on the entry point's locals.

`preview.lua` takes a row, width and snapshot and returns formatted lines without
terminal IO. `sessions.lua` is shared by the launcher helper and TUI, so session
selection has one implementation.

Run `julia --project=. -e 'using Pkg; Pkg.test()'` for the complete Julia suite.
Use `Pkg.test()` rather than including `test/runtests.jl` directly: package tests
expect the isolated test project to depend on jEMach. Install LuaJIT to include
the discovery and TUI checks. Run `luajit "$PWD/test/tui.lua"` for Lua modules
alone, and `bash -n scripts/jl-assist` for shell syntax.

The multi-process regression starts two Julia processes against one project,
routes commands to both, and verifies that closing one preserves the other.
Restart checks give old watcher tasks time to wake, detecting stale shutdowns.
The Lua suite covers Unicode/invalid JSON, keyboard normalization, display rows,
view rendering and error previews, and rejects accidental reads of undefined globals.
The pseudoterminal smoke test also switches tabs, filters the guide and opens
the procedure preview against a live Julia process.

Run `zig build test` from `zig/` separately when changing native code, using a
compiler compatible with the version in `build.zig.zon`.
