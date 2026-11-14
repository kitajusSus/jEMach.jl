# Procedure metadata, discovery, AST parameterization, recording, execution & error tracking.

mutable struct ProcedureInfo
    name::Symbol
    signature::String
    file::String
    doc::String
    code::String
    last_run_time_ms::Float64
    last_run_alloc_bytes::Int
    last_run_status::Symbol # :ok, :error, :never
    last_run_at::String
    last_run_cmd::String
    last_error::String
    last_error_detail::String
    last_error_line::Int
    last_error_cmd::String
    origin::Symbol # :disk, :modified, :live, :unloaded
    disk_code::String
    live_code::String
    edit_code::String
    imports_block::String
    disk_hash::UInt64
    live_hash::UInt64
    generation::Int
    last_args_str::String
    func_start_line::Int
end

function ProcedureInfo(
        name::Symbol,
        signature::AbstractString,
        file::AbstractString,
        doc::AbstractString,
        code::AbstractString,
        last_run_time_ms::Real,
        last_run_alloc_bytes::Integer,
        last_run_status::Symbol,
        last_run_at::AbstractString;
        origin::Symbol = isempty(file) ? :live : :disk,
        disk_code::AbstractString = isempty(file) ? "" : code,
        live_code::AbstractString = code,
        edit_code::AbstractString = code,
        imports_block::AbstractString = "",
        disk_hash::UInt64 = UInt64(0),
        live_hash::UInt64 = UInt64(0),
        generation::Int = 1,
        last_args_str::AbstractString = "",
        func_start_line::Int = 1,
    )
    return ProcedureInfo(
        name, String(signature), String(file), String(doc), String(code),
        Float64(last_run_time_ms), Int(last_run_alloc_bytes), last_run_status, String(last_run_at),
        "", "", "", 0, "",
        origin, String(disk_code), String(live_code), String(edit_code), String(imports_block),
        disk_hash, live_hash, generation, String(last_args_str), func_start_line
    )
end

struct FailedCommandInfo
    id::Int
    cmd::String
    source::String
    proc_name::String
    error_msg::String
    error_detail::String
    error_line::Int
    failed_stmt::String
    timestamp::String
end

function Base.show(io::IO, p::ProcedureInfo)
    print(io, "ProcedureInfo(:$(p.name), \"$(p.signature)\", origin=:$(p.origin), status=:$(p.last_run_status))")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", p::ProcedureInfo)
    use_color = get(io, :color, true)
    bold = use_color ? "\e[1m" : ""
    cyan = use_color ? "\e[36m" : ""
    green = use_color ? "\e[32m" : ""
    yellow = use_color ? "\e[33m" : ""
    red = use_color ? "\e[31m" : ""
    dim = use_color ? "\e[2m" : ""
    reset = use_color ? "\e[0m" : ""

    origin_badge = if p.origin == :modified
        yellow * bold * "⚡ MODIFIED (v$(p.generation))" * reset
    elseif p.origin == :live
        cyan * bold * "◆ LIVE (in memory)" * reset
    elseif p.origin == :unloaded
        dim * "○ UNLOADED" * reset
    else
        green * "● DISK" * reset
    end

    status_badge = p.last_run_status == :ok ? (green * "✓ OK" * reset) :
        p.last_run_status == :error ? (red * "✗ ERROR" * reset) : (dim * "○ NEVER RUN" * reset)
    metrics_str = p.last_run_status != :never ?
        "$(p.last_run_time_ms) ms, $(Base.format_bytes(p.last_run_alloc_bytes)) (at $(p.last_run_at))" :
        "-"
    file_disp = isempty(p.file) ? "(memory only)" : p.file

    println(io, bold * cyan * "╭─ Procedure: " * string(p.name) * " " * ("─"^max(1, 50 - length(string(p.name)))) * "╮" * reset)
    println(io, "│ " * bold * "Signature: " * reset * cyan * p.signature * reset * "  " * origin_badge)
    println(io, "│ " * bold * "File:      " * reset * file_disp)
    println(io, "│ " * bold * "Status:    " * reset * status_badge * "  " * yellow * metrics_str * reset)
    !isempty(p.last_run_cmd) && println(io, "│ " * bold * "Last Call: " * reset * cyan * p.last_run_cmd * reset)
    if p.last_run_status == :error && !isempty(p.last_error)
        println(io, "│ " * bold * red * "Error:     " * reset * red * p.last_error * reset)
        if p.last_error_line > 0 && !isempty(p.last_error_cmd)
            println(io, "│ " * bold * red * "At Line $(p.last_error_line): " * reset * p.last_error_cmd)
        end
    end
    !isempty(p.doc) && println(io, "│ " * bold * "Doc:       " * reset * dim * replace(p.doc, '\n' => " ") * reset)
    if !isempty(strip(p.code))
        println(io, cyan * "├─ Source " * ("─"^58) * "┤" * reset)
        for (li, line) in enumerate(split(rstrip(p.code), '\n'))
            is_err_line = p.last_run_status == :error && p.last_error_line == li
            if is_err_line
                println(io, "│ " * red * bold * "✗" * lpad(string(li), 2) * " │ " * line * reset)
            else
                println(io, "│ " * dim * lpad(string(li), 3) * " │ " * reset * line)
            end
        end
    end
    if p.last_run_status == :error && !isempty(strip(p.last_error_detail))
        println(io, red * "├─ Error Detail " * ("─"^52) * "┤" * reset)
        for line in split(rstrip(p.last_error_detail), '\n')
            println(io, "│ " * red * line * reset)
        end
    end
    print(io, bold * cyan * "╰" * ("─"^67) * "╯" * reset)
    return nothing
