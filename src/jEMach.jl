# src/jEMach.jl — Julia Background Watcher for jemach TUI
#
# Load in your Julia REPL:
#   using jEMach
#
# The watcher runs as a background task and writes the current workspace
# state to /tmp/jl_tui_state.json every UPDATE_INTERVAL seconds.

module jEMach

import Dates
import Pkg
import Sockets

const STATE_FILE = Ref{String}("/tmp/jl_tui_state.json")
const SOCKET_PATH = Ref{String}("/tmp/jemach.sock")
const UPDATE_INTERVAL = 2.0  # seconds between state refreshes

function _get_project_dir()::String
    proj_path = try Pkg.project().path catch; nothing end
    if !isnothing(proj_path) && isfile(proj_path) && !occursin(".julia/environments", proj_path)
        return dirname(proj_path)
    else
        return pwd()
    end
end

function _get_safe_name(proj_dir::String)::String
    return replace(proj_dir, r"[^a-zA-Z0-9]" => "_")
end

# ---------------------------------------------------------------------------
# Minimal JSON serialiser (no external dependencies)
# ---------------------------------------------------------------------------

function _json_str(s::AbstractString)::String
    buf = IOBuffer()
    write(buf, '"')
    for c in s
        if c == '"'
            write(buf, "\\\"")
        elseif c == '\\'
            write(buf, "\\\\")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        elseif c == '\b'
            write(buf, "\\b")
        elseif c == '\f'
            write(buf, "\\f")
        elseif iscntrl(c)
            write(buf, "\\u$(lpad(string(Int(c), base = 16), 4, '0'))")
        else
            write(buf, c)
        end
    end
    write(buf, '"')
    return String(take!(buf))
end

function _item_to_json(item::Dict{String, Any})::String
    s = "{\"name\":$(_json_str(item["name"]))," *
        "\"kind\":$(_json_str(item["kind"]))," *
        "\"type\":$(_json_str(item["type"]))," *
        "\"value\":$(_json_str(item["value"]))," *
        "\"expr\":$(_json_str(item["expr"]))"
    if haskey(item, "children")
        children = item["children"]::Vector{Dict{String, Any}}
        child_strs = String[]
        for c in children
            push!(child_strs, _item_to_json(c))
        end
        s *= ",\"children\":[" * join(child_strs, ",") * "]"
    end
    s *= "}"
    return s
end

function _get_children(val, parent_expr::String)::Vector{Dict{String, Any}}
    children = Dict{String, Any}[]
    T = typeof(val)

    try
        if val isa Dict
            for (k, v) in val
                length(children) >= 15 && break
                k_str = string(k)
                k_expr = parent_expr * "[" * repr(k) * "]"
                push!(children, Dict{String, Any}(
                    "name" => k_str,
                    "kind" => "variable",
                    "type" => string(typeof(v)),
                    "value" => _value_preview(v),
                    "expr" => k_expr
                ))
            end
        elseif val isa AbstractArray && ndims(val) == 1
            for i in 1:min(length(val), 15)
                push!(children, Dict{String, Any}(
                    "name" => "[$i]",
                    "kind" => "variable",
                    "type" => string(typeof(val[i])),
                    "value" => _value_preview(val[i]),
                    "expr" => parent_expr * "[$i]"
                ))
            end
        elseif val isa NamedTuple
            for name in keys(val)
                v = val[name]
                name_str = string(name)
                push!(children, Dict{String, Any}(
                    "name" => name_str,
                    "kind" => "variable",
                    "type" => string(typeof(v)),
                    "value" => _value_preview(v),
                    "expr" => parent_expr * "." * name_str
                ))
            end
        elseif !isprimitivetype(T) && T !== Module && T !== Function && T !== DataType && T !== UnionAll
            fns = fieldnames(T)
            for f in fns
                f_str = string(f)
                f_val = getfield(val, f)
                push!(children, Dict{String, Any}(
                    "name" => f_str,
                    "kind" => "variable",
                    "type" => string(typeof(f_val)),
                    "value" => _value_preview(f_val),
                    "expr" => parent_expr * "." * f_str
                ))
            end
        end
    catch
    end
    return children
