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

function _json_skip_ws(io::IO)
    while !eof(io) && peek(io) in (0x20, 0x09, 0x0a, 0x0d)
        read(io, UInt8)
    end
end

function _json_hex4(io::IO)::UInt32
    chars = String(read(io, 4))
    ncodeunits(chars) == 4 && all(isxdigit, chars) || throw(ArgumentError("invalid JSON Unicode escape"))
    return parse(UInt32, chars; base = 16)
end

function _json_read_string(io::IO)::String
    read(io, Char) == '"' || throw(ArgumentError("expected JSON string"))
    out = IOBuffer()
    while !eof(io)
        c = read(io, Char)
        c == '"' && return String(take!(out))
        if c == '\\'
            esc = read(io, Char)
            if esc == 'u'
                cp = _json_hex4(io)
                if 0xd800 <= cp <= 0xdbff
                    read(io, Char) == '\\' && read(io, Char) == 'u' || throw(ArgumentError("missing low surrogate"))
                    low = _json_hex4(io)
                    0xdc00 <= low <= 0xdfff || throw(ArgumentError("invalid low surrogate"))
                    cp = 0x10000 + (cp - 0xd800) * 0x400 + low - 0xdc00
                elseif 0xdc00 <= cp <= 0xdfff
                    throw(ArgumentError("unpaired low surrogate"))
                end
                write(out, Char(cp))
            else
                decoded = esc == '"' ? '"' : esc == '\\' ? '\\' : esc == '/' ? '/' :
                    esc == 'b' ? '\b' : esc == 'f' ? '\f' : esc == 'n' ? '\n' :
                    esc == 'r' ? '\r' : esc == 't' ? '\t' : nothing
                isnothing(decoded) && throw(ArgumentError("invalid JSON escape"))
                write(out, decoded)
            end
        else
            isvalid(c) && UInt32(c) >= 0x20 || throw(ArgumentError("invalid JSON character"))
            write(out, c)
        end
    end
    throw(ArgumentError("unterminated JSON string"))
end

# RPC accepts a flat JSON object. Reject the entire frame on malformed input;
# a partially parsed eval command must never be executed.
function _parse_json_cmd(s::AbstractString)::Dict{String, Any}
    str = strip(s)
    startswith(str, "CMD ") && (str = strip(str[5:end]))
    result = Dict{String, Any}()
    io = IOBuffer(str)
    try
        read(io, Char) == '{' || return result
        _json_skip_ws(io)
        if !eof(io) && peek(io) == UInt8('}')
            read(io, UInt8)
        else
            while true
                _json_skip_ws(io)
                key = _json_read_string(io)
                _json_skip_ws(io)
                read(io, Char) == ':' || throw(ArgumentError("expected colon"))
                _json_skip_ws(io)
                if peek(io) == UInt8('"')
                    result[key] = _json_read_string(io)
                else
                    token_io = IOBuffer()
                    while !eof(io) && !(peek(io) in (0x20, 0x09, 0x0a, 0x0d, UInt8(','), UInt8('}')))
                        write(token_io, read(io, UInt8))
                    end
                    token = String(take!(token_io))
                    if token == "true" || token == "false"
                        result[key] = token == "true"
                    elseif token == "null"
                        result[key] = nothing
                    else
                        occursin(r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$", token) || throw(ArgumentError("invalid JSON value"))
                        number = something(tryparse(Int, token), tryparse(Float64, token), NaN)
                        isfinite(number) || throw(ArgumentError("JSON number out of range"))
                        result[key] = number
                    end
                end
                _json_skip_ws(io)
                sep = read(io, Char)
                sep == '}' && break
                sep == ',' || throw(ArgumentError("expected comma"))
            end
        end
        _json_skip_ws(io)
        eof(io) || throw(ArgumentError("trailing JSON input"))
        return result
    catch e
        e isa InterruptException && rethrow()
        return Dict{String, Any}()
    end
end