end

const _procedures = Dict{Symbol, ProcedureInfo}()
const _proc_registry_epoch = Ref{UInt64}(1)
const _parsed_proc_mtimes = Dict{String, Float64}()
const _parsed_proc_names = Dict{String, Symbol}()
const _loaded_proc_mtimes = Dict{String, Float64}()
const _failed_commands = FailedCommandInfo[]
const _failed_cmd_seq = Ref{Int}(0)
const _cmd_outcomes = Dict{String, Symbol}()
const _cmd_outcome_order = String[]
const _MAX_FAILED_COMMANDS = 30
const _MAX_CMD_OUTCOMES = 200
const _recording = Ref{Bool}(false)
const _record_name = Ref{Symbol}(:proc)
const _record_start_pos = Ref{Int64}(0)
const _record_hist_idx = Ref{Int}(0)
const _orig_julia_prompt = Ref{Any}(nothing)
const _orig_julia_prefix = Ref{Any}(nothing)

const _PROCEDURES_FILE = normpath(@__FILE__)
const _IPC_FILE = normpath(joinpath(@__DIR__, "ipc.jl"))
const _REPL_MODE_FILE = normpath(joinpath(@__DIR__, "repl_mode.jl"))

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
        if f == _PROCEDURES_FILE || f == _IPC_FILE || f == _REPL_MODE_FILE
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

function _extract_sig_and_name(fexpr::Expr, default_name::Symbol; allow_qualified::Bool = true)::Tuple{String, Symbol}
    while fexpr.head == :macrocall && length(fexpr.args) >= 3 && fexpr.args[end] isa Expr
        fexpr = fexpr.args[end]
    end
    sig = ""
    fname = default_name
    head_lhs = if fexpr.head == :function && !isempty(fexpr.args)
        fexpr.args[1]
    elseif fexpr.head == :(=) && length(fexpr.args) >= 2 && _is_func_sig_lhs(fexpr.args[1]) && !(fexpr.args[1] isa Expr && fexpr.args[1].head == :tuple)
        fexpr.args[1]
    else
        nothing
    end
    if !isnothing(head_lhs)
        sig = string(head_lhs)
        call_lhs = head_lhs
        while call_lhs isa Expr && call_lhs.head in (:where, :(::)) && !isempty(call_lhs.args)
            call_lhs = call_lhs.args[1]
        end
        if call_lhs isa Expr && call_lhs.head == :call && !isempty(call_lhs.args)
            callee = call_lhs.args[1]
            if callee isa Symbol
                fname = callee
            elseif allow_qualified && callee isa Expr && callee.head == :. && length(callee.args) == 2 &&
                    callee.args[2] isa QuoteNode && callee.args[2].value isa Symbol
                fname = callee.args[2].value
            end
        end
    end
    return (sig, fname)
end

function _fnv1a64_normalized_lines(s::AbstractString)::UInt64
    h = UInt64(0xcbf29ce484222325)
    prime = UInt64(0x100000001b3)
    lines = split(s, '\n')
    for (idx, raw_line) in enumerate(lines)
        clean = rstrip(raw_line, (' ', '\t', '\r'))
        for b in codeunits(clean)
            h ⊻= UInt64(b)
            h *= prime
        end
        if idx < length(lines)
            h ⊻= UInt64(0x0a)
            h *= prime
        end
    end
    return h
end

function _extract_imports_from_prefix(prefix::AbstractString)::String
    isempty(prefix) && return ""
    imps = String[]
    for raw_line in split(prefix, '\n')
        t = strip(rstrip(raw_line, '\r'))
        if startswith(t, "using ") || startswith(t, "using\t") || startswith(t, "import ") || startswith(t, "import\t")
            push!(imps, String(t))
        end
    end
    return join(imps, "\n")
end