end

function _serialize(modules_data::Vector, packages_data::Vector)::String
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
    write(buf, "],\"packages\":[")
    for (i, pkg) in enumerate(packages_data)
        write(buf, "{\"name\":$(_json_str(pkg["name"])),\"version\":$(_json_str(pkg["version"]))}")
        i < length(packages_data) && write(buf, ",")
    end
    write(buf, "]}")
    return String(take!(buf))
end

function _get_packages()::Vector{Dict{String, String}}
    pkgs = Dict{String, String}[]
    try
        for (name, uuid) in Pkg.project().dependencies
            ver = "unknown"
            try
                dep_info = Pkg.dependencies()[uuid]
                if dep_info.version !== nothing
                    ver = string(dep_info.version)
                end
            catch
            end
            push!(pkgs, Dict("name" => name, "version" => ver))
        end
    catch e
    end
    return sort!(pkgs; by = x -> x["name"])
end

# ---------------------------------------------------------------------------
# Workspace introspection
# ---------------------------------------------------------------------------

# Names that are always present in a fresh REPL and clutter the view
const _BUILTIN_NAMES = Set(
    [
        "ans", "err", "eval", "include",
        "Base", "Core", "Main", "InteractiveUtils",
    ]
)

const _SKIP_PREFIXES = ("#", "_REPL", "REPL", "IJulia")

function _skip_name(s::String)::Bool
    s in _BUILTIN_NAMES && return true
    for pfx in _SKIP_PREFIXES
        startswith(s, pfx) && return true
    end
    return false
end

function _value_preview(val)::String
    return try
        s = sprint((io, x) -> Base.invokelatest(show, io, x), val; context = IOContext(devnull, :limit => true, :compact => true))
        # strip newlines and limit length
        s = replace(s, '\n' => ' ')
        length(s) > 60 ? s[1:60] * "…" : s
    catch
        "<?>"
    end
end

function _get_items(mod::Module, all::Bool)::Vector{Dict{String, Any}}
    items = Dict{String, Any}[]
    for sym in Base.invokelatest(names, mod; all = all, imported = false)
        name = string(sym)
        _skip_name(name) && continue

        val = try
            Base.invokelatest(getfield, mod, sym)
        catch
            continue
        end

        kind = if isa(val, Function)
            "function"
        elseif isa(val, Module)
            "module"
        elseif isa(val, DataType) || isa(val, UnionAll)
            "type"
        else
            "variable"
        end

        kind == "module" && continue  # modules shown at top level

        type_str = string(typeof(val))

        # Only preview values in Main or simple types in other modules to avoid stack overflows
        value_str = ""
        if kind == "variable"
            if all || isa(val, Number) || isa(val, AbstractString) || isa(val, Symbol) || isa(val, Bool)
                value_str = _value_preview(val)
            end
        elseif kind == "function"
            try
                ms = methods(val)
                value_str = "($(length(ms)) method" * (length(ms) == 1 ? "" : "s") * ")"
            catch
                value_str = "(function)"
            end
        elseif kind == "type"
            value_str = "(type)"
        end

        item_expr = (mod == Main) ? name : (string(mod) * "." * name)

        item = Dict{String, Any}(
            "name" => name,
            "kind" => kind,
            "type" => type_str,
            "value" => value_str,
            "expr" => item_expr
        )

        if kind == "variable"
            children = _get_children(val, item_expr)
            if !isempty(children)
                item["children"] = children
            end
        end

        push!(items, item)
    end
    return sort!(items; by = x -> (x["kind"] == "variable" ? 0 : 1, x["name"]))
end

