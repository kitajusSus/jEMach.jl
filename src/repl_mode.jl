# Shared REPL command dispatcher, `@jemach` & `@inspect` macros, and `jemach>` mode.

const _JEMACH_COMMANDS = [
    "help", "ui", "toggle", "open", "close", "clear", "ws", "vars", "ls", "find", "show",
    "run", "edit", "make", "rec", "stop", "inspect", "errors", "save", "reload", "status", "shutdown",
]

function _print_jemach_help(io::IO = stdout)
    bold, cyan, dim, reset = "\e[1m", "\e[36m", "\e[2m", "\e[0m"
    rows = [
        ("ui | toggle", "Toggle the TUI split/window (also Alt+j)"),
        ("open | close | clear", "Open / close TUI, or clear REPL screen (clear())"),
        ("ws [filter]", "Workspace table with memory sizes (also `workspace()`)"),
        ("ls [query] | find <q>", "List / search saved & live procedures"),
        ("show <name>", "Show a procedure card with status, errors & source"),
        ("edit <name>", "Load clean function into `julia>` REPL editor"),
        ("errors", "Show recent failed commands and errored procedures"),
        ("run <name>(args...)", "Run a procedure with profiling (args space- or comma-sep)"),
        ("<name>(args...)", "Shortcut: run an existing procedure directly"),
        ("make <name> [N]", "Create a procedure from the last N commands (default 5)"),
        ("rec [name] | stop", "Start / stop recording a procedure (also Alt+r)"),
        ("inspect <expr> | i <expr>", "Deep inspection of a variable/function"),
        ("save [<name> [new]]", "Save session script, or save modified/live procedure"),
        ("reload [<name>]", "Reload procedures/ (or one procedure) from disk"),
        ("status", "Watcher, socket and terminal diagnostics"),
        ("shutdown", "Stop the watcher and close the TUI"),
    ]
    println(io, bold * cyan * "jEMach REPL mode" * reset * dim * "  (Backspace on empty line → julia>, Tab completes)" * reset)
    for (c, d) in rows
        println(io, "  " * cyan * rpad(c, 26) * reset * " " * d)
    end
    return nothing
end

function _print_errors_summary(io::IO = stdout)
    bold, red, cyan, yellow, dim, reset = "\e[1m", "\e[31m", "\e[36m", "\e[33m", "\e[2m", "\e[0m"
    err_procs = [p for p in sort(collect(values(_procedures)), by = x -> string(x.name)) if p.last_run_status == :error]
    if isempty(err_procs) && isempty(_failed_commands)
        println(io, dim * "No failed procedures or failed REPL commands recorded in this session." * reset)
        return nothing
    end
    if !isempty(err_procs)
        println(io, bold * red * "Errored Procedures ($(length(err_procs))):" * reset)
        for p in err_procs
            loc = p.last_error_line > 0 ? " [L$(p.last_error_line)]" : ""
            println(io, "  " * red * "✗ " * cyan * string(p.name) * reset * yellow * loc * reset * " — " * red * p.last_error * reset)
            !isempty(p.last_run_cmd) && println(io, "    " * dim * "call: " * reset * p.last_run_cmd)
        end
    end
    if !isempty(_failed_commands)
        println(io, bold * red * "Failed REPL Commands ($(length(_failed_commands))):" * reset)
        for fc in _failed_commands
            first_line = _truncate_chars(replace(fc.cmd, '\n' => " ⏎ "), 70)
            println(io, "  " * red * "✗ " * reset * bold * first_line * reset * dim * " ($(fc.timestamp))" * reset)
            println(io, "    " * red * fc.error_msg * reset)
        end
    end
    return nothing
end

function _next_proc_name()::Symbol
    _load_procedures!()
    i = length(_procedures) + 1
    while haskey(_procedures, Symbol("proc_", i)) || Base.invokelatest(isdefined, Main, Symbol("proc_", i))
        i += 1
    end
    return Symbol("proc_", i)
end

_esc_arg(a) = (a isa Expr && a.head == :kw) ? Expr(:kw, a.args[1], esc(a.args[2])) : esc(a)

