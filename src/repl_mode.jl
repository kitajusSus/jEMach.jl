# Shared REPL command dispatcher, `@jemach` & `@inspect` macros, and `jemach>` mode.

const _JEMACH_COMMANDS = [
    "help", "ui", "toggle", "open", "close", "ws", "vars", "ls", "find", "show",
    "run", "make", "rec", "stop", "inspect", "save", "reload", "status", "shutdown",
]

function _print_jemach_help(io::IO = stdout)
    bold, cyan, dim, reset = "\e[1m", "\e[36m", "\e[2m", "\e[0m"
    rows = [
        ("ui | toggle", "Toggle the TUI split/window (also Alt+j)"),
        ("open | close", "Open / close the TUI panel"),
        ("ws [filter]", "Workspace table with memory sizes (also `workspace()`)"),
        ("ls [query] | find <q>", "List / search saved procedures"),
        ("show <name>", "Show a procedure card with its source"),
        ("run <name> [args...]", "Run a procedure with profiling (`run f(1, x=2)` works too)"),
        ("<name> [args...]", "Shortcut: run an existing procedure directly"),
        ("make <name> [N]", "Create a procedure from the last N commands (default 5)"),
        ("rec [name] | stop", "Start / stop recording a procedure (also Alt+r)"),
        ("inspect <expr> | i <expr>", "Deep inspection of a variable/function"),
        ("save", "Save a clean, replayable session script"),
        ("reload", "Reload procedures/ into Main"),
        ("status", "Watcher, socket and terminal diagnostics"),
        ("shutdown", "Stop the watcher and close the TUI"),
    ]
    println(io, bold * cyan * "jEMach REPL mode" * reset * dim * "  (Backspace on empty line → julia>, Tab completes)" * reset)
    for (c, d) in rows
        println(io, "  " * cyan * rpad(c, 26) * reset * " " * d)
    end
    return nothing
end

function _next_proc_name()::Symbol
    _load_procedures!()
    i = length(_procedures) + 1
    while haskey(_procedures, Symbol("proc_", i)) || isdefined(Main, Symbol("proc_", i))
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
    s = strip(rest)
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
    m = match(r"^(\S+)\s*(.*)$"s, s)
    cmd = lowercase(m.captures[1])
    rest = String(strip(m.captures[2]))

    if cmd in ("help", "?", "h")
        _print_jemach_help()
    elseif cmd in ("ui", "toggle")
        toggle()
    elseif cmd == "open"
        _is_tui_open() ? println("TUI is already open.") : ui()
    elseif cmd == "close"
        _is_tui_open() ? toggle() : println("TUI is not open.")
    elseif cmd in ("ws", "vars", "workspace")
        workspace(rest)
    elseif cmd in ("ls", "list", "procs", "find", "search")
        list_procedures(rest)
    elseif cmd == "show"
        isempty(rest) && throw(ArgumentError("usage: show <procedure>"))
        _load_procedures!()
        sym = Symbol(rest)
        haskey(_procedures, sym) || throw(ArgumentError("no procedure named '$rest'"))
        return _procedures[sym]
    elseif cmd == "run"
        isempty(rest) && throw(ArgumentError("usage: run <name> [args...]  or  run name(args...)"))
        return _run_from_string(rest)
    elseif cmd == "make"
        parts = split(rest)
        isempty(parts) && throw(ArgumentError("usage: make <name> [N]"))
        n = length(parts) >= 2 ? something(tryparse(Int, parts[2]), 0) : 0
        make_procedure(Symbol(parts[1]); last = n)
    elseif cmd in ("rec", "record")
        record(isempty(rest) ? _next_proc_name() : Symbol(rest))
    elseif cmd in ("stop", "record_stop")
        _recording[] ? record_stop() : println("No recording in progress (use `shutdown` to stop the jEMach watcher).")
    elseif cmd in ("inspect", "i")
        isempty(rest) && throw(ArgumentError("usage: inspect <expr>"))
        inspect_var(Main, rest)
    elseif cmd == "save"
        save_clean_session()
    elseif cmd in ("reload", "autoload")
        autoload_procedures!()
        publish_state()
        println("✓ Loaded $(length(_procedures)) procedure(s) into Main")
    elseif cmd in ("status", "info")
        status()
        info = terminal_info()
        for k in (:term, :term_program, :tmux, :zellij, :kitty, :ghostty, :rex)
            println("  ", rpad(string(k), 14), info[k])
        end
        println("  ", rpad("procedures", 14), length(_procedures), "   recording: ", _recording[] ? string(_record_name[]) : "no")
        println("  ", rpad("tui open", 14), _is_tui_open())
    elseif cmd in ("shutdown", "quit")
        stop()
    else
        _load_procedures!()
        haskey(_procedures, Symbol(m.captures[1])) && return _run_from_string(s)
        println("Unknown jemach command '$(m.captures[1])'. Type `help` for the list of commands.")
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
    for sym in names(Main; all = true, imported = true)
        n = string(sym)
        (_skip_name(n) || startswith(n, "#") || startswith(n, "_")) && continue
        push!(out, n)
    end
    return out
end

function _jemach_completions(partial::AbstractString)
    wm = match(r"(\S*)$", partial)
    word = isnothing(wm) ? "" : String(wm.captures[1])
    before = String(codeunits(partial)[1:(ncodeunits(partial) - ncodeunits(word))])
    words_before = split(before)
    proc_names = String[string(k) for k in keys(_procedures)]
    cands = if isempty(words_before)
        vcat(_JEMACH_COMMANDS, proc_names)
    else
        c = lowercase(words_before[1])
        if c in ("run", "show", "ls", "find") && length(words_before) == 1
            proc_names
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

function _install_jemach_mode!(repl)
    (hasproperty(repl, :interface) && isdefined(repl, :interface)) || return nothing
    iface = repl.interface
    any(m -> m isa LineEdit.Prompt && m.complete isa JEMachCompletionProvider, iface.modes) && return nothing
    main = iface.modes[1]
    main isa LineEdit.Prompt || return nothing

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
                        @async (sleep(0.02); publish_state())
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