function inspect_var(mod::Module, expr_str::String)
    val = try
        expr = Meta.parse(expr_str)
        Base.invokelatest(Core.eval, mod, expr)
    catch
        println("Could not evaluate expression $expr_str in module $mod.")
        return nothing
    end

    # ANSI styles
    bold = "\e[1m"
    green = "\e[32m"
    reset = "\e[0m"

    println("\n" * green * bold * "━"^60 * reset)
    println(bold * "Variable:      " * reset * "$mod.$name_str")
    println(bold * "Type:          " * reset * "$(typeof(val))")
    if hasmethod(size, Tuple{typeof(val)})
        try
            println(bold * "Size:          " * reset * "$(size(val))")
        catch
        end
    end

    # Methods & Return Types
    if isa(val, Function) || (hasmethod(methods, Tuple{typeof(val)}) && !isempty(methods(val)))
        try
            ms = methods(val)
            println(bold * "Methods & Return Types:" * reset)
            for m in first(ms, 15)
                temp = m.sig
                while temp isa UnionAll
                    temp = temp.body
                end
                params = temp.parameters
                sig_types = Tuple{params[2:end]...}
                rts = Base.return_types(val, sig_types)
                rt = isempty(rts) ? "Any" : rts[1]
                m_str = sprint(show, m)
                sig_part = split(m_str, " @ ")[1]
                println("  ", sig_part, " -> ", rt)
            end
            if length(ms) > 15
                println("  ... ($(length(ms) - 15) more methods)")
            end
            println()
        catch
        end
    end

    # Search REPL history for creation/assignment
    base_m = match(r"^[a-zA-Z_][a-zA-Z0-9_]*", expr_str)
    base_var_str = isnothing(base_m) ? expr_str : base_m.match
    sym = Symbol(base_var_str)

    hist_path = joinpath(homedir(), ".julia", "logs", "repl_history.jl")
    if isfile(hist_path)
        try
            lines = readlines(hist_path)
            var_regex = Regex("\\b" * base_var_str * "\\b")
            found_cmd = ""
            current_block = String[]
            for line in reverse(lines)
                if startswith(line, "# time:")
                    block_str = join(reverse(current_block), "\n")
                    if occursin(var_regex, block_str) && occursin(r"=|function|macro|struct", block_str)
                        if !occursin("inspect_var", block_str) && !occursin("println", block_str) && !occursin("typeof", block_str) && !occursin("dump", block_str)
                            found_cmd = block_str
                            break
                        end
                    end
                    empty!(current_block)
                elseif !startswith(line, "#")
                    push!(current_block, line)
                end
            end
            if !isempty(found_cmd)
                println(bold * "Created/Modified by:" * reset)
                code_md = Base.Docs.Markdown.parse("```julia\n" * found_cmd * "\n```")
                show(IOContext(stdout, :color => true), MIME("text/plain"), code_md)
                println()
            end
        catch
        end
    end

    # Documentation
    try
        doc = Base.Docs.doc(Base.Docs.Binding(mod, sym))
        doc_str = string(doc)
        if !isempty(doc_str) && !occursin("No documentation found", doc_str)
            println(bold * "Documentation:" * reset)
            show(IOContext(stdout, :color => true), MIME("text/plain"), doc)
            println()
        end
    catch
    end
    println(green * bold * "━"^60 * reset)
    return nothing
end

function _collect_state()::Vector
    modules_data = []

    # 1. Main module — always first
    push!(
        modules_data, Dict(
            :name => "Main",
            :items => _get_items(Main, true),
        )
    )

    # 2. Collect modules explicitly loaded/imported in Main
    user_loaded_modules = Set{Module}()
    for sym in Base.invokelatest(names, Main; all = true, imported = true)
        try
            val = Base.invokelatest(getfield, Main, sym)
            if isa(val, Module)
                push!(user_loaded_modules, val)
            end
        catch
        end
    end

    # 3. Other loaded packages (from Base.loaded_modules)
    seen = Set(["Main", "Base", "Core"])
    for (_, mod) in Base.loaded_modules
        name = string(mod)
        name in seen && continue

        # Only show if the module was explicitly loaded/imported in Main
        if mod in user_loaded_modules
            push!(seen, name)
            push!(
                modules_data, Dict(
                    :name => name,
                    :items => _get_items(mod, false),
                )
            )
        end
    end

    return modules_data
