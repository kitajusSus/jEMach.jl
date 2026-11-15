# Data-Oriented Design (DoD) workspace table, reflection, inspection & session saving.

struct WorkspaceTable
    names::Vector{String}
    kinds::Vector{String}
    types::Vector{String}
    values::Vector{String}
    exprs::Vector{String}
    modules::Vector{String}
    depths::Vector{Int32}
    parent_indices::Vector{Int32}
    has_children::Vector{Bool}
end

function WorkspaceTable()
    return WorkspaceTable(
        String[], String[], String[], String[], String[], String[],
        Int32[], Int32[], Bool[]
    )
end

function Base.empty!(t::WorkspaceTable)
    empty!(t.names)
    empty!(t.kinds)
    empty!(t.types)
    empty!(t.values)
    empty!(t.exprs)
    empty!(t.modules)
    empty!(t.depths)
    empty!(t.parent_indices)
    empty!(t.has_children)
    return t
end

function _add_entry!(
        t::WorkspaceTable,
        name::String,
        kind::String,
        type_str::String,
        value_str::String,
        expr_str::String,
        mod_str::String,
        depth::Int,
        parent_idx::Int,
        has_children::Bool
    )::Int
    push!(t.names, name)
    push!(t.kinds, kind)
    push!(t.types, type_str)
    push!(t.values, value_str)
    push!(t.exprs, expr_str)
    push!(t.modules, mod_str)
    push!(t.depths, Int32(depth))
    push!(t.parent_indices, Int32(parent_idx))
    push!(t.has_children, has_children)
    return length(t.names)
end

const _shared_workspace_table = Ref{WorkspaceTable}(WorkspaceTable())

function Base.show(io::IO, t::WorkspaceTable)
    top_count = count(==(0), t.depths)
    print(io, "WorkspaceTable($top_count top-level items, $(length(t.names)) total nodes)")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", t::WorkspaceTable)
    use_color = get(io, :color, true)
    bold = use_color ? "\e[1m" : ""
    cyan = use_color ? "\e[36m" : ""
    green = use_color ? "\e[32m" : ""
    yellow = use_color ? "\e[33m" : ""
    magenta = use_color ? "\e[35m" : ""
    dim = use_color ? "\e[2m" : ""
    reset = use_color ? "\e[0m" : ""

    n = length(t.names)
    if n == 0
        print(io, "$(dim)WorkspaceTable is empty (no user variables in Main).$(reset)")
        return nothing
    end

    top_indices = [i for i in 1:n if t.depths[i] == 0]
    println(io, bold * cyan * "┌─ jEMach Workspace (" * string(length(top_indices)) * " top-level items) " * ("─"^28) * reset)
    println(io, bold * "│ " * rpad("NAME", 22) * " " * rpad("TYPE", 22) * " " * rpad("SIZE", 10) * " VALUE" * reset)
    println(io, cyan * "├" * ("─"^76) * reset)

    for i in top_indices
        name = t.names[i]
        kind = t.kinds[i]
        tp = t.types[i]
        val_str = t.values[i]
        mod_str = t.modules[i]

        sz_str = "-"
        if mod_str == "Main" && kind == "variable"
            sym = Symbol(name)
            if Base.invokelatest(isdefined, Main, sym)
                try
                    v = Base.invokelatest(getfield, Main, sym)
                    sz_str = Base.format_bytes(Base.summarysize(v))
                catch
                end
            end
        end

        name_disp = mod_str == "Main" ? name : (mod_str * "." * name)
        name_short = length(name_disp) > 21 ? first(name_disp, 20) * "…" : name_disp
        tp_short = length(tp) > 21 ? first(tp, 20) * "…" : tp
        val_short = length(val_str) > 32 ? first(val_str, 31) * "…" : val_str

        k_color = kind == "function" ? cyan : (kind == "type" ? magenta : green)
        println(
            io,
            "│ " * k_color * bold * rpad(name_short, 22) * reset * " " *
                yellow * rpad(tp_short, 22) * reset * " " *
                dim * rpad(sz_str, 10) * reset * " " *
                val_short
        )
    end
    print(io, bold * cyan * "└" * ("─"^76) * reset)
    return nothing
