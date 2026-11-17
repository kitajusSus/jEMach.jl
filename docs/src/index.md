# Engineer's Notebook: jEMach.jl

Field notes and internal architecture log for `jEMach.jl` - Data-Oriented Julia runtime introspection engine and terminal workspace assistant (`jl-assist`).

## Core Overview

jEMach runs an asynchronous background task inside the active Julia REPL process.
It extracts active module symbols, types, evaluated values, and project dependencies,
serializing them into a columnar snapshot sent directly to `jl-assist` through a
private per-process UNIX socket.

#### Components

- **jEMach.jl**: Julia package exporting async background task watcher with Data-Oriented Design (DoD) tables.
- **jl-assist / jl_tui.lua / tui/**: Modular LuaJIT terminal inspector with multiple terminal backends.
- **zig/**: Optional native accelerator and separate experimental IPC broker.

## Documentation Sections

- [REPL Auto-Hook (startup.jl)](startup.md): Manual setup instructions for loading `jEMach` automatically on Julia start.
- [IPC & Socket Architecture](ipc.md): UNIX domain socket server broadcasting and backup state persistence.
- [Type Introspection](types.md): Inspection rules for DataFrames, matrices, arrays, dicts, tuples, and structs.
- [Development](development.md): Source map and regression checks.
- [Performance](performance.md): Reproducible snapshot benchmark and measurement limits.
