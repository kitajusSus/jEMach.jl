# ---------------------------------------------------------------------------
# Live recording & execution
# ---------------------------------------------------------------------------

function _update_repl_prompt!()
    isdefined(Base, :active_repl) || return nothing
    repl = Base.active_repl
    (hasproperty(repl, :interface) && !isnothing(repl.interface) && !isempty(repl.interface.modes)) || return nothing
    julia_mode = repl.interface.modes[1]
    if isnothing(_orig_julia_prompt[])
        _orig_julia_prompt[] = julia_mode.prompt
        _orig_julia_prefix[] = julia_mode.prompt_prefix
    end
    if _recording[]
        rec_name = _record_name[]
        orig = _orig_julia_prompt[]
        julia_mode.prompt = () -> "⏺ [rec: $(rec_name)] " * (orig isa Function ? string(orig()) : string(orig))
        julia_mode.prompt_prefix = "\e[31m\e[1m"
    else
        !isnothing(_orig_julia_prompt[]) && (julia_mode.prompt = _orig_julia_prompt[])
        !isnothing(_orig_julia_prefix[]) && (julia_mode.prompt_prefix = _orig_julia_prefix[])
    end
    return nothing
end

"""
    record(name::Union{Symbol, AbstractString} = :proc)

Start recording subsequent REPL commands into a procedure named `name`.
While recording, the REPL prompt changes to `⏺ [rec: <name>] julia> `.
Call `record_stop()` (or press `Alt+r`) to finish and save the procedure.
"""
function record(name::Union{Symbol, AbstractString} = :proc)
    _recording[] = true
    _record_name[] = Symbol(name)
    hist_path = _history_path()
    _record_start_pos[] = isfile(hist_path) ? Int64(filesize(hist_path)) : Int64(0)
    hp = _active_history_provider()
    _record_hist_idx[] = isnothing(hp) ? 0 : length(hp.history)
    _update_repl_prompt!()
    println("\e[1m\e[36m⏺ [jEMach] Recording procedure '$(_record_name[])'...\e[0m")
    println("  Execute your commands in the REPL. When done, call \e[1mrecord_stop()\e[0m or press \e[1mAlt+r\e[0m")
    return nothing
end

function _recorded_commands_since_start()::Vector{String}
    hp = _active_history_provider()
    if !isnothing(hp) && _record_hist_idx[] >= 0 && length(hp.history) >= _record_hist_idx[]
        cmds = String[]
        for idx in (_record_hist_idx[] + 1):length(hp.history)
            entry = hp.history[idx]
            mode_sym, content = if isdefined(REPL, :History) && isdefined(REPL.History, :HistEntry) && entry isa REPL.History.HistEntry
                (entry.mode, entry.content)
            else
                m = (hasproperty(hp, :modes) && idx <= length(hp.modes)) ? hp.modes[idx] : :julia
                (m, String(entry))
            end
            cmd = String(rstrip(content))
            mode_sym == :julia && _is_valid_user_cmd(cmd) && push!(cmds, cmd)
        end
        !isempty(cmds) && return cmds
    end

    hist_path = _history_path()
    !isfile(hist_path) && return String[]
    sz = filesize(hist_path)
    pos = clamp(_record_start_pos[], Int64(0), Int64(sz))
    nbytes = Int(sz - pos)
    nbytes <= 0 && return String[]
    raw = try
        open(hist_path, "r") do f
            seek(f, pos)
            buf = Vector{UInt8}(undef, nbytes)
            read!(f, buf)
            buf
        end
    catch
        return String[]
    end
    return _parse_history_bytes(raw, false, 4096)
end

"""
    record_stop(; save::Bool = true)

Stop the active procedure recording, restore the standard `julia> ` prompt,
and generate `procedures/<name>.jl` with automatic AST parameterization.
"""
function record_stop(; save::Bool = true)
    if !_recording[]
        println("No procedure recording is in progress.")
        return nothing
    end
    _recording[] = false
    _update_repl_prompt!()
    cmds = filter(c -> !occursin("record_stop", c) && !occursin("@jemach stop", c), _recorded_commands_since_start())
    return make_procedure(_record_name[]; commands = cmds, save = save)
