# Path resolution and optional Zig native accelerator loading.

const STATE_FILE = Ref{String}("")
const SOCKET_PATH = Ref{String}("")
const UPDATE_INTERVAL = 0.5  # seconds between state refreshes

function _get_project_dir()::String
    proj_path = try
        Base.active_project()
    catch
        nothing
    end
    if !isnothing(proj_path) && isfile(proj_path) && !occursin(".julia/environments", proj_path)
        return dirname(proj_path)
    end
    return pwd()
end

_history_path()::String = get(ENV, "JULIA_HISTORY", joinpath(homedir(), ".julia", "logs", "repl_history.jl"))

# Portable native Zig accelerator (built via deps/build.jl into zig/zig-out/lib)
const _zig_lib_handle = Ref{Ptr{Nothing}}(C_NULL)
const _zig_parse_history_ptr = Ref{Ptr{Nothing}}(C_NULL)
const _zig_escape_json_ptr = Ref{Ptr{Nothing}}(C_NULL)
const _zig_proc_scan_ptr = Ref{Ptr{Nothing}}(C_NULL)

struct _ZigProcScanResult
    content_hash::UInt64
    body_start::UInt32
    body_end::UInt32
    func_line::UInt32
    has_doc::UInt8
    has_imports::UInt8
end

function _load_zig_native!()::Bool
    _zig_lib_handle[] != C_NULL && return true
    lib_name = "libjemach_native." * Base.Libc.Libdl.dlext
    lib_path = normpath(joinpath(@__DIR__, "..", "zig", "zig-out", "lib", lib_name))
    !isfile(lib_path) && return false
    return try
        h = Base.Libc.Libdl.dlopen(lib_path)
        p_hist = Base.Libc.Libdl.dlsym(h, :jemach_parse_history_buf; throw_error = false)
        p_json = Base.Libc.Libdl.dlsym(h, :jemach_escape_json_str; throw_error = false)
        p_scan = Base.Libc.Libdl.dlsym(h, :jemach_proc_scan_source; throw_error = false)
        _zig_lib_handle[] = h
        _zig_parse_history_ptr[] = isnothing(p_hist) ? C_NULL : p_hist
        _zig_escape_json_ptr[] = isnothing(p_json) ? C_NULL : p_json
        _zig_proc_scan_ptr[] = isnothing(p_scan) ? C_NULL : p_scan
        true
    catch
        false
    end
end
