# ---------------------------------------------------------------------------
# Bidirectional REPL evaluation from socket commands
# ---------------------------------------------------------------------------

function _get_mistate()
    if isdefined(Base, :active_repl)
        repl = Base.active_repl
        hasproperty(repl, :mistate) && !isnothing(repl.mistate) && return repl.mistate
    end
    return nothing
end

function _clear_repl_input_area(s)
    return try
        st = LineEdit.state(s)
        Base.invokelatest(LineEdit.clear_input_area, st)
        true
    catch
        print(stdout, "\r\e[2K")
        false
    end
end

function _repl_eval(code::AbstractString; silent::Bool = false, record_history::Bool = true, filename::AbstractString = "REPL[TUI]", proc_hint::String = "")
    clean_code = strip(String(code))
    isempty(clean_code) && return

    if silent
        try
            Base.invokelatest(Core.eval, Main, Meta.parseall(clean_code; filename = String(filename)))
            _capture_repl_definitions!(clean_code)
            if !isempty(proc_hint)
                sym = Symbol(proc_hint)
                if haskey(_procedures, sym) && _procedures[sym].last_run_status == :error &&
                        startswith(_procedures[sym].last_run_cmd, "edit(")
                    p = _procedures[sym]
                    p.last_run_status = :never
                    p.last_error = ""
                    p.last_error_detail = ""
                    p.last_error_line = 0
                    p.last_error_cmd = ""
                end
            end
        catch e
            bt = catch_backtrace()
            if !isempty(proc_hint) && haskey(_procedures, Symbol(proc_hint))
                p = _procedures[Symbol(proc_hint)]
                summary, detail, err_line, err_stmt = _format_error_pair(e, bt; source_code = clean_code)
                p.last_run_status = :error
                p.last_run_at = Dates.format(Dates.now(), "HH:MM:SS")
                p.last_run_cmd = "edit(" * proc_hint * ")"
                p.last_error = summary
                p.last_error_detail = detail
                p.last_error_line = err_line
                p.last_error_cmd = err_stmt
            else
                @warn "jEMach background eval failed" exception = e
            end
        end
        return Base.invokelatest(publish_state)
    end

    s = _get_mistate()
    if !isnothing(s)
        _clear_repl_input_area(s)
        print(stdout, "\e[32m\e[1mjulia> \e[0m", clean_code, "\n")
        flush(stdout)
    else
        println(stdout, "\njulia> ", clean_code)
    end

    record_history && _append_repl_history(clean_code)
    is_proc_runner = startswith(clean_code, "jEMach.run_procedure(") ||
        startswith(clean_code, "jEMach.benchmark_procedure(")
    is_internal = startswith(clean_code, "jEMach.inspect_var(") ||
        startswith(clean_code, "jEMach.save_clean_session(") ||
        startswith(clean_code, "jEMach.reload_procedure(") ||
        startswith(clean_code, "jEMach.save_procedure(") ||
        startswith(clean_code, "jEMach.edit_procedure(") ||
        startswith(clean_code, "jEMach.generate_procedure_test(") ||
        startswith(clean_code, "jEMach._")

    !is_internal && _set_repl_busy!(true, clean_code)
    eval_ok = true
    try
        parsed_ast = Meta.parseall(clean_code; filename = String(filename))
        val = Base.invokelatest(Core.eval, Main, parsed_ast)
        try
            Core.eval(Main, Expr(:(=), :ans, QuoteNode(val)))
        catch
        end

        _capture_repl_definitions!(clean_code)
        if !is_proc_runner && !is_internal
            _record_command_outcome!(clean_code, true; source = "tui")
            _maybe_capture_plot!(val, clean_code)
        end

        is_self_printing = startswith(clean_code, "println(") ||
            startswith(clean_code, "print(") ||
            startswith(clean_code, "dump(") ||
            startswith(clean_code, "jEMach.")
        if val !== nothing && !endswith(clean_code, ";") && !is_self_printing
            Base.invokelatest(show, IOContext(stdout, :limit => true, :color => true), MIME("text/plain"), val)
            println(stdout)
        end
    catch e
        eval_ok = false
        bt = catch_backtrace()
        Base.invokelatest(Base.showerror, stdout, e, bt)
        println(stdout)
        if !(is_proc_runner && !(e isa Base.Meta.ParseError))
            _record_command_outcome!(clean_code, false, e, bt; source = "tui")
        end
    finally
        !is_internal && _set_repl_busy!(false, clean_code; ok = eval_ok)
    end

    println(stdout)
    flush(stdout)
    if !isnothing(s)
        try
            le = parentmodule(typeof(s))
            Base.invokelatest(le.refresh_line, s)
        catch
        end
    end
    return Base.invokelatest(publish_state)
