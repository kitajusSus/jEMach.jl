const _PROCEDURE_SOURCE_DIR = normpath(@__DIR__)
const _IPC_SOURCE_DIR = normpath(joinpath(@__DIR__, "..", "ipc"))
const _REPL_MODE_FILE = normpath(joinpath(@__DIR__, "..", "repl_mode.jl"))

_strip_ansi_codes(s::AbstractString)::String = replace(String(s), r"\e\[[0-9;?]*[a-zA-Z]" => "")

function _truncate_chars(s::AbstractString, max_chars::Int)::String
    str = String(s)
    length(str) <= max_chars && return str
    max_chars <= 1 && return "…"
    return first(str, max_chars - 1) * "…"
end

function _scrub_jemach_frames(st::Vector{Base.StackTraces.StackFrame})::Vector{Base.StackTraces.StackFrame}
    cut = nothing
    for (i, fr) in enumerate(st)
        f = normpath(String(fr.file))
        if dirname(f) == _PROCEDURE_SOURCE_DIR || dirname(f) == _IPC_SOURCE_DIR || f == _REPL_MODE_FILE
            cut = i
            break
        end
    end
    trimmed = isnothing(cut) ? copy(st) : st[1:(cut - 1)]
    while !isempty(trimmed)
        fn = String(trimmed[end].func)
        f = String(trimmed[end].file)
        if fn in ("invokelatest", "#invokelatest#1", "#invokelatest#2", "eval") &&
                (occursin("essentials.jl", f) || occursin("boot.jl", f))
            pop!(trimmed)
        else
            break
        end
    end
    return trimmed
end

function _match_source_file(frame_file::AbstractString, target_file::AbstractString)::Bool
    isempty(target_file) && return false
    sf = String(frame_file)
    tf = String(target_file)
    sf == tf && return true
    if isabspath(sf) && isabspath(tf)
        return normpath(sf) == normpath(tf)
    end
    return normpath(sf) == normpath(tf) || endswith(normpath(sf), "/" * normpath(tf)) || basename(sf) == basename(tf)
end

function _line_at(source_code::AbstractString, line_no::Int)::String
    (line_no <= 0 || isempty(source_code)) && return ""
    lines = split(rstrip(source_code, '\n'), '\n')
    1 <= line_no <= length(lines) && return String(strip(lines[line_no]))
    return ""
end

function _extract_error_line(e, st::Vector{Base.StackTraces.StackFrame}, target_file::AbstractString, source_code::AbstractString)::Int
    if e isa LoadError && e.line > 0
        if isempty(target_file) || _match_source_file(e.file, target_file)
            return Int(e.line)
        end
    end
    if e isa Base.Meta.ParseError
        msg = sprint(io -> Base.invokelatest(Base.showerror, IOContext(io, :color => false), e))
        m = match(r"Error @ [^:\n]+:(\d+):\d+", msg)
        if !isnothing(m)
            ln = something(tryparse(Int, m.captures[1]), 0)
            ln > 0 && return ln
        end
    end
    for fr in st
        fr.line <= 0 && continue
        if !isempty(target_file)
            if _match_source_file(String(fr.file), target_file)
                return Int(fr.line)
            end
        else
            sf = String(fr.file)
            if startswith(sf, "REPL[") || startswith(sf, "jEMach:")
                return Int(fr.line)
            end
        end
    end
    return 0
end

function _format_error_pair(e, bt; target_file::AbstractString = "", source_code::AbstractString = "")::Tuple{String, String, Int, String}
    raw_summary = try
        sprint(io -> Base.invokelatest(Base.showerror, IOContext(io, :color => false, :limit => true), e))
    catch
        string(typeof(e))
    end
    clean_summary_lines = split(_strip_ansi_codes(raw_summary), '\n')
    first_nonempty = ""
    for l in clean_summary_lines
        sl = strip(l)
        if !isempty(sl)
            first_nonempty = String(sl)
            break
        end
    end
    if e isa Base.Meta.ParseError
        for l in clean_summary_lines
            sl = strip(l)
            if occursin("──", sl)
                first_nonempty = "ParseError: " * String(sl)
                break
            end
        end
    end
    summary = _truncate_chars(isempty(first_nonempty) ? string(typeof(e)) : first_nonempty, 220)

    st = try
        raw_bt = isnothing(bt) ? Base.StackTraces.StackFrame[] : stacktrace(bt)
        _scrub_jemach_frames(raw_bt)
    catch
        Base.StackTraces.StackFrame[]
    end

    detail = try
        if isempty(st)
            _strip_ansi_codes(raw_summary)
        else
            _strip_ansi_codes(sprint(io -> Base.invokelatest(Base.showerror, IOContext(io, :color => false, :limit => true), e, st)))
        end
    catch
        summary
    end
    detail = _truncate_chars(rstrip(detail), 3800)

    err_line = _extract_error_line(e, st, target_file, source_code)
    err_stmt = _line_at(source_code, err_line)
    return (summary, detail, err_line, err_stmt)
