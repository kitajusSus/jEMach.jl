# jl_watcher.jl — Julia Background Watcher for jemach TUI
#
# Load in your Julia REPL:
#   include("scripts/jl_watcher.jl")
#
# The watcher runs as a background task and writes the current workspace
# state to /tmp/jl_tui_state.json every UPDATE_INTERVAL seconds.
# The jl_tui.lua standalone TUI reads this file and renders the tree view.

module JlWatcher

const STATE_FILE = "/tmp/jl_tui_state.json"
const UPDATE_INTERVAL = 2.0  # seconds between state refreshes

# ---------------------------------------------------------------------------
# Minimal JSON serialiser (no external dependencies)
# ---------------------------------------------------------------------------

function _json_str(s::AbstractString)::String
    buf = IOBuffer()
    write(buf, '"')
    for c in s
        if c == '"';  write(buf, "\\\"")
        elseif c == '\\'; write(buf, "\\\\")
        elseif c == '\n'; write(buf, "\\n")
        elseif c == '\r'; write(buf, "\\r")
        elseif c == '\t'; write(buf, "\\t")
        else write(buf, c)
        end
    end
    write(buf, '"')
    String(take!(buf))
end

function _item_to_json(item::Dict{String,String})::String
    "{\"name\":$(_json_str(item["name"]))," *
    "\"kind\":$(_json_str(item["kind"]))," *
    "\"type\":$(_json_str(item["type"]))," *
    "\"value\":$(_json_str(item["value"]))}"
end

function _serialize(modules_data::Vector)::String
    buf = IOBuffer()
    write(buf, "{\"timestamp\":")
    write(buf, string(round(Int, time())))
    write(buf, ",\"modules\":[")
    for (i, mod_data) in enumerate(modules_data)
        write(buf, "{\"name\":")
        write(buf, _json_str(mod_data[:name]))
        write(buf, ",\"items\":[")
        items = mod_data[:items]
        for (j, item) in enumerate(items)
            write(buf, _item_to_json(item))
            j < length(items) && write(buf, ",")
        end
        write(buf, "]}")
        i < length(modules_data) && write(buf, ",")
    end
    write(buf, "]}")
    String(take!(buf))
end

# ---------------------------------------------------------------------------
# Workspace introspection
# ---------------------------------------------------------------------------

# Names that are always present in a fresh REPL and clutter the view
const _BUILTIN_NAMES = Set([
    "ans", "err", "eval", "include",
    "Base", "Core", "Main", "InteractiveUtils",
])

const _SKIP_PREFIXES = ("#", "_REPL", "REPL", "IJulia")

function _skip_name(s::String)::Bool
    s in _BUILTIN_NAMES && return true
    for pfx in _SKIP_PREFIXES
        startswith(s, pfx) && return true
    end
    return false
end

function _value_preview(val)::String
    try
        s = sprint(show, val; context = IOContext(devnull, :limit => true, :compact => true))
        # strip newlines and limit length
        s = replace(s, '\n' => ' ')
        length(s) > 60 ? s[1:60] * "…" : s
    catch
        "<?>"
    end
end

function _get_items(mod::Module)::Vector{Dict{String,String}}
    items = Dict{String,String}[]
    for sym in names(mod; all = true, imported = false)
        name = string(sym)
        _skip_name(name) && continue

        val = try getfield(mod, sym) catch; continue end

        kind = if isa(val, Function);        "function"
               elseif isa(val, Module);      "module"
               elseif isa(val, DataType) || isa(val, UnionAll); "type"
               else                          "variable"
               end

        kind == "module" && continue  # modules shown at top level

        type_str = string(typeof(val))
        value_str = kind == "variable" ? _value_preview(val) : ""

        push!(items, Dict(
            "name"  => name,
            "kind"  => kind,
            "type"  => type_str,
            "value" => value_str,
        ))
    end
    sort!(items; by = x -> (x["kind"] == "variable" ? 0 : 1, x["name"]))
end

function _collect_state()::Vector
    modules_data = []

    # 1. Main module — always first
    push!(modules_data, Dict(
        :name  => "Main",
        :items => _get_items(Main),
    ))

    # 2. Other loaded packages (from Base.loaded_modules)
    seen = Set(["Main", "Base", "Core"])
    for (_, mod) in Base.loaded_modules
        name = string(mod)
        name in seen && continue
        push!(seen, name)
        push!(modules_data, Dict(
            :name  => name,
            :items => _get_items(mod),
        ))
    end

    modules_data
end

# ---------------------------------------------------------------------------
# Background watcher task
# ---------------------------------------------------------------------------

const _task_ref = Ref{Union{Task, Nothing}}(nothing)
const _running  = Ref{Bool}(false)

function start()
    if _running[]
        @info "JlWatcher already running"
        return
    end
    _running[] = true
    _task_ref[] = @async begin
        @info "JlWatcher started — writing state to $STATE_FILE"
        while _running[]
            try
                state = _collect_state()
                json  = _serialize(state)
                open(STATE_FILE, "w") do f
                    write(f, json)
                end
            catch e
                @warn "JlWatcher error" exception = e
            end
            sleep(UPDATE_INTERVAL)
        end
        @info "JlWatcher stopped"
    end
    nothing
end

function stop()
    _running[] = false
    @info "JlWatcher stopping after current cycle…"
end

function status()
    if _running[]
        println("JlWatcher is RUNNING  →  $STATE_FILE")
    else
        println("JlWatcher is STOPPED")
    end
end

end  # module JlWatcher

# Auto-start when the file is include()'d
JlWatcher.start()
