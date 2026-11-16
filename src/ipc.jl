const _task_ref = Ref{Union{Task, Nothing}}(nothing)
const _running = Ref{Bool}(false)
const _socket_clients = Set{Sockets.PipeEndpoint}()
const _server_ref = Ref{Union{Sockets.PipeServer, Nothing}}(nothing)
const _last_serialized_json = Ref{String}("")
const _last_serialized_body = Ref{String}("")
const _tui_pane_ref = Ref{String}("")
const _tui_backend_ref = Ref{Symbol}(:none)
const _tui_proc_ref = Ref{Union{Base.Process, Nothing}}(nothing)
const _json_dst_buf = Vector{UInt8}(undef, 4096)
const _serialize_lock = ReentrantLock()
const _publish_lock = ReentrantLock()
const _hasmethod_cache = Dict{Symbol, Bool}()
const _hasmethod_world_ref = Ref{UInt64}(UInt64(0))

_has_active_tui_clients()::Bool = any(isopen, _socket_clients)

function _write_json_str_col(buf::IOBuffer, vals::Vector{String}, dst_buf::Vector{UInt8})
    write(buf, '[')
    @inbounds for i in eachindex(vals)
        i > 1 && write(buf, ',')
        _write_json_str(buf, vals[i], dst_buf)
    end
    return write(buf, ']')
end

function _write_json_int_col(buf::IOBuffer, vals::Vector{Int32})
    write(buf, '[')
    @inbounds for i in eachindex(vals)
        i > 1 && write(buf, ',')
        print(buf, vals[i])
    end
    return write(buf, ']')
end

