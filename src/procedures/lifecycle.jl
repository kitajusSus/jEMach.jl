# ---------------------------------------------------------------------------
# Live REPL function capture, in-REPL editing, reload & save lifecycle
# ---------------------------------------------------------------------------

function _extract_balanced_block(lines::Vector{<:AbstractString}, start_idx::Int)::String
    (start_idx < 1 || start_idx > length(lines)) && return ""
    limit = min(length(lines), start_idx + 250)
    buf = IOBuffer()
    for i in start_idx:limit
        i > start_idx && write(buf, '\n')
        write(buf, lines[i])
        candidate = String(take!(copy(buf)))
        ex = Meta.parse(candidate; raise = false)
        if !(ex isa Expr && (ex.head == :incomplete || ex.head == :error))
            return String(strip(candidate))
        end
    end
    return ""
end

function _resolve_main_function_source(sym::Symbol)::Tuple{String, String}
    if !Base.invokelatest(isdefined, Main, sym)
        return ("$(sym)()", "function $(sym)()\n    \nend")
    end
    val = Base.invokelatest(getfield, Main, sym)
    if !(val isa Function)
        return ("$(sym)()", "function $(sym)()\n    \nend")
    end

    ms = try
        collect(Base.invokelatest(methods, val))
    catch
        Method[]
    end

    for m in ms
        m.module === Main || continue
        fpath = string(m.file)
        if !startswith(fpath, "REPL[") && fpath != "none" && isfile(fpath) && m.line > 0
            file_lines = try
                readlines(fpath)
            catch
                String[]
            end
            block = _extract_balanced_block(file_lines, Int(m.line))
            if !isempty(block)
                ex = Meta.parse(block; raise = false)
                sig = ex isa Expr ? _extract_sig_and_name(ex, sym; allow_qualified = false)[1] : ""
                isempty(sig) && (sig = "$(sym)()")
                return (sig, block)
            end
        end
    end

    for cmd in reverse(get_recent_commands(50))
        parsed = try
            Meta.parseall(cmd)
        catch
            nothing
        end
        parsed isa Expr || continue
        for a in parsed.args
            a isa Expr || continue
            s, fn = _extract_sig_and_name(a, Symbol(""); allow_qualified = false)
            if fn == sym && !isempty(s)
                scan = _scan_proc_source(cmd)
                clean = isempty(scan.edit_code) ? String(strip(cmd)) : scan.edit_code
                return (s, clean)
            end
        end
    end

    sig_guess = if !isempty(ms)
        m1 = ms[1]
        argnames = try
            Base.method_argnames(m1)[2:end]
        catch
            Symbol[]
        end
        params = [string(a) for a in argnames if a != Symbol("") && !startswith(string(a), "#")]
        "$(sym)(" * join(params, ", ") * ")"
    else
        "$(sym)()"
    end
    return (sig_guess, "function $(sig_guess)\n    \nend")
end

function _ensure_live_proc_for_symbol(sym::Symbol)::Union{Nothing, ProcedureInfo}
    haskey(_procedures, sym) && return _procedures[sym]
    Base.invokelatest(isdefined, Main, sym) || return nothing
    val = try
        Base.invokelatest(getfield, Main, sym)
    catch
        return nothing
    end
    val isa Function || return nothing

    sig, src = _resolve_main_function_source(sym)
    scan = _scan_proc_source(src)
    edit_s = isempty(scan.edit_code) ? src : scan.edit_code
    p = ProcedureInfo(
        sym, sig, "", "", src, 0.0, 0, :never, "-";
        origin = :live,
        disk_code = "",
        live_code = src,
        edit_code = edit_s,
        imports_block = scan.imports_block,
        disk_hash = UInt64(0),
        live_hash = scan.content_hash,
        generation = 1,
        func_start_line = scan.func_line,
    )
    _procedures[sym] = p
    _proc_registry_epoch[] += 1
    return p
end