end

"""
    workspace(query::AbstractString = "")

Collect and display the current Julia workspace variables, functions, types,
their memory footprint (`summarysize`), and value previews directly in the REPL.
Optionally filter entries by `query`.
"""
function workspace(query::AbstractString = "")
    t = Base.invokelatest(_collect_state_dod!, _shared_workspace_table[])
    q = lowercase(strip(query))
    if isempty(q)
        Base.invokelatest(show, IOContext(stdout, :color => true), MIME("text/plain"), t)
        println(stdout)
        return nothing
    end

    filtered = WorkspaceTable()
    for i in 1:length(t.names)
        if t.depths[i] == 0 && (
                occursin(q, lowercase(t.names[i])) ||
                    occursin(q, lowercase(t.types[i])) ||
                    occursin(q, lowercase(t.values[i])) ||
                    occursin(q, lowercase(t.modules[i]))
            )
            _add_entry!(
                filtered, t.names[i], t.kinds[i], t.types[i], t.values[i],
                t.exprs[i], t.modules[i], Int(t.depths[i]), Int(t.parent_indices[i]), t.has_children[i]
            )
        end
    end
    Base.invokelatest(show, IOContext(stdout, :color => true), MIME("text/plain"), filtered)
    println(stdout)
    return nothing
end

# ---------------------------------------------------------------------------
# Workspace introspection & child extraction
# ---------------------------------------------------------------------------

const _cached_pkgs = Ref{Vector{Dict{String, String}}}(Dict{String, String}[])
const _last_pkg_mtime = Ref{Float64}(0.0)
const _last_pkg_file = Ref{String}("")

function _get_packages()::Vector{Dict{String, String}}
    proj_dir = _get_project_dir()
    proj_file = joinpath(proj_dir, "Project.toml")
    mf_path = joinpath(proj_dir, "Manifest.toml")
    !isfile(mf_path) && isfile(joinpath(proj_dir, "JuliaManifest.toml")) &&
        (mf_path = joinpath(proj_dir, "JuliaManifest.toml"))
    mtime_proj = (isfile(proj_file) ? mtime(proj_file) : 0.0) +
        (isfile(mf_path) ? mtime(mf_path) : 0.0)

    if !isempty(_cached_pkgs[]) && proj_file == _last_pkg_file[] && mtime_proj == _last_pkg_mtime[]
        return _cached_pkgs[]
    end

    pkgs = Dict{String, String}[]
    try
        isfile(proj_file) || return _cached_pkgs[]
        proj_toml = Base.parsed_toml(proj_file)
        deps = get(proj_toml, "deps", nothing)
        deps isa AbstractDict || return _cached_pkgs[]

        manifest_versions = Dict{String, String}()
        if isfile(mf_path)
            mf = Base.parsed_toml(mf_path)
            mf_deps = get(mf, "deps", mf)
            if mf_deps isa AbstractDict
                for (_, entries) in mf_deps
                    entries isa AbstractVector || continue
                    for entry in entries
                        entry isa AbstractDict || continue
                        uuid = string(get(entry, "uuid", ""))
                        ver = get(entry, "version", nothing)
                        if !isnothing(ver) && !isempty(uuid)
                            manifest_versions[uuid] = string(ver)
                        end
                    end
                end
            end
        end

        for (name, uuid) in deps
            ver = get(manifest_versions, string(uuid), "unknown")
            push!(pkgs, Dict("name" => String(name), "version" => ver))
        end
        sort!(pkgs; by = x -> x["name"])
        _cached_pkgs[] = pkgs
        _last_pkg_file[] = proj_file
        _last_pkg_mtime[] = mtime_proj
    catch
    end
    return _cached_pkgs[]
end

