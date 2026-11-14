# Procedure metadata, discovery, AST parameterization, recording & benchmark runner.

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
end

function Base.show(io::IO, p::ProcedureInfo)
    print(io, "ProcedureInfo(:$(p.name), \"$(p.signature)\", status=:$(p.last_run_status))")
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

    status_badge = p.last_run_status == :ok ? (green * "✓ OK" * reset) :
        p.last_run_status == :error ? (red * "✗ ERROR" * reset) : (dim * "○ NEVER RUN" * reset)
    metrics_str = p.last_run_status != :never ?
        "$(p.last_run_time_ms) ms, $(Base.format_bytes(p.last_run_alloc_bytes)) (at $(p.last_run_at))" :
        "-"

    println(io, bold * cyan * "╭─ Procedure: " * string(p.name) * " " * ("─"^max(1, 50 - length(string(p.name)))) * "╮" * reset)
    println(io, "│ " * bold * "Signature: " * reset * cyan * p.signature * reset)
    println(io, "│ " * bold * "File:      " * reset * p.file)
    println(io, "│ " * bold * "Status:    " * reset * status_badge * "  " * yellow * metrics_str * reset)
    !isempty(p.doc) && println(io, "│ " * bold * "Doc:       " * reset * dim * replace(p.doc, '\n' => " ") * reset)
    if !isempty(strip(p.code))
        println(io, cyan * "├─ Source " * ("─"^58) * "┤" * reset)
        for (li, line) in enumerate(split(rstrip(p.code), '\n'))
            println(io, "│ " * dim * lpad(string(li), 3) * " │ " * reset * line)
        end
    end
    print(io, bold * cyan * "╰" * ("─"^67) * "╯" * reset)
    return nothing
end

const _procedures = Dict{Symbol, ProcedureInfo}()
const _parsed_proc_mtimes = Dict{String, Float64}()
const _parsed_proc_names = Dict{String, Symbol}()
const _loaded_proc_mtimes = Dict{String, Float64}()
const _recording = Ref{Bool}(false)
const _record_name = Ref{Symbol}(:proc)
const _record_start_pos = Ref{Int64}(0)
const _record_hist_idx = Ref{Int}(0)
const _orig_julia_prompt = Ref{Any}(nothing)
const _orig_julia_prefix = Ref{Any}(nothing)

function _extract_sig_and_name(fexpr::Expr, default_name::Symbol)::Tuple{String, Symbol}
    while fexpr.head == :macrocall && length(fexpr.args) >= 3 && fexpr.args[end] isa Expr
        fexpr = fexpr.args[end]
    end
    sig = ""
    fname = default_name
    if fexpr.head == :function && !isempty(fexpr.args)
        fsym = fexpr.args[1]
        sig = string(fsym)
        if fsym isa Expr && fsym.head == :call && !isempty(fsym.args)
            fname = Symbol(fsym.args[1])
        end
    elseif fexpr.head == :(=) && length(fexpr.args) >= 2 && fexpr.args[1] isa Expr && fexpr.args[1].head == :call
        fsym = fexpr.args[1]
        sig = string(fsym)
        !isempty(fsym.args) && (fname = Symbol(fsym.args[1]))
    end
    return (sig, fname)
end

