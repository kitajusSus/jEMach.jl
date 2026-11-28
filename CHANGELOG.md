# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-28

### Added
- **Standalone LuaJIT Terminal UI (`scripts/jl_tui.lua`, `scripts/tui/`, `scripts/jl-assist`)**: Works independently of Neovim with automatic backend detection and split/window management for **Ghostty**, **Kitty**, **tmux**, **Zellij**, and **Rex**.
- **Six interactive TUI views**:
  - `[1] Workspace`: Data-Oriented variable/module/struct/DataFrame/matrix tree with memory `SIZE` column, sorting (`default` / `size` / `name` / `type`), lazy subtree loading, and an interactive **2D Table / Matrix / Slice Viewer** (`v`).
  - `[2] History`: Session-separated REPL command history (folded previous sessions + current session) with pass/fail markers, multi-select (`Space`), full preview (`v`), and procedure creation (`p`).
  - `[3] Procedures`: Saved procedures and captured failed commands (`✗ ERR`), scrollable code/traceback preview, multi-sample benchmarking (`b`) with `v1 → v2` generation deltas, and `@testset` file generation (`T`).
  - `[4] Packages`: Interactive project package manager (`a` add, `d` remove, `u` update).
  - `[5] Plots`: Automatic PNG plot gallery (`CairoMakie`, `Plots.jl`, `jEMach.capture_plot`) with inline **Kitty Graphics Protocol** rendering in Ghostty & Kitty, PNG export (`s`), and external viewer launch (`o`).
  - `[?] Guide`: Built-in quick-reference tab covering REPL modes, macros, API functions, and TUI keybindings.
- **Native Julia REPL integration (`src/repl_mode.jl`)**: Dedicated `jemach>` REPL mode (`}` or `Alt+m`) with Tab completion, global shortcuts (`Alt+j` toggle TUI, `Alt+r` live procedure recording), `@jemach` / `@inspect` macros, `workspace()`, and live `REPLHistoryProvider` history sync.
- **Reusable Procedures Engine (`src/procedures/`)**: AST-based free-variable analysis and parameterization (`make_procedure`, `record` / `record_stop`), lazy on-demand indexing on startup (`ENV["JEMACH_AUTOLOAD"] = "1"` for eager loading), live reload/save lifecycle, and error/traceback diagnostics.
- **Multi-Session Isolation & Live Status**: Private per-REPL session directories under `/tmp/jemach-<uid>/session-*/` (`0700`/`0600`), interactive **Session Switcher** (`B` / `Ctrl+S`), `⟳ BUSY` elapsed timer with completion notifications (`>= 10s`), and `Revise.jl` status indicator.
- **Optional Native Zig Accelerator (`zig/`)**: `libjemach_native` for fast JSON string escaping and history/source scanning with pure-Julia fallbacks, plus experimental `jemach-broker`.
- **Testing, Benchmarks & Docs**: Full Julia + LuaJIT + PTY smoke + Zig test suites (`test/`), reproducible snapshot benchmark (`scripts/benchmark.jl`), Documenter.jl documentation (`docs/`), and GitHub Actions CI & TagBot workflows.

### Changed
- Replaced the legacy Neovim Lua plugin with a Data-Oriented Struct-of-Arrays (`WorkspaceTable`) Julia engine communicating over full-duplex UNIX domain sockets (`src/ipc/`).
- Set minimum supported Julia version to `1.10` with standard-library-only runtime dependencies (`Dates`, `Pkg`, `REPL`, `Sockets`).

### Fixed
- Normalized `select(2)` `timeval` (`0 <= tv_usec < 1_000_000`) and Darwin `suseconds_t` FFI typedef (`int` on macOS) so TUI keyboard input and socket updates work on macOS instead of failing with `EINVAL`.
- Fixed disappearing `julia>` / `jemach>` prompt in Ghostty on Julia 1.14+ (OSC 133 handling), `Alt+j` redraws, symlink resolution in `jl-assist`, and Julia 1.13+ world-age workspace binding visibility.
- Fixed UTF-8 input/truncation, `Ctrl+U` search clearing, CSI-u key normalization, and FNV-1a/Wyhash parity between Zig and Julia.
- Updated macOS CI matrix to use native Apple Silicon (`aarch64`) instead of Rosetta `x64` emulation and silenced noisy Homebrew keg check output.

## [0.1.1-dAiSy] - 2026-06-11

- Early prototype release prior to standalone TUI and procedures engine rewrite.

[0.2.0]: https://github.com/kitajusSus/jEMach.jl/compare/v0.1.1-dAiSy...v0.2.0
[0.1.1-dAiSy]: https://github.com/kitajusSus/jEMach.jl/releases/tag/v0.1.1-dAiSy