function _split_call_args(args)
    params = Any[]
    positional = Any[]
    for a in args
        if a isa Expr && a.head == :parameters
            append!(params, a.args)
        else
            push!(positional, a)
        end
    end
    return params, positional
end

function _run_expr(target)
    rp = GlobalRef(jEMach, :run_procedure)
    if target isa Symbol
        return Expr(:call, rp, QuoteNode(target))
    elseif target isa Expr && target.head == :call && target.args[1] isa Symbol
        params, positional = _split_call_args(target.args[2:end])
        call = Expr(:call, rp)
        isempty(params) || push!(call.args, Expr(:parameters, params...))
        push!(call.args, QuoteNode(target.args[1]))
        append!(call.args, positional)
        return call
    end
    throw(ArgumentError("expected a procedure name or call, got: $(target)"))
end

function _run_from_string(rest::AbstractString)
    s = replace(strip(rest), r"^([A-Za-z_][A-Za-z0-9_!]*)\s+\(" => s"\1(")
    target = try
        Meta.parse(s)
    catch
        nothing
    end
    if !(target isa Symbol || (target isa Expr && target.head == :call && target.args[1] isa Symbol))
        m = match(r"^([A-Za-z_][A-Za-z0-9_!]*)\s+(.*)$"s, s)
        isnothing(m) && throw(ArgumentError("usage: run <name> [args...]  or  run name(args...)"))
        argstr = strip(m.captures[2])
        occursin(',', argstr) || (argstr = join(split(argstr), ", "))
        target = Meta.parse(m.captures[1] * "(" * argstr * ")")
    end
    return Base.invokelatest(Core.eval, Main, _run_expr(target))
end

