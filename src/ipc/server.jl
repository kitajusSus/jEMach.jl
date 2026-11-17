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