function _collect_top_func_defs!(defs::Vector{Tuple{Expr, String, Symbol, String}}, ex)
    ex isa Expr || return nothing
    if ex.head in (:toplevel, :block)
        for a in ex.args
            _collect_top_func_defs!(defs, a)
        end
    elseif ex.head == :macrocall && length(ex.args) >= 4
        mac = ex.args[1]
        is_doc = (mac == Symbol("@doc")) || (mac == GlobalRef(Core, Symbol("@doc"))) ||
            (mac isa GlobalRef && mac.name == Symbol("@doc"))
        if is_doc && ex.args[4] isa Expr
            s, fn = _extract_sig_and_name(ex.args[4], Symbol(""); allow_qualified = false)
            if fn != Symbol("") && !isempty(s) && !startswith(string(fn), "#")
                push!(defs, (ex.args[4], string(ex.args[3]), fn, s))
            end
        end
    elseif ex.head == :function || ex.head == :(=)
        s, fn = _extract_sig_and_name(ex, Symbol(""); allow_qualified = false)
        if fn != Symbol("") && !isempty(s) && !startswith(string(fn), "#")
            push!(defs, (ex, "", fn, s))
        end
    end
    return nothing
end

function _capture_repl_definitions!(code_str::AbstractString)::Bool
    s = String(strip(code_str))
    isempty(s) && return false
    (!occursin("function", s) && !occursin("=", s)) && return false
    startswith(s, "jEMach.") && return false

    parsed = try
        Meta.parseall(s)
    catch
        return false
    end
    defs = Tuple{Expr, String, Symbol, String}[]
    _collect_top_func_defs!(defs, parsed)
    isempty(defs) && return false

    captured = false
    for (fexpr, doc_str, fname, sig) in defs
        Base.invokelatest(isdefined, Main, fname) || continue
        val = try
            Base.invokelatest(getfield, Main, fname)
        catch
            nothing
        end
        val isa Function || continue

        raw_src = if length(defs) == 1
            s
        else
            string(Base.remove_linenums!(copy(fexpr)))
        end
        scan = _scan_proc_source(raw_src)
        edit_s = isempty(scan.edit_code) ? raw_src : scan.edit_code

        if haskey(_procedures, fname)
            p = _procedures[fname]
            p.signature = sig
            !isempty(strip(doc_str)) && (p.doc = strip(doc_str))
            if !isempty(scan.imports_block)
                p.imports_block = scan.imports_block
            end
            p.live_code = raw_src
            p.code = raw_src
            p.edit_code = edit_s
            p.live_hash = scan.content_hash
            p.func_start_line = scan.func_line
            if !isempty(p.file)
                if p.disk_hash != UInt64(0) && scan.content_hash == p.disk_hash
                    p.origin = :disk
                else
                    if p.last_run_status == :ok
                        p.prev_time_ms = p.last_run_time_ms
                        p.prev_alloc_bytes = p.last_run_alloc_bytes
                        p.prev_generation = p.generation
                    end
                    p.origin = :modified
                    p.generation += 1
                end
            else
                if p.last_run_status == :ok
                    p.prev_time_ms = p.last_run_time_ms
                    p.prev_alloc_bytes = p.last_run_alloc_bytes
                    p.prev_generation = p.generation
                end
                p.origin = :live
                p.generation += 1
            end
            p.last_error_line = 0
            if p.last_run_status == :error &&
                    (startswith(p.last_run_cmd, "parse(") || startswith(p.last_run_cmd, "include("))
                p.last_run_status = :never
                p.last_run_cmd = ""
                p.last_error = ""
                p.last_error_detail = ""
                p.last_error_cmd = ""
            end
        else
            _procedures[fname] = ProcedureInfo(
                fname, sig, "", strip(doc_str), raw_src,
                0.0, 0, :never, "-";
                origin = :live,
                disk_code = "",
                live_code = raw_src,
                edit_code = edit_s,
                imports_block = scan.imports_block,
                disk_hash = UInt64(0),
                live_hash = scan.content_hash,
                generation = 1,
                func_start_line = scan.func_line,
            )
        end
        _proc_registry_epoch[] += 1
        captured = true
    end
    return captured
end

function _rewrite_func_name(src::AbstractString, old_sym::Symbol, new_sym::Symbol)::String
    old_sym == new_sym && return String(src)
    old_esc = replace(string(old_sym), r"([\\^$.|?*+()\[\]{}])" => s"\\\1")
    new_str = string(new_sym)
    lines = split(String(src), '\n')
    pat = Regex("^(\\s*(?:function\\s+)?)($(old_esc))(\\s*\\()")
    for i in eachindex(lines)
        m = match(pat, lines[i])
        if !isnothing(m)
            lines[i] = replace(lines[i], pat => SubstitutionString("$(m.captures[1])$(new_str)$(m.captures[3])"); count = 1)
            break
        end
    end
    return join(lines, '\n')