end

function _safe_arg_preview(val)::String
    return try
        s = Base.invokelatest(repr, val)
        length(s) > 40 ? first(s, 37) * "…" : s
    catch
        string(typeof(val))
    end
end

function _safe_call_str(sym::Symbol, args, kwargs)::String
    pos_parts = [_safe_arg_preview(a) for a in args]
    kw_parts = ["$(k) = $(_safe_arg_preview(v))" for (k, v) in kwargs]
    args_str = isempty(kw_parts) ? join(pos_parts, ", ") :
        isempty(pos_parts) ? join(kw_parts, "; ") :
        join(pos_parts, ", ") * "; " * join(kw_parts, ", ")
    return _truncate_chars("$(sym)($args_str)", 300)
end

"""
    run_procedure(name, args...; kwargs...)

Execute a saved procedure from `procedures/` with timing and memory profiling,
updating its metrics and error details in the jEMach TUI.
"""
function _format_raw_args_str(args, kwargs; max_len::Int = 200)::String
    (isempty(args) && isempty(kwargs)) && return ""
    return try
        pos = [Base.invokelatest(repr, a) for a in args]
        kw = ["$(k) = $(Base.invokelatest(repr, v))" for (k, v) in kwargs]
        joined = isempty(kw) ? join(pos, ", ") :
            isempty(pos) ? join(kw, "; ") :
            join(pos, ", ") * "; " * join(kw, ", ")
        length(joined) <= max_len ? joined : ""
    catch
        ""
    end
end

