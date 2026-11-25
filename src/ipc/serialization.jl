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

function _write_json_int64_col(buf::IOBuffer, vals::Vector{Int64})
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
        write(buf, ",\"revise\":")
        _write_json_str(buf, _get_revise_status(), dst_buf)
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
        write(buf, ",\"sizes\":")
        _write_json_int64_col(buf, t.sizes)

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
            write(buf, ",\"prev_time_ms\":")
            print(buf, p.prev_time_ms)
            write(buf, ",\"prev_alloc_bytes\":")
            print(buf, p.prev_alloc_bytes)
            write(buf, ",\"prev_gen\":")
            print(buf, p.prev_generation)
            write(buf, ",\"bench_samples\":")
            print(buf, p.bench_samples)
            write(buf, ",\"min_time_ms\":")
            print(buf, p.min_time_ms)
            write(buf, ",\"max_time_ms\":")
            print(buf, p.max_time_ms)
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
        write(buf, "],\"plots\":[")
        lock(_plots_lock) do
            for (i, pl) in enumerate(_plots)
                i > 1 && write(buf, ',')
                write(buf, "{\"id\":")
                print(buf, pl.id)
                write(buf, ",\"title\":")
                _write_json_str(buf, pl.title, dst_buf)
                write(buf, ",\"timestamp\":")
                _write_json_str(buf, pl.timestamp, dst_buf)
                write(buf, ",\"path\":")
                _write_json_str(buf, pl.filepath, dst_buf)
                write(buf, ",\"width\":")
                print(buf, pl.width)
                write(buf, ",\"height\":")
                print(buf, pl.height)
                write(buf, ",\"bytes\":")
                print(buf, pl.bytes)
                write(buf, '}')
            end
        end
        write(buf, "],\"inspector\":")
        insp = _inspector_json[]
        write(buf, isempty(insp) ? "null" : insp)
        write(buf, "}")
        return String(take!(buf))
    end
end

function _serialize_dod(t::WorkspaceTable, packages_data::Vector)::String
    return "{\"timestamp\":" * string(round(Int, time())) * "," * _serialize_dod_body(t, packages_data)
end

