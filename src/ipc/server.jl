# ---------------------------------------------------------------------------
# UNIX socket server & state broadcaster
# ---------------------------------------------------------------------------

function _disconnect_socket_clients!()
    stop_msg = "{\"event\":\"stop\",\"action\":\"close\"}\n"
    for client in collect(_socket_clients)
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
    _reset_client_view_state!()
    return nothing
end

function _broadcast_event(json_line::AbstractString)
    !_has_active_tui_clients() && return nothing
    msg = endswith(json_line, "\n") ? String(json_line) : (String(json_line) * "\n")
    dead_clients = Sockets.PipeEndpoint[]
    for client in collect(_socket_clients)
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
    return nothing
end

function _format_busy_event(busy::Bool, started_at::Float64, elapsed::Float64, cmd::AbstractString, ok::Bool)::String
    buf = IOBuffer()
    write(buf, "{\"event\":\"busy\",\"busy\":", busy ? "true" : "false")
    write(buf, ",\"started_at\":")
    print(buf, round(started_at; digits = 3))
    write(buf, ",\"elapsed\":")
    print(buf, round(elapsed; digits = 2))
    write(buf, ",\"ok\":", ok ? "true" : "false")
    write(buf, ",\"cmd\":")
    _write_json_str(buf, String(cmd))
    write(buf, "}")
    return String(take!(buf))
end

function _set_repl_busy!(busy::Bool, cmd::AbstractString = ""; ok::Bool = true)
    now_t = time()
    if busy
        short_cmd = _truncate_chars(replace(strip(String(cmd)), '\n' => ' '), 60)
        _repl_busy[] = true
        _repl_busy_since[] = now_t
        _repl_busy_cmd[] = short_cmd
        _has_active_tui_clients() && _broadcast_event(_format_busy_event(true, now_t, 0.0, short_cmd, true))
    else
        was_busy = _repl_busy[]
        started = _repl_busy_since[]
        elapsed = (was_busy && started > 0.0) ? max(0.0, now_t - started) : 0.0
        last_c = isempty(strip(cmd)) ? _repl_busy_cmd[] : _truncate_chars(replace(strip(String(cmd)), '\n' => ' '), 60)
        _repl_busy[] = false
        _has_active_tui_clients() && _broadcast_event(_format_busy_event(false, started, elapsed, last_c, ok))
    end
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
        chmod(path, 0o600)
        _server_ref[] = server
        _advertise_session!()
        @async begin
            while _running[] && isopen(server)
                try
                    client = Sockets.accept(server)
                    @async begin
                        try
                            if isopen(client)
                                line = readline(client)
                                if line == "SUB"
                                    had_clients = _has_active_tui_clients()
                                    push!(_socket_clients, client)
                                    if isempty(_last_serialized_json[])
                                        Base.invokelatest(publish_state)
                                    else
                                        write(client, _last_serialized_json[] * "\n")
                                        flush(client)
                                        !had_clients && @async Base.invokelatest(publish_state)
                                    end
                                    if _repl_busy[]
                                        ev = _format_busy_event(true, _repl_busy_since[], max(0.0, time() - _repl_busy_since[]), _repl_busy_cmd[], true)
                                        write(client, ev * "\n")
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
                        catch e
                            @debug "jEMach socket client disconnected" exception = (e, catch_backtrace())
                        finally
                            delete!(_socket_clients, client)
                            !_has_active_tui_clients() && _reset_client_view_state!()
                            close(client)
                        end
                    end
                catch
                    break
                end
            end
        end
    catch e
        @warn "jEMach Socket Server failed to listen on $path" exception = e
        rethrow()
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
            _ensure_session!()
            if _running[] && (isnothing(_server_ref[]) || !isopen(_server_ref[]) || !ispath(SOCKET_PATH[]))
                _start_socket_server()
            end
            # Enter latest world age so background tasks see bindings/methods defined after __init__
            state = Base.invokelatest(_collect_state_dod!, _shared_workspace_table[])
            pkgs = Base.invokelatest(_get_packages)
            body = _serialize_dod_body(state, pkgs)

            body == _last_serialized_body[] && isfile(STATE_FILE[]) && return
            json = "{\"timestamp\":" * string(round(Int, time())) * "," * body

            temp_file = STATE_FILE[] * ".tmp"
            open(temp_file, "w") do f
                write(f, json)
            end
            mv(temp_file, STATE_FILE[]; force = true)
            _last_serialized_body[] = body
            _last_serialized_json[] = json

            msg = json * "\n"
            dead_clients = Sockets.PipeEndpoint[]
            for client in collect(_socket_clients)
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
