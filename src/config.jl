# Path resolution, portable Zig native accelerator loader, and JSON helpers.

const STATE_FILE = Ref{String}("/tmp/jl_tui_state.json")
const SOCKET_PATH = Ref{String}("/tmp/jemach.sock")
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

_get_safe_name(proj_dir::String)::String = replace(proj_dir, r"[^a-zA-Z0-9]" => "_")

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

# ---------------------------------------------------------------------------
# Minimal JSON serializer & command parser (no external dependencies)
# ---------------------------------------------------------------------------

function _write_json_str_julia(buf::IO, s::AbstractString)
    if s isa String
        cu = codeunits(s)
        clean = true
        @inbounds for b in cu
            if b < 0x20 || b == 0x22 || b == 0x5c
                clean = false
                break
            end
        end
        if clean
            write(buf, UInt8(0x22))
            write(buf, cu)
            return write(buf, UInt8(0x22))
        end
    end
    write(buf, '"')
    for c in s
        if c == '"'
            write(buf, "\\\"")
        elseif c == '\\'
            write(buf, "\\\\")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        elseif c == '\b'
            write(buf, "\\b")
        elseif c == '\f'
            write(buf, "\\f")
        elseif iscntrl(c)
            write(buf, "\\u$(lpad(string(Int(c), base = 16), 4, '0'))")
        else
            write(buf, c)
        end
    end
    return write(buf, '"')
end

function _write_json_str(buf::IOBuffer, s::String, dst_buf::Vector{UInt8})
    isempty(s) && return write(buf, "\"\"")
    fn = _zig_escape_json_ptr[]
    if fn != C_NULL
        nb = ncodeunits(s)
        need = 6 * nb + 2
        need > length(dst_buf) && resize!(dst_buf, need)
        n = GC.@preserve s dst_buf ccall(
            fn, Int64, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
            pointer(s), nb, pointer(dst_buf), length(dst_buf)
        )
        if n > 0
            return GC.@preserve dst_buf unsafe_write(buf, pointer(dst_buf), UInt(n))
        end
    end
    return _write_json_str_julia(buf, s)
end

_write_json_str(buf::IO, s::AbstractString, ::Vector{UInt8}) = _write_json_str_julia(buf, s)
_write_json_str(buf::IO, s::AbstractString) = _write_json_str_julia(buf, s)

function _parse_json_cmd(s::AbstractString)::Dict{String, Any}
    res = Dict{String, Any}()
    str = strip(s)
    startswith(str, "CMD ") && (str = strip(str[5:end]))
    (!startswith(str, "{") || !endswith(str, "}")) && return res

    pos = nextind(str, firstindex(str))
    last_i = prevind(str, lastindex(str))

    function skip_ws(i)
        while i <= last_i && (str[i] in (' ', '\t', '\n', '\r'))
            i = nextind(str, i)
        end
        return i
    end

    function read_str(i)
        (i > last_i || str[i] != '"') && return ("", i)
        i = nextind(str, i)
        buf = IOBuffer()
        while i <= last_i
            c = str[i]
            if c == '"'
                return (String(take!(buf)), nextind(str, i))
            elseif c == '\\'
                i = nextind(str, i)
                i > last_i && break
                esc_c = str[i]
                if esc_c == '"'
                    write(buf, '"')
                elseif esc_c == '\\'
                    write(buf, '\\')
                elseif esc_c == 'n'
                    write(buf, '\n')
                elseif esc_c == 'r'
                    write(buf, '\r')
                elseif esc_c == 't'
                    write(buf, '\t')
                else
                    write(buf, esc_c)
                end
            else
                write(buf, c)
            end
            i = nextind(str, i)
        end
        return (String(take!(buf)), i)
    end

    while pos <= last_i
        pos = skip_ws(pos)
        pos > last_i && break
        if str[pos] == ','
            pos = skip_ws(nextind(str, pos))
        end
        (pos > last_i || str[pos] != '"') && break
        key, pos = read_str(pos)
        pos = skip_ws(pos)
        (pos > last_i || str[pos] != ':') && break
        pos = skip_ws(nextind(str, pos))
        pos > last_i && break

        if str[pos] == '"'
            val, pos = read_str(pos)
            res[key] = val
        elseif isdigit(str[pos]) || str[pos] == '-'
            start_num = pos
            while pos <= last_i && (isdigit(str[pos]) || str[pos] in ('-', '.'))
                pos = nextind(str, pos)
            end
            num_str = SubString(str, start_num, prevind(str, pos))
            res[key] = something(tryparse(Int, num_str), tryparse(Float64, num_str), 0)
        elseif startswith(SubString(str, pos), "true")
            res[key] = true
            pos = nextind(str, pos, 4)
        elseif startswith(SubString(str, pos), "false")
            res[key] = false
            pos = nextind(str, pos, 5)
        else
            break
        end
    end
    return res
end