const _BUILTIN_NAMES = Set([
    "ans", "err", "eval", "include", "clear",
    "Base", "Core", "Main", "InteractiveUtils",
    "jEMach", "OhMyREPL", "Revise",
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
    (val isa Number || val isa Bool || val isa Symbol) && return string(val)
    if val isa AbstractString
        return length(val) > 60 ? repr(first(val, 57)) * "…" : repr(val)
    end
    return try
        s = sprint((io, x) -> Base.invokelatest(show, io, x), val; context = IOContext(devnull, :limit => true, :compact => true))
        s = replace(s, '\n' => ' ')
        length(s) > 60 ? first(s, 60) * "…" : s
    catch
        "<?>"
    end
end

function _collect_children_dod!(
        t::WorkspaceTable,
        val,
        parent_expr::String,
        mod_name::String,
        depth::Int,
        parent_idx::Int
    )
    depth > 5 && return
    add_child!(name::String, type_str::String, val_preview::String, expr::String) =
        _add_entry!(t, name, "variable", type_str, val_preview, expr, mod_name, depth, parent_idx, false)

    T = typeof(val)
    return try
        type_name_str = string(T)
        if occursin("DataFrame", type_name_str) || (hasmethod(names, Tuple{T}) && hasmethod(getindex, Tuple{T, Symbol}))
            try
                col_names = names(val)
                r_count = size(val, 1)
                for cname in col_names[1:min(length(col_names), 20)]
                    c_str = string(cname)
                    c_col = val[!, Symbol(cname)]
                    add_child!(":" * c_str, "$(typeof(c_col)) ($r_count rows)", _value_preview(c_col), "$parent_expr[!, :$c_str]")
                end
            catch
            end
        elseif val isa AbstractDict
            for (count, (k, v)) in enumerate(val)
                count > 20 && break
                add_child!(string(k), string(typeof(v)), _value_preview(v), "$parent_expr[$(repr(k))]")
            end
        elseif val isa AbstractArray && ndims(val) == 1
            for i in 1:min(length(val), 20)
                add_child!("[$i]", string(typeof(val[i])), _value_preview(val[i]), "$parent_expr[$i]")
            end
        elseif val isa AbstractArray && ndims(val) == 2
            rows, cols = size(val)
            el_tp = string(eltype(val))
            for i in 1:min(rows, 5), j in 1:min(cols, 5)
                add_child!("[$i, $j]", el_tp, _value_preview(val[i, j]), "$parent_expr[$i, $j]")
            end
        elseif val isa AbstractArray && ndims(val) > 2
            add_child!("[dimensions]", "Tuple", string(size(val)), "size($parent_expr)")
        elseif val isa NamedTuple
            for name in keys(val)
                v = val[name]
                n_str = string(name)
                add_child!(n_str, string(typeof(v)), _value_preview(v), "$parent_expr.$n_str")
            end
        elseif val isa Tuple
            for (i, v) in enumerate(val)
                i > 20 && break
                add_child!("[$i]", string(typeof(v)), _value_preview(v), "$parent_expr[$i]")
            end
        elseif !isprimitivetype(T) && T !== Module && T !== Function && T !== DataType && T !== UnionAll
            for f in fieldnames(T)
                f_str = string(f)
                f_val = try
                    getfield(val, f)
                catch
                    continue
                end
                add_child!(f_str, string(typeof(f_val)), _value_preview(f_val), "$parent_expr.$f_str")
            end
        end
    catch
    end
end

const _methods_summary_cache = Dict{UInt64, String}()
const _methods_summary_world_ref = Ref{UInt64}(UInt64(0))

function _method_count_summary(val)::String
    cur_world = Base.get_world_counter()
    if _methods_summary_world_ref[] != cur_world
        empty!(_methods_summary_cache)
        _methods_summary_world_ref[] = cur_world
    end
    oid = objectid(val)
    cached = get(_methods_summary_cache, oid, nothing)
    !isnothing(cached) && return cached
    s = try
        ms = methods(val)
        n = length(ms)
        "($(n) method" * (n == 1 ? "" : "s") * ")"
    catch
        "(function)"
    end
    _methods_summary_cache[oid] = s
    return s
end

function _collect_module_items_dod!(t::WorkspaceTable, mod::Module, mod_name::String, all::Bool)
    syms = names(mod; all = all, imported = false)
    candidates = Tuple{Symbol, String, Any, String}[]
    for sym in syms
        name = string(sym)
        _skip_name(name) && continue
        isdefined(mod, sym) || continue
        val = try
            getfield(mod, sym)
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
        kind == "module" && continue
        push!(candidates, (sym, name, val, kind))
    end

    sort!(candidates; by = x -> (x[4] == "variable" ? 0 : 1, x[2]))

    for (_, name, val, kind) in candidates
        type_str = string(typeof(val))
        value_str = ""
        if kind == "variable"
            if all || isa(val, Number) || isa(val, AbstractString) || isa(val, Symbol) || isa(val, Bool)
                value_str = _value_preview(val)
            end
        elseif kind == "function"
            value_str = _method_count_summary(val)
        elseif kind == "type"
            value_str = "(type)"
        end

        item_expr = (mod == Main) ? name : (mod_name * "." * name)
        has_kids = (kind == "variable") && (
            val isa AbstractDict ||
                (val isa AbstractArray && !isempty(val)) ||
                val isa Tuple ||
                val isa NamedTuple ||
                (!isprimitivetype(typeof(val)) && !(typeof(val) in (Module, Function, DataType, UnionAll)))
        )

        entry_idx = _add_entry!(t, name, kind, type_str, value_str, item_expr, mod_name, 0, -1, has_kids)
        has_kids && _collect_children_dod!(t, val, item_expr, mod_name, 1, entry_idx)
    end
    return nothing
end

const _IGNORED_LOADED_MODULES = Set(["Main", "Base", "Core", "jEMach", "OhMyREPL", "Revise", "Pkg", "InteractiveUtils", "VSCodeServer"])

const _last_loaded_modules = Ref{Vector{Module}}(Module[])

function _snapshot_loaded_modules()::Vector{Module}
    if isdefined(Base, :require_lock) && Base.require_lock isa ReentrantLock
        if trylock(Base.require_lock)
            try
                mods = collect(values(Base.loaded_modules))
                _last_loaded_modules[] = mods
                return mods
            finally
                unlock(Base.require_lock)
            end
        end
        return _last_loaded_modules[]
    end
    return try
        mods = collect(values(Base.loaded_modules))
        _last_loaded_modules[] = mods
        mods
    catch
        _last_loaded_modules[]
    end
end

function _collect_state_dod!(t::WorkspaceTable)::WorkspaceTable
    empty!(t)
    _collect_module_items_dod!(t, Main, "Main", true)

    seen = copy(_IGNORED_LOADED_MODULES)
    for mod in _snapshot_loaded_modules()
        name = string(mod)
        name in seen && continue
        mod_sym = nameof(mod)
        if isdefined(Main, mod_sym)
            bound = try
                getfield(Main, mod_sym)
            catch
                nothing
            end
            if bound === mod
                push!(seen, name)
                _collect_module_items_dod!(t, mod, name, false)
            end
        end
    end

    # Collect non-ignored submodules bound directly in Main (e.g., local `module Foo ... end`)
    for sym in names(Main; all = true, imported = false)
        name = string(sym)
        (_skip_name(name) || name in seen) && continue
        isdefined(Main, sym) || continue
        val = try
            getfield(Main, sym)
        catch
            continue
        end
        val isa Module || continue
        (val === Main || val === Base || val === Core) && continue
        full_name = string(val)
        full_name in seen && continue
        push!(seen, name)
        push!(seen, full_name)
        _collect_module_items_dod!(t, val, name, parentmodule(val) === Main)
    end
    return t
end

function _inspect_var_details(val)
    bold, reset = "\e[1m", "\e[0m"
    println(bold * "Type:          " * reset * "$(typeof(val))")
    if hasmethod(size, Tuple{typeof(val)})
        try
            println(bold * "Size:          " * reset * "$(size(val))")
        catch
        end
    end
    if hasmethod(length, Tuple{typeof(val)}) && !(val isa Function)
        try
            println(bold * "Length:        " * reset * "$(length(val))")
        catch
        end
    end
    println()

    if val isa Function
        println(bold * "Methods & Return Types:" * reset)
        try
            ms = methods(val)
            for (i, m) in enumerate(ms)
                i > 15 && break
                r_str = ""
                try
                    sig_types = m.sig.types[2:end]
                    rt = Base.promote_op(val, sig_types...)
                    r_str = " → \e[36m$(rt)\e[0m"
                catch
                end
                println("  [$i] $m$r_str")
            end
            length(ms) > 15 && println("  ... ($(length(ms) - 15) more methods)")
            println()
        catch
        end
    end
    return nothing
end

"""
    inspect_var(mod::Module, expr_str::String)

Print a detailed report about the value of `expr_str` evaluated in `mod`: type, size,
methods with inferred return types, the REPL command that created it, and its docstring.
See also `@inspect`.
"""
function inspect_var(mod::Module, expr_str::String)
    val = try
        Base.invokelatest(Core.eval, mod, Meta.parse(expr_str))
    catch
        println("Could not evaluate expression $expr_str in module $mod.")
        return nothing
    end

    bold, green, reset = "\e[1m", "\e[32m", "\e[0m"
    println("\n" * green * bold * "━"^60 * reset)
    println(bold * "Variable:      " * reset * "$mod.$expr_str")
    Base.invokelatest(_inspect_var_details, val)

    base_m = match(r"^[a-zA-Z_][a-zA-Z0-9_]*", expr_str)
    base_var_str = isnothing(base_m) ? expr_str : base_m.match
    sym = Symbol(base_var_str)

    try
        var_regex = Regex("\\b" * base_var_str * "\\b")
        found_cmd = ""
        for cmd in Iterators.reverse(get_recent_commands(limit = 100))
            if occursin(var_regex, cmd) && occursin(r"=|function|macro|struct", cmd) &&
                    !occursin("println", cmd) && !occursin("typeof", cmd) && !occursin("dump", cmd)
                found_cmd = cmd
                break
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

    try
        doc = Base.invokelatest(Base.Docs.doc, Base.Docs.Binding(mod, sym))
        doc_str = string(doc)
        if !occursin("No documentation found", doc_str)
            println(bold * "Documentation:" * reset)
            Base.invokelatest(show, IOContext(stdout, :color => true), MIME("text/plain"), doc)
            println()
        end
    catch
    end
    println(green * bold * "━"^60 * reset)
    return nothing
end

"""
    save_clean_session()

Replay the current session's commands in a sandbox module and save only the ones that
succeed to `jemach/repl_session_<timestamp>.jl`.
"""
function save_clean_session()
    cmds = get_session_commands()
    if isempty(cmds)
        println("\nNo commands found in the current session.")
        return nothing
    end

    sandbox_mod = Module(Symbol("Sandbox_", round(Int, time())))
    Core.eval(sandbox_mod, :(using Base))

    successful_cmds = String[]
    for cmd in cmds
        if occursin("jEMach", cmd) || occursin("inspect_var", cmd) || occursin("STATE_FILE", cmd) || occursin("save_clean_session", cmd)
            continue
        end
        expr = try
            Meta.parse(cmd)
        catch
            nothing
        end
        expr === nothing && continue
        try
            Base.invokelatest(Core.eval, sandbox_mod, expr)
            push!(successful_cmds, cmd)
        catch
        end
    end

    if isempty(successful_cmds)
        println("\nNo successful commands to save.")
        return nothing
    end

    jemach_dir = joinpath(_get_project_dir(), "jemach")
    !isdir(jemach_dir) && mkpath(jemach_dir)

    timestamp_str = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    filepath = joinpath(jemach_dir, "repl_session_$(timestamp_str).jl")

    open(filepath, "w") do f
        write(f, "# Clean Julia REPL session saved on $(Dates.now())\n")
        write(f, "# Generated by jEMach\n\n")
        for cmd in successful_cmds
            write(f, cmd, "\n\n")
        end
    end

    println("\n" * "✓"^60)
    println(" Clean REPL session saved successfully!")
    println(" File: $filepath")
    println(" " * "✓"^60)
    return nothing
end