function run_procedure(name::Union{Symbol, AbstractString}, args...; kwargs...)
    sym = Symbol(name)
    _load_procedures!()

    proj_dir = _get_project_dir()
    existing_p = get(_procedures, sym, nothing)
    proc_file = if !isnothing(existing_p) && !isempty(existing_p.file)
        joinpath(proj_dir, existing_p.file)
    else
        joinpath(proj_dir, "procedures", string(sym) * ".jl")
    end

    if !isfile(proc_file) && (isnothing(existing_p) || existing_p.origin != :live) && isdir(joinpath(proj_dir, "procedures"))
        for (root, _, files) in walkdir(joinpath(proj_dir, "procedures"))
            if string(sym) * ".jl" in files
                proc_file = joinpath(root, string(sym) * ".jl")
                break
            end
        end
    end

    call_str = _safe_call_str(sym, args, kwargs)
    now_str = Dates.format(Dates.now(), "HH:MM:SS")

    is_modified_or_live = !isnothing(existing_p) && (existing_p.origin == :modified || existing_p.origin == :live)
    loaded_mt = isfile(proc_file) ? get(_loaded_proc_mtimes, proc_file, -1.0) : -1.0
    disk_mt = isfile(proc_file) ? (try mtime(proc_file) catch; 0.0 end) : -1.0
    should_include = isfile(proc_file) && !is_modified_or_live && (
        isnothing(existing_p) ||
        existing_p.origin == :unloaded ||
        !Base.invokelatest(isdefined, Main, sym) ||
        loaded_mt != disk_mt
    )

    if should_include
        try
            Base.include(Main, proc_file)
            _loaded_proc_mtimes[proc_file] = disk_mt
            if !isnothing(existing_p)
                scan = _scan_proc_source(existing_p.disk_code)
                existing_p.live_code = existing_p.disk_code
                existing_p.code = existing_p.disk_code
                existing_p.edit_code = isempty(scan.edit_code) ? existing_p.disk_code : scan.edit_code
                existing_p.live_hash = existing_p.disk_hash
                existing_p.func_start_line = scan.func_line
                existing_p.origin = :disk
                existing_p.generation = 1
                _proc_registry_epoch[] += 1
            end
        catch e
            bt = catch_backtrace()
            code_str = !isnothing(existing_p) ? existing_p.code : (try read(proc_file, String) catch; "" end)
            summary, detail, err_line, err_stmt = _format_error_pair(e, bt; target_file = proc_file, source_code = code_str)
            if !isnothing(existing_p)
                existing_p.origin = :unloaded
                existing_p.last_run_status = :error
                existing_p.last_run_at = now_str
                existing_p.last_run_cmd = call_str
                existing_p.last_error = summary
                existing_p.last_error_detail = detail
                existing_p.last_error_line = err_line
                existing_p.last_error_cmd = err_stmt
            end
            publish_state()
            @warn "Failed to reload $proc_file" exception = e
            throw(e)
        end
    end

    if !Base.invokelatest(isdefined, Main, sym)
        err = ErrorException("Procedure '$sym' not found in Main or procedures/$sym.jl")
        _record_command_outcome!(call_str, false, err, nothing; source = "procedure")
        publish_state()
        throw(err)
    end
    func = Base.invokelatest(getfield, Main, sym)

    println("▶ Running procedure '$sym'...")
    err_ref = Ref{Any}(nothing)
    bt_ref = Ref{Any}(nothing)
    t_res = @timed try
        Base.invokelatest(func, args...; kwargs...)
    catch e
        err_ref[] = e
        bt_ref[] = catch_backtrace()
        nothing
    end

    val = t_res.value
    is_err = !isnothing(err_ref[])
    status_sym = is_err ? :error : :ok
    time_ms = round(t_res.time * 1000, digits = 2)
    alloc_bytes = t_res.bytes
    now_str = Dates.format(Dates.now(), "HH:MM:SS")

    if !haskey(_procedures, sym)
        rel_f = isfile(proc_file) ? relpath(proc_file, proj_dir) : ""
        code_f = isfile(proc_file) ? (try read(proc_file, String) catch; "" end) : ""
        if !isempty(code_f)
            scan = _scan_proc_source(code_f)
            _procedures[sym] = ProcedureInfo(
                sym, string(sym) * "()", rel_f,
                "", code_f, time_ms, alloc_bytes, status_sym, now_str;
                origin = :disk,
                disk_code = code_f,
                live_code = code_f,
                edit_code = isempty(scan.edit_code) ? code_f : scan.edit_code,
                imports_block = scan.imports_block,
                disk_hash = scan.content_hash,
                live_hash = scan.content_hash,
                func_start_line = scan.func_line,
            )
            _proc_registry_epoch[] += 1
        else
            _ensure_live_proc_for_symbol(sym)
        end
    end

    p = _procedures[sym]
    p.last_run_time_ms = time_ms
    p.last_run_alloc_bytes = alloc_bytes
    p.last_run_status = status_sym
    p.last_run_at = now_str
    p.last_run_cmd = call_str
    raw_args = _format_raw_args_str(args, kwargs)
    if !isempty(args) || !isempty(kwargs) || !is_err
        p.last_args_str = raw_args
    end
    _remember_cmd_outcome!(call_str, status_sym)

    if is_err
        err_target = (p.origin in (:modified, :live) || !isfile(proc_file)) ? "" : proc_file
        summary, detail, err_line, err_stmt = _format_error_pair(
            err_ref[], bt_ref[];
            target_file = err_target,
            source_code = p.code
        )
        if err_ref[] isa MethodError && isempty(args) && isempty(kwargs)
            hint = "Hint: expected signature `$(p.signature)` — run `$(sym)(args...)` or `run $(sym)(args...)`"
            detail = isempty(detail) ? hint : (detail * "\n\n" * hint)
            println("\e[33m  " * hint * "\e[0m")
        end
        p.last_error = summary
        p.last_error_detail = detail
        p.last_error_line = err_line
        p.last_error_cmd = err_stmt
        publish_state()
        println("\e[31m\e[1m✗ Procedure '$sym' failed in $(time_ms)ms: $(summary)\e[0m")
        throw(err_ref[])
    end

    p.last_error = ""
    p.last_error_detail = ""
    p.last_error_line = 0
    p.last_error_cmd = ""
    publish_state()
    println("\e[32m\e[1m✓ Procedure '$sym' completed in $(time_ms)ms ($(Base.format_bytes(alloc_bytes)) allocated)\e[0m")
    return val