end

"""
    edit_procedure(name) -> Union{String, Nothing}

Return the clean editable function definition (`function ... end`) for `name`,
and if running in an interactive Julia REPL, load it into the active `julia>`
input buffer so you can tweak the function directly in memory.
"""
function edit_procedure(name::Union{Symbol, AbstractString})
    sym = Symbol(strip(string(name)))
    _load_procedures!()
    p = get(_procedures, sym, nothing)
    if isnothing(p)
        p = _ensure_live_proc_for_symbol(sym)
    end
    if isnothing(p)
        println("\e[31m✗ Function or procedure ':$sym' not found.\e[0m")
        return nothing
    end

    src = strip(isempty(strip(p.edit_code)) ? (isempty(strip(p.live_code)) ? p.code : p.live_code) : p.edit_code)
    isempty(src) && (src = strip(p.code))

    if isdefined(Base, :active_repl) && !isnothing(_get_mistate())
        edit_txt = String(src)
        @async begin
            sleep(0.06)
            _repl_switch_to_main_and_replace(edit_txt)
        end
    end
    return String(src)
end

"""
    reload_procedure(name) -> Union{ProcedureInfo, Nothing}

Discard any in-memory modifications to `name` by re-evaluating its disk file
`procedures/<name>.jl` into `Main`, resetting its status back to `:disk`.
"""
function reload_procedure(name::Union{Symbol, AbstractString})
    sym = Symbol(strip(string(name)))
    _load_procedures!()
    proj_dir = _get_project_dir()
    p = get(_procedures, sym, nothing)

    proc_file = if !isnothing(p) && !isempty(p.file)
        joinpath(proj_dir, p.file)
    else
        joinpath(proj_dir, "procedures", string(sym) * ".jl")
    end
    if !isfile(proc_file) && isdir(joinpath(proj_dir, "procedures"))
        for (root, _, files) in walkdir(joinpath(proj_dir, "procedures"))
            if string(sym) * ".jl" in files
                proc_file = joinpath(root, string(sym) * ".jl")
                break
            end
        end
    end

    if !isfile(proc_file)
        println("\e[33m! No disk file for live function ':$sym'. Use `save $sym` or `jEMach.save_procedure(:$sym)` first.\e[0m")
        return nothing
    end

    content = read(proc_file, String)
    file_mt = try
        mtime(proc_file)
    catch
        0.0
    end
    rel_path = relpath(proc_file, proj_dir)
    scan = _scan_proc_source(content)

    Base.include(Main, proc_file)
    _loaded_proc_mtimes[proc_file] = file_mt
    _parsed_proc_mtimes[proc_file] = file_mt
    _parsed_proc_names[proc_file] = sym

    if isnothing(p)
        p = ProcedureInfo(
            sym, string(sym) * "()", rel_path, "", content, 0.0, 0, :never, "-";
            origin = :disk,
            disk_code = content,
            live_code = content,
            edit_code = isempty(scan.edit_code) ? content : scan.edit_code,
            imports_block = scan.imports_block,
            disk_hash = scan.content_hash,
            live_hash = scan.content_hash,
            generation = 1,
            func_start_line = scan.func_line,
        )
        _procedures[sym] = p
    else
        p.file = rel_path
        p.origin = :disk
        p.disk_code = content
        p.live_code = content
        p.code = content
        p.edit_code = isempty(scan.edit_code) ? content : scan.edit_code
        p.imports_block = scan.imports_block
        p.disk_hash = scan.content_hash
        p.live_hash = scan.content_hash
        p.generation = 1
        p.func_start_line = scan.func_line
        p.last_error = ""
        p.last_error_detail = ""
        p.last_error_line = 0
        p.last_error_cmd = ""
        p.last_run_status == :error && (p.last_run_status = :never)
    end
    _proc_registry_epoch[] += 1
    publish_state()
    println("\e[32m✓ Reloaded ':$sym' from $rel_path\e[0m")
    return p
end