function _load_procedures!(; eval_in_main::Bool = false)
    proj_dir = _get_project_dir()
    proc_dir = joinpath(proj_dir, "procedures")
    !isdir(proc_dir) && return _procedures

    found_names = Set{Symbol}()
    seen_files = Set{String}()
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
            func_name = if !isnothing(cached_name) &&
                    get(_parsed_proc_mtimes, filepath, -1.0) == file_mt &&
                    haskey(_procedures, cached_name)
                cached_name
            else
                content = try
                    read(filepath, String)
                catch
                    continue
                end
                parsed = try
                    Meta.parse("begin\n" * content * "\nend")
                catch
                    continue
                end
                doc_str = ""
                sig_str = ""
                parsed_name = Symbol(splitext(file)[1])

                for a in parsed.args
                    !(a isa Expr) && continue
                    if a.head == :macrocall && length(a.args) >= 4
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
                rel_path = relpath(filepath, proj_dir)

                if !haskey(_procedures, parsed_name)
                    _procedures[parsed_name] = ProcedureInfo(
                        parsed_name, sig_str, rel_path, strip(doc_str), content,
                        0.0, 0, :never, "-"
                    )
                else
                    p = _procedures[parsed_name]
                    p.signature = sig_str
                    p.doc = strip(doc_str)
                    p.code = content
                    p.file = rel_path
                end
                _parsed_proc_mtimes[filepath] = file_mt
                _parsed_proc_names[filepath] = parsed_name
                parsed_name
            end

            push!(found_names, func_name)

            if eval_in_main && (get(_loaded_proc_mtimes, filepath, -1.0) != file_mt || !isdefined(Main, func_name))
                try
                    Base.include(Main, filepath)
                    _loaded_proc_mtimes[filepath] = file_mt
                catch
                end
            end
        end
    end

    for k in collect(keys(_procedures))
        !(k in found_names) && delete!(_procedures, k)
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
    autoload_procedures!() -> Dict{Symbol, ProcedureInfo}

Discover all `.jl` files in the project's `procedures/` folder and evaluate them
into `Main` so that tab-completion, direct function calls, and `?procedure_name`
docstrings work immediately in the Julia REPL.
"""
autoload_procedures!() = _load_procedures!(; eval_in_main = true)

# ---------------------------------------------------------------------------
# AST scope & free-variable analyzer
# ---------------------------------------------------------------------------

function _is_global_or_type(sym::Symbol)::Bool
    for m in (Main, Base, Core)
        if isdefined(m, sym)
            try
                v = getfield(m, sym)
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
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
        if lhs isa Symbol || (lhs isa Expr && lhs.head in (:tuple, :(::)))
            _bind_ast_lhs!(lhs, assigned)
        else
            _collect_ast_symbols!(lhs, assigned, referenced, local_scope)
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
        new_scope = copy(local_scope)
        if !isempty(ex.args)
            sig = ex.args[1]
            if sig isa Symbol
                push!(assigned, sig)
            elseif sig isa Expr && sig.head == :call && !isempty(sig.args)
                sig.args[1] isa Symbol && push!(assigned, sig.args[1])
                for a in sig.args[2:end]
                    _bind_ast_lhs!(a, new_scope)
                end
            elseif sig isa Expr && sig.head == :tuple
                _bind_ast_lhs!(sig, new_scope)
            end
        end
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
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
    if isdefined(Main, sym)
        val = try
            getfield(Main, sym)
        catch
            nothing
        end
        if !isnothing(val)
            try
                rep = repr(val)
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

    # Step 1: Promote initial literal/constant assignments to parameters with defaults
    promoted_params = String[]
    promoted_syms = Set{Symbol}()
    computation_start_idx = 1

    for (i, cmd) in enumerate(clean_cmds)
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

    if computation_start_idx > length(clean_cmds)
        computation_start_idx = length(clean_cmds)
        pop!(promoted_params)
    end

    body_cmds = clean_cmds[computation_start_idx:end]

    # Step 2: Detect remaining free variables via scoped AST traversal
    assigned = copy(promoted_syms)
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

    code = """
    # Generated by jEMach on $timestamp
    \"\"\"
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
        try
            Base.include(Main, filepath)
            _loaded_proc_mtimes[filepath] = file_mt
        catch e
            @warn "Failed to evaluate generated procedure in Main" exception = e
        end

        rel_path = relpath(filepath, _get_project_dir())
        _procedures[proc_name] = ProcedureInfo(
            proc_name, func_sig, rel_path, doc_text, code, 0.0, 0, :never, "-"
        )
        _parsed_proc_mtimes[filepath] = file_mt
        _parsed_proc_names[filepath] = proc_name
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