end

const HIST_START_POS = Ref{Int}(0)

function get_session_commands()
    hist_path = joinpath(homedir(), ".julia", "logs", "repl_history.jl")
    !isfile(hist_path) && return String[]

    content = open(hist_path, "r") do f
        pos = min(HIST_START_POS[], filesize(hist_path))
        seek(f, pos)
        read(f, String)
    end

    commands = String[]
    current_block = String[]

    for line in split(content, '\n')
        if startswith(line, "# time:")
            if !isempty(current_block)
                cmd = join(current_block, "\n")
                push!(commands, cmd)
                empty!(current_block)
            end
        elseif !startswith(line, "#")
            # Strip leading tab which Julia REPL adds to history lines
            clean_line = startswith(line, '\t') ? line[2:end] : line
            push!(current_block, clean_line)
        end
    end
    if !isempty(current_block)
        cmd = join(current_block, "\n")
        push!(commands, cmd)
    end

    return filter(c -> !isempty(strip(c)), commands)
end

function save_clean_session()
    cmds = get_session_commands()
    if isempty(cmds)
        println("\nNo commands found in the current session.")
        return nothing
    end

    # Create a unique sandbox module to test evaluation
    sandbox_name = Symbol("Sandbox_", round(Int, time()))
    sandbox_mod = Module(sandbox_name)
    # Import Base and Core in sandbox so standard functions work
    Core.eval(sandbox_mod, :(using Base))

    successful_cmds = String[]

    for cmd in cmds
        # Skip TUI commands or watcher commands to avoid noise
        if occursin("jEMach", cmd) || occursin("inspect_var", cmd) || occursin("STATE_FILE", cmd) || occursin("save_clean_session", cmd)
            continue
        end

        # Parse the command
        expr = try
            Meta.parse(cmd)
        catch
            nothing
        end
        expr === nothing && continue

        # Try evaluating in the sandbox
        try
            Base.invokelatest(Core.eval, sandbox_mod, expr)
            push!(successful_cmds, cmd)
        catch e
            # Skip failed command
        end
    end

    if isempty(successful_cmds)
        println("\nNo successful commands to save.")
        return nothing
    end

    # Determine the project directory (workspace root)
    proj_dir = pwd()
    if !isfile(joinpath(proj_dir, "Project.toml"))
        proj_dir = dirname(dirname(@__FILE__))
    end

    jemach_dir = joinpath(proj_dir, "jemach")
    if !isdir(jemach_dir)
        mkpath(jemach_dir)
    end

    timestamp_str = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    filename = "repl_session_$(timestamp_str).jl"
    filepath = joinpath(jemach_dir, filename)

    open(filepath, "w") do f
        write(f, "# Clean Julia REPL session saved on $(Dates.now())\n")
        write(f, "# Generated by jEMach\n\n")
        for cmd in successful_cmds
            write(f, cmd)
            write(f, "\n\n")
        end
    end

    println("\n" * "✓"^60)
    println(" Clean REPL session saved successfully!")
    println(" File: $filepath")
    println(" " * "✓"^60)
    return nothing
end