"""
    save_procedure(name; as_name = nothing) -> Union{String, Nothing}

Write the current in-memory function definition of `name` cleanly to
`procedures/<as_name || name>.jl`, include it in `Main`, and mark it `:disk`.
"""
function save_procedure(name::Union{Symbol, AbstractString}; as_name::Union{Nothing, Symbol, AbstractString} = nothing)
    sym = Symbol(strip(string(name)))
    _load_procedures!()
    p = get(_procedures, sym, nothing)
    if isnothing(p)
        p = _ensure_live_proc_for_symbol(sym)
    end
    if isnothing(p)
        println("\e[31m✗ Cannot save ':$sym': not found in procedures or Main.\e[0m")
        return nothing
    end

    target_sym = if isnothing(as_name) || isempty(strip(string(as_name)))
        sym
    else
        Symbol(strip(string(as_name)))
    end

    raw_src = strip(isempty(strip(p.edit_code)) ? (isempty(strip(p.live_code)) ? p.code : p.live_code) : p.edit_code)
    isempty(raw_src) && (raw_src = strip(p.code))
    raw_scan = _scan_proc_source(raw_src)
    body = strip(isempty(raw_scan.edit_code) ? raw_src : raw_scan.edit_code)
    if target_sym != sym
        body = _rewrite_func_name(body, sym, target_sym)
    end

    imports_s = strip(isempty(raw_scan.imports_block) ? p.imports_block : raw_scan.imports_block)
    doc_s = strip(p.doc)
    sig_s = p.signature
    if target_sym != sym
        ex = try
            Meta.parse(body; raise = false)
        catch
            nothing
        end
        if ex isa Expr
            sig_new, _ = _extract_sig_and_name(ex, target_sym; allow_qualified = false)
            !isempty(sig_new) && (sig_s = sig_new)
        end
    end

    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    parts = String["# Generated by jEMach on $timestamp"]
    !isempty(imports_s) && push!(parts, imports_s)
    if !isempty(doc_s) && !startswith(lstrip(body), "\"\"\"")
        push!(parts, "\"\"\"\n    $sig_s\n\n$doc_s\n\"\"\"")
    end
    push!(parts, body)
    full_code = join(parts, "\n\n") * "\n"

    proc_dir = joinpath(_get_project_dir(), "procedures")
    !isdir(proc_dir) && mkpath(proc_dir)
    filepath = joinpath(proc_dir, string(target_sym) * ".jl")
    write(filepath, full_code)

    file_mt = try
        mtime(filepath)
    catch
        0.0
    end
    rel_path = relpath(filepath, _get_project_dir())
    scan = _scan_proc_source(full_code)

    try
        Base.include(Main, filepath)
        _loaded_proc_mtimes[filepath] = file_mt
    catch e
        @warn "Saved $rel_path, but evaluating it into Main failed" exception = e
    end

    if target_sym == sym
        p.file = rel_path
        p.signature = sig_s
        p.origin = :disk
        p.disk_code = full_code
        p.live_code = full_code
        p.code = full_code
        p.edit_code = isempty(scan.edit_code) ? full_code : scan.edit_code
        p.imports_block = scan.imports_block
        p.disk_hash = scan.content_hash
        p.live_hash = scan.content_hash
        p.generation = 1
        p.func_start_line = scan.func_line
    else
        _procedures[target_sym] = ProcedureInfo(
            target_sym, sig_s, rel_path, doc_s, full_code, 0.0, 0, :never, "-";
            origin = :disk,
            disk_code = full_code,
            live_code = full_code,
            edit_code = isempty(scan.edit_code) ? full_code : scan.edit_code,
            imports_block = scan.imports_block,
            disk_hash = scan.content_hash,
            live_hash = scan.content_hash,
            generation = 1,
            func_start_line = scan.func_line,
        )
    end
    _parsed_proc_mtimes[filepath] = file_mt
    _parsed_proc_names[filepath] = target_sym
    _proc_registry_epoch[] += 1
    publish_state()
    println("\e[32m✓ Saved ':$target_sym' to $rel_path\e[0m")
    return rel_path
end

function _delete_procedure!(name::Union{Symbol, AbstractString})
    sym = Symbol(strip(string(name)))
    p = get(_procedures, sym, nothing)
    isnothing(p) && return false
    if !isempty(p.file)
        full_p = joinpath(_get_project_dir(), p.file)
        isfile(full_p) && rm(full_p; force = true)
        delete!(_loaded_proc_mtimes, full_p)
        delete!(_parsed_proc_mtimes, full_p)
        delete!(_parsed_proc_names, full_p)
    end
    delete!(_procedures, sym)
    _proc_registry_epoch[] += 1
    publish_state()
    return true
end