end

function _repl_insert(text::AbstractString, move_left::Int = 0)
    s = _get_mistate()
    isnothing(s) && return
    return try
        le = parentmodule(typeof(s))
        Base.invokelatest(le.edit_insert, s, String(text))
        for _ in 1:move_left
            Base.invokelatest(le.edit_move_left, s)
        end
        Base.invokelatest(le.refresh_line, s)
    catch
    end
end

function _repl_replace_input(text::AbstractString, move_left::Int = 0; switch_to_main::Bool = false)
    s = _get_mistate()
    isnothing(s) && return
    return try
        le = parentmodule(typeof(s))
        if switch_to_main && isdefined(Base, :active_repl) && hasproperty(Base.active_repl, :interface)
            modes = Base.active_repl.interface.modes
            if !isempty(modes) && Base.invokelatest(le.mode, s) !== modes[1]
                Base.invokelatest(le.transition, s, modes[1])
            end
        end
        ps = Base.invokelatest(le.state, s)
        Base.invokelatest(le.push_undo, ps)
        Base.invokelatest(le.replace_line, ps, String(text), true)
        for _ in 1:move_left
            Base.invokelatest(le.edit_move_left, s)
        end
        Base.invokelatest(le.refresh_line, s)
    catch
    end
end

_repl_switch_to_main_and_replace(text::AbstractString, move_left::Int = 0) =
    _repl_replace_input(text, move_left; switch_to_main = true)

function _repl_clear()
    s = _get_mistate()
    return try
        print(stdout, "\e[2J\e[H")
        flush(stdout)
        if !isnothing(s)
            le = parentmodule(typeof(s))
            Base.invokelatest(le.refresh_line, s)
        end
    catch
    end
end

function _handle_socket_message(line::AbstractString)
    msg = _parse_json_cmd(line)
    isempty(msg) && return
    cmd = get(msg, "cmd", get(msg, "action", ""))
    return if cmd == "eval"
        code = string(get(msg, "code", ""))
        rec_hist = Bool(get(msg, "history", true))
        @async _repl_eval(code; silent = false, record_history = rec_hist)
    elseif cmd == "eval_silent"
        code = string(get(msg, "code", ""))
        fname = string(get(msg, "filename", "REPL[TUI]"))
        phint = string(get(msg, "proc_name", ""))
        @async _repl_eval(code; silent = true, filename = fname, proc_hint = phint)
    elseif cmd == "insert"
        text = string(get(msg, "text", ""))
        move_left = Int(get(msg, "move_left", 0))
        @async _repl_insert(text, move_left)
    elseif cmd == "replace_input"
        text = string(get(msg, "text", ""))
        move_left = Int(get(msg, "move_left", 0))
        @async _repl_replace_input(text, move_left; switch_to_main = true)
    elseif cmd == "clear"
        @async _repl_clear()
    elseif cmd == "set_expanded"
        paths = string(get(msg, "paths", ""))
        _set_expanded_paths!(paths)
        @async Base.invokelatest(publish_state)
    elseif cmd == "inspect_slice"
        mod_s = string(get(msg, "mod", "Main"))
        expr_s = string(get(msg, "expr", ""))
        r1 = max(1, Int(get(msg, "row", 1)))
        c1 = max(1, Int(get(msg, "col", 1)))
        max_r = clamp(Int(get(msg, "max_rows", 30)), 1, 200)
        max_c = clamp(Int(get(msg, "max_cols", 8)), 1, 30)
        @async begin
            _inspector_json[] = Base.invokelatest(_compute_inspector_json, mod_s, expr_s, r1, c1, max_r, max_c)
            Base.invokelatest(publish_state)
        end
    elseif cmd == "clear_inspector"
        _inspector_json[] = "null"
        @async Base.invokelatest(publish_state)
    end
end