function _serialize_dod_body(t::WorkspaceTable, packages_data::Vector)::String
    return lock(_serialize_lock) do
        buf = IOBuffer()
        dst_buf = _json_dst_buf

        write(buf, "\"backend\":")
        _write_json_str(buf, string(detect_backend()), dst_buf)
        write(buf, ",\"columns\":{\"names\":")
        _write_json_str_col(buf, t.names, dst_buf)
        write(buf, ",\"kinds\":")
        _write_json_str_col(buf, t.kinds, dst_buf)
        write(buf, ",\"types\":")
        _write_json_str_col(buf, t.types, dst_buf)
        write(buf, ",\"values\":")
        _write_json_str_col(buf, t.values, dst_buf)
        write(buf, ",\"exprs\":")
        _write_json_str_col(buf, t.exprs, dst_buf)
        write(buf, ",\"modules\":")
        _write_json_str_col(buf, t.modules, dst_buf)
        write(buf, ",\"depths\":")
        _write_json_int_col(buf, t.depths)
        write(buf, ",\"parent_indices\":")
        _write_json_int_col(buf, t.parent_indices)

        write(buf, ",\"has_children\":[")
        @inbounds for i in eachindex(t.has_children)
            i > 1 && write(buf, ',')
            write(buf, t.has_children[i] ? "true" : "false")
        end

        write(buf, "]},\"packages\":[")
        for (i, pkg) in enumerate(packages_data)
            i > 1 && write(buf, ',')
            write(buf, "{\"name\":")
            _write_json_str(buf, get(pkg, "name", ""), dst_buf)
            write(buf, ",\"version\":")
            _write_json_str(buf, get(pkg, "version", ""), dst_buf)
            write(buf, '}')
        end

        write(buf, "],\"procedures\":[")
        proc_list = sort(collect(values(_procedures)), by = p -> string(p.name))
        for (i, p) in enumerate(proc_list)
            i > 1 && write(buf, ',')
            write(buf, "{\"name\":")
            _write_json_str(buf, string(p.name), dst_buf)
            write(buf, ",\"signature\":")
            _write_json_str(buf, p.signature, dst_buf)
            write(buf, ",\"file\":")
            _write_json_str(buf, p.file, dst_buf)
            write(buf, ",\"doc\":")
            _write_json_str(buf, p.doc, dst_buf)
            write(buf, ",\"code\":")
            _write_json_str(buf, p.code, dst_buf)
            write(buf, ",\"time_ms\":")
            print(buf, p.last_run_time_ms)
            write(buf, ",\"alloc_bytes\":")
            print(buf, p.last_run_alloc_bytes)
            write(buf, ",\"status\":")
            _write_json_str(buf, string(p.last_run_status), dst_buf)
            write(buf, ",\"last_run\":")
            _write_json_str(buf, p.last_run_at, dst_buf)
            write(buf, ",\"last_run_cmd\":")
            _write_json_str(buf, p.last_run_cmd, dst_buf)
            write(buf, ",\"last_error\":")
            _write_json_str(buf, p.last_error, dst_buf)
            write(buf, ",\"last_error_detail\":")
            _write_json_str(buf, p.last_error_detail, dst_buf)
            write(buf, ",\"last_error_line\":")
            print(buf, p.last_error_line)
            write(buf, ",\"last_error_cmd\":")
            _write_json_str(buf, p.last_error_cmd, dst_buf)
            cur_world = Base.get_world_counter()
            if _hasmethod_world_ref[] != cur_world
                empty!(_hasmethod_cache)
                _hasmethod_world_ref[] = cur_world
            end
            needs_args = get(_hasmethod_cache, p.name, nothing)
            if isnothing(needs_args)
                needs_args = false
                if Base.invokelatest(isdefined, Main, p.name)
                    fn_obj = try
                        Base.invokelatest(getfield, Main, p.name)
                    catch
                        nothing
                    end
                    if fn_obj isa Function
                        needs_args = !Base.invokelatest(hasmethod, fn_obj, Tuple{})
                    end
                else
                    m_sig = match(r"^[^(]+\((.*)\)$"s, strip(p.signature))
                    if !isnothing(m_sig)
                        inner_sig = strip(m_sig.captures[1])
                        !isempty(inner_sig) && !startswith(inner_sig, ";") && !occursin("=", inner_sig) && (needs_args = true)
                    end
                end
                _hasmethod_cache[p.name] = needs_args
            end
            write(buf, ",\"needs_args\":")
            write(buf, needs_args ? "true" : "false")
            write(buf, ",\"origin\":")
            _write_json_str(buf, string(p.origin), dst_buf)
            write(buf, ",\"edit_code\":")
            _write_json_str(buf, p.edit_code, dst_buf)
            write(buf, ",\"generation\":")
            print(buf, p.generation)
            write(buf, ",\"func_start_line\":")
            print(buf, p.func_start_line)
            write(buf, ",\"last_args\":")
            _write_json_str(buf, p.last_args_str, dst_buf)
            write(buf, '}')
        end

        write(buf, "],\"failed_commands\":[")
        for (i, fc) in enumerate(_failed_commands)
            i > 1 && write(buf, ',')
            write(buf, "{\"id\":")
            print(buf, fc.id)
            write(buf, ",\"cmd\":")
            _write_json_str(buf, fc.cmd, dst_buf)
            write(buf, ",\"source\":")
            _write_json_str(buf, fc.source, dst_buf)
            write(buf, ",\"proc_name\":")
            _write_json_str(buf, fc.proc_name, dst_buf)
            write(buf, ",\"error\":")
            _write_json_str(buf, fc.error_msg, dst_buf)
            write(buf, ",\"error_detail\":")
            _write_json_str(buf, fc.error_detail, dst_buf)
            write(buf, ",\"error_line\":")
            print(buf, fc.error_line)
            write(buf, ",\"failed_stmt\":")
            _write_json_str(buf, fc.failed_stmt, dst_buf)
            write(buf, ",\"timestamp\":")
            _write_json_str(buf, fc.timestamp, dst_buf)
            write(buf, '}')
        end

        split_hist = get_split_history(limit = HISTORY_LIMIT)
        recent_cmds = split_hist.commands
        write(buf, "],\"history\":[")
        for (i, cmd) in enumerate(recent_cmds)
            i > 1 && write(buf, ',')
            _write_json_str(buf, cmd, dst_buf)
        end
        write(buf, "],\"history_prev_count\":")
        print(buf, split_hist.prev_count)
        write(buf, ",\"history_statuses\":[")
        for (i, cmd) in enumerate(recent_cmds)
            i > 1 && write(buf, ',')
            st_sym = get(_cmd_outcomes, String(strip(cmd)), :unknown)
            st_str = st_sym == :ok ? "ok" : st_sym == :error ? "error" : ""
            _write_json_str(buf, st_str, dst_buf)
        end
        write(buf, "]}")
        return String(take!(buf))
    end
end

function _serialize_dod(t::WorkspaceTable, packages_data::Vector)::String
    return "{\"timestamp\":" * string(round(Int, time())) * "," * _serialize_dod_body(t, packages_data)