function _scan_proc_source_julia(s::String)
    cu = codeunits(s)
    n = length(cu)
    i = 1
    line_no = 1
    in_doc = false
    found_body = false
    body_start = 0
    func_line = 1
    has_doc = false
    has_imports = false

    while i <= n
        nl = findnext(==(UInt8('\n')), cu, i)
        line_end = isnothing(nl) ? n : (nl - 1)
        raw_end = (line_end >= i && cu[line_end] == UInt8('\r')) ? (line_end - 1) : line_end
        line_str = raw_end >= i ? String(cu[i:raw_end]) : ""
        trimmed = strip(line_str)

        if in_doc
            occursin("\"\"\"", trimmed) && (in_doc = false)
        elseif isempty(trimmed)
            # skip blank lines before function
        elseif startswith(trimmed, "# Generated by jEMach")
            # skip auto-generated banner
        elseif startswith(trimmed, "using ") || startswith(trimmed, "using\t") ||
                startswith(trimmed, "import ") || startswith(trimmed, "import\t")
            has_imports = true
        elseif startswith(trimmed, "\"\"\"")
            has_doc = true
            rest = length(trimmed) >= 6 ? SubString(trimmed, nextind(trimmed, 1, 3)) : ""
            !occursin("\"\"\"", rest) && (in_doc = true)
        else
            found_body = true
            body_start = i - 1
            func_line = line_no
            break
        end

        isnothing(nl) && break
        i = nl + 1
        line_no += 1
    end

    if !found_body
        body_start = 0
        func_line = 1
        body_end = n
        while body_end > 0 && cu[body_end] in (UInt8(' '), UInt8('\t'), UInt8('\r'), UInt8('\n'))
            body_end -= 1
        end
    else
        body_end = n
        while body_end > body_start && cu[body_end] in (UInt8(' '), UInt8('\t'), UInt8('\r'), UInt8('\n'))
            body_end -= 1
        end
    end

    edit_code = body_end > body_start ? String(cu[(body_start + 1):body_end]) : ""
    prefix = body_start > 0 ? String(cu[1:body_start]) : ""
    return (
        content_hash = _fnv1a64_normalized_lines(edit_code),
        edit_code = edit_code,
        imports_block = _extract_imports_from_prefix(prefix),
        func_line = func_line,
        has_doc = has_doc,
        has_imports = has_imports,
    )
end

function _scan_proc_source(src::AbstractString)
    s = String(src)
    fn = _zig_proc_scan_ptr[]
    if fn != C_NULL
        res_ref = Ref(_ZigProcScanResult(0, 0, 0, 1, 0, 0))
        rc = GC.@preserve s res_ref ccall(
            fn, Int32,
            (Ptr{UInt8}, Csize_t, Ptr{_ZigProcScanResult}),
            pointer(s), ncodeunits(s), res_ref
        )
        if rc == 0
            r = res_ref[]
            cu = codeunits(s)
            bs = Int(r.body_start)
            be = Int(r.body_end)
            edit_code = (be > bs && be <= length(cu)) ? String(cu[(bs + 1):be]) : ""
            prefix = bs > 0 && bs <= length(cu) ? String(cu[1:bs]) : ""
            return (
                content_hash = r.content_hash,
                edit_code = edit_code,
                imports_block = _extract_imports_from_prefix(prefix),
                func_line = Int(r.func_line),
                has_doc = r.has_doc != 0,
                has_imports = r.has_imports != 0,
            )
        end
    end
    return _scan_proc_source_julia(s)
end