"""
    _exec_command(line::AbstractString)

Execute one `jemach>` command line. Returns a value only when it is worth displaying
(e.g. the result of `run`, or a `ProcedureInfo` for `show`).
"""
function _exec_command(line::AbstractString)
    s = strip(line)
    isempty(s) && return nothing

    m_call = match(r"^([A-Za-z_][A-Za-z0-9_!]*)\s*\((.*)\)\s*$"s, s)
    m_ws = match(r"^(\S+)\s*(.*)$"s, s)
    raw_head = !isnothing(m_call) ? String(m_call.captures[1]) : String(m_ws.captures[1])
    cmd = lowercase(raw_head)
    rest = if !isnothing(m_call)
        String(strip(m_call.captures[2]))
    else
        String(strip(m_ws.captures[2]))
    end
    is_proc_call = !isnothing(m_call) && !isempty(rest)

    if !is_proc_call && cmd in ("help", "?", "h")
        _print_jemach_help()
    elseif !is_proc_call && cmd in ("ui", "toggle")
        toggle()
    elseif !is_proc_call && cmd == "open"
        _is_tui_open() ? println("TUI is already open.") : ui()
    elseif !is_proc_call && cmd == "close"
        _is_tui_open() ? toggle() : println("TUI is not open.")
    elseif !is_proc_call && cmd in ("clear", "cls")
        _repl_clear()
    elseif cmd in ("ws", "vars", "workspace") && isnothing(m_call)
        workspace(rest)
    elseif cmd in ("ls", "list", "procs", "find", "search") && isnothing(m_call)
        list_procedures(rest)
    elseif cmd == "show" && isnothing(m_call)
        isempty(rest) && throw(ArgumentError("usage: show <procedure>"))
        _load_procedures!()
        sym = Symbol(rest)
        haskey(_procedures, sym) || throw(ArgumentError("no procedure named '$rest'"))
        return _procedures[sym]
    elseif cmd == "run" && isnothing(m_call)
        isempty(rest) && throw(ArgumentError("usage: run <name> [args...]  or  run name(args...)"))
        return _run_from_string(rest)
    elseif cmd == "make" && isnothing(m_call)
        parts = split(rest)
        isempty(parts) && throw(ArgumentError("usage: make <name> [N]"))
        n = length(parts) >= 2 ? something(tryparse(Int, parts[2]), 0) : 0
        make_procedure(Symbol(parts[1]); last = n)
    elseif cmd in ("rec", "record") && isnothing(m_call)
        record(isempty(rest) ? _next_proc_name() : Symbol(rest))
    elseif !is_proc_call && cmd in ("stop", "record_stop")
        _recording[] ? record_stop() : println("No recording in progress (use `shutdown` to stop the jEMach watcher).")
    elseif cmd in ("inspect", "i") && isnothing(m_call)
        isempty(rest) && throw(ArgumentError("usage: inspect <expr>"))
        inspect_var(Main, rest)
    elseif !is_proc_call && cmd in ("errors", "errs", "failed")
        _print_errors_summary()
    elseif cmd in ("edit", "e") && isnothing(m_call)
        isempty(rest) && throw(ArgumentError("usage: edit <name>"))
        res = edit_procedure(rest)
        return isnothing(_get_mistate()) ? res : nothing
    elseif !is_proc_call && cmd == "save"
        if isempty(rest)
            save_clean_session()
        else
            parts = split(rest)
            as_arg = if length(parts) >= 3 && lowercase(parts[2]) == "as"
                parts[3]
            elseif length(parts) >= 2
                parts[2]
            else
                nothing
            end
            save_procedure(parts[1]; as_name = as_arg)
        end
    elseif !is_proc_call && cmd in ("reload", "autoload")
        if isempty(rest)
            autoload_procedures!(; force = true)
            publish_state()
            println("✓ Reloaded $(length(_procedures)) procedure(s) from disk into Main")
        else
            reload_procedure(rest)
        end
    elseif !is_proc_call && cmd in ("status", "info")
        status()
        info = terminal_info()
        for k in (:term, :term_program, :tmux, :zellij, :kitty, :ghostty, :rex)
            println("  ", rpad(string(k), 14), info[k])
        end
        println("  ", rpad("procedures", 14), length(_procedures), "   recording: ", _recording[] ? string(_record_name[]) : "no")
        println("  ", rpad("tui open", 14), _is_tui_open())
    elseif !is_proc_call && cmd in ("shutdown", "quit")
        stop()
    else
        _load_procedures!()
        proc_sym = Symbol(raw_head)
        haskey(_procedures, proc_sym) && return _run_from_string(s)
        println("Unknown jemach command '$(m_ws.captures[1])'. Type `help` for the list of commands.")
    end
    return nothing
end

"""
    @jemach
    @jemach <command> [args...]

Without arguments, toggle the jEMach TUI panel. With arguments, run a `jemach>` command.
"""
macro jemach(args...)
    isempty(args) && return :($(GlobalRef(jEMach, :toggle))())
    cmd = lowercase(string(args[1]))
    rest = args[2:end]
    if cmd == "run" && !isempty(rest)
        target = rest[1]
        if target isa Expr && target.head == :call && target.args[1] isa Symbol
            params, positional = _split_call_args(target.args[2:end])
            call = Expr(:call, GlobalRef(jEMach, :run_procedure))
            isempty(params) || push!(call.args, Expr(:parameters, map(_esc_arg, params)...))
            push!(call.args, QuoteNode(target.args[1]))
            append!(call.args, map(_esc_arg, positional))
            return call
        end
        return Expr(:call, GlobalRef(jEMach, :run_procedure), QuoteNode(Symbol(string(target))), map(_esc_arg, rest[2:end])...)
    elseif cmd in ("inspect", "i") && !isempty(rest)
        expr_str = join(map(string, rest), " ")
        return :($(GlobalRef(jEMach, :inspect_var))($__module__, $expr_str))
    end
    line = join(vcat([cmd], [a isa AbstractString ? String(a) : string(a) for a in rest]), " ")
    return :($(GlobalRef(jEMach, :_exec_command))($line))
end

"""
    @inspect expr

Deep-inspect `expr` (type, size, methods & return types, the REPL command that created it,
and documentation). Shorthand for `inspect_var(@__MODULE__, "expr")`.
"""
macro inspect(ex)
    return :($(GlobalRef(jEMach, :inspect_var))($__module__, $(string(ex))))