end

"""
    search_procedures(query::AbstractString = "") -> Vector{ProcedureInfo}

Search and return discovered procedures matching `query` by name, signature, docstring, source code, or error details.
"""
function search_procedures(query::AbstractString = "")::Vector{ProcedureInfo}
    _load_procedures!()
    q = lowercase(strip(query))
    procs = sort(collect(values(_procedures)), by = p -> string(p.name))
    isempty(q) && return procs
    return filter(procs) do p
        occursin(q, lowercase(string(p.name))) ||
            occursin(q, lowercase(p.signature)) ||
            occursin(q, lowercase(p.doc)) ||
            occursin(q, lowercase(p.file)) ||
            occursin(q, lowercase(p.code)) ||
            occursin(q, lowercase(p.last_error)) ||
            occursin(q, lowercase(p.last_run_cmd))
    end
end

const find_procedures = search_procedures

"""
    list_procedures(query::AbstractString = "")

Print a formatted table of available procedures (optionally filtered by `query`) with their
signatures, docstrings, error summaries, and latest benchmark metrics.
"""
function list_procedures(query::AbstractString = "")
    procs = search_procedures(query)
    bold, cyan, green, yellow, red, dim, reset = "\e[1m", "\e[36m", "\e[32m", "\e[33m", "\e[31m", "\e[2m", "\e[0m"

    if isempty(_procedures) && isempty(_failed_commands)
        println("$(dim)No procedures defined. Create one with $(cyan)jEMach.make_procedure(:name, last=5)$(reset)")
        return nothing
    elseif isempty(procs) && (!isempty(query) || isempty(_failed_commands))
        println("$(yellow)No procedures found matching \"$query\"$(reset) ($(length(_procedures)) total defined).")
        return nothing
    end

    if !isempty(procs)
        header = isempty(query) ? "Available Procedures ($(length(procs))):" : "Matching Procedures for \"$query\" ($(length(procs))/$(length(_procedures))):"
        println(bold * cyan * "┌─ " * header * " " * ("─"^max(0, 48 - length(header))) * reset)
        for p in procs
            status_icon = p.last_run_status == :ok ? (green * "✓" * reset) :
                p.last_run_status == :error ? (red * "✗" * reset) : (dim * "○" * reset)
            origin_tag = if p.origin == :modified
                " " * yellow * bold * "[⚡v$(p.generation)]" * reset
            elseif p.origin == :live
                " " * cyan * bold * "[◆LIVE]" * reset
            elseif p.origin == :unloaded
                " " * dim * "[○DISK]" * reset
            else
                " " * green * "[●]" * reset
            end
            time_str = p.last_run_status != :never ? " $(yellow)($(p.last_run_time_ms)ms, $(Base.format_bytes(p.last_run_alloc_bytes)))$(reset)" : ""
            println("│ $status_icon " * cyan * bold * string(p.name) * reset * origin_tag * " → " * p.signature * time_str)
            if p.last_run_status == :error && !isempty(p.last_error)
                loc = p.last_error_line > 0 ? " [L$(p.last_error_line)]" : ""
                println("│   " * red * "✗ Error$(loc): " * p.last_error * reset)
            end
            !isempty(p.doc) && println("│   $(dim)\"$(split(p.doc, '\n')[1])\"$(reset)")
            !isempty(p.file) && println("│   $(dim)File: $(p.file)$(reset)")
        end
        println(bold * cyan * "└" * ("─"^52) * reset)
    end

    if !isempty(_failed_commands) && isempty(query)
        println(bold * red * "┌─ Recent Failed Commands ($(length(_failed_commands))) " * ("─"^26) * reset)
        for fc in _failed_commands
            first_line = _truncate_chars(replace(fc.cmd, '\n' => " ⏎ "), 64)
            println("│ " * red * "✗" * reset * " " * bold * first_line * reset * " " * dim * "($(fc.timestamp))" * reset)
            println("│   " * red * fc.error_msg * reset)
        end
        println(bold * red * "└" * ("─"^52) * reset)
    end
    return nothing
end