function _load_procedures!(; eval_in_main::Bool = false, force::Bool = false)
    proj_dir = _get_project_dir()
    proc_dir = joinpath(proj_dir, "procedures")
    found_names = Set{Symbol}()
    seen_files = Set{String}()

    if isdir(proc_dir)
        for (root, _, files) in walkdir(proc_dir)
            for file in files
                !endswith(file, ".jl") && continue
                filepath = joinpath(root, file)
                push!(seen_files, filepath)
                file_mt = try
                    mtime(filepath)
                catch
                    0.0
                end

                cached_name = get(_parsed_proc_names, filepath, nothing)
                cached_hit = !isnothing(cached_name) &&
                    get(_parsed_proc_mtimes, filepath, -1.0) == file_mt &&
                    haskey(_procedures, cached_name)

                func_name = if cached_hit
                    cached_name
                else
                    content = try
                        read(filepath, String)
                    catch
                        continue
                    end
                    rel_path = relpath(filepath, proj_dir)
                    parsed_name = Symbol(splitext(file)[1])
                    parsed = try
                        Meta.parseall(content; filename = rel_path)
                    catch e
                        Expr(:toplevel, Expr(:error, e))
                    end
                    doc_str = ""
                    sig_str = ""
                    parse_err = nothing

                    if parsed isa Expr && parsed.head in (:error, :incomplete)
                        parse_err = !isempty(parsed.args) ? parsed.args[1] : nothing
                    elseif parsed isa Expr
                        for a in parsed.args
                            !(a isa Expr) && continue
                            if a.head in (:error, :incomplete)
                                isnothing(parse_err) && (parse_err = !isempty(a.args) ? a.args[1] : nothing)
                                continue
                            elseif a.head == :macrocall && length(a.args) >= 4
                                mac_name = a.args[1]
                                is_doc_mac = (
                                    mac_name == Symbol("@doc") ||
                                        mac_name == GlobalRef(Core, Symbol("@doc")) ||
                                        (mac_name isa GlobalRef && mac_name.name == Symbol("@doc"))
                                )
                                if is_doc_mac
                                    doc_str = string(a.args[3])
                                    if a.args[4] isa Expr
                                        s, fn = _extract_sig_and_name(a.args[4], parsed_name)
                                        !isempty(s) && (sig_str = s)
                                        parsed_name = fn
                                    end
                                end
                            elseif a.head == :function || a.head == :(=)
                                s, fn = _extract_sig_and_name(a, parsed_name)
                                !isempty(s) && (sig_str = s)
                                parsed_name = fn
                            end
                        end
                    end

                    if isempty(strip(doc_str))
                        comment_lines = String[]
                        for l in split(content, '\n')
                            sl = strip(l)
                            if startswith(sl, "#") && !occursin("Generated by jEMach", sl)
                                push!(comment_lines, strip(lstrip(sl, ['#', ' '])))
                            elseif !isempty(sl)
                                break
                            end
                        end
                        !isempty(comment_lines) && (doc_str = join(comment_lines, " "))
                    end

                    isempty(sig_str) && (sig_str = string(parsed_name) * "()")
                    scan = _scan_proc_source(content)
                    is_loaded = Base.invokelatest(isdefined, Main, parsed_name) &&
                        get(_loaded_proc_mtimes, filepath, -1.0) == file_mt

                    if !haskey(_procedures, parsed_name)
                        _procedures[parsed_name] = ProcedureInfo(
                            parsed_name, sig_str, rel_path, strip(doc_str), content,
                            0.0, 0, :never, "-";
                            origin = is_loaded ? :disk : :unloaded,
                            disk_code = content,
                            live_code = is_loaded ? content : "",
                            edit_code = isempty(scan.edit_code) ? content : scan.edit_code,
                            imports_block = scan.imports_block,
                            disk_hash = scan.content_hash,
                            live_hash = is_loaded ? scan.content_hash : UInt64(0),
                            generation = 1,
                            func_start_line = scan.func_line,
                        )
                    else
                        p = _procedures[parsed_name]
                        p.file = rel_path
                        p.disk_code = content
                        p.disk_hash = scan.content_hash
                        p.imports_block = scan.imports_block
                        if isempty(p.doc) || p.origin != :modified
                            p.doc = strip(doc_str)
                        end
                        if p.origin == :modified && !eval_in_main
                            # Preserve active in-memory edits until explicitly reloaded
                            p.origin = (p.live_hash == scan.content_hash) ? :disk : :modified
                        elseif p.origin == :live
                            p.origin = (p.live_hash == scan.content_hash) ? :disk : :modified
                        else
                            p.signature = sig_str
                            p.code = content
                            p.live_code = is_loaded ? content : p.live_code
                            p.edit_code = isempty(scan.edit_code) ? content : scan.edit_code
                            p.func_start_line = scan.func_line
                            p.origin = is_loaded ? :disk : :unloaded
                            is_loaded && (p.live_hash = scan.content_hash)
                        end
                    end
                    p_cur = _procedures[parsed_name]
                    if !isnothing(parse_err)
                        summary, detail, err_line, err_stmt = _format_error_pair(parse_err, nothing; target_file = rel_path, source_code = content)
                        p_cur.last_run_status = :error
                        p_cur.last_run_at = Dates.format(Dates.now(), "HH:MM:SS")
                        p_cur.last_run_cmd = "parse(" * rel_path * ")"
                        p_cur.last_error = summary
                        p_cur.last_error_detail = detail
                        p_cur.last_error_line = err_line
                        p_cur.last_error_cmd = err_stmt
                    elseif p_cur.last_run_status == :error && startswith(p_cur.last_run_cmd, "parse(")
                        p_cur.last_run_status = :never
                        p_cur.last_run_cmd = ""
                        p_cur.last_error = ""
                        p_cur.last_error_detail = ""
                        p_cur.last_error_line = 0
                        p_cur.last_error_cmd = ""
                    end
                    _parsed_proc_mtimes[filepath] = file_mt
                    _parsed_proc_names[filepath] = parsed_name
                    _proc_registry_epoch[] += 1
                    parsed_name
                end

                push!(found_names, func_name)

                if eval_in_main && (force || get(_loaded_proc_mtimes, filepath, -1.0) != file_mt || !Base.invokelatest(isdefined, Main, func_name))
                    p_cur = _procedures[func_name]
                    if !(p_cur.last_run_status == :error && startswith(p_cur.last_run_cmd, "parse("))
                        try
                            Base.include(Main, filepath)
                            _loaded_proc_mtimes[filepath] = file_mt
                            scan = _scan_proc_source(p_cur.disk_code)
                            p_cur.live_code = p_cur.disk_code
                            p_cur.code = p_cur.disk_code
                            p_cur.edit_code = isempty(scan.edit_code) ? p_cur.disk_code : scan.edit_code
                            p_cur.live_hash = p_cur.disk_hash
                            p_cur.func_start_line = scan.func_line
                            p_cur.origin = :disk
                            p_cur.generation = 1
                            _proc_registry_epoch[] += 1
                            if p_cur.last_run_status == :error && startswith(p_cur.last_run_cmd, "include(")
                                p_cur.last_run_status = :never
                                p_cur.last_run_cmd = ""
                                p_cur.last_error = ""
                                p_cur.last_error_detail = ""
                                p_cur.last_error_line = 0
                                p_cur.last_error_cmd = ""
                            end
                        catch e
                            bt = catch_backtrace()
                            summary, detail, err_line, err_stmt = _format_error_pair(e, bt; target_file = filepath, source_code = p_cur.code)
                            p_cur.last_run_status = :error
                            p_cur.last_run_at = Dates.format(Dates.now(), "HH:MM:SS")
                            p_cur.last_run_cmd = "include(" * p_cur.file * ")"
                            p_cur.last_error = summary
                            p_cur.last_error_detail = detail
                            p_cur.last_error_line = err_line
                            p_cur.last_error_cmd = err_stmt
                            p_cur.origin = :unloaded
                        end
                    end
                end
            end
        end
    end

    for k in collect(keys(_procedures))
        if !(k in found_names)
            p_old = _procedures[k]
            if p_old.origin == :live
                # Keep live REPL functions while defined in Main
                if !Base.invokelatest(isdefined, Main, k)
                    delete!(_procedures, k)
                    _proc_registry_epoch[] += 1
                end
            elseif p_old.origin == :modified && Base.invokelatest(isdefined, Main, k)
                p_old.origin = :live
                p_old.file = ""
                p_old.disk_code = ""
                p_old.disk_hash = UInt64(0)
                _proc_registry_epoch[] += 1
            else
                delete!(_procedures, k)
                _proc_registry_epoch[] += 1
            end
        end
    end
    for fp in collect(keys(_parsed_proc_mtimes))
        if !(fp in seen_files)
            delete!(_parsed_proc_mtimes, fp)
            delete!(_parsed_proc_names, fp)
            delete!(_loaded_proc_mtimes, fp)
        end
    end
    return _procedures