end

# ---------------------------------------------------------------------------
# Dedicated `jemach>` REPL mode with Tab completion & hotkeys
# ---------------------------------------------------------------------------

struct JEMachCompletionProvider <: LineEdit.CompletionProvider end

function _main_symbol_names()::Vector{String}
    out = String[]
    for sym in Base.invokelatest(names, Main; all = true, imported = true)
        n = string(sym)
        (_skip_name(n) || startswith(n, "#") || startswith(n, "_")) && continue
        push!(out, n)
    end
    return out
end

function _jemach_completions(partial::AbstractString)
    wm = match(r"([A-Za-z0-9_!@]*)$", partial)
    word = isnothing(wm) ? "" : String(wm.captures[1])
    before = String(codeunits(partial)[1:(ncodeunits(partial) - ncodeunits(word))])
    words_before = split(before)
    proc_names = String[string(k) for k in keys(_procedures)]
    cands = if occursin('(', before)
        _main_symbol_names()
    elseif isempty(words_before)
        vcat(_JEMACH_COMMANDS, proc_names)
    else
        c = lowercase(words_before[1])
        if c in ("run", "show", "ls", "find", "reload", "save") && length(words_before) == 1
            proc_names
        elseif c in ("edit", "e") && length(words_before) == 1
            vcat(proc_names, _main_symbol_names())
        elseif c in ("inspect", "i", "ws", "vars")
            _main_symbol_names()
        else
            String[]
        end
    end
    return sort!(unique!(filter(x -> startswith(x, word), cands))), word
end

function LineEdit.complete_line(::JEMachCompletionProvider, s; hint::Bool = false)
    buf = LineEdit.buffer(s)
    partial = isdefined(REPL, :beforecursor) ? REPL.beforecursor(buf) : String(buf.data[1:position(buf)])
    matches, word = _jemach_completions(partial)
    return matches, word, !isempty(matches)
end

const _jemach_mode_ref = Ref{Any}(nothing)

function _enter_jemach_mode(s)
    mode = _jemach_mode_ref[]
    isnothing(mode) && return nothing
    buf = copy(LineEdit.buffer(s))
    return LineEdit.transition(s, mode) do
        LineEdit.state(s, mode).input_buffer = buf
    end
end

function _toggle_recording_key(s)
    _clear_repl_input_area(s)
    try
        _recording[] ? record_stop() : record(_next_proc_name())
    catch e
        @error "jEMach recording failed" exception = e
    end
    println(stdout)
    LineEdit.refresh_line(s)
    return :ok
end

const _hooked_repl_prompts = WeakKeyDict{Any, Bool}()

function _install_repl_error_hook!(repl, main::LineEdit.Prompt)
    get(_hooked_repl_prompts, main, false) && return nothing
    orig_on_done = main.on_done
    _hooked_repl_prompts[main] = true

    main.on_done = function (s, buf, ok)
        line = ""
        if ok && buf isa IOBuffer
            try
                b_copy = copy(buf)
                seekstart(b_copy)
                line = read(b_copy, String)
            catch
                line = ""
            end
        end
        prev_err = isdefined(Base.MainInclude, :err) ? getfield(Base.MainInclude, :err) : nothing
        has_waserr = hasproperty(repl, :waserror)
        if has_waserr
            try
                repl.waserror = false
            catch
            end
        end

        res = orig_on_done(s, buf, ok)

        if ok && !isempty(strip(line))
            try
                was_err = has_waserr ? Bool(repl.waserror) : false
                new_err = isdefined(Base.MainInclude, :err) ? getfield(Base.MainInclude, :err) : nothing
                is_proc_runner = startswith(strip(line), "jEMach.run_procedure(")
                if was_err
                    err_stack = (new_err !== prev_err && !isnothing(new_err)) ? new_err : nothing
                    is_stack = !isnothing(err_stack) && err_stack isa Base.ExceptionStack
                    if !(is_proc_runner && !isnothing(err_stack))
                        Base.invokelatest(_record_command_outcome!, line, false, err_stack, nothing; source = "repl", is_stack = is_stack)
                    end
                elseif !is_proc_runner
                    Base.invokelatest(_capture_repl_definitions!, line)
                    Base.invokelatest(_record_command_outcome!, line, true; source = "repl")
                end
                _has_active_tui_clients() && @async (sleep(0.02); Base.invokelatest(publish_state))
            catch
            end
        end
        return res
    end
    return nothing