"""
    run_procedure(name, args...; kwargs...)

Execute a saved procedure from `procedures/` with timing and memory profiling,
updating its metrics in the jEMach TUI.
"""
function run_procedure(name::Union{Symbol, AbstractString}, args...; kwargs...)
    sym = Symbol(name)
    _load_procedures!()

    proj_dir = _get_project_dir()
    proc_file = if haskey(_procedures, sym) && !isempty(_procedures[sym].file)
        joinpath(proj_dir, _procedures[sym].file)
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

    if isfile(proc_file)
        try
            Base.include(Main, proc_file)
            _loaded_proc_mtimes[proc_file] = try
                mtime(proc_file)
            catch
                0.0
            end
        catch e
            @warn "Failed to reload $proc_file" exception = e
        end
    end

    Base.invokelatest(isdefined, Main, sym) || error("Procedure '$sym' not found in Main or procedures/$sym.jl")
    func = Base.invokelatest(getfield, Main, sym)

    println("▶ Running procedure '$sym'...")
    t_res = @timed try
        Base.invokelatest(func, args...; kwargs...)
    catch e
        e
    end

    val = t_res.value
    is_err = val isa Exception
    status_sym = is_err ? :error : :ok
    time_ms = round(t_res.time * 1000, digits = 2)
    alloc_bytes = t_res.bytes
    now_str = Dates.format(Dates.now(), "HH:MM:SS")

    if haskey(_procedures, sym)
        p = _procedures[sym]
        p.last_run_time_ms = time_ms
        p.last_run_alloc_bytes = alloc_bytes
        p.last_run_status = status_sym
        p.last_run_at = now_str
    else
        _procedures[sym] = ProcedureInfo(
            sym, string(sym) * "()", isfile(proc_file) ? relpath(proc_file, proj_dir) : "",
            "", "", time_ms, alloc_bytes, status_sym, now_str
        )
    end
    publish_state()

    if is_err
        println("\e[31m\e[1m✗ Procedure '$sym' failed in $(time_ms)ms\e[0m")
        throw(val)
    end
    println("\e[32m\e[1m✓ Procedure '$sym' completed in $(time_ms)ms ($(Base.format_bytes(alloc_bytes)) allocated)\e[0m")
    return val
end

"""
    search_procedures(query::AbstractString = "") -> Vector{ProcedureInfo}

Search and return discovered procedures matching `query` by name, signature, docstring, or source code.
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
            occursin(q, lowercase(p.code))
    end
end

const find_procedures = search_procedures

"""
    list_procedures(query::AbstractString = "")

Print a formatted table of available procedures (optionally filtered by `query`) with their
signatures, docstrings, and latest benchmark metrics.
"""
function list_procedures(query::AbstractString = "")
    procs = search_procedures(query)
    bold, cyan, green, yellow, red, dim, reset = "\e[1m", "\e[36m", "\e[32m", "\e[33m", "\e[31m", "\e[2m", "\e[0m"

    if isempty(_procedures)
        println("$(dim)No procedures defined. Create one with $(cyan)jEMach.make_procedure(:name, last=5)$(reset)")
        return nothing
    elseif isempty(procs)
        println("$(yellow)No procedures found matching \"$query\"$(reset) ($(length(_procedures)) total defined).")
        return nothing
    end

    header = isempty(query) ? "Available Procedures ($(length(procs))):" : "Matching Procedures for \"$query\" ($(length(procs))/$(length(_procedures))):"
    println(bold * cyan * "┌─ " * header * " " * ("─"^max(0, 48 - length(header))) * reset)
    for p in procs
        status_icon = p.last_run_status == :ok ? (green * "✓" * reset) :
            p.last_run_status == :error ? (red * "✗" * reset) : (dim * "○" * reset)
        time_str = p.last_run_status != :never ? " $(yellow)($(p.last_run_time_ms)ms, $(Base.format_bytes(p.last_run_alloc_bytes)))$(reset)" : ""
        println("│ $status_icon " * cyan * bold * string(p.name) * reset * " → " * p.signature * time_str)
        !isempty(p.doc) && println("│   $(dim)\"$(split(p.doc, '\n')[1])\"$(reset)")
        println("│   $(dim)File: $(p.file)$(reset)")
    end
    println(bold * cyan * "└" * ("─"^52) * reset)
    return nothing
end