end

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
    is_proc_runner = startswith(clean_code, "jEMach.run_procedure(")
    is_internal = startswith(clean_code, "jEMach.inspect_var(") ||
        startswith(clean_code, "jEMach.save_clean_session(") ||
        startswith(clean_code, "jEMach.reload_procedure(") ||
        startswith(clean_code, "jEMach.save_procedure(") ||
        startswith(clean_code, "jEMach.edit_procedure(") ||
        startswith(clean_code, "jEMach._")

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
        bt = catch_backtrace()
        Base.invokelatest(Base.showerror, stdout, e, bt)
        println(stdout)
        if !(is_proc_runner && !(e isa Base.Meta.ParseError))
            _record_command_outcome!(clean_code, false, e, bt; source = "tui")
        end
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
    end
end

# ---------------------------------------------------------------------------
# UNIX socket server & state broadcaster
# ---------------------------------------------------------------------------

function _disconnect_socket_clients!()
    stop_msg = "{\"event\":\"stop\",\"action\":\"close\"}\n"
    for client in _socket_clients
        try
            if isopen(client)
                write(client, stop_msg)
                flush(client)
                close(client)
            end
        catch
        end
    end
    empty!(_socket_clients)
    return nothing
end

function _start_socket_server()
    path = SOCKET_PATH[]
    if !isnothing(_server_ref[])
        try
            close(_server_ref[])
        catch
        end
        _server_ref[] = nothing
    end
    try
        rm(path; force = true)
    catch
    end
    return try
        server = Sockets.listen(path)
        _server_ref[] = server
        @async begin
            while _running[] && isopen(server)
                try
                    client = Sockets.accept(server)
                    @async begin
                        try
                            if isopen(client)
                                line = readline(client)
                                if startswith(line, "SUB")
                                    had_clients = _has_active_tui_clients()
                                    push!(_socket_clients, client)
                                    if isempty(_last_serialized_json[])
                                        Base.invokelatest(publish_state)
                                    else
                                        write(client, _last_serialized_json[] * "\n")
                                        flush(client)
                                        !had_clients && @async Base.invokelatest(publish_state)
                                    end
                                    while _running[] && isopen(client) && !eof(client)
                                        cmd_line = readline(client)
                                        !isempty(strip(cmd_line)) && _handle_socket_message(cmd_line)
                                    end
                                elseif !isempty(strip(line))
                                    _handle_socket_message(line)
                                    try
                                        close(client)
                                    catch
                                    end
                                end
                            end
                        catch
                        finally
                            delete!(_socket_clients, client)
                        end
                    end
                catch
                    break
                end
            end
        end
    catch e
        @warn "jEMach Socket Server failed to listen on $path" exception = e
    end
end

function _stop_socket_server()
    _disconnect_socket_clients!()
    if !isnothing(_server_ref[])
        try
            close(_server_ref[])
        catch
        end
        _server_ref[] = nothing
    end
    return try
        rm(SOCKET_PATH[]; force = true)
    catch
    end
end

function publish_state()
    return lock(_publish_lock) do
        try
            if _running[] && (isnothing(_server_ref[]) || !isopen(_server_ref[]) || !ispath(SOCKET_PATH[]))
                _start_socket_server()
            end
            # Enter latest world age so background tasks see bindings/methods defined after __init__
            state = Base.invokelatest(_collect_state_dod!, _shared_workspace_table[])
            pkgs = Base.invokelatest(_get_packages)
            body = _serialize_dod_body(state, pkgs)

            body == _last_serialized_body[] && return
            _last_serialized_body[] = body
            json = "{\"timestamp\":" * string(round(Int, time())) * "," * body
            _last_serialized_json[] = json

            temp_file = STATE_FILE[] * ".tmp"
            open(temp_file, "w") do f
                write(f, json)
            end
            mv(temp_file, STATE_FILE[]; force = true)

            msg = json * "\n"
            dead_clients = Sockets.PipeEndpoint[]
            for client in _socket_clients
                try
                    if isopen(client)
                        write(client, msg)
                        flush(client)
                    else
                        push!(dead_clients, client)
                    end
                catch
                    push!(dead_clients, client)
                end
            end
            for dc in dead_clients
                delete!(_socket_clients, dc)
            end
        catch e
            @warn "jEMach Watcher error" exception = e
        end
    end
end