end

function _install_jemach_mode!(repl)
    (hasproperty(repl, :interface) && isdefined(repl, :interface)) || return nothing
    iface = repl.interface
    any(m -> m isa LineEdit.Prompt && m.complete isa JEMachCompletionProvider, iface.modes) && return nothing
    main = iface.modes[1]
    main isa LineEdit.Prompt || return nothing

    _install_repl_error_hook!(repl, main)

    jm = LineEdit.Prompt(
        "jemach> ";
        prompt_prefix = "\e[36m\e[1m",
        prompt_suffix = main.prompt_suffix,
        complete = JEMachCompletionProvider(),
        sticky = true,
    )
    jm.repl = repl
    hp = main.hist
    hp isa REPL.REPLHistoryProvider && (hp.mode_mapping[:jemach] = jm)
    jm.hist = hp
    jm.on_done = REPL.respond(line -> Expr(:call, GlobalRef(jEMach, :_exec_command), line), repl, main)

    _, prefix_keymap = LineEdit.setup_prefix_keymap(hp, jm)
    keymaps = Dict{Any, Any}[]
    !isdefined(REPL, :History) && push!(keymaps, last(LineEdit.setup_search_keymap(hp)))
    push!(keymaps, Dict{Any, Any}("\er" => (s, o...) -> _toggle_recording_key(s)))
    push!(keymaps, REPL.mode_keymap(main), prefix_keymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults)
    jm.keymap_dict = LineEdit.keymap(keymaps)

    push!(iface.modes, jm)
    _jemach_mode_ref[] = jm

    use_bracket = isdefined(LineEdit, :bracket_insert_keymap) &&
        hasproperty(repl, :options) && hasproperty(repl.options, :auto_insert_closing_bracket) &&
        repl.options.auto_insert_closing_bracket && haskey(LineEdit.bracket_insert_keymap, '}')

    main_keymap = Dict{Any, Any}(
        '}' => function (s, o...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                return _enter_jemach_mode(s)
            elseif use_bracket
                return LineEdit.bracket_insert_keymap['}'](s, o...)
            else
                LineEdit.edit_insert(s, '}')
                isdefined(LineEdit, :check_show_hint) && LineEdit.check_show_hint(s)
                return nothing
            end
        end,
        "\ej" => (s, o...) -> (@async toggle(); return :ok),
        "\em" => (s, o...) -> _enter_jemach_mode(s),
        "\er" => (s, o...) -> _toggle_recording_key(s),
    )
    main.keymap_dict = LineEdit.keymap_merge(main.keymap_dict, main_keymap)
    return jm
end

function _setup_repl_hooks(repl)
    return @async begin
        for _ in 1:25
            if isdefined(Base, :active_repl_backend) && !isnothing(Base.active_repl_backend) &&
                    hasproperty(repl, :interface) && !isnothing(repl.interface)
                break
            end
            sleep(0.05)
        end
        try
            if isdefined(Base, :active_repl_backend) && !isnothing(Base.active_repl_backend)
                push!(
                    Base.active_repl_backend.ast_transforms,
                    function (ast)
                        _has_active_tui_clients() && @async (sleep(0.02); Base.invokelatest(publish_state))
                        return ast
                    end
                )
            end
        catch
        end

        try
            sleep(0.25) # let OhMyREPL finish installing its keymap first if present
            Base.invokelatest(_install_jemach_mode!, repl)
        catch e
            @debug "jEMach: failed to install jemach> REPL hooks" exception = e
        end
    end
end