end

"""
    autoload_procedures!(; force::Bool = false) -> Dict{Symbol, ProcedureInfo}

Discover all `.jl` files in the project's `procedures/` folder and evaluate them
into `Main` so that tab-completion, direct function calls, and `?procedure_name`
docstrings work immediately in the Julia REPL. Pass `force=true` to overwrite any
in-memory `:modified` edits with the versions currently saved on disk.
"""
autoload_procedures!(; force::Bool = false) = _load_procedures!(; eval_in_main = true, force = force)

# ---------------------------------------------------------------------------
# AST scope & free-variable analyzer
# ---------------------------------------------------------------------------

function _is_global_or_type(sym::Symbol)::Bool
    for m in (Main, Base, Core)
        if Base.invokelatest(isdefined, m, sym)
            try
                v = Base.invokelatest(getfield, m, sym)
                (v isa Function || v isa DataType || v isa UnionAll || v isa Module) && return true
            catch
            end
        end
    end
    return false
end

function _bind_ast_lhs!(lhs, target_set::Set{Symbol})
    if lhs isa Symbol
        push!(target_set, lhs)
    elseif lhs isa Expr
        if lhs.head in (:tuple, :parameters)
            for a in lhs.args
                _bind_ast_lhs!(a, target_set)
            end
        elseif lhs.head in (:(::), :(=), :...) && !isempty(lhs.args)
            _bind_ast_lhs!(lhs.args[1], target_set)
        end
    end
    return target_set
end

function _collect_for_bindings!(spec, assigned::Set{Symbol}, referenced::Set{Symbol}, outer_scope::Set{Symbol}, loop_scope::Set{Symbol})
    if spec isa Expr && spec.head == :(=) && length(spec.args) >= 2
        _collect_ast_symbols!(spec.args[2], assigned, referenced, outer_scope)
        _bind_ast_lhs!(spec.args[1], loop_scope)
    elseif spec isa Expr && spec.head == :block
        for item in spec.args
            item isa LineNumberNode && continue
            _collect_for_bindings!(item, assigned, referenced, outer_scope, loop_scope)
        end
    end
    return loop_scope
end

function _is_func_sig_lhs(lhs)::Bool
    while lhs isa Expr && lhs.head in (:where, :(::)) && !isempty(lhs.args)
        lhs = lhs.args[1]
    end
    return lhs isa Expr && lhs.head in (:call, :tuple)
end

function _visit_function_def!(sig, body_args, assigned::Set{Symbol}, referenced::Set{Symbol}, local_scope::Set{Symbol})
    new_scope = copy(local_scope)
    while sig isa Expr && sig.head == :where && !isempty(sig.args)
        for i in 2:length(sig.args)
            _bind_ast_lhs!(sig.args[i], new_scope)
        end
        sig = sig.args[1]
    end
    if sig isa Symbol
        push!(assigned, sig)
    elseif sig isa Expr && sig.head == :call && !isempty(sig.args)
        sig.args[1] isa Symbol && push!(assigned, sig.args[1])
        for a in sig.args[2:end]
            if a isa Expr && a.head == :kw && length(a.args) >= 2
                _collect_ast_symbols!(a.args[2], assigned, referenced, new_scope)
            end
            _bind_ast_lhs!(a, new_scope)
        end
    elseif sig isa Expr && sig.head == :tuple
        _bind_ast_lhs!(sig, new_scope)
    end
    for a in body_args
        _collect_ast_symbols!(a, assigned, referenced, new_scope)
    end
    return nothing
end

