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

const _lazy_children_mode = Ref{Bool}(false)
const _expanded_paths = Set{String}()
const _expanded_lock = ReentrantLock()
const _inspector_json = Ref{String}("null")

const _repl_busy = Ref{Bool}(false)
const _repl_busy_since = Ref{Float64}(0.0)
const _repl_busy_cmd = Ref{String}("")

_has_active_tui_clients()::Bool = any(isopen, _socket_clients)

function _is_path_expanded(path::String)::Bool
    !_lazy_children_mode[] && return true
    return lock(_expanded_lock) do
        path in _expanded_paths
    end
end

function _set_expanded_paths!(paths_raw::AbstractString)
    lock(_expanded_lock) do
        _lazy_children_mode[] = true
        empty!(_expanded_paths)
        for p in split(paths_raw, '\n')
            sp = String(strip(p))
            !isempty(sp) && push!(_expanded_paths, sp)
        end
    end
    return nothing
end

function _reset_client_view_state!()
    lock(_expanded_lock) do
        _lazy_children_mode[] = false
        empty!(_expanded_paths)
    end
    _inspector_json[] = "null"
    return nothing
end


