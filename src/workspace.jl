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
    sizes::Vector{Int64}
end

function WorkspaceTable()
    return WorkspaceTable(
        String[], String[], String[], String[], String[], String[],
        Int32[], Int32[], Bool[], Int64[]
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
    empty!(t.sizes)
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
        has_children::Bool,
        size_bytes::Integer = Int64(-1)
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
    push!(t.sizes, Int64(size_bytes))
    return length(t.names)
end

function _append_table!(dst::WorkspaceTable, src::WorkspaceTable)
    offset = Int32(length(dst.names))
    append!(dst.names, src.names)
    append!(dst.kinds, src.kinds)
    append!(dst.types, src.types)
    append!(dst.values, src.values)
    append!(dst.exprs, src.exprs)
    append!(dst.modules, src.modules)
    append!(dst.depths, src.depths)
    for pidx in src.parent_indices
        push!(dst.parent_indices, pidx >= Int32(0) ? pidx + offset : Int32(-1))
    end
    append!(dst.has_children, src.has_children)
    append!(dst.sizes, src.sizes)
    return dst
end

const _shared_workspace_table = Ref{WorkspaceTable}(WorkspaceTable())
const _pkg_items_cache = WorkspaceTable()
const _pkg_items_world_ref = Ref{UInt64}(UInt64(0))
const _pkg_items_mods_ref = Ref{UInt64}(UInt64(0))
const _pkg_cache_lock = ReentrantLock()

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

        sz_str = t.sizes[i] >= 0 ? Base.format_bytes(t.sizes[i]) : "-"
        if sz_str == "-" && mod_str == "Main" && kind == "variable"
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
    t = Base.invokelatest(_collect_state_dod!, WorkspaceTable())
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
                t.exprs[i], t.modules[i], Int(t.depths[i]), Int(t.parent_indices[i]),
                t.has_children[i], t.sizes[i]
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

const _var_size_cache = Dict{UInt64, Tuple{Int, Int64}}()
const _var_size_lock = ReentrantLock()

function _fast_var_size(val)::Int64
    T = typeof(val)
    (T === Module || val isa Function || T === DataType || T === UnionAll) && return Int64(-1)
    if isbitstype(T) || val isa String || val isa SubString{String} || val isa Symbol
        return Int64(sizeof(val))
    elseif (val isa Array || val isa BitArray) && isbitstype(eltype(val))
        return Int64(sizeof(val))
    end
    oid = objectid(val)
    stamp = if val isa AbstractDict || val isa AbstractArray || val isa Tuple
        try
            Int(length(val))
        catch
            0
        end
    elseif hasmethod(size, Tuple{T, Int})
        try
            Int(size(val, 1))
        catch
            0
        end
    else
        Int(Base.get_world_counter() & 0x7fffffff)
    end
    return lock(_var_size_lock) do
        cached = get(_var_size_cache, oid, nothing)
        if !isnothing(cached) && cached[1] == stamp
            return cached[2]
        end
        sz = try
            Int64(Base.summarysize(val))
        catch
            Int64(-1)
        end
        length(_var_size_cache) >= 512 && empty!(_var_size_cache)
        _var_size_cache[oid] = (stamp, sz)
        return sz
    end
end

function _value_has_children(val)::Bool
    T = typeof(val)
    (T === Module || val isa Function || T === DataType || T === UnionAll) && return false
    if val isa AbstractDict
        return !isempty(val)
    elseif val isa AbstractArray
        return !isempty(val)
    elseif val isa Tuple || val isa NamedTuple
        return !isempty(val)
    elseif !isprimitivetype(T)
        return fieldcount(T) > 0
    end
    return false
end

function _value_preview(val)::String
    (val isa Number || val isa Bool || val isa Symbol) && return string(val)
    if val isa AbstractString
        return length(val) > 60 ? repr(first(val, 57)) * "…" : repr(val)
    elseif val isa AbstractArray && length(val) > 64
        s = try
            head_els = String[]
            for (k, el) in enumerate(val)
                k > 3 && break
                push!(head_els, (el isa Number || el isa Bool || el isa Symbol) ? string(el) : repr(el))
            end
            sample_s = isempty(head_els) ? "" : " [" * join(head_els, ", ") * ", …]"
            summary(val) * sample_s
        catch
            string(typeof(val))
        end
        return length(s) > 60 ? first(s, 59) * "…" : s
    elseif val isa AbstractDict && length(val) > 16
        s = "$(typeof(val)) ($(length(val)) entries)"
        return length(s) > 60 ? first(s, 59) * "…" : s
    end
    return try
        s = sprint((io, x) -> Base.invokelatest(show, io, x), val; context = IOContext(devnull, :limit => true, :compact => true))
        s = replace(s, '\n' => ' ')
        length(s) > 60 ? first(s, 59) * "…" : s
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
    function add_child!(name::String, type_str::String, child_val, val_preview::String, expr::String, allow_recurse::Bool = true)
        kids = allow_recurse && depth < 5 && _value_has_children(child_val)
        sz = _fast_var_size(child_val)
        cidx = _add_entry!(t, name, "variable", type_str, val_preview, expr, mod_name, depth, parent_idx, kids, sz)
        if kids && _is_path_expanded(mod_name * "/" * expr)
            _collect_children_dod!(t, child_val, expr, mod_name, depth + 1, cidx)
        end
        return cidx
    end

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
                    add_child!(":" * c_str, "$(typeof(c_col)) ($r_count rows)", c_col, _value_preview(c_col), "$parent_expr[!, :$c_str]")
                end
            catch
            end
        elseif val isa AbstractDict
            for (count, (k, v)) in enumerate(val)
                count > 20 && break
                add_child!(string(k), string(typeof(v)), v, _value_preview(v), "$parent_expr[$(repr(k))]")
            end
        elseif val isa AbstractArray && ndims(val) == 1
            for i in 1:min(length(val), 20)
                add_child!("[$i]", string(typeof(val[i])), val[i], _value_preview(val[i]), "$parent_expr[$i]")
            end
        elseif val isa AbstractArray && ndims(val) == 2
            rows, cols = size(val)
            el_tp = string(eltype(val))
            for i in 1:min(rows, 5), j in 1:min(cols, 5)
                add_child!("[$i, $j]", el_tp, val[i, j], _value_preview(val[i, j]), "$parent_expr[$i, $j]", false)
            end
        elseif val isa AbstractArray && ndims(val) > 2
            sz_t = size(val)
            _add_entry!(t, "[dimensions]", "variable", "Tuple", string(sz_t), "size($parent_expr)", mod_name, depth, parent_idx, false, Int64(sizeof(sz_t)))
        elseif val isa NamedTuple
            for name in keys(val)
                v = val[name]
                n_str = string(name)
                add_child!(n_str, string(typeof(v)), v, _value_preview(v), "$parent_expr.$n_str")
            end
        elseif val isa Tuple
            for (i, v) in enumerate(val)
                i > 20 && break
                add_child!("[$i]", string(typeof(v)), v, _value_preview(v), "$parent_expr[$i]")
            end
        elseif !isprimitivetype(T) && T !== Module && T !== Function && T !== DataType && T !== UnionAll
            for f in fieldnames(T)
                f_str = string(f)
                f_val = try
                    getfield(val, f)
                catch
                    continue
                end
                add_child!(f_str, string(typeof(f_val)), f_val, _value_preview(f_val), "$parent_expr.$f_str")
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
        has_kids = (kind == "variable") && _value_has_children(val)
        sz_bytes = (kind == "variable" && all) ? _fast_var_size(val) : Int64(-1)

        entry_idx = _add_entry!(t, name, kind, type_str, value_str, item_expr, mod_name, 0, -1, has_kids, sz_bytes)
        if has_kids && _is_path_expanded(mod_name * "/" * item_expr)
            _collect_children_dod!(t, val, item_expr, mod_name, 1, entry_idx)
        end
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
    pkg_mods = Tuple{Module, String}[]
    mods_hash = UInt64(0)
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
                push!(pkg_mods, (mod, name))
                mods_hash = hash(objectid(mod), mods_hash)
            end
        end
    end

    if !isempty(pkg_mods)
        cur_world = Base.get_world_counter()
        lock(_pkg_cache_lock) do
            if _pkg_items_world_ref[] != cur_world || _pkg_items_mods_ref[] != mods_hash
                empty!(_pkg_items_cache)
                for (mod, name) in pkg_mods
                    _collect_module_items_dod!(_pkg_items_cache, mod, name, false)
                end
                _pkg_items_world_ref[] = cur_world
                _pkg_items_mods_ref[] = mods_hash
            end
            _append_table!(t, _pkg_items_cache)
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

function _get_revise_status()::String
    for mod in _snapshot_loaded_modules()
        if nameof(mod) === :Revise
            return try
                has_err = isdefined(mod, :queue_errors) && !isempty(Base.invokelatest(getfield, mod, :queue_errors))
                has_err && return "error"
                has_pend = isdefined(mod, :revision_queue) && !isempty(Base.invokelatest(getfield, mod, :revision_queue))
                has_pend ? "pending" : "ok"
            catch
                "ok"
            end
        end
    end
    return ""
end

function _resolve_module_by_name(mod_str::AbstractString)::Module
    mod_str == "Main" && return Main
    sym = Symbol(mod_str)
    if Base.invokelatest(isdefined, Main, sym)
        m = try
            Base.invokelatest(getfield, Main, sym)
        catch
            nothing
        end
        m isa Module && return m
    end
    for m in _snapshot_loaded_modules()
        string(m) == mod_str && return m
    end
    return Main
end

function _cell_preview(x, max_len::Int = 36)::String
    (x isa Number || x isa Bool || x isa Symbol) && return _truncate_chars(string(x), max_len)
    isnothing(x) && return "nothing"
    x === missing && return "missing"
    if x isa AbstractString
        r = repr(x)
        return _truncate_chars(r, max_len)
    end
    return try
        s = sprint((io, v) -> Base.invokelatest(show, io, v), x; context = IOContext(devnull, :limit => true, :compact => true))
        _truncate_chars(replace(s, '\n' => ' '), max_len)
    catch
        "<?>"
    end
end

function _compute_inspector_json(
        mod_str::AbstractString,
        expr_str::AbstractString,
        row_start::Int = 1,
        col_start::Int = 1,
        max_rows::Int = 30,
        max_cols::Int = 8
    )::String
    mod = _resolve_module_by_name(mod_str)
    val = try
        Base.invokelatest(Core.eval, mod, Meta.parse(expr_str))
    catch e
        buf = IOBuffer()
        write(buf, "{\"ok\":false,\"expr\":")
        _write_json_str(buf, String(expr_str))
        write(buf, ",\"mod\":")
        _write_json_str(buf, String(mod_str))
        write(buf, ",\"error\":")
        _write_json_str(buf, _truncate_chars(sprint(showerror, e), 240))
        write(buf, "}")
        return String(take!(buf))
    end

    T = typeof(val)
    type_str = string(T)
    sz_bytes = _fast_var_size(val)
    kind = "scalar"
    dims_str = ""
    total_rows = 0
    total_cols = 0
    r1 = max(1, row_start)
    c1 = max(1, col_start)
    headers = String[]
    grid_rows = Vector{String}[]
    body_text = ""

    is_df = occursin("DataFrame", type_str) || (hasmethod(names, Tuple{T}) && hasmethod(size, Tuple{T, Int}) && !(val isa AbstractArray))
    if is_df
        try
            cnames = collect(names(val))
            total_rows = Int(size(val, 1))
            total_cols = length(cnames)
            dims_str = "$(total_rows)×$(total_cols)"
            kind = "table"
            r1 = total_rows > 0 ? clamp(r1, 1, total_rows) : 1
            c1 = total_cols > 0 ? clamp(c1, 1, total_cols) : 1
            r2 = min(total_rows, r1 + max(1, max_rows) - 1)
            c2 = min(total_cols, c1 + max(1, max_cols) - 1)
            push!(headers, "ROW")
            cols_slice = Any[]
            for c in c1:c2
                cn = cnames[c]
                col_vec = val[!, Symbol(cn)]
                push!(cols_slice, col_vec)
                push!(headers, "$(cn) :: $(eltype(col_vec))")
            end
            for r in r1:r2
                row_cells = String[string(r)]
                for col_vec in cols_slice
                    cell_v = try
                        col_vec[r]
                    catch
                        "<?>"
                    end
                    push!(row_cells, _cell_preview(cell_v, 28))
                end
                push!(grid_rows, row_cells)
            end
        catch
            kind = "scalar"
        end
    elseif val isa AbstractArray && ndims(val) == 2
        total_rows, total_cols = size(val)
        dims_str = "$(total_rows)×$(total_cols)"
        kind = "matrix"
        r1 = total_rows > 0 ? clamp(r1, 1, total_rows) : 1
        c1 = total_cols > 0 ? clamp(c1, 1, total_cols) : 1
        r2 = min(total_rows, r1 + max(1, max_rows) - 1)
        c2 = min(total_cols, c1 + max(1, max_cols) - 1)
        push!(headers, "ROW \\ COL")
        for c in c1:c2
            push!(headers, "[:, $c]")
        end
        for r in r1:r2
            row_cells = String["[$r, :]"]
            for c in c1:c2
                cell_v = try
                    val[r, c]
                catch
                    "<?>"
                end
                push!(row_cells, _cell_preview(cell_v, 24))
            end
            push!(grid_rows, row_cells)
        end
    elseif (val isa AbstractArray && ndims(val) == 1) || val isa Tuple || val isa AbstractSet
        items_vec = val isa AbstractSet ? collect(val) : val
        total_rows = length(items_vec)
        total_cols = 1
        dims_str = "$(total_rows) items"
        kind = "vector"
        r1 = total_rows > 0 ? clamp(r1, 1, total_rows) : 1
        c1 = 1
        r2 = min(total_rows, r1 + max(1, max_rows) - 1)
        append!(headers, ("INDEX", "TYPE", "VALUE"))
        for r in r1:r2
            el = try
                items_vec[r]
            catch
                "<?>"
            end
            push!(grid_rows, String["[$r]", string(typeof(el)), _cell_preview(el, 56)])
        end
    elseif val isa AbstractArray && ndims(val) > 2
        total_rows = length(val)
        total_cols = 1
        dims_str = join(size(val), "×")
        kind = "vector"
        r1 = total_rows > 0 ? clamp(r1, 1, total_rows) : 1
        c1 = 1
        r2 = min(total_rows, r1 + max(1, max_rows) - 1)
        append!(headers, ("INDEX", "TYPE", "VALUE"))
        cis = CartesianIndices(val)
        for r in r1:r2
            ci = cis[r]
            el = try
                val[ci]
            catch
                "<?>"
            end
            idx_s = "[" * join(Tuple(ci), ", ") * "]"
            push!(grid_rows, String[idx_s, string(typeof(el)), _cell_preview(el, 52)])
        end
    elseif val isa AbstractDict
        total_rows = length(val)
        total_cols = 1
        dims_str = "$(total_rows) entries"
        kind = "dict"
        r1 = total_rows > 0 ? clamp(r1, 1, total_rows) : 1
        c1 = 1
        append!(headers, ("KEY", "TYPE", "VALUE"))
        for (idx, (k, v)) in enumerate(val)
            idx < r1 && continue
            idx >= r1 + max(1, max_rows) && break
            push!(grid_rows, String[_cell_preview(k, 28), string(typeof(v)), _cell_preview(v, 48)])
        end
    elseif val isa NamedTuple || (!isprimitivetype(T) && T !== Module && !(val isa Function) && T !== DataType && T !== UnionAll && fieldcount(T) > 0)
        fnames = val isa NamedTuple ? collect(keys(val)) : collect(fieldnames(T))
        total_rows = length(fnames)
        total_cols = 1
        dims_str = "$(total_rows) fields"
        kind = "struct"
        r1 = total_rows > 0 ? clamp(r1, 1, total_rows) : 1
        c1 = 1
        r2 = min(total_rows, r1 + max(1, max_rows) - 1)
        append!(headers, ("FIELD", "TYPE", "VALUE"))
        for r in r1:r2
            f = fnames[r]
            fv = try
                val isa NamedTuple ? val[f] : getfield(val, f)
            catch
                "<undef>"
            end
            push!(grid_rows, String[string(f), string(typeof(fv)), _cell_preview(fv, 52)])
        end
    else
        kind = (val isa Function || T === DataType || T === UnionAll) ? "callable" : "scalar"
        io_b = IOBuffer()
        if val isa Function
            try
                ms = collect(Base.invokelatest(methods, val))
                println(io_b, "Methods ($(length(ms))):")
                for (mi, m) in enumerate(ms)
                    mi > 25 && (println(io_b, "  ... ($(length(ms) - 25) more)"); break)
                    println(io_b, "  [$mi] ", m)
                end
            catch
            end
        else
            try
                Base.invokelatest(show, IOContext(io_b, :limit => true), MIME("text/plain"), val)
            catch
                print(io_b, _cell_preview(val, 200))
            end
        end
        base_m = match(r"^[a-zA-Z_][a-zA-Z0-9_!]*", expr_str)
        if !isnothing(base_m)
            try
                doc = Base.invokelatest(Base.Docs.doc, Base.Docs.Binding(mod, Symbol(base_m.match)))
                ds = _strip_ansi_codes(sprint(io -> Base.invokelatest(show, IOContext(io, :color => false), MIME("text/plain"), doc)))
                if !occursin("No documentation found", ds)
                    println(io_b, "\nDocumentation:\n", strip(ds))
                end
            catch
            end
        end
        body_text = _truncate_chars(String(take!(io_b)), 3500)
    end

    return lock(_serialize_lock) do
        buf = IOBuffer()
        dst_buf = _json_dst_buf
        write(buf, "{\"ok\":true,\"expr\":")
        _write_json_str(buf, String(expr_str), dst_buf)
        write(buf, ",\"mod\":")
        _write_json_str(buf, String(mod_str), dst_buf)
        write(buf, ",\"kind\":")
        _write_json_str(buf, kind, dst_buf)
        write(buf, ",\"type\":")
        _write_json_str(buf, type_str, dst_buf)
        write(buf, ",\"dims\":")
        _write_json_str(buf, dims_str, dst_buf)
        write(buf, ",\"size_bytes\":")
        print(buf, sz_bytes)
        write(buf, ",\"row\":")
        print(buf, r1)
        write(buf, ",\"col\":")
        print(buf, c1)
        write(buf, ",\"total_rows\":")
        print(buf, total_rows)
        write(buf, ",\"total_cols\":")
        print(buf, total_cols)
        write(buf, ",\"headers\":")
        _write_json_str_col(buf, headers, dst_buf)
        write(buf, ",\"rows\":[")
        for (ri, rvec) in enumerate(grid_rows)
            ri > 1 && write(buf, ',')
            _write_json_str_col(buf, rvec, dst_buf)
        end
        write(buf, "],\"text\":")
        _write_json_str(buf, body_text, dst_buf)
        write(buf, "}")
        String(take!(buf))
    end
end