function _collect_ast_symbols!(ex, assigned::Set{Symbol}, referenced::Set{Symbol}, local_scope::Set{Symbol} = Set{Symbol}())
    if ex isa QuoteNode || ex isa LineNumberNode
        return nothing
    elseif ex isa Symbol
        !(ex in local_scope) && !(ex in assigned) && push!(referenced, ex)
        return nothing
    elseif !(ex isa Expr)
        return nothing
    end

    h = ex.head
    if h in (:quote, :inert, :using, :import, :export, :meta)
        return nothing
    elseif h == :(=)
        lhs = ex.args[1]
        if _is_func_sig_lhs(lhs) && !(lhs isa Expr && lhs.head == :tuple)
            _visit_function_def!(lhs, ex.args[2:end], assigned, referenced, local_scope)
        else
            length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
            if lhs isa Symbol || (lhs isa Expr && lhs.head in (:tuple, :(::)))
                _bind_ast_lhs!(lhs, assigned)
            else
                _collect_ast_symbols!(lhs, assigned, referenced, local_scope)
            end
        end
    elseif h == :kw
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
    elseif h == :parameters
        for a in ex.args
            if a isa Expr && a.head == :kw
                length(a.args) >= 2 && _collect_ast_symbols!(a.args[2], assigned, referenced, local_scope)
            else
                _collect_ast_symbols!(a, assigned, referenced, local_scope)
            end
        end
    elseif h == :(->)
        new_scope = copy(local_scope)
        length(ex.args) >= 1 && _bind_ast_lhs!(ex.args[1], new_scope)
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, new_scope)
    elseif h == :function
        if !isempty(ex.args)
            _visit_function_def!(ex.args[1], ex.args[2:end], assigned, referenced, local_scope)
        end
    elseif h in (:generator, :comprehension)
        new_scope = copy(local_scope)
        if h == :comprehension && length(ex.args) == 1 && ex.args[1] isa Expr && ex.args[1].head in (:generator, :flatten)
            _collect_ast_symbols!(ex.args[1], assigned, referenced, local_scope)
        else
            for i in 2:length(ex.args)
                iter_spec = ex.args[i]
                if iter_spec isa Expr && iter_spec.head == :filter
                    for j in 2:length(iter_spec.args)
                        _collect_for_bindings!(iter_spec.args[j], assigned, referenced, local_scope, new_scope)
                    end
                    !isempty(iter_spec.args) && _collect_ast_symbols!(iter_spec.args[1], assigned, referenced, new_scope)
                else
                    _collect_for_bindings!(iter_spec, assigned, referenced, local_scope, new_scope)
                end
            end
            !isempty(ex.args) && _collect_ast_symbols!(ex.args[1], assigned, referenced, new_scope)
        end
    elseif h == :for
        new_scope = copy(local_scope)
        length(ex.args) >= 1 && _collect_for_bindings!(ex.args[1], assigned, referenced, local_scope, new_scope)
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
        end
    elseif h == :while
        new_scope = copy(local_scope)
        for a in ex.args
            _collect_ast_symbols!(a, assigned, referenced, new_scope)
        end
    elseif h == :let
        new_scope = copy(local_scope)
        if length(ex.args) >= 1
            binds = ex.args[1]
            bind_list = (binds isa Expr && binds.head == :block) ? binds.args : Any[binds]
            for b in bind_list
                b isa LineNumberNode && continue
                if b isa Expr && b.head == :(=)
                    length(b.args) >= 2 && _collect_ast_symbols!(b.args[2], assigned, referenced, new_scope)
                    _bind_ast_lhs!(b.args[1], new_scope)
                elseif b isa Symbol
                    push!(new_scope, b)
                end
            end
        end
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
        end
    elseif h == :local
        for a in ex.args
            if a isa Expr && a.head == :(=)
                length(a.args) >= 2 && _collect_ast_symbols!(a.args[2], assigned, referenced, local_scope)
                _bind_ast_lhs!(a.args[1], local_scope)
            elseif a isa Symbol
                push!(local_scope, a)
            end
        end
    elseif h == :macrocall
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, local_scope)
        end
    elseif h == :.
        !isempty(ex.args) && _collect_ast_symbols!(ex.args[1], assigned, referenced, local_scope)
    else
        for a in ex.args
            _collect_ast_symbols!(a, assigned, referenced, local_scope)
        end
    end
    return nothing
end

const _LITERAL_CALL_OPS = Set([:(:), :+, :-, :*, :/, :^, :vect, :vcat, :hcat, :tuple, :(=>)])

function _is_literal_expr(ex)::Bool
    if ex isa Number || ex isa AbstractString || ex isa Char || ex isa Bool || ex isa QuoteNode
        return true
    elseif ex isa Symbol
        return ex in (:nothing, :missing, :true, :false, :pi, :ℯ, :im)
    elseif ex isa Expr
        if ex.head in (:vect, :vcat, :hcat, :row, :tuple, :braces)
            return all(_is_literal_expr, ex.args)
        elseif ex.head == :call && !isempty(ex.args) && ex.args[1] in _LITERAL_CALL_OPS
            return all(_is_literal_expr, ex.args[2:end])
        elseif ex.head == :... && length(ex.args) == 1
            return _is_literal_expr(ex.args[1])
        end
    end
    return false
end

function _default_param_str(sym::Symbol)::Tuple{String, Bool}
    if Base.invokelatest(isdefined, Main, sym)
        val = try
            Base.invokelatest(getfield, Main, sym)
        catch
            nothing
        end
        if !isnothing(val)
            try
                rep = Base.invokelatest(repr, val)
                if length(rep) <= 80 && !occursin('\n', rep)
                    return ("$(sym) = $(rep)", true)
                end
            catch
            end
            return ("$(sym) = Main.$(sym)", true)
        end
    end
    return (string(sym), false)
end

function _is_import_expr(ex)::Bool
    return ex isa Expr && ex.head in (:using, :import)
end

