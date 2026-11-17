# REPL Auto-Hooking Setup

Manual configuration notes for auto-loading `jEMach` on Julia interactive sessions via `~/.julia/config/startup.jl`.

## Why Manual Hooking?

`jEMach` runs a background task using `Timer` or `@async`. To avoid overhead in non-interactive background scripts (e.g. batch jobs, CI test runners), `jEMach` should only load when `isinteractive()` is true.

## Adding to startup.jl

Location: `~/.julia/config/startup.jl` (create file if it does not exist).

#### Basic Setup (Installed Package)

If `jEMach` is added to your primary global Julia environment (`@v1.11` or default):

```julia
# ~/.julia/config/startup.jl

if isinteractive()
    try
        using jEMach
    catch e
        # Silently fail or log if jEMach is not available in the current environment
    end
end
```

#### Advanced Setup (Handling Local Project Environments)

When starting Julia with `--project=.`, global packages might not be in scope unless loaded explicitly from global specs:

```julia
# ~/.julia/config/startup.jl

if isinteractive()
    let
        # Auto-load Revise if present
        try
            using Revise
        catch
        end

        # Attempt loading jEMach from dev path or package manager
        try
            using jEMach
        catch
        end
    end
end
```

#### Behavior Verification

When configured correctly, launching `julia` starts the background watcher and a
private UNIX socket. Run `jEMach.terminal_info()` to see its session paths.
Connect with `jl-assist` from the same project. While a TUI subscriber is connected,
the watcher checks the workspace every 0.5 seconds and publishes changed snapshots
to the socket and session's `state.json` file. Without subscribers it skips
collection. See [IPC and sessions](ipc.md) for multiple REPLs and explicit selection.
