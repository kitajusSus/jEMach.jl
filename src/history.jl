# REPL history parsing (Zig-accelerated with mtime/size cache), filtering, and live sync.

const HIST_START_POS = Ref{Int}(0)
const HISTORY_LIMIT = 60

const _JEMACH_API_PREFIXES = (
    "@jemach", "@inspect", "record(", "record_stop(", "workspace(", "list_procedures(",
    "find_procedures(", "search_procedures(", "autoload_procedures!(", "make_procedure(",
    "using jEMach", "import jEMach",
)

const _JEMACH_SKIP_EXACT = Set([
    "jEMach", "exit()", "quit()", "clear()", "ans",
])

function _is_valid_user_cmd(cmd::AbstractString)::Bool
    s = strip(cmd)
    isempty(s) && return false
    s in _JEMACH_SKIP_EXACT && return false
    if occursin("jEMach.", s) || occursin("save_clean_session", s) ||
            occursin("inspect_var", s) || occursin("publish_state", s)
        return false
    end
    for pfx in _JEMACH_API_PREFIXES
        startswith(s, pfx) && return false
    end
    return true
end

const _HIST_READ_CAP = 131072
const _hist_io_buf = UInt8[]
const _hist_out_buf = UInt8[]
const _hist_offsets = UInt32[]
const _hist_lens = UInt32[]
const _hist_cache_lock = ReentrantLock()
const _hist_cache_path = Ref{String}("")
const _hist_cache_mtime = Ref{Float64}(-1.0)
const _hist_cache_size = Ref{Int64}(-1)
const _hist_cache_pos = Ref{Int64}(-1)
const _hist_cache_limit = Ref{Int}(-1)
const _hist_cache_cmds = String[]

function _invalidate_hist_cache!()
    _hist_cache_size[] = -1
    return nothing
end

function _parse_history_blocks_julia(content::AbstractString)::Vector{String}
    commands = String[]
    current_block = String[]
    block_mode = "julia"

    flush_block!() = begin
        if !isempty(current_block)
            cmd = String(rstrip(join(current_block, "\n")))
            # Only Julia-mode entries are code (skip jemach>, shell>, pkg>, help?> ...)
            block_mode == "julia" && _is_valid_user_cmd(cmd) && push!(commands, cmd)
            empty!(current_block)
        end
    end

    for line in split(content, '\n')
        if startswith(line, "# time:")
            flush_block!()
            block_mode = "julia"
        elseif startswith(line, "# mode:")
            block_mode = lowercase(strip(line[8:end]))
        elseif !startswith(line, "#")
            clean_line = startswith(line, '\t') ? line[2:end] : line
            push!(current_block, clean_line)
        end
    end
    flush_block!()
    return commands
end

function _parse_history_bytes(raw::Vector{UInt8}, skip_partial_first::Bool, limit::Int)::Vector{String}
    (isempty(raw) || limit <= 0) && return String[]
    fn = _zig_parse_history_ptr[]
    if fn != C_NULL
        cap = min(limit, 4096)
        length(_hist_out_buf) < length(raw) && resize!(_hist_out_buf, length(raw))
        length(_hist_offsets) < cap && resize!(_hist_offsets, cap)
        length(_hist_lens) < cap && resize!(_hist_lens, cap)
        n = GC.@preserve raw _hist_out_buf _hist_offsets _hist_lens ccall(
            fn, Int64,
            (Ptr{UInt8}, Csize_t, UInt8, Csize_t, Ptr{UInt8}, Csize_t, Ptr{UInt32}, Ptr{UInt32}),
            pointer(raw), length(raw), skip_partial_first ? UInt8(1) : UInt8(0),
            Csize_t(cap), pointer(_hist_out_buf), length(_hist_out_buf),
            pointer(_hist_offsets), pointer(_hist_lens)
        )
        if n >= 0
            cmds = Vector{String}(undef, Int(n))
            @inbounds for k in 1:Int(n)
                off = Int(_hist_offsets[k]) + 1
                ln = Int(_hist_lens[k])
                cmds[k] = String(view(_hist_out_buf, off:(off + ln - 1)))
            end
            return cmds
        end
    end

    s = String(copy(raw))
    if skip_partial_first
        nl = findfirst('\n', s)
        s = isnothing(nl) ? "" : SubString(s, nextind(s, nl))
    end
    cmds = _parse_history_blocks_julia(s)
    return length(cmds) > limit ? cmds[(end - limit + 1):end] : cmds