function _collect_imported_bindings!(ex, imported_syms::Set{Symbol})
    !_is_import_expr(ex) && return nothing
    for a in ex.args
        !(a isa Expr) && continue
        if a.head == :(:) && length(a.args) >= 2
            for item in a.args[2:end]
                if item isa Expr && item.head == :. && !isempty(item.args) && item.args[end] isa Symbol
                    push!(imported_syms, item.args[end])
                elseif item isa Expr && item.head == :as && length(item.args) >= 2 && item.args[2] isa Symbol
                    push!(imported_syms, item.args[2])
                end
            end
        elseif a.head == :as && length(a.args) >= 2 && a.args[2] isa Symbol
            push!(imported_syms, a.args[2])
        elseif a.head == :. && !isempty(a.args) && a.args[end] isa Symbol
            push!(imported_syms, a.args[end])
        end
    end
    return nothing
end

function _extract_imports_and_body(clean_cmds::Vector{String})
    import_stmts = String[]
    seen_imports = Set{String}()
    body_cmds = String[]
    imported_syms = Set{Symbol}()

    push_import!(s::AbstractString) = begin
        norm = String(strip(s))
        if !isempty(norm) && !(norm in seen_imports)
            push!(seen_imports, norm)
            push!(import_stmts, norm)
        end
    end

    for cmd in clean_cmds
        ex = try
            Meta.parseall(cmd)
        catch
            nothing
        end
        if !(ex isa Expr)
            push!(body_cmds, cmd)
            continue
        end
        top_stmts = [a for a in ex.args if !(a isa LineNumberNode)]
        if !any(_is_import_expr, top_stmts)
            push!(body_cmds, cmd)
            continue
        end

        for stmt in top_stmts
            _is_import_expr(stmt) && _collect_imported_bindings!(stmt, imported_syms)
        end

        if all(_is_import_expr, top_stmts)
            for stmt in top_stmts
                push_import!(string(stmt))
            end
            continue
        end

        # Mixed block: strip standalone `using`/`import` lines cleanly so remaining lines keep formatting
        kept_lines = String[]
        raw_lines = split(cmd, '\n')
        line_clean_ok = true
        extracted_from_lines = String[]
        for ln in raw_lines
            sln = strip(ln)
            if startswith(sln, "using ") || startswith(sln, "using\t") || startswith(sln, "import ") || startswith(sln, "import\t")
                lp = try
                    Meta.parseall(sln)
                catch
                    nothing
                end
                lstmts = (lp isa Expr) ? [a for a in lp.args if !(a isa LineNumberNode)] : Any[]
                if !isempty(lstmts) && all(_is_import_expr, lstmts)
                    for stmt in lstmts
                        push!(extracted_from_lines, string(stmt))
                    end
                    continue
                else
                    line_clean_ok = false
                    break
                end
            end
            push!(kept_lines, String(ln))
        end

        if line_clean_ok && !isempty(extracted_from_lines)
            for imp in extracted_from_lines
                push_import!(imp)
            end
            rem = rstrip(join(kept_lines, "\n"))
            !isempty(strip(rem)) && push!(body_cmds, String(rem))
        else
            rem_stmts = String[]
            for stmt in top_stmts
                if _is_import_expr(stmt)
                    push_import!(string(stmt))
                else
                    push!(rem_stmts, string(stmt))
                end
            end
            !isempty(rem_stmts) && push!(body_cmds, join(rem_stmts, "\n"))
        end
    end

    return import_stmts, body_cmds, imported_syms
end

