# src/jEMach.jl — Julia Background Watcher & REPL Assistant for jEMach TUI
#
#   using jEMach
#
#   • Press `}` at the start of an empty line (or `Alt+m`) to enter `jemach>` mode
#   • Press `Alt+j` (or `@jemach`) to toggle the TUI split/window
#   • Press `Alt+r` to start/stop live procedure recording
#   • Use `@jemach ls`, `@jemach inspect x`, `@jemach ws`, or `workspace()`

"""
    jEMach

Julia Workspace Assistant & REPL Monitor with multi-terminal TUI
(`Ghostty`, `Kitty`, `tmux`, `Zellij`, `Rex`) and dedicated `jemach>` REPL mode.

### Quick REPL Shortcuts
- **`}`** (at start of line) or **`Alt+m`**: Enter interactive `jemach>` REPL mode (`help` for commands)
- **`Alt+j`** or **`@jemach`**: Toggle the interactive TUI panel open/closed
- **`Alt+r`**: Start / stop live procedure recording (`⏺ [rec] julia>`)
- **`workspace()`** or **`@jemach ws`**: Print a formatted workspace variable table in the REPL
- **`@inspect expr`** or **`@jemach inspect expr`**: Deep inspect variable/function & creation history
"""
module jEMach

import Dates
import REPL
import REPL.LineEdit
import Sockets

export make_procedure, record, record_stop, run_procedure, benchmark_procedure,
    generate_procedure_test, list_procedures, find_procedures, search_procedures,
    autoload_procedures!, get_recent_commands, edit_procedure, reload_procedure,
    save_procedure, capture_plot, detect_backend, terminal_info, workspace,
    inspect_var, save_clean_session, @jemach, @inspect

include("config.jl")
include("json.jl")
include("session.jl")
include("workspace.jl")
include("history.jl")
include("procedures.jl")
include("plots.jl")
include("ipc.jl")
include("backends.jl")
include("repl_mode.jl")

function __init__()
    _load_zig_native!()
    hist_path = _history_path()
    HIST_START_POS[] = isfile(hist_path) ? filesize(hist_path) : 0

    atexit(() -> stop(quiet = true))

    # Index procedures/*.jl metadata lazily without executing top-level code on startup.
    # Procedures are evaluated into Main on demand when clicked/run or reloaded;
    # set ENV["JEMACH_AUTOLOAD"] = "1" to opt into eager evaluation at startup.
    if get(ENV, "JEMACH_AUTOLOAD", "0") == "1"
        try
            autoload_procedures!()
        catch e
            @debug "jEMach: autoload of procedures failed" exception = e
        end
    else
        try
            _load_procedures!(; eval_in_main = false)
        catch e
            @debug "jEMach: procedure indexing failed" exception = e
        end
    end

    if isinteractive()
        if isdefined(Base, :active_repl) && !isnothing(Base.active_repl)
            _setup_repl_hooks(Base.active_repl)
        else
            Base.atreplinit(_setup_repl_hooks)
        end
    end

    return start(split = false, quiet = true)
end

# ---------------------------------------------------------------------------
# Precompilation of hot paths (reduces first-refresh latency after `using jEMach`)
# ---------------------------------------------------------------------------
precompile(_collect_state_dod!, (WorkspaceTable,))
precompile(_collect_module_items_dod!, (WorkspaceTable, Module, String, Bool))
precompile(_collect_children_dod!, (WorkspaceTable, Any, String, String, Int, Int))
precompile(_get_packages, ())
precompile(_serialize_dod_body, (WorkspaceTable, Vector{Dict{String, String}}))
precompile(_serialize_dod, (WorkspaceTable, Vector{Dict{String, String}}))
precompile(publish_state, ())
precompile(_parse_json_cmd, (String,))
precompile(_handle_socket_message, (String,))
precompile(_load_procedures!, ())
precompile(get_recent_commands, ())
precompile(_parse_history_bytes, (Vector{UInt8}, Bool, Int))
precompile(_write_json_str, (IOBuffer, String, Vector{UInt8}))
precompile(_write_json_str_julia, (IOBuffer, String))
precompile(detect_backend, ())
precompile(detect_backend, (Symbol,))
precompile(_value_preview, (Int,))
precompile(_value_preview, (Float64,))
precompile(_value_preview, (String,))
precompile(_value_preview, (Vector{Float64},))
precompile(_exec_command, (String,))
precompile(_jemach_completions, (String,))
precompile(workspace, (String,))
precompile(inspect_var, (Module, String))
precompile(edit_procedure, (Symbol,))
precompile(reload_procedure, (Symbol,))
precompile(save_procedure, (Symbol,))
precompile(_scan_proc_source, (String,))
precompile(_capture_repl_definitions!, (String,))
precompile(Base.show, (Base.TTY, MIME"text/plain", WorkspaceTable))
precompile(Base.show, (IOContext{Base.TTY}, MIME"text/plain", WorkspaceTable))
precompile(Base.show, (IOContext{Base.TTY}, MIME"text/plain", ProcedureInfo))

end  # module jEMach