end

_parse_history_blocks(content::AbstractString)::Vector{String} = _parse_history_blocks_julia(content)

function get_recent_commands(; limit::Int = 50, session_only::Bool = false)::Vector{String}
    hist_path = _history_path()
    st = try
        stat(hist_path)
    catch
        return String[]
    end
    !isfile(st) && return String[]

    sz = Int64(st.size)
    sz == 0 && return String[]
    pos = (session_only && HIST_START_POS[] > 0) ? min(Int64(HIST_START_POS[]), sz) : max(Int64(0), sz - Int64(_HIST_READ_CAP))
    to_read = Int(sz - pos)
    to_read <= 0 && return String[]

    return lock(_hist_cache_lock) do
        if _hist_cache_path[] == hist_path &&
                _hist_cache_mtime[] == st.mtime &&
                _hist_cache_size[] == sz &&
                _hist_cache_pos[] == pos &&
                _hist_cache_limit[] == limit
            return copy(_hist_cache_cmds)
        end

        resize!(_hist_io_buf, to_read)
        ok = try
            open(hist_path, "r") do f
                pos > 0 && seek(f, pos)
                read!(f, _hist_io_buf)
            end
            true
        catch
            false
        end
        !ok && return String[]

        cmds = _parse_history_bytes(_hist_io_buf, pos > 0, limit)
        _hist_cache_path[] = hist_path
        _hist_cache_mtime[] = st.mtime
        _hist_cache_size[] = sz
        _hist_cache_pos[] = pos
        _hist_cache_limit[] = limit
        empty!(_hist_cache_cmds)
        append!(_hist_cache_cmds, cmds)
        return copy(cmds)
    end
end

get_session_commands()::Vector{String} = get_recent_commands(session_only = true)

function _active_history_provider()
    isdefined(Base, :active_repl) || return nothing
    repl = Base.active_repl
    (hasproperty(repl, :interface) && isdefined(repl, :interface) && !isempty(repl.interface.modes)) || return nothing
    julia_mode = repl.interface.modes[1]
    hasproperty(julia_mode, :hist) || return nothing
    hp = julia_mode.hist
    return hp isa REPL.REPLHistoryProvider ? hp : nothing
end

function _append_history_file(code::AbstractString)
    hist_path = _history_path()
    !isdir(dirname(hist_path)) && return
    _invalidate_hist_cache!()
    return try
        ts = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
        open(hist_path, "a") do f
            write(f, "# time: $(ts) CET\n# mode: julia\n")
            for line in split(code, '\n')
                write(f, "\t", line, "\n")
            end
        end
    catch
    end
end

"""
Append `code` (executed from the TUI) to the REPL history, both on disk and in the
in-memory history of the running REPL, so that it is reachable with the `↑` key.
"""
function _append_repl_history(code::AbstractString)
    !_is_valid_user_cmd(code) && return
    str = String(rstrip(code))
    _invalidate_hist_cache!()
    hp = _active_history_provider()
    if isnothing(hp)
        _append_history_file(str)
        return
    end
    try
        hist = hp.history
        if isdefined(REPL, :History) && isdefined(REPL.History, :HistoryFile) && hist isa REPL.History.HistoryFile
            !isempty(hist) && hist[end].content == str && return
            entry = REPL.History.HistEntry(:julia, Dates.now(Dates.UTC), str, UInt32(0))
            push!(hist, entry)
            !isopen(hist.file) && _append_history_file(str)
        else
            _append_history_file(str)
            !isempty(hist) && hist[end] == str && return
            push!(hist, str)
            hasproperty(hp, :modes) && push!(hp.modes, :julia)
        end
        if hasproperty(hp, :cur_idx)
            hp.last_idx = -1
            hp.cur_idx = length(hp.history) + 1
        end
    catch
        _append_history_file(str)
    end
    return nothing
end