"""
    make_procedure(name; last=0, indices=Int[], commands=String[], params=Symbol[], doc="", save=true)

Extract REPL commands into a parameterized, documented Julia function saved under
`procedures/<name>.jl` and automatically loaded into `Main`.
"""
function make_procedure(
        name::Union{Symbol, AbstractString};
        last::Int = 0,
        indices::Vector{Int} = Int[],
        commands::Vector{String} = String[],
        params::Vector{Symbol} = Symbol[],
        doc::String = "",
        save::Bool = true
    )
    proc_name = Symbol(name)
    all_cmds = get_recent_commands(limit = HISTORY_LIMIT)

    cmds = if !isempty(commands)
        copy(commands)
    elseif !isempty(indices)
        sort!(indices)
        [all_cmds[i] for i in indices if 1 <= i <= length(all_cmds)]
    elseif last > 0
        all_cmds[max(1, end - last + 1):end]
    else
        all_cmds[max(1, end - 4):end]
    end

    clean_cmds = [c for c in cmds if (s = strip(c); !isempty(s) && !startswith(s, "#") && !occursin("make_procedure", s))]
    if isempty(clean_cmds)
        @warn "No executable commands found to create procedure '$proc_name'"
        return nothing
    end

    # Step 0: Hoist all top-level `using` / `import` statements above the function & docstring
    import_stmts, non_import_cmds, imported_syms = _extract_imports_and_body(clean_cmds)
    isempty(non_import_cmds) && push!(non_import_cmds, "nothing")

    # Step 1: Promote initial literal/constant assignments to parameters with defaults
    promoted_params = String[]
    promoted_syms = Set{Symbol}()
    computation_start_idx = 1

    for (i, cmd) in enumerate(non_import_cmds)
        ex = try
            Meta.parse("begin\n" * cmd * "\nend")
        catch
            nothing
        end
        isnothing(ex) && break
        sub = filter(a -> !(a isa LineNumberNode), ex.args)
        isempty(sub) && continue
        stmt = sub[1]
        if length(sub) == 1 && stmt isa Expr && stmt.head == :(=) && stmt.args[1] isa Symbol && _is_literal_expr(stmt.args[2])
            rhs_refs = Set{Symbol}()
            _collect_ast_symbols!(stmt.args[2], Set{Symbol}(), rhs_refs)
            if isempty(intersect(rhs_refs, promoted_syms))
                push!(promoted_syms, stmt.args[1])
                push!(promoted_params, strip(cmd))
                computation_start_idx = i + 1
                continue
            end
        end
        break
    end

    if computation_start_idx > length(non_import_cmds)
        computation_start_idx = length(non_import_cmds)
        !isempty(promoted_params) && pop!(promoted_params)
    end

    body_cmds = non_import_cmds[computation_start_idx:end]

    # Step 2: Detect remaining free variables via scoped AST traversal
    assigned = union(copy(promoted_syms), imported_syms)
    referenced = Set{Symbol}()
    parsed_exprs = Expr[]
    for cmd in body_cmds
        ex = try
            Meta.parse("begin\n" * cmd * "\nend")
        catch
            nothing
        end
        if !isnothing(ex)
            push!(parsed_exprs, ex)
            _collect_ast_symbols!(ex, assigned, referenced)
        end
    end

    free_syms = setdiff(referenced, assigned)
    detected_params = filter(s -> !startswith(string(s), "@") && !_is_global_or_type(s), collect(free_syms))
    final_params = !isempty(params) ? params : sort(detected_params, by = string)

    required_params = String[]
    other_default_params = String[]
    for p in final_params
        p_str, has_default = _default_param_str(p)
        push!(has_default ? other_default_params : required_params, p_str)
    end

    sig_args = join(vcat(required_params, promoted_params, other_default_params), ", ")
    func_sig = "$(proc_name)($sig_args)"

    body_lines = String["    " * line for cmd in body_cmds for line in split(cmd, '\n')]
    if !isempty(parsed_exprs) && parsed_exprs[end] isa Expr && parsed_exprs[end].head == :block
        sub_args = filter(a -> !(a isa LineNumberNode), parsed_exprs[end].args)
        if !isempty(sub_args)
            leaf = sub_args[end]
            leaf isa Expr && leaf.head == :(=) && leaf.args[1] isa Symbol && push!(body_lines, "    return " * string(leaf.args[1]))
        end
    end

    body_code = join(body_lines, "\n")
    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    doc_text = isempty(doc) ? "Automated procedure extracted from Julia REPL." : doc
    imports_block = isempty(import_stmts) ? "" : (join(import_stmts, "\n") * "\n\n")

    code = """
    # Generated by jEMach on $timestamp
    $imports_block\"\"\"
        $func_sig

    $doc_text
    \"\"\"
    function $func_sig
    $body_code
    end
    """

    if save
        proc_dir = joinpath(_get_project_dir(), "procedures")
        !isdir(proc_dir) && mkpath(proc_dir)
        filepath = joinpath(proc_dir, string(proc_name) * ".jl")
        write(filepath, code)

        file_mt = try
            mtime(filepath)
        catch
            0.0
        end
        rel_path = relpath(filepath, _get_project_dir())
        scan = _scan_proc_source(code)
        p_info = ProcedureInfo(
            proc_name, func_sig, rel_path, doc_text, code, 0.0, 0, :never, "-";
            origin = :disk,
            disk_code = code,
            live_code = code,
            edit_code = isempty(scan.edit_code) ? code : scan.edit_code,
            imports_block = scan.imports_block,
            disk_hash = scan.content_hash,
            live_hash = scan.content_hash,
            generation = 1,
            func_start_line = scan.func_line,
        )
        try
            Base.include(Main, filepath)
            _loaded_proc_mtimes[filepath] = file_mt
        catch e
            bt = catch_backtrace()
            summary, detail, err_line, err_stmt = _format_error_pair(e, bt; target_file = filepath, source_code = code)
            p_info.origin = :unloaded
            p_info.live_code = ""
            p_info.live_hash = UInt64(0)
            p_info.last_run_status = :error
            p_info.last_run_at = Dates.format(Dates.now(), "HH:MM:SS")
            p_info.last_run_cmd = "include(" * rel_path * ")"
            p_info.last_error = summary
            p_info.last_error_detail = detail
            p_info.last_error_line = err_line
            p_info.last_error_cmd = err_stmt
            @warn "Failed to evaluate generated procedure in Main" exception = e
        end

        _procedures[proc_name] = p_info
        _parsed_proc_mtimes[filepath] = file_mt
        _parsed_proc_names[filepath] = proc_name
        _proc_registry_epoch[] += 1
        publish_state()

        green, reset, cyan = "\e[32m\e[1m", "\e[0m", "\e[36m"
        println("\n" * green * "✓" * reset * " Procedure " * cyan * "$proc_name" * reset * " created in " * green * "$rel_path" * reset)
        println("  Callable in REPL: " * cyan * "$func_sig" * reset * "\n")
    end

    return code
end

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
                    p.origin = :modified
                    p.generation += 1
                end
            else
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