function compile_sysimage(extra_pkgs::Vector{Symbol} = Symbol[])
    println("Starting jEMach system image compilation...")

    # 1. Ensure PackageCompiler is installed in the global environment
    current_project = Pkg.project().path

    println("Ensuring PackageCompiler.jl is available in global environment...")
    try
        Pkg.activate() # activate global environment
        Pkg.add("PackageCompiler")
    catch e
        println("Failed to install PackageCompiler: ", e)
        return
    end

    # Load PackageCompiler dynamically while global environment is active
    PackageCompiler = try
        Base.require(Base.PkgId(Base.UUID("9b87118b-4619-50d2-8e1e-99f35a4d4d9d"), "PackageCompiler"))
    catch e
        println("Could not load PackageCompiler.jl: ", e)
        Pkg.activate(current_project)
        return
    end

    # Reactivate original project
    Pkg.activate(current_project)

    # 2. Define the output path
    sysimage_dir = joinpath(homedir(), ".julia", "sysimages")
    if !isdir(sysimage_dir)
        mkpath(sysimage_dir)
    end
    sysimage_path = joinpath(sysimage_dir, "jemach_sysimage.so")

    pkgs_to_compile = unique(vcat([:jEMach, :Dates], extra_pkgs))
    println("Compiling sysimage for packages: ", pkgs_to_compile)
    println("Output path: ", sysimage_path)
    println("This process may take 2-5 minutes. Please be patient...")

    return try
        Base.invokelatest(
            PackageCompiler.create_sysimage,
            pkgs_to_compile,
            sysimage_path = sysimage_path,
            project = dirname(current_project)
        )
        println("\n" * "✓"^60)
        println(" System image compiled successfully!")
        println(" File: $sysimage_path")
        println(" To use it, run Julia with: julia -J $sysimage_path")
        println(" " * "✓"^60)
    catch e
        println("Error during sysimage compilation: ", e)
    end
end

# ---------------------------------------------------------------------------
# Background watcher task
# ---------------------------------------------------------------------------

const _task_ref = Ref{Union{Task, Nothing}}(nothing)
const _running = Ref{Bool}(false)

function publish_state()
    return try
        state = _collect_state()
        pkgs = _get_packages()
        json = _serialize(state, pkgs)

        # Write to file (fallback / legacy)
        temp_file = STATE_FILE[] * ".tmp"
        open(temp_file, "w") do f
            write(f, json)
        end
        mv(temp_file, STATE_FILE[]; force = true)

        # Publish to Zig broker
        try
            conn = Sockets.connect(SOCKET_PATH[])
            write(conn, json)
            close(conn)
        catch
        end
    catch e
        @warn "jEMach Watcher error" exception = e
    end
end

function start(; split::Bool = true)
    if _running[]
        @info "jEMach Watcher already running"
    else
        _running[] = true
        _task_ref[] = @async begin
            @info "jEMach Watcher started — writing state to $(STATE_FILE[])"
            while _running[]
                publish_state()
                sleep(UPDATE_INTERVAL)
            end
            @info "jEMach Watcher stopped"
        end
    end

    if split
        # Find the path of the jl-assist TUI script
        assist_path = joinpath(@__DIR__, "..", "scripts", "jl-assist")
        if !isfile(assist_path)
            # Fallback to standard installation path
            assist_path = joinpath(homedir(), ".local/share/nvim/site/pack/core/opt/jemach/scripts/jl-assist")
        end

        try
            run(`tmux split-window -h -l 80 $assist_path`)
            println("🚀 tmux TUI split opened!")
        catch e
            @warn "Failed to open tmux TUI pane (are you inside tmux?)" exception = e
        end
    end
    return nothing
end

function stop()
    _running[] = false
    return @info "jEMach Watcher stopping after current cycle…"
end

function status()
    return if _running[]
        println("jEMach Watcher is RUNNING  →  $(STATE_FILE[])")
    else
        println("jEMach Watcher is STOPPED")
    end
end

function __init__()
    hist_path = joinpath(homedir(), ".julia", "logs", "repl_history.jl")
    if isfile(hist_path)
        HIST_START_POS[] = filesize(hist_path)
    else
        HIST_START_POS[] = 0
    end
    # Initialize unique session paths based on the project folder
    safe_name = _get_safe_name(_get_project_dir())
    STATE_FILE[] = "/tmp/jl_tui_state_" * safe_name * ".json"
    SOCKET_PATH[] = "/tmp/jemach_" * safe_name * ".sock"

    # Auto-start watcher silently (without split) when loaded as a package
    return start(split = false)
end

end  # module jEMach
