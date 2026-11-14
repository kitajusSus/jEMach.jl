# State serialization, UNIX domain socket RPC server/broadcast, and live REPL evaluation.

const _task_ref = Ref{Union{Task, Nothing}}(nothing)
const _running = Ref{Bool}(false)
const _socket_clients = Set{Sockets.PipeEndpoint}()
const _server_ref = Ref{Union{Sockets.PipeServer, Nothing}}(nothing)
const _last_serialized_json = Ref{String}("")
const _last_serialized_body = Ref{String}("")
const _tui_pane_ref = Ref{String}("")
const _tui_backend_ref = Ref{Symbol}(:none)
const _tui_proc_ref = Ref{Union{Base.Process, Nothing}}(nothing)

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
    buf = IOBuffer()
    dst_buf = Vector{UInt8}(undef, 4096)

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
        write(buf, '}')
    end

    write(buf, "],\"history\":[")
    recent_cmds = get_recent_commands(limit = HISTORY_LIMIT)
    for (i, cmd) in enumerate(recent_cmds)
        i > 1 && write(buf, ',')
        _write_json_str(buf, cmd, dst_buf)
    end
    write(buf, "]}")
    return String(take!(buf))
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

function _repl_eval(code::AbstractString; silent::Bool = false, record_history::Bool = true)
    clean_code = strip(String(code))
    isempty(clean_code) && return

    if silent
        try
            Base.invokelatest(Core.eval, Main, Meta.parseall(clean_code))
        catch e
            @warn "jEMach background eval failed" exception = e
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

    try
        val = Base.invokelatest(Core.eval, Main, Meta.parseall(clean_code))
        try
            Core.eval(Main, Expr(:(=), :ans, QuoteNode(val)))
        catch
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
        Base.invokelatest(Base.showerror, stdout, e, catch_backtrace())
        println(stdout)
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
        @async _repl_eval(code; silent = true)
    elseif cmd == "insert"
        text = string(get(msg, "text", ""))
        move_left = Int(get(msg, "move_left", 0))
        @async _repl_insert(text, move_left)
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
                                    push!(_socket_clients, client)
                                    if !isempty(_last_serialized_json[])
                                        write(client, _last_serialized_json[] * "\n")
                                        flush(client)
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
    return try
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