end

function _format_exception_stack(stack; target_file::AbstractString = "", source_code::AbstractString = "")::Tuple{String, String, Int, String}
    if isempty(stack)
        return ("Error during evaluation", "", 0, "")
    end
    top = stack[1]
    return _format_error_pair(top.exception, top.backtrace; target_file = target_file, source_code = source_code)
end

function _extract_parse_or_lower_error(cmd::AbstractString)::Tuple{String, String, Int, String}
    ex = Base.parse_input_line(cmd; filename = "REPL")
    if ex isa Expr
        err_node = if ex.head == :error
            ex
        elseif ex.head == :toplevel
            idx = findfirst(a -> a isa Expr && a.head == :error, ex.args)
            isnothing(idx) ? nothing : ex.args[idx]
        else
            nothing
        end
        if !isnothing(err_node) && !isempty(err_node.args)
            return _format_error_pair(err_node.args[1], nothing; source_code = cmd)
        end
        lowered = try
            Meta.lower(Main, ex)
        catch le
            return _format_error_pair(le, catch_backtrace(); source_code = cmd)
        end
        if lowered isa Expr && lowered.head == :error && !isempty(lowered.args)
            return ("LoweringError: " * string(lowered.args[1]), string(lowered.args[1]), 1, _line_at(cmd, 1))
        end
    end
    return ("REPL evaluation error (trivial top-level error — see REPL output)", "Evaluation failed in REPL for:\n" * _truncate_chars(cmd, 500), 1, _line_at(cmd, 1))
end

function _remember_cmd_outcome!(cmd::AbstractString, status::Symbol)
    key = String(strip(cmd))
    isempty(key) && return
    if !haskey(_cmd_outcomes, key)
        push!(_cmd_outcome_order, key)
        while length(_cmd_outcome_order) > _MAX_CMD_OUTCOMES
            old = popfirst!(_cmd_outcome_order)
            delete!(_cmd_outcomes, old)
        end
    end
    _cmd_outcomes[key] = status
    return nothing
end

function _find_proc_from_call(cmd::AbstractString, err = nothing, bt = nothing; is_stack::Bool = false)::Union{ProcedureInfo, Nothing}
    proj_dir = _get_project_dir()
    if !isnothing(err)
        st = try
            if is_stack && !isempty(err)
                stacktrace(err[1].backtrace)
            elseif !isnothing(bt)
                stacktrace(bt)
            else
                Base.StackTraces.StackFrame[]
            end
        catch
            Base.StackTraces.StackFrame[]
        end
        for fr in st
            sf = String(fr.file)
            for p in values(_procedures)
                isempty(p.file) && continue
                full_p = joinpath(proj_dir, p.file)
                if _match_source_file(sf, full_p) || _match_source_file(sf, p.file)
                    return p
                end
            end
        end
    end

    ex = try
        Meta.parseall(strip(cmd))
    catch
        nothing
    end
    if ex isa Expr && ex.head == :toplevel
        stmts = filter(a -> !(a isa LineNumberNode), ex.args)
        if length(stmts) == 1 && stmts[1] isa Expr && stmts[1].head == :call
            call_ex = stmts[1]
            callee = call_ex.args[1]
            if callee isa Symbol && haskey(_procedures, callee)
                return _procedures[callee]
            elseif (callee == GlobalRef(jEMach, :run_procedure) ||
                    (callee isa Expr && callee.head == :. && length(callee.args) == 2 &&
                     callee.args[1] == :jEMach && callee.args[2] == QuoteNode(:run_procedure)) ||
                    callee == :run_procedure) && length(call_ex.args) >= 2
                arg1 = call_ex.args[2]
                pname = arg1 isa QuoteNode ? arg1.value : (arg1 isa AbstractString ? Symbol(arg1) : nothing)
                pname isa Symbol && haskey(_procedures, pname) && return _procedures[pname]
            end
        end
    end
    return nothing
end

function _extract_call_args_str(cmd::AbstractString, sym::Symbol)::String
    s = String(strip(rstrip(String(cmd), ';')))
    isempty(s) && return ""
    name_str = string(sym)
    idx = firstindex(s)
    n_end = lastindex(s)
    open_paren = 0

    while idx <= n_end
        rng = findnext(name_str, s, idx)
        isnothing(rng) && break
        before_ok = (first(rng) == firstindex(s)) || begin
            pc = s[prevind(s, first(rng))]
            !(isletter(pc) || isdigit(pc) || pc == '_' || pc == '!')
        end
        if before_ok
            after = nextind(s, last(rng))
            while after <= n_end && (s[after] == ' ' || s[after] == '\t')
                after = nextind(s, after)
            end
            if after <= n_end && s[after] == '('
                open_paren = after
                break
            end
        end
        idx = nextind(s, first(rng))
    end

    open_paren == 0 && return ""
    i = nextind(s, open_paren)
    depth = 1
    in_dq = false
    in_sq = false
    escaped = false
    close_paren = 0

    while i <= n_end
        c = s[i]
        if escaped
            escaped = false
        elseif (in_dq || in_sq) && c == '\\'
            escaped = true
        elseif in_dq
            c == '"' && (in_dq = false)
        elseif in_sq
            c == '\'' && (in_sq = false)
        elseif c == '"'
            in_dq = true
        elseif c == '\''
            in_sq = true
        elseif c == '(' || c == '[' || c == '{'
            depth += 1
        elseif c == ')' || c == ']' || c == '}'
            depth -= 1
            if depth == 0 && c == ')'
                close_paren = i
                break
            end
        end
        i = nextind(s, i)
    end

    close_paren == 0 && return ""
    inner_start = nextind(s, open_paren)
    inner_end = prevind(s, close_paren)
    inner_start > inner_end && return ""
    return String(strip(SubString(s, inner_start, inner_end)))
end

function _record_command_outcome!(
        cmd::AbstractString,
        ok::Bool,
        err = nothing,
        bt = nothing;
        source::String = "repl",
        is_stack::Bool = false
    )
    clean_cmd = String(strip(cmd))
    isempty(clean_cmd) && return nothing
    _remember_cmd_outcome!(clean_cmd, ok ? :ok : :error)

    matched_proc = _find_proc_from_call(clean_cmd, ok ? nothing : err, ok ? nothing : bt; is_stack = is_stack)
    now_str = Dates.format(Dates.now(), "HH:MM:SS")

    if !isnothing(matched_proc)
        matched_proc.last_run_at = now_str
        matched_proc.last_run_cmd = _truncate_chars(clean_cmd, 300)
        args_s = _extract_call_args_str(clean_cmd, matched_proc.name)
        if !isempty(args_s) || !(err isa MethodError)
            matched_proc.last_args_str = _truncate_chars(args_s, 200)
        end
        if ok
            matched_proc.last_run_status = :ok
            matched_proc.last_error = ""
            matched_proc.last_error_detail = ""
            matched_proc.last_error_line = 0
            matched_proc.last_error_cmd = ""
        else
            full_p = (matched_proc.origin in (:modified, :live) || isempty(matched_proc.file)) ? "" : joinpath(_get_project_dir(), matched_proc.file)
            summary, detail, err_line, err_stmt = if is_stack && !isnothing(err)
                _format_exception_stack(err; target_file = full_p, source_code = matched_proc.code)
            elseif !isnothing(err)
                _format_error_pair(err, bt; target_file = full_p, source_code = matched_proc.code)
            else
                _extract_parse_or_lower_error(clean_cmd)
            end
            matched_proc.last_run_status = :error
            matched_proc.last_error = summary
            matched_proc.last_error_detail = detail
            matched_proc.last_error_line = err_line
            matched_proc.last_error_cmd = err_stmt
        end
        return nothing
    end

    if ok
        filter!(fc -> fc.cmd != clean_cmd, _failed_commands)
        return nothing
    end

    summary, detail, err_line, err_stmt = if is_stack && !isnothing(err)
        _format_exception_stack(err; source_code = clean_cmd)
    elseif !isnothing(err)
        _format_error_pair(err, bt; source_code = clean_cmd)
    else
        _extract_parse_or_lower_error(clean_cmd)
    end

    filter!(fc -> fc.cmd != clean_cmd, _failed_commands)
    _failed_cmd_seq[] += 1
    entry = FailedCommandInfo(
        _failed_cmd_seq[],
        _truncate_chars(clean_cmd, 4000),
        source,
        "",
        summary,
        detail,
        err_line,
        err_stmt,
        now_str,
    )
    pushfirst!(_failed_commands, entry)
    while length(_failed_commands) > _MAX_FAILED_COMMANDS
        pop!(_failed_commands)
    end
    return entry
end

function _dismiss_failed_command!(id::Int)
    filter!(fc -> fc.id != id, _failed_commands)
    publish_state()
    return nothing
end

function _clear_failed_commands!()
    empty!(_failed_commands)
    publish_state()
    return nothing
end

