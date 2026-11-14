# src/jEMach.jl — Julia Background Watcher & REPL Assistant for jEMach TUI
#
#   using jEMach
#
#   • Press `}` at the start of an empty line (or `Alt+m`) to enter `jemach>` mode
#   • Press `Alt+j` (or `@jemach`) to toggle the TUI split/window
#   • Press `Alt+r` to start/stop live procedure recording
#   • Use `@jemach ls`, `@jemach inspect x`, `@jemach ws`, or `workspace()`

"""
    jEMach

Data-Oriented Julia Workspace Assistant & REPL Monitor with multi-terminal TUI
(`Ghostty`, `Kitty`, `tmux`, `Zellij`, `Rex`) and dedicated `jemach>` REPL mode.

### Quick REPL Shortcuts
- **`}`** (at start of line) or **`Alt+m`**: Enter interactive `jemach>` REPL mode (`help` for commands)
- **`Alt+j`** or **`@jemach`**: Toggle the interactive TUI panel open/closed
- **`Alt+r`**: Start / stop live procedure recording (`⏺ [rec] julia>`)
- **`workspace()`** or **`@jemach ws`**: Print a formatted workspace variable table in the REPL
- **`@inspect expr`** or **`@jemach inspect expr`**: Deep inspect variable/function & creation history
"""
module jEMach

import Dates
import Pkg
import REPL
import REPL.LineEdit
import Sockets

export make_procedure, record, record_stop, run_procedure, list_procedures,
    find_procedures, search_procedures, autoload_procedures!, get_recent_commands,
    detect_backend, terminal_info, workspace, inspect_var, save_clean_session,
    @jemach, @inspect

const STATE_FILE = Ref{String}("/tmp/jl_tui_state.json")
const SOCKET_PATH = Ref{String}("/tmp/jemach.sock")
const UPDATE_INTERVAL = 0.5  # seconds between state refreshes

_history_path()::String = get(ENV, "JULIA_HISTORY", joinpath(homedir(), ".julia", "logs", "repl_history.jl"))

# Portable native Zig accelerator (built via deps/build.jl into zig/zig-out/lib)
const _zig_lib_handle = Ref{Ptr{Nothing}}(C_NULL)
const _zig_parse_history_ptr = Ref{Ptr{Nothing}}(C_NULL)
const _zig_escape_json_ptr = Ref{Ptr{Nothing}}(C_NULL)

function _load_zig_native!()::Bool
    _zig_lib_handle[] != C_NULL && return true
    lib_name = "libjemach_native." * Base.Libc.Libdl.dlext
    lib_path = normpath(joinpath(@__DIR__, "..", "zig", "zig-out", "lib", lib_name))
    !isfile(lib_path) && return false
    return try
        h = Base.Libc.Libdl.dlopen(lib_path)
        p_hist = Base.Libc.Libdl.dlsym(h, :jemach_parse_history_buf; throw_error = false)
        p_json = Base.Libc.Libdl.dlsym(h, :jemach_escape_json_str; throw_error = false)
        _zig_lib_handle[] = h
        _zig_parse_history_ptr[] = isnothing(p_hist) ? C_NULL : p_hist
        _zig_escape_json_ptr[] = isnothing(p_json) ? C_NULL : p_json
        true
    catch
        false
    end
end

function _get_project_dir()::String
    proj_path = try
        Pkg.project().path
    catch
        nothing
    end
    if !isnothing(proj_path) && isfile(proj_path) && !occursin(".julia/environments", proj_path)
        return dirname(proj_path)
    else
        return pwd()
    end
end

function _get_safe_name(proj_dir::String)::String
    return replace(proj_dir, r"[^a-zA-Z0-9]" => "_")
end

# ---------------------------------------------------------------------------
# Minimal JSON serialiser (no external dependencies)
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

function _write_json_str(buf::IO, s::AbstractString, ::Vector{UInt8})
    return _write_json_str_julia(buf, s)
end

_write_json_str(buf::IO, s::AbstractString) = _write_json_str_julia(buf, s)

# ---------------------------------------------------------------------------
# Data-Oriented Design (DoD) Columnar Workspace Representation
# ---------------------------------------------------------------------------

struct WorkspaceTable
    names::Vector{String}
    kinds::Vector{String}
    types::Vector{String}
    values::Vector{String}
    exprs::Vector{String}
    modules::Vector{String}
    depths::Vector{Int32}
    parent_indices::Vector{Int32}
    has_children::Vector{Bool}
end

function WorkspaceTable()
    return WorkspaceTable(
        String[],
        String[],
        String[],
        String[],
        String[],
        String[],
        Int32[],
        Int32[],
        Bool[]
    )
end

function Base.empty!(t::WorkspaceTable)
    empty!(t.names)
    empty!(t.kinds)
    empty!(t.types)
    empty!(t.values)
    empty!(t.exprs)
    empty!(t.modules)
    empty!(t.depths)
    empty!(t.parent_indices)
    empty!(t.has_children)
    return t
end

function _add_entry!(
        t::WorkspaceTable,
        name::String,
        kind::String,
        type_str::String,
        value_str::String,
        expr_str::String,
        mod_str::String,
        depth::Int,
        parent_idx::Int,
        has_children::Bool
    )::Int
    push!(t.names, name)
    push!(t.kinds, kind)
    push!(t.types, type_str)
    push!(t.values, value_str)
    push!(t.exprs, expr_str)
    push!(t.modules, mod_str)
    push!(t.depths, Int32(depth))
    push!(t.parent_indices, Int32(parent_idx))
    push!(t.has_children, has_children)
    return length(t.names)
end

const _shared_workspace_table = Ref{WorkspaceTable}(WorkspaceTable())

function Base.show(io::IO, t::WorkspaceTable)
    top_count = count(==(0), t.depths)
    print(io, "WorkspaceTable($top_count top-level items, $(length(t.names)) total nodes)")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", t::WorkspaceTable)
    use_color = get(io, :color, true)
    bold = use_color ? "\e[1m" : ""
    cyan = use_color ? "\e[36m" : ""
    green = use_color ? "\e[32m" : ""
    yellow = use_color ? "\e[33m" : ""
    magenta = use_color ? "\e[35m" : ""
    dim = use_color ? "\e[2m" : ""
    reset = use_color ? "\e[0m" : ""

    n = length(t.names)
    if n == 0
        print(io, "$(dim)WorkspaceTable is empty (no user variables in Main).$(reset)")
        return nothing
    end

    top_indices = [i for i in 1:n if t.depths[i] == 0]
    println(io, bold * cyan * "┌─ jEMach Workspace (" * string(length(top_indices)) * " top-level items) " * ("─"^28) * reset)
    println(io, bold * "│ " * rpad("NAME", 22) * " " * rpad("TYPE", 22) * " " * rpad("SIZE", 10) * " VALUE" * reset)
    println(io, cyan * "├" * ("─"^76) * reset)

    for i in top_indices
        name = t.names[i]
        kind = t.kinds[i]
        tp = t.types[i]
        val_str = t.values[i]
        mod_str = t.modules[i]

        sz_str = "-"
        if mod_str == "Main" && kind == "variable"
            sym = Symbol(name)
            if isdefined(Main, sym)
                try
                    v = Base.invokelatest(getfield, Main, sym)
                    sz_str = Base.format_bytes(Base.summarysize(v))
                catch
                end
            end
        end

        name_disp = mod_str == "Main" ? name : (mod_str * "." * name)
        name_short = length(name_disp) > 21 ? name_disp[1:20] * "…" : name_disp
        tp_short = length(tp) > 21 ? tp[1:20] * "…" : tp
        val_short = length(val_str) > 32 ? first(val_str, 31) * "…" : val_str

        k_color = kind == "function" ? cyan : (kind == "type" ? magenta : green)
        println(
            io,
            "│ " * k_color * bold * rpad(name_short, 22) * reset * " " *
                yellow * rpad(tp_short, 22) * reset * " " *
                dim * rpad(sz_str, 10) * reset * " " *
                val_short
        )
    end
    print(io, bold * cyan * "└" * ("─"^76) * reset)
    return nothing
end

"""
    workspace(query::AbstractString = "") -> WorkspaceTable

Collect and display the current Julia workspace variables, functions, types,
their memory footprint (`summarysize`), and value previews directly in the REPL.
Optionally filter entries by `query`.
"""
function workspace(query::AbstractString = "")
    t = _collect_state_dod!(_shared_workspace_table[])
    q = lowercase(strip(query))
    if isempty(q)
        show(IOContext(stdout, :color => true), MIME("text/plain"), t)
        println(stdout)
        return nothing
    end

    filtered = WorkspaceTable()
    for i in 1:length(t.names)
        if t.depths[i] == 0 && (
                occursin(q, lowercase(t.names[i])) ||
                    occursin(q, lowercase(t.types[i])) ||
                    occursin(q, lowercase(t.values[i])) ||
                    occursin(q, lowercase(t.modules[i]))
            )
            _add_entry!(
                filtered,
                t.names[i],
                t.kinds[i],
                t.types[i],
                t.values[i],
                t.exprs[i],
                t.modules[i],
                Int(t.depths[i]),
                Int(t.parent_indices[i]),
                t.has_children[i]
            )
        end
    end
    show(IOContext(stdout, :color => true), MIME("text/plain"), filtered)
    println(stdout)
    return nothing
end

function _collect_children_dod!(
        t::WorkspaceTable,
        val,
        parent_expr::String,
        mod_name::String,
        depth::Int,
        parent_idx::Int
    )
    depth > 5 && return
    T = typeof(val)
    return try
        type_name_str = string(T)
        # 1. DataFrames / Tables.jl interface
        if occursin("DataFrame", type_name_str) || (hasmethod(names, Tuple{T}) && hasmethod(getindex, Tuple{T, Symbol}))
            try
                col_names = names(val)
                r_count = size(val, 1)
                for cname in col_names[1:min(length(col_names), 20)]
                    c_str = string(cname)
                    c_col = val[!, Symbol(cname)]
                    c_expr = parent_expr * "[!, :" * c_str * "]"
                    _add_entry!(
                        t,
                        ":" * c_str,
                        "variable",
                        string(typeof(c_col)) * " (" * string(r_count) * " rows)",
                        _value_preview(c_col),
                        c_expr,
                        mod_name,
                        depth,
                        parent_idx,
                        false
                    )
                end
            catch
            end
            return
        end

        # 2. Dictionaries
        if val isa AbstractDict
            count = 0
            for (k, v) in val
                count >= 20 && break
                k_str = string(k)
                k_expr = parent_expr * "[" * repr(k) * "]"
                _add_entry!(
                    t,
                    k_str,
                    "variable",
                    string(typeof(v)),
                    _value_preview(v),
                    k_expr,
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
                count += 1
            end
            # 3. 1D Arrays
        elseif val isa AbstractArray && ndims(val) == 1
            for i in 1:min(length(val), 20)
                _add_entry!(
                    t,
                    "[$i]",
                    "variable",
                    string(typeof(val[i])),
                    _value_preview(val[i]),
                    parent_expr * "[$i]",
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
            # 4. 2D Matrices / Arrays
        elseif val isa AbstractArray && ndims(val) == 2
            rows, cols = size(val)
            for i in 1:min(rows, 5)
                for j in 1:min(cols, 5)
                    _add_entry!(
                        t,
                        "[$i, $j]",
                        "variable",
                        string(eltype(val)),
                        _value_preview(val[i, j]),
                        parent_expr * "[$i, $j]",
                        mod_name,
                        depth,
                        parent_idx,
                        false
                    )
                end
            end
            # 5. Multidimensional Arrays
        elseif val isa AbstractArray && ndims(val) > 2
            _add_entry!(
                t,
                "[dimensions]",
                "variable",
                "Tuple",
                string(size(val)),
                "size(" * parent_expr * ")",
                mod_name,
                depth,
                parent_idx,
                false
            )
            # 6. Tuples and NamedTuples
        elseif val isa NamedTuple
            for name in keys(val)
                v = val[name]
                name_str = string(name)
                _add_entry!(
                    t,
                    name_str,
                    "variable",
                    string(typeof(v)),
                    _value_preview(v),
                    parent_expr * "." * name_str,
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
        elseif val isa Tuple
            for (i, v) in enumerate(val)
                i > 20 && break
                _add_entry!(
                    t,
                    "[$i]",
                    "variable",
                    string(typeof(v)),
                    _value_preview(v),
                    parent_expr * "[$i]",
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
            # 7. Arbitrary composite structs
        elseif !isprimitivetype(T) && T !== Module && T !== Function && T !== DataType && T !== UnionAll
            fns = fieldnames(T)
            for f in fns
                f_str = string(f)
                f_val = try
                    getfield(val, f)
                catch
                    continue
                end
                _add_entry!(
                    t,
                    f_str,
                    "variable",
                    string(typeof(f_val)),
                    _value_preview(f_val),
                    parent_expr * "." * f_str,
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
        end
    catch
    end
end

# ---------------------------------------------------------------------------
# Procedure Engine & REPL History
# ---------------------------------------------------------------------------

mutable struct ProcedureInfo
    name::Symbol
    signature::String
    file::String
    doc::String
    code::String
    last_run_time_ms::Float64
    last_run_alloc_bytes::Int
    last_run_status::Symbol # :ok, :error, :never
    last_run_at::String
end

function Base.show(io::IO, p::ProcedureInfo)
    print(io, "ProcedureInfo(:$(p.name), \"$(p.signature)\", status=:$(p.last_run_status))")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", p::ProcedureInfo)
    use_color = get(io, :color, true)
    bold = use_color ? "\e[1m" : ""
    cyan = use_color ? "\e[36m" : ""
    green = use_color ? "\e[32m" : ""
    yellow = use_color ? "\e[33m" : ""
    red = use_color ? "\e[31m" : ""
    dim = use_color ? "\e[2m" : ""
    reset = use_color ? "\e[0m" : ""

    status_badge = p.last_run_status == :ok ? (green * "✓ OK" * reset) :
        p.last_run_status == :error ? (red * "✗ ERROR" * reset) : (dim * "○ NEVER RUN" * reset)
    metrics_str = p.last_run_status != :never ?
        "$(p.last_run_time_ms) ms, $(Base.format_bytes(p.last_run_alloc_bytes)) (at $(p.last_run_at))" :
        "-"

    println(io, bold * cyan * "╭─ Procedure: " * string(p.name) * " " * ("─"^max(1, 50 - length(string(p.name)))) * "╮" * reset)
    println(io, "│ " * bold * "Signature: " * reset * cyan * p.signature * reset)
    println(io, "│ " * bold * "File:      " * reset * p.file)
    println(io, "│ " * bold * "Status:    " * reset * status_badge * "  " * yellow * metrics_str * reset)
    if !isempty(p.doc)
        println(io, "│ " * bold * "Doc:       " * reset * dim * replace(p.doc, '\n' => " ") * reset)
    end
    if !isempty(strip(p.code))
        println(io, cyan * "├─ Source " * ("─"^58) * "┤" * reset)
        for (li, line) in enumerate(split(rstrip(p.code), '\n'))
            println(io, "│ " * dim * lpad(string(li), 3) * " │ " * reset * line)
        end
    end
    print(io, bold * cyan * "╰" * ("─"^67) * "╯" * reset)
    return nothing
end

const _procedures = Dict{Symbol, ProcedureInfo}()
const _parsed_proc_mtimes = Dict{String, Float64}()
const _parsed_proc_names = Dict{String, Symbol}()
const _loaded_proc_mtimes = Dict{String, Float64}()
const _recording = Ref{Bool}(false)
const _record_name = Ref{Symbol}(:proc)
const _record_start_pos = Ref{Int64}(0)
const _record_hist_idx = Ref{Int}(0)
const HIST_START_POS = Ref{Int}(0)
const HISTORY_LIMIT = 60
const _orig_julia_prompt = Ref{Any}(nothing)
const _orig_julia_prefix = Ref{Any}(nothing)

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
    isempty(raw) && return String[]
    limit <= 0 && return String[]
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

    # Pure-Julia fallback
    s = String(copy(raw))
    if skip_partial_first
        nl = findfirst('\n', s)
        s = isnothing(nl) ? "" : SubString(s, nextind(s, nl))
    end
    cmds = _parse_history_blocks_julia(s)
    return length(cmds) > limit ? cmds[(end - limit + 1):end] : cmds
end

function _parse_history_blocks(content::AbstractString)::Vector{String}
    return _parse_history_blocks_julia(content)
end

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
    pos = if session_only && HIST_START_POS[] > 0
        min(Int64(HIST_START_POS[]), sz)
    else
        max(Int64(0), sz - Int64(_HIST_READ_CAP))
    end
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

function get_session_commands()::Vector{String}
    return get_recent_commands(session_only = true)
end

function _extract_sig_and_name(fexpr::Expr, default_name::Symbol)::Tuple{String, Symbol}
    while fexpr.head == :macrocall && length(fexpr.args) >= 3 && fexpr.args[end] isa Expr
        fexpr = fexpr.args[end]
    end
    sig = ""
    fname = default_name
    if fexpr.head == :function && !isempty(fexpr.args)
        fsym = fexpr.args[1]
        sig = string(fsym)
        if fsym isa Expr && fsym.head == :call && !isempty(fsym.args)
            fname = Symbol(fsym.args[1])
        end
    elseif fexpr.head == :(=) && length(fexpr.args) >= 2 && fexpr.args[1] isa Expr && fexpr.args[1].head == :call
        fsym = fexpr.args[1]
        sig = string(fsym)
        if !isempty(fsym.args)
            fname = Symbol(fsym.args[1])
        end
    end
    return (sig, fname)
end

function _load_procedures!(; eval_in_main::Bool = false)
    proj_dir = _get_project_dir()
    proc_dir = joinpath(proj_dir, "procedures")
    !isdir(proc_dir) && return _procedures

    found_names = Set{Symbol}()
    seen_files = Set{String}()
    for (root, _, files) in walkdir(proc_dir)
        for file in files
            !endswith(file, ".jl") && continue
            filepath = joinpath(root, file)
            push!(seen_files, filepath)
            file_mt = try
                mtime(filepath)
            catch
                0.0
            end

            cached_name = get(_parsed_proc_names, filepath, nothing)
            func_name = if !isnothing(cached_name) &&
                    get(_parsed_proc_mtimes, filepath, -1.0) == file_mt &&
                    haskey(_procedures, cached_name)
                cached_name
            else
                content = try
                    read(filepath, String)
                catch
                    continue
                end
                parsed = try
                    Meta.parse("begin\n" * content * "\nend")
                catch
                    continue
                end
                doc_str = ""
                sig_str = ""
                parsed_name = Symbol(splitext(file)[1])

                for a in parsed.args
                    !(a isa Expr) && continue
                    if a.head == :macrocall && length(a.args) >= 4
                        mac_name = a.args[1]
                        is_doc_mac = (
                            mac_name == Symbol("@doc") ||
                                mac_name == GlobalRef(Core, Symbol("@doc")) ||
                                (mac_name isa GlobalRef && mac_name.name == Symbol("@doc"))
                        )
                        if is_doc_mac
                            doc_str = string(a.args[3])
                            if a.args[4] isa Expr
                                s, fn = _extract_sig_and_name(a.args[4], parsed_name)
                                !isempty(s) && (sig_str = s)
                                parsed_name = fn
                            end
                        end
                    elseif a.head == :function || a.head == :(=)
                        s, fn = _extract_sig_and_name(a, parsed_name)
                        !isempty(s) && (sig_str = s)
                        parsed_name = fn
                    end
                end

                # Fallback docstring from top-of-file comments
                if isempty(strip(doc_str))
                    comment_lines = String[]
                    for l in split(content, '\n')
                        sl = strip(l)
                        if startswith(sl, "#") && !occursin("Generated by jEMach", sl)
                            push!(comment_lines, strip(lstrip(sl, ['#', ' '])))
                        elseif !isempty(sl)
                            break
                        end
                    end
                    !isempty(comment_lines) && (doc_str = join(comment_lines, " "))
                end

                isempty(sig_str) && (sig_str = string(parsed_name) * "()")
                rel_path = relpath(filepath, proj_dir)

                if !haskey(_procedures, parsed_name)
                    _procedures[parsed_name] = ProcedureInfo(
                        parsed_name, sig_str, rel_path, strip(doc_str), content,
                        0.0, 0, :never, "-"
                    )
                else
                    p = _procedures[parsed_name]
                    p.signature = sig_str
                    p.doc = strip(doc_str)
                    p.code = content
                    p.file = rel_path
                end
                _parsed_proc_mtimes[filepath] = file_mt
                _parsed_proc_names[filepath] = parsed_name
                parsed_name
            end

            push!(found_names, func_name)

            if eval_in_main && (get(_loaded_proc_mtimes, filepath, -1.0) != file_mt || !isdefined(Main, func_name))
                try
                    Base.include(Main, filepath)
                    _loaded_proc_mtimes[filepath] = file_mt
                catch
                end
            end
        end
    end

    # Clean up deleted procedures & stale mtime caches
    for k in collect(keys(_procedures))
        !(k in found_names) && delete!(_procedures, k)
    end
    for fp in collect(keys(_parsed_proc_mtimes))
        if !(fp in seen_files)
            delete!(_parsed_proc_mtimes, fp)
            delete!(_parsed_proc_names, fp)
            delete!(_loaded_proc_mtimes, fp)
        end
    end

    return _procedures
end

"""
    autoload_procedures!() -> Dict{Symbol, ProcedureInfo}

Discover all `.jl` files in the project's `procedures/` folder and evaluate them
into `Main` so that tab-completion, direct function calls, and `?procedure_name`
docstrings work immediately in the Julia REPL.
"""
function autoload_procedures!()
    return _load_procedures!(; eval_in_main = true)
end

function _is_global_or_type(sym::Symbol)::Bool
    for m in (Main, Base, Core)
        if isdefined(m, sym)
            try
                v = getfield(m, sym)
                if v isa Function || v isa DataType || v isa UnionAll || v isa Module
                    return true
                end
            catch
            end
        end
    end
    return false
end

function _bind_ast_lhs!(lhs, target_set::Set{Symbol})
    if lhs isa Symbol
        push!(target_set, lhs)
    elseif lhs isa Expr
        if lhs.head == :tuple || lhs.head == :parameters
            for a in lhs.args
                _bind_ast_lhs!(a, target_set)
            end
        elseif lhs.head == :(::) && !isempty(lhs.args)
            _bind_ast_lhs!(lhs.args[1], target_set)
        elseif lhs.head == :(=) && !isempty(lhs.args)
            _bind_ast_lhs!(lhs.args[1], target_set)
        elseif lhs.head == :... && !isempty(lhs.args)
            _bind_ast_lhs!(lhs.args[1], target_set)
        end
    end
    return target_set
end

function _collect_for_bindings!(spec, assigned::Set{Symbol}, referenced::Set{Symbol}, outer_scope::Set{Symbol}, loop_scope::Set{Symbol})
    if spec isa Expr && spec.head == :(=) && length(spec.args) >= 2
        _collect_ast_symbols!(spec.args[2], assigned, referenced, outer_scope)
        _bind_ast_lhs!(spec.args[1], loop_scope)
    elseif spec isa Expr && spec.head == :block
        for item in spec.args
            item isa LineNumberNode && continue
            _collect_for_bindings!(item, assigned, referenced, outer_scope, loop_scope)
        end
    end
    return loop_scope
end

function _collect_ast_symbols!(ex, assigned::Set{Symbol}, referenced::Set{Symbol}, local_scope::Set{Symbol} = Set{Symbol}())
    if ex isa QuoteNode || ex isa LineNumberNode
        return nothing
    elseif ex isa Symbol
        if !(ex in local_scope) && !(ex in assigned)
            push!(referenced, ex)
        end
        return nothing
    elseif !(ex isa Expr)
        return nothing
    end

    h = ex.head
    if h == :quote || h == :inert || h == :using || h == :import || h == :export || h == :meta
        return nothing
    elseif h == :(=)
        lhs = ex.args[1]
        if length(ex.args) >= 2
            _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
        end
        if lhs isa Symbol || (lhs isa Expr && lhs.head in (:tuple, :(::)))
            _bind_ast_lhs!(lhs, assigned)
        else
            # e.g. `arr[i] = val` or `obj.field = val`: `arr`/`i`/`obj` are referenced, not assigned
            _collect_ast_symbols!(lhs, assigned, referenced, local_scope)
        end
    elseif h == :kw
        # Keyword argument `name = val`: only `val` is an expression in caller scope
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
    elseif h == :parameters
        for a in ex.args
            if a isa Expr && a.head == :kw
                length(a.args) >= 2 && _collect_ast_symbols!(a.args[2], assigned, referenced, local_scope)
            else
                _collect_ast_symbols!(a, assigned, referenced, local_scope)
            end
        end
    elseif h == :(->)
        new_scope = copy(local_scope)
        length(ex.args) >= 1 && _bind_ast_lhs!(ex.args[1], new_scope)
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, new_scope)
    elseif h == :function
        new_scope = copy(local_scope)
        if !isempty(ex.args)
            sig = ex.args[1]
            if sig isa Symbol
                push!(assigned, sig)
            elseif sig isa Expr && sig.head == :call && !isempty(sig.args)
                sig.args[1] isa Symbol && push!(assigned, sig.args[1])
                for a in sig.args[2:end]
                    _bind_ast_lhs!(a, new_scope)
                end
            elseif sig isa Expr && sig.head == :tuple
                _bind_ast_lhs!(sig, new_scope)
            end
        end
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
        end
    elseif h == :do
        length(ex.args) >= 1 && _collect_ast_symbols!(ex.args[1], assigned, referenced, local_scope)
        length(ex.args) >= 2 && _collect_ast_symbols!(ex.args[2], assigned, referenced, local_scope)
    elseif h == :generator || h == :comprehension
        new_scope = copy(local_scope)
        if h == :comprehension && length(ex.args) == 1 && ex.args[1] isa Expr && ex.args[1].head in (:generator, :flatten)
            _collect_ast_symbols!(ex.args[1], assigned, referenced, local_scope)
        else
            for i in 2:length(ex.args)
                iter_spec = ex.args[i]
                if iter_spec isa Expr && iter_spec.head == :filter
                    for j in 2:length(iter_spec.args)
                        _collect_for_bindings!(iter_spec.args[j], assigned, referenced, local_scope, new_scope)
                    end
                    !isempty(iter_spec.args) && _collect_ast_symbols!(iter_spec.args[1], assigned, referenced, new_scope)
                else
                    _collect_for_bindings!(iter_spec, assigned, referenced, local_scope, new_scope)
                end
            end
            !isempty(ex.args) && _collect_ast_symbols!(ex.args[1], assigned, referenced, new_scope)
        end
    elseif h == :flatten
        for a in ex.args
            _collect_ast_symbols!(a, assigned, referenced, local_scope)
        end
    elseif h == :for
        new_scope = copy(local_scope)
        length(ex.args) >= 1 && _collect_for_bindings!(ex.args[1], assigned, referenced, local_scope, new_scope)
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
        end
    elseif h == :while
        new_scope = copy(local_scope)
        for a in ex.args
            _collect_ast_symbols!(a, assigned, referenced, new_scope)
        end
    elseif h == :let
        new_scope = copy(local_scope)
        if length(ex.args) >= 1
            binds = ex.args[1]
            bind_list = (binds isa Expr && binds.head == :block) ? binds.args : Any[binds]
            for b in bind_list
                b isa LineNumberNode && continue
                if b isa Expr && b.head == :(=)
                    length(b.args) >= 2 && _collect_ast_symbols!(b.args[2], assigned, referenced, new_scope)
                    _bind_ast_lhs!(b.args[1], new_scope)
                elseif b isa Symbol
                    push!(new_scope, b)
                end
            end
        end
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, new_scope)
        end
    elseif h == :local
        for a in ex.args
            if a isa Expr && a.head == :(=)
                length(a.args) >= 2 && _collect_ast_symbols!(a.args[2], assigned, referenced, local_scope)
                _bind_ast_lhs!(a.args[1], local_scope)
            elseif a isa Symbol
                push!(local_scope, a)
            end
        end
    elseif h == :macrocall
        for i in 2:length(ex.args)
            _collect_ast_symbols!(ex.args[i], assigned, referenced, local_scope)
        end
    elseif h == :.
        !isempty(ex.args) && _collect_ast_symbols!(ex.args[1], assigned, referenced, local_scope)
    else
        for a in ex.args
            _collect_ast_symbols!(a, assigned, referenced, local_scope)
        end
    end
    return nothing
end

const _LITERAL_CALL_OPS = Set([:(:), :+, :-, :*, :/, :^, :vect, :vcat, :hcat, :tuple, :(=>)])

function _is_literal_expr(ex)::Bool
    if ex isa Number || ex isa AbstractString || ex isa Char || ex isa Bool || ex isa QuoteNode
        return true
    elseif ex isa Symbol
        return ex in (:nothing, :missing, :true, :false, :pi, :ℯ, :im)
    elseif ex isa Expr
        if ex.head in (:vect, :vcat, :hcat, :row, :tuple, :braces)
            return all(_is_literal_expr, ex.args)
        elseif ex.head == :call && !isempty(ex.args) && ex.args[1] in _LITERAL_CALL_OPS
            return all(_is_literal_expr, ex.args[2:end])
        elseif ex.head == :... && length(ex.args) == 1
            return _is_literal_expr(ex.args[1])
        end
    end
    return false
end

function _default_param_str(sym::Symbol)::Tuple{String, Bool}
    if isdefined(Main, sym)
        val = try
            getfield(Main, sym)
        catch
            nothing
        end
        if !isnothing(val)
            try
                rep = repr(val)
                if length(rep) <= 80 && !occursin('\n', rep)
                    return (string(sym) * " = " * rep, true)
                else
                    return (string(sym) * " = Main." * string(sym), true)
                end
            catch
                return (string(sym) * " = Main." * string(sym), true)
            end
        end
    end
    return (string(sym), false)
end

"""
    make_procedure(name; last=0, indices=Int[], commands=String[], params=Symbol[], doc="", save=true)

Extract REPL commands into a parameterized, documented Julia function saved under
`procedures/<name>.jl` and automatically loaded into `Main`.
"""
function make_procedure(
        name::Union{Symbol, AbstractString};
        last::Int = 0,
        indices::Vector{Int} = Int[],
        commands::Vector{String} = String[],
        params::Vector{Symbol} = Symbol[],
        doc::String = "",
        save::Bool = true
    )
    proc_name = Symbol(name)
    all_cmds = get_recent_commands(limit = HISTORY_LIMIT)

    cmds = String[]
    if !isempty(commands)
        cmds = copy(commands)
    elseif !isempty(indices)
        sort!(indices)
        cmds = [all_cmds[i] for i in indices if 1 <= i <= length(all_cmds)]
    elseif last > 0
        cmds = all_cmds[max(1, end - last + 1):end]
    else
        cmds = all_cmds[max(1, end - 4):end]
    end

    # Clean out comments and make_procedure calls
    clean_cmds = String[]
    for c in cmds
        s = strip(c)
        if !isempty(s) && !startswith(s, "#") && !occursin("make_procedure", s)
            push!(clean_cmds, c)
        end
    end

    if isempty(clean_cmds)
        @warn "No executable commands found to create procedure '$proc_name'"
        return nothing
    end

    # Step 1: Detect initial constant/literal assignments to promote as procedure parameters
    promoted_params = String[]
    promoted_syms = Set{Symbol}()
    computation_start_idx = 1

    for (i, cmd) in enumerate(clean_cmds)
        ex = try
            Meta.parse("begin\n" * cmd * "\nend")
        catch
            nothing
        end
        isnothing(ex) && break
        sub = filter(a -> !(a isa LineNumberNode), ex.args)
        isempty(sub) && continue
        stmt = sub[1]
        if length(sub) == 1 && stmt isa Expr && stmt.head == :(=) && stmt.args[1] isa Symbol
            lhs = stmt.args[1]
            rhs = stmt.args[2]
            if _is_literal_expr(rhs)
                rhs_refs = Set{Symbol}()
                _collect_ast_symbols!(rhs, Set{Symbol}(), rhs_refs)
                if isempty(intersect(rhs_refs, promoted_syms))
                    push!(promoted_syms, lhs)
                    push!(promoted_params, strip(cmd))
                    computation_start_idx = i + 1
                    continue
                end
            end
        end
        break
    end

    if computation_start_idx > length(clean_cmds)
        computation_start_idx = length(clean_cmds)
        pop!(promoted_params)
    end

    body_cmds = clean_cmds[computation_start_idx:end]

    # Step 2: Analyze body_cmds for remaining free variables
    assigned = copy(promoted_syms)
    referenced = Set{Symbol}()
    parsed_exprs = Expr[]

    for cmd in body_cmds
        ex = try
            Meta.parse("begin\n" * cmd * "\nend")
        catch
            nothing
        end
        if !isnothing(ex)
            push!(parsed_exprs, ex)
            _collect_ast_symbols!(ex, assigned, referenced)
        end
    end

    free_syms = setdiff(referenced, assigned)
    detected_params = filter(s -> !startswith(string(s), "@") && !_is_global_or_type(s), collect(free_syms))

    final_params = !isempty(params) ? params : sort(detected_params, by = string)

    required_params = String[]
    other_default_params = String[]
    for p in final_params
        (p_str, has_default) = _default_param_str(p)
        if has_default
            push!(other_default_params, p_str)
        else
            push!(required_params, p_str)
        end
    end

    all_sig_params = vcat(required_params, promoted_params, other_default_params)
    sig_args = join(all_sig_params, ", ")
    func_sig = "$(proc_name)($sig_args)"

    body_lines = String[]
    for cmd in body_cmds
        for line in split(cmd, '\n')
            push!(body_lines, "    " * line)
        end
    end

    last_ex = !isempty(parsed_exprs) ? parsed_exprs[end] : nothing
    if !isnothing(last_ex) && last_ex isa Expr && last_ex.head == :block
        sub_args = filter(a -> !(a isa LineNumberNode), last_ex.args)
        if !isempty(sub_args)
            leaf = sub_args[end]
            if leaf isa Expr && leaf.head == :(=) && leaf.args[1] isa Symbol
                push!(body_lines, "    return " * string(leaf.args[1]))
            end
        end
    end

    body_code = join(body_lines, "\n")
    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    doc_text = isempty(doc) ? "Automated procedure extracted from Julia REPL." : doc

    code = """
    # Generated by jEMach on $timestamp
    \"\"\"
        $func_sig

    $doc_text
    \"\"\"
    function $func_sig
    $body_code
    end
    """

    if save
        proc_dir = joinpath(_get_project_dir(), "procedures")
        !isdir(proc_dir) && mkpath(proc_dir)
        filepath = joinpath(proc_dir, string(proc_name) * ".jl")
        write(filepath, code)

        try
            Base.include(Main, filepath)
            _loaded_proc_mtimes[filepath] = try
                mtime(filepath)
            catch
                0.0
            end
        catch e
            @warn "Failed to evaluate generated procedure in Main" exception = e
        end

        rel_path = relpath(filepath, _get_project_dir())
        _procedures[proc_name] = ProcedureInfo(
            proc_name,
            func_sig,
            rel_path,
            doc_text,
            code,
            0.0,
            0,
            :never,
            "-"
        )
        publish_state()

        green = "\e[32m\e[1m"
        reset = "\e[0m"
        cyan = "\e[36m"
        println("\n" * green * "✓" * reset * " Procedure " * cyan * "$proc_name" * reset * " created in " * green * "$rel_path" * reset)
        println("  Callable in REPL: " * cyan * "$func_sig" * reset * "\n")
    end

    return code
end

function _update_repl_prompt!()
    isdefined(Base, :active_repl) || return
    repl = Base.active_repl
    (hasproperty(repl, :interface) && !isnothing(repl.interface) && !isempty(repl.interface.modes)) || return
    julia_mode = repl.interface.modes[1]
    if isnothing(_orig_julia_prompt[])
        _orig_julia_prompt[] = julia_mode.prompt
        _orig_julia_prefix[] = julia_mode.prompt_prefix
    end
    if _recording[]
        rec_name = _record_name[]
        orig = _orig_julia_prompt[]
        julia_mode.prompt = () -> "⏺ [rec: $(rec_name)] " * (orig isa Function ? string(orig()) : string(orig))
        julia_mode.prompt_prefix = "\e[31m\e[1m"
    else
        if !isnothing(_orig_julia_prompt[])
            julia_mode.prompt = _orig_julia_prompt[]
        end
        if !isnothing(_orig_julia_prefix[])
            julia_mode.prompt_prefix = _orig_julia_prefix[]
        end
    end
    # The prompt is re-rendered lazily on the next refresh; no explicit refresh here,
    # because this may run while the REPL backend is still printing command output.
    return nothing
end

"""
    record(name::Union{Symbol, AbstractString} = :proc)

Start recording subsequent REPL commands into a procedure named `name`.
While recording, the REPL prompt changes to `⏺ [rec: <name>] julia> `.
Call `record_stop()` (or press `Alt+r`) to finish and save the procedure.
"""
function record(name::Union{Symbol, AbstractString} = :proc)
    _recording[] = true
    _record_name[] = Symbol(name)
    hist_path = _history_path()
    _record_start_pos[] = isfile(hist_path) ? Int64(filesize(hist_path)) : Int64(0)
    hp = _active_history_provider()
    _record_hist_idx[] = isnothing(hp) ? 0 : length(hp.history)
    _update_repl_prompt!()
    cyan = "\e[36m"
    bold = "\e[1m"
    reset = "\e[0m"
    println(bold * cyan * "⏺ [jEMach] Recording procedure '$(_record_name[])'..." * reset)
    println("  Execute your commands in the REPL. When done, call " * bold * "record_stop()" * reset * " or press " * bold * "Alt+r" * reset)
    return nothing
end

function _recorded_commands_since_start()::Vector{String}
    hp = _active_history_provider()
    if !isnothing(hp) && _record_hist_idx[] >= 0 && length(hp.history) >= _record_hist_idx[]
        cmds = String[]
        for idx in (_record_hist_idx[] + 1):length(hp.history)
            entry = hp.history[idx]
            mode_sym, content = if isdefined(REPL, :History) && isdefined(REPL.History, :HistEntry) && entry isa REPL.History.HistEntry
                (entry.mode, entry.content)
            else
                m = (hasproperty(hp, :modes) && idx <= length(hp.modes)) ? hp.modes[idx] : :julia
                (m, String(entry))
            end
            cmd = String(rstrip(content))
            if mode_sym == :julia && _is_valid_user_cmd(cmd)
                push!(cmds, cmd)
            end
        end
        !isempty(cmds) && return cmds
    end

    hist_path = _history_path()
    !isfile(hist_path) && return String[]
    sz = filesize(hist_path)
    pos = clamp(_record_start_pos[], Int64(0), Int64(sz))
    nbytes = Int(sz - pos)
    nbytes <= 0 && return String[]
    raw = try
        open(hist_path, "r") do f
            seek(f, pos)
            buf = Vector{UInt8}(undef, nbytes)
            read!(f, buf)
            buf
        end
    catch
        return String[]
    end
    return _parse_history_bytes(raw, false, 4096)
end

"""
    record_stop(; save::Bool = true)

Stop the active procedure recording, restore the standard `julia> ` prompt,
and generate `procedures/<name>.jl` with automatic AST parameterization.
"""
function record_stop(; save::Bool = true)
    if !_recording[]
        println("No procedure recording is in progress.")
        return nothing
    end
    _recording[] = false
    _update_repl_prompt!()
    cmds = _recorded_commands_since_start()
    cmds = filter(c -> !occursin("record_stop", c) && !occursin("@jemach stop", c), cmds)
    return make_procedure(_record_name[]; commands = cmds, save = save)
end

"""
    run_procedure(name, args...; kwargs...)

Reload and execute the procedure `name` with timing and memory allocation profiling,
updating its metrics in the jEMach TUI.
"""
function run_procedure(name::Union{Symbol, AbstractString}, args...; kwargs...)
    sym = Symbol(name)
    _load_procedures!()

    proc_file = if haskey(_procedures, sym) && !isempty(_procedures[sym].file)
        joinpath(_get_project_dir(), _procedures[sym].file)
    else
        joinpath(_get_project_dir(), "procedures", string(sym) * ".jl")
    end

    if !isfile(proc_file)
        proc_dir = joinpath(_get_project_dir(), "procedures")
        if isdir(proc_dir)
            for (root, _, files) in walkdir(proc_dir)
                for f in files
                    if f == string(sym) * ".jl"
                        proc_file = joinpath(root, f)
                        break
                    end
                end
            end
        end
    end

    if isfile(proc_file)
        try
            Base.include(Main, proc_file)
            _loaded_proc_mtimes[proc_file] = try
                mtime(proc_file)
            catch
                0.0
            end
        catch e
            @warn "Failed to reload $proc_file" exception = e
        end
    end

    if !Base.invokelatest(isdefined, Main, sym)
        error("Procedure '$sym' not found in Main or procedures/$sym.jl")
    end
    func = Base.invokelatest(getfield, Main, sym)

    println("▶ Running procedure '$sym'...")
    t_res = @timed try
        Base.invokelatest(func, args...; kwargs...)
    catch e
        e
    end

    val = t_res.value
    is_err = val isa Exception
    status_sym = is_err ? :error : :ok
    time_ms = round(t_res.time * 1000, digits = 2)
    alloc_bytes = t_res.bytes
    now_str = Dates.format(Dates.now(), "HH:MM:SS")

    if haskey(_procedures, sym)
        p = _procedures[sym]
        p.last_run_time_ms = time_ms
        p.last_run_alloc_bytes = alloc_bytes
        p.last_run_status = status_sym
        p.last_run_at = now_str
    else
        _procedures[sym] = ProcedureInfo(
            sym,
            string(sym) * "()",
            isfile(proc_file) ? relpath(proc_file, _get_project_dir()) : "",
            "",
            "",
            time_ms,
            alloc_bytes,
            status_sym,
            now_str
        )
    end
    publish_state()

    green = "\e[32m\e[1m"
    red = "\e[31m\e[1m"
    reset = "\e[0m"
    if is_err
        println(red * "✗ Procedure '$sym' failed in $(time_ms)ms" * reset)
        throw(val)
    else
        println(green * "✓ Procedure '$sym' completed in $(time_ms)ms ($(Base.format_bytes(alloc_bytes)) allocated)" * reset)
        return val
    end
end

"""
    search_procedures(query::AbstractString = "") -> Vector{ProcedureInfo}

Search and return discovered procedures matching `query` by name, signature, docstring, or source code.
"""
function search_procedures(query::AbstractString = "")::Vector{ProcedureInfo}
    _load_procedures!()
    q = lowercase(strip(query))
    procs = sort(collect(values(_procedures)), by = p -> string(p.name))
    if isempty(q)
        return procs
    end
    return filter(procs) do p
        occursin(q, lowercase(string(p.name))) ||
            occursin(q, lowercase(p.signature)) ||
            occursin(q, lowercase(p.doc)) ||
            occursin(q, lowercase(p.file)) ||
            occursin(q, lowercase(p.code))
    end
end

const find_procedures = search_procedures

"""
    list_procedures(query::AbstractString = "")

Print a formatted table of available procedures (optionally filtered by `query`) with their
signatures, docstrings, and latest benchmark metrics.
"""
function list_procedures(query::AbstractString = "")
    procs = search_procedures(query)
    bold = "\e[1m"
    cyan = "\e[36m"
    green = "\e[32m"
    yellow = "\e[33m"
    red = "\e[31m"
    dim = "\e[2m"
    reset = "\e[0m"

    if isempty(_procedures)
        println("$(dim)No procedures defined. Create one with $(cyan)jEMach.make_procedure(:name, last=5)$(reset)")
        return nothing
    end

    if isempty(procs)
        println("$(yellow)No procedures found matching \"$query\"$(reset) ($(length(_procedures)) total defined).")
        return nothing
    end

    header = isempty(query) ? "Available Procedures ($(length(procs))):" : "Matching Procedures for \"$query\" ($(length(procs))/$(length(_procedures))):"
    println(bold * cyan * "┌─ " * header * " " * ("─"^max(0, 48 - length(header))) * reset)
    for p in procs
        status_icon = (p.last_run_status == :ok) ? (green * "✓" * reset) :
            (p.last_run_status == :error) ? (red * "✗" * reset) : (dim * "○" * reset)
        time_str = (p.last_run_status != :never) ? " $(yellow)($(p.last_run_time_ms)ms, $(Base.format_bytes(p.last_run_alloc_bytes)))$(reset)" : ""
        println("│ $status_icon " * cyan * bold * string(p.name) * reset * " → " * p.signature * time_str)
        if !isempty(p.doc)
            first_doc_line = split(p.doc, '\n')[1]
            println("│   $(dim)\"$(first_doc_line)\"$(reset)")
        end
        println("│   $(dim)File: $(p.file)$(reset)")
    end
    println(bold * cyan * "└" * ("─"^52) * reset)
    return nothing
end

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

const _cached_pkgs = Ref{Vector{Dict{String, String}}}(Dict{String, String}[])
const _last_pkg_mtime = Ref{Float64}(0.0)

function _get_packages()::Vector{Dict{String, String}}
    proj_dir = _get_project_dir()
    proj_file = joinpath(proj_dir, "Project.toml")
    mtime_proj = isfile(proj_file) ? mtime(proj_file) : 0.0

    if !isempty(_cached_pkgs[]) && mtime_proj == _last_pkg_mtime[]
        return _cached_pkgs[]
    end

    pkgs = Dict{String, String}[]
    try
        for (name, uuid) in Pkg.project().dependencies
            ver = "unknown"
            try
                dep_info = Pkg.dependencies()[uuid]
                if dep_info.version !== nothing
                    ver = string(dep_info.version)
                end
            catch
            end
            push!(pkgs, Dict("name" => name, "version" => ver))
        end
        sort!(pkgs; by = x -> x["name"])
        _cached_pkgs[] = pkgs
        _last_pkg_mtime[] = mtime_proj
    catch e
    end
    return _cached_pkgs[]
end

# ---------------------------------------------------------------------------
# Workspace introspection
# ---------------------------------------------------------------------------

# Names that are always present in a fresh REPL and clutter the view
const _BUILTIN_NAMES = Set(
    [
        "ans", "err", "eval", "include", "clear",
        "Base", "Core", "Main", "InteractiveUtils",
        "jEMach", "OhMyREPL", "Revise",
    ]
)

const _SKIP_PREFIXES = ("#", "_REPL", "REPL", "IJulia")

function _skip_name(s::String)::Bool
    s in _BUILTIN_NAMES && return true
    for pfx in _SKIP_PREFIXES
        startswith(s, pfx) && return true
    end
    return false
end

function _value_preview(val)::String
    val isa Number && return string(val)
    val isa Bool && return string(val)
    val isa Symbol && return string(val)
    if val isa AbstractString
        return length(val) > 60 ? repr(val[1:min(end, 57)]) * "…" : repr(val)
    end
    return try
        s = sprint((io, x) -> Base.invokelatest(show, io, x), val; context = IOContext(devnull, :limit => true, :compact => true))
        s = replace(s, '\n' => ' ')
        length(s) > 60 ? s[1:60] * "…" : s
    catch
        "<?>"
    end
end

function _collect_module_items_dod!(t::WorkspaceTable, mod::Module, mod_name::String, all::Bool)
    syms = names(mod; all = all, imported = false)
    candidates = Tuple{Symbol, String, Any, String}[]
    for sym in syms
        name = string(sym)
        _skip_name(name) && continue
        isdefined(mod, sym) || continue
        val = try
            getfield(mod, sym)
        catch
            continue
        end
        kind = if isa(val, Function)
            "function"
        elseif isa(val, Module)
            "module"
        elseif isa(val, DataType) || isa(val, UnionAll)
            "type"
        else
            "variable"
        end
        kind == "module" && continue
        push!(candidates, (sym, name, val, kind))
    end

    sort!(candidates; by = x -> (x[4] == "variable" ? 0 : 1, x[2]))

    for (_, name, val, kind) in candidates
        type_str = string(typeof(val))
        value_str = ""
        if kind == "variable"
            if all || isa(val, Number) || isa(val, AbstractString) || isa(val, Symbol) || isa(val, Bool)
                value_str = _value_preview(val)
            end
        elseif kind == "function"
            try
                ms = methods(val)
                value_str = "($(length(ms)) method" * (length(ms) == 1 ? "" : "s") * ")"
            catch
                value_str = "(function)"
            end
        elseif kind == "type"
            value_str = "(type)"
        end

        item_expr = (mod == Main) ? name : (mod_name * "." * name)

        has_kids = (kind == "variable") && (
            val isa AbstractDict ||
                (val isa AbstractArray && length(val) > 0) ||
                val isa Tuple ||
                val isa NamedTuple ||
                (!isprimitivetype(typeof(val)) && typeof(val) !== Module && typeof(val) !== Function && typeof(val) !== DataType && typeof(val) !== UnionAll)
        )

        entry_idx = _add_entry!(t, name, kind, type_str, value_str, item_expr, mod_name, 0, -1, has_kids)
        if has_kids
            _collect_children_dod!(t, val, item_expr, mod_name, 1, entry_idx)
        end
    end
    return
end

"""
    inspect_var(mod::Module, expr_str::String)

Print a detailed report about the value of `expr_str` evaluated in `mod`: type, size,
methods with inferred return types, the REPL command that created it, and its docstring.
See also `@inspect`.
"""
function inspect_var(mod::Module, expr_str::String)
    val = try
        expr = Meta.parse(expr_str)
        Base.invokelatest(Core.eval, mod, expr)
    catch
        println("Could not evaluate expression $expr_str in module $mod.")
        return nothing
    end

    # ANSI styles
    bold = "\e[1m"
    green = "\e[32m"
    reset = "\e[0m"

    println("\n" * green * bold * "━"^60 * reset)
    println(bold * "Variable:      " * reset * "$mod.$expr_str")
    println(bold * "Type:          " * reset * "$(typeof(val))")
    if hasmethod(size, Tuple{typeof(val)})
        try
            println(bold * "Size:          " * reset * "$(size(val))")
        catch
        end
    end

    # Methods & Return Types
    if isa(val, Function) || (hasmethod(methods, Tuple{typeof(val)}) && !isempty(methods(val)))
        try
            ms = methods(val)
            println(bold * "Methods & Return Types:" * reset)
            for m in first(ms, 15)
                temp = m.sig
                while temp isa UnionAll
                    temp = temp.body
                end
                params = temp.parameters
                sig_types = Tuple{params[2:end]...}
                rts = Base.return_types(val, sig_types)
                rt = isempty(rts) ? "Any" : rts[1]
                m_str = sprint(show, m)
                sig_part = split(m_str, " @ ")[1]
                println("  ", sig_part, " -> ", rt)
            end
            if length(ms) > 15
                println("  ... ($(length(ms) - 15) more methods)")
            end
            println()
        catch
        end
    end

    # Search REPL history for creation/assignment (read only last 64KB for speed)
    base_m = match(r"^[a-zA-Z_][a-zA-Z0-9_]*", expr_str)
    base_var_str = isnothing(base_m) ? expr_str : base_m.match
    sym = Symbol(base_var_str)

    try
        var_regex = Regex("\\b" * base_var_str * "\\b")
        found_cmd = ""
        for cmd in Iterators.reverse(get_recent_commands(limit = 100))
            if occursin(var_regex, cmd) && occursin(r"=|function|macro|struct", cmd) &&
                    !occursin("println", cmd) && !occursin("typeof", cmd) && !occursin("dump", cmd)
                found_cmd = cmd
                break
            end
        end
        if !isempty(found_cmd)
            println(bold * "Created/Modified by:" * reset)
            code_md = Base.Docs.Markdown.parse("```julia\n" * found_cmd * "\n```")
            show(IOContext(stdout, :color => true), MIME("text/plain"), code_md)
            println()
        end
    catch
    end

    # Documentation
    try
        doc = Base.Docs.doc(Base.Docs.Binding(mod, sym))
        doc_str = string(doc)
        if !isempty(doc_str) && !occursin("No documentation found", doc_str)
            println(bold * "Documentation:" * reset)
            show(IOContext(stdout, :color => true), MIME("text/plain"), doc)
            println()
        end
    catch
    end
    println(green * bold * "━"^60 * reset)
    return nothing
end

const _IGNORED_LOADED_MODULES = Set(["Main", "Base", "Core", "jEMach", "OhMyREPL", "Revise", "Pkg", "InteractiveUtils", "VSCodeServer"])

function _collect_state_dod!(t::WorkspaceTable)::WorkspaceTable
    empty!(t)

    # 1. Main module — always first
    _collect_module_items_dod!(t, Main, "Main", true)

    # 2. Loaded packages explicitly visible in Main (avoids full imported names(Main) scan)
    seen = copy(_IGNORED_LOADED_MODULES)
    for (_, mod) in Base.loaded_modules
        name = string(mod)
        name in seen && continue
        mod_sym = nameof(mod)
        if isdefined(Main, mod_sym)
            bound = try
                getfield(Main, mod_sym)
            catch
                nothing
            end
            if bound === mod
                push!(seen, name)
                _collect_module_items_dod!(t, mod, name, false)
            end
        end
    end

    return t
end

"""
    save_clean_session()

Replay the current session's commands in a sandbox module and save only the ones that
succeed to `jemach/repl_session_<timestamp>.jl`.
"""
function save_clean_session()
    cmds = get_session_commands()
    if isempty(cmds)
        println("\nNo commands found in the current session.")
        return nothing
    end

    # Create a unique sandbox module to test evaluation
    sandbox_name = Symbol("Sandbox_", round(Int, time()))
    sandbox_mod = Module(sandbox_name)
    # Import Base and Core in sandbox so standard functions work
    Core.eval(sandbox_mod, :(using Base))

    successful_cmds = String[]

    for cmd in cmds
        # Skip TUI commands or watcher commands to avoid noise
        if occursin("jEMach", cmd) || occursin("inspect_var", cmd) || occursin("STATE_FILE", cmd) || occursin("save_clean_session", cmd)
            continue
        end

        # Parse the command
        expr = try
            Meta.parse(cmd)
        catch
            nothing
        end
        expr === nothing && continue

        # Try evaluating in the sandbox
        try
            Base.invokelatest(Core.eval, sandbox_mod, expr)
            push!(successful_cmds, cmd)
        catch e
            # Skip failed command
        end
    end

    if isempty(successful_cmds)
        println("\nNo successful commands to save.")
        return nothing
    end

    # Determine the project directory (workspace root)
    proj_dir = pwd()
    if !isfile(joinpath(proj_dir, "Project.toml"))
        proj_dir = dirname(dirname(@__FILE__))
    end

    jemach_dir = joinpath(proj_dir, "jemach")
    if !isdir(jemach_dir)
        mkpath(jemach_dir)
    end

    timestamp_str = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    filename = "repl_session_$(timestamp_str).jl"
    filepath = joinpath(jemach_dir, filename)

    open(filepath, "w") do f
        write(f, "# Clean Julia REPL session saved on $(Dates.now())\n")
        write(f, "# Generated by jEMach\n\n")
        for cmd in successful_cmds
            write(f, cmd)
            write(f, "\n\n")
        end
    end

    println("\n" * "✓"^60)
    println(" Clean REPL session saved successfully!")
    println(" File: $filepath")
    println(" " * "✓"^60)
    return nothing
end

# ---------------------------------------------------------------------------
# Terminal & Multiplexer Backend Detection (Ghostty / Kitty / tmux / Zellij / Rex)
# ---------------------------------------------------------------------------

const _backend_override = Ref{Symbol}(:auto)

"""
    detect_backend(preferred::Symbol = :auto) -> Symbol

Detect the active terminal multiplexer or terminal emulator backend.
Priority order:
1. Explicit `preferred` argument or `ENV["JEMACH_BACKEND"]`
2. Active terminal multiplexers (since they may run inside Ghostty or Kitty):
   - `:rex`    (upcoming multiplexer from Ghostty creators: `REX_SESSION`, `REX`, `REX_PANE_ID`, `REX_SOCKET`, `GHOSTTY_REX`)
   - `:zellij` (`ZELLIJ`, `ZELLIJ_SESSION_NAME`, `ZELLIJ_PANE_ID`)
   - `:tmux`   (`TMUX`)
3. Terminal emulators with native split / window control:
   - `:kitty`   (`KITTY_WINDOW_ID`, `KITTY_PID`, `TERM == "xterm-kitty"`)
   - `:ghostty` (`TERM_PROGRAM == "ghostty"`, `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR`, `TERM == "xterm-ghostty"`)
4. `:standalone` fallback
"""
function detect_backend(preferred::Symbol = :auto)::Symbol
    if preferred != :auto
        return preferred
    end
    if _backend_override[] != :auto
        return _backend_override[]
    end
    env_b = strip(lowercase(get(ENV, "JEMACH_BACKEND", "")))
    if !isempty(env_b) && env_b != "auto"
        return Symbol(env_b)
    end

    # 1. Multiplexers
    if haskey(ENV, "REX_SESSION") || haskey(ENV, "REX") || haskey(ENV, "REX_PANE_ID") ||
            haskey(ENV, "REX_SOCKET") || haskey(ENV, "GHOSTTY_REX")
        return :rex
    elseif haskey(ENV, "ZELLIJ") || haskey(ENV, "ZELLIJ_SESSION_NAME") || haskey(ENV, "ZELLIJ_PANE_ID")
        return :zellij
    elseif haskey(ENV, "TMUX") && !isempty(ENV["TMUX"])
        return :tmux
    end

    # 2. Native terminals
    term = lowercase(get(ENV, "TERM", ""))
    term_prog = lowercase(get(ENV, "TERM_PROGRAM", ""))

    if haskey(ENV, "KITTY_WINDOW_ID") || haskey(ENV, "KITTY_PID") || term == "xterm-kitty"
        return :kitty
    elseif term_prog == "ghostty" || haskey(ENV, "GHOSTTY_RESOURCES_DIR") ||
            haskey(ENV, "GHOSTTY_BIN_DIR") || term == "xterm-ghostty"
        return :ghostty
    end

    return :standalone
end

"""
    terminal_info() -> Dict{Symbol, Any}

Return diagnostic details about the detected terminal and multiplexer environment.
"""
function terminal_info()::Dict{Symbol, Any}
    b = detect_backend()
    return Dict{Symbol, Any}(
        :backend => b,
        :term => get(ENV, "TERM", ""),
        :term_program => get(ENV, "TERM_PROGRAM", ""),
        :tmux => haskey(ENV, "TMUX"),
        :zellij => haskey(ENV, "ZELLIJ") || haskey(ENV, "ZELLIJ_SESSION_NAME"),
        :kitty => haskey(ENV, "KITTY_WINDOW_ID") || get(ENV, "TERM", "") == "xterm-kitty",
        :kitty_listen_on => get(ENV, "KITTY_LISTEN_ON", ""),
        :ghostty => lowercase(get(ENV, "TERM_PROGRAM", "")) == "ghostty" || haskey(ENV, "GHOSTTY_RESOURCES_DIR"),
        :rex => haskey(ENV, "REX_SESSION") || haskey(ENV, "REX") || haskey(ENV, "GHOSTTY_REX"),
        :socket_path => SOCKET_PATH[],
        :state_file => STATE_FILE[],
    )
end

# ---------------------------------------------------------------------------
# Bidirectional Socket Command Parser & REPL Executor
# ---------------------------------------------------------------------------

function _parse_json_cmd(s::AbstractString)::Dict{String, Any}
    res = Dict{String, Any}()
    str = strip(s)
    if startswith(str, "CMD ")
        str = strip(str[5:end])
    end
    (!startswith(str, "{") || !endswith(str, "}")) && return res

    # Lightweight key-value extractor for flat JSON command objects
    pos = nextind(str, firstindex(str))
    last_i = prevind(str, lastindex(str))

    function skip_ws(i)
        while i <= last_i && isspace(str[i])
            i = nextind(str, i)
        end
        return i
    end

    function read_str(i)
        i > last_i || str[i] != '"' && return ("", i)
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
            pos = nextind(str, pos)
            pos = skip_ws(pos)
        end
        pos > last_i || str[pos] != '"' && break
        key, pos = read_str(pos)
        pos = skip_ws(pos)
        (pos > last_i || str[pos] != ':') && break
        pos = nextind(str, pos)
        pos = skip_ws(pos)
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

function _get_mistate()
    if isdefined(Base, :active_repl)
        repl = Base.active_repl
        if hasproperty(repl, :mistate) && !isnothing(repl.mistate)
            return repl.mistate
        end
    end
    return nothing
end

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
            # Julia ≥ 1.13: push! writes to the history file and updates the in-memory records
            if !isempty(hist) && hist[end].content == str
                return
            end
            entry = REPL.History.HistEntry(:julia, Dates.now(Dates.UTC), str, UInt32(0))
            push!(hist, entry)
            if !isopen(hist.file)
                _append_history_file(str)
            end
        else
            # Julia ≤ 1.12: Vector{String} history + parallel modes vector
            _append_history_file(str)
            if !isempty(hist) && hist[end] == str
                return
            end
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

function _clear_repl_input_area(s)
    try
        st = LineEdit.state(s)
        Base.invokelatest(LineEdit.clear_input_area, st)
        return true
    catch
        print(stdout, "\r\e[2K")
        return false
    end
end

function _repl_eval(code::AbstractString; silent::Bool = false, record_history::Bool = true)
    clean_code = strip(String(code))
    isempty(clean_code) && return

    if silent
        try
            ex = Meta.parseall(clean_code)
            Base.invokelatest(Core.eval, Main, ex)
        catch e
            @warn "jEMach background eval failed" exception = e
        end
        publish_state()
        return
    end

    s = _get_mistate()
    if !isnothing(s)
        # Wipe the (possibly multi-line) prompt + pending input; the LineEdit buffer itself
        # is left untouched, so the user's half-typed command is redrawn afterwards.
        _clear_repl_input_area(s)
        print(stdout, "\e[32m\e[1mjulia> \e[0m", clean_code, "\n")
        flush(stdout)
    else
        println(stdout, "\njulia> ", clean_code)
    end

    record_history && _append_repl_history(clean_code)

    try
        ex = Meta.parseall(clean_code)
        val = Base.invokelatest(Core.eval, Main, ex)
        try
            Core.eval(Main, Expr(:(=), :ans, QuoteNode(val)))
        catch
        end

        is_self_printing = startswith(clean_code, "println(") ||
            startswith(clean_code, "print(") ||
            startswith(clean_code, "dump(") ||
            startswith(clean_code, "jEMach.")
        if val !== nothing && !endswith(clean_code, ";") && !is_self_printing
            Base.invokelatest(
                show,
                IOContext(stdout, :limit => true, :color => true),
                MIME("text/plain"),
                val
            )
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
    return publish_state()
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
# Background watcher task
# ---------------------------------------------------------------------------

const _task_ref = Ref{Union{Task, Nothing}}(nothing)
const _running = Ref{Bool}(false)
const _socket_clients = Set{Sockets.PipeEndpoint}()
const _server_ref = Ref{Union{Sockets.PipeServer, Nothing}}(nothing)
const _last_serialized_json = Ref{String}("")
const _last_serialized_body = Ref{String}("")
const _tui_pane_ref = Ref{String}("")
const _tui_backend_ref = Ref{Symbol}(:none)
const _tui_proc_ref = Ref{Union{Base.Process, Nothing}}(nothing)

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
                                    # Keep reading bidirectional RPC commands from this TUI subscriber
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
    # Notify all subscribers that jEMach has stopped and panels should close
    stop_msg = "{\"event\":\"stop\",\"action\":\"close\"}\n"
    for client in _socket_clients
        try
            if isopen(client)
                write(client, stop_msg)
                flush(client)
            end
        catch
        end
    end

    if !isnothing(_server_ref[])
        try
            close(_server_ref[])
        catch
        end
        _server_ref[] = nothing
    end
    for client in _socket_clients
        try
            close(client)
        catch
        end
    end
    empty!(_socket_clients)
    return try
        rm(SOCKET_PATH[]; force = true)
    catch
    end
end

function _ensure_ghostty_shell_hook()
    return try
        zshenv = joinpath(homedir(), ".zshenv")
        hook_line = "[[ -o interactive && -f \"/tmp/jemach_ghostty_split_\${PPID}.sh\" ]] && source \"/tmp/jemach_ghostty_split_\${PPID}.sh\""
        existing = isfile(zshenv) ? read(zshenv, String) : ""
        if !occursin("jemach_ghostty_split_", existing)
            open(zshenv, "a") do f
                !isempty(existing) && !endswith(existing, "\n") && write(f, "\n")
                write(f, "# jEMach Ghostty native split bootstrap\n" * hook_line * "\n")
            end
        end
    catch
    end
end

function _find_ghostty_ancestor_pid()::Int
    Sys.islinux() || return 0
    pid = Int(getpid())
    for _ in 1:16
        pid <= 1 && break
        comm_file = "/proc/$pid/comm"
        stat_file = "/proc/$pid/stat"
        (isfile(comm_file) && isfile(stat_file)) || break
        comm = try
            lowercase(strip(read(comm_file, String)))
        catch
            ""
        end
        if comm == "ghostty"
            return pid
        end
        stat_str = try
            read(stat_file, String)
        catch
            ""
        end
        idx = findlast(')', stat_str)
        isnothing(idx) && break
        fields = split(strip(stat_str[(idx + 1):end]))
        length(fields) < 2 && break
        ppid = tryparse(Int, fields[2])
        isnothing(ppid) && break
        pid = ppid
    end
    return 0
end

function _trigger_ghostty_dbus_split(proj_dir::String, sock::String, st_file::String, tui_script::String)::Bool
    Sys.islinux() || return false
    (isnothing(Sys.which("gdbus")) || isnothing(Sys.which("busctl"))) && return false

    ghostty_pid = _find_ghostty_ancestor_pid()
    ghostty_pid <= 0 && return false

    _ensure_ghostty_shell_hook()

    dbus_dest = "com.mitchellh.ghostty"
    try
        out = read(`busctl --user list --no-pager`, String)
        for line in split(out, '\n')
            parts = split(strip(line))
            if length(parts) >= 3 && startswith(parts[1], ":") && parts[2] == string(ghostty_pid)
                dbus_dest = String(parts[1])
                break
            end
        end
    catch
    end

    win_path = "/com/mitchellh/ghostty/window/1"
    try
        intro = read(pipeline(`gdbus introspect --session --dest $dbus_dest --object-path /com/mitchellh/ghostty/window`, stderr = devnull), String)
        m = match(r"node\s+(?:/com/mitchellh/ghostty/window/)?(\d+)", intro)
        if !isnothing(m)
            win_path = "/com/mitchellh/ghostty/window/" * m.captures[1]
        end
    catch
    end

    split_script = "/tmp/jemach_ghostty_split_$(ghostty_pid).sh"
    sq_escape(s) = "'" * replace(s, "'" => "'\\''") * "'"
    script_body = """
    rm -f $(sq_escape(split_script))
    cd $(sq_escape(proj_dir)) 2>/dev/null || true
    export JEMACH_SOCKET=$(sq_escape(sock))
    export JEMACH_STATE=$(sq_escape(st_file))
    export JEMACH_PROJ=$(sq_escape(proj_dir))
    export JEMACH_BACKEND='ghostty'
    exec luajit $(sq_escape(tui_script)) ghostty $(sq_escape(sock)) $(sq_escape(st_file))
    """
    try
        open(split_script, "w") do f
            write(f, script_body)
        end
        run(pipeline(`gdbus call --session --dest $dbus_dest --object-path $win_path --method org.gtk.Actions.Activate split-right "[]" "{}"`, stdout = devnull, stderr = devnull))
        @async begin
            sleep(3.0)
            try
                rm(split_script; force = true)
            catch
            end
        end
        return true
    catch
        try
            rm(split_script; force = true)
        catch
        end
        return false
    end
end

function _close_tui_pane()
    backend = _tui_backend_ref[] != :none ? _tui_backend_ref[] : detect_backend()

    # 1. Close tracked background process if spawned directly (Ghostty / Kitty window fallback)
    if !isnothing(_tui_proc_ref[])
        try
            if process_running(_tui_proc_ref[])
                kill(_tui_proc_ref[])
            end
        catch
        end
        _tui_proc_ref[] = nothing
    end

    # 2. Close backend-specific pane/window if still open
    if backend == :tmux || haskey(ENV, "TMUX")
        if !isempty(_tui_pane_ref[])
            try
                run(pipeline(`tmux kill-pane -t $(_tui_pane_ref[])`, devnull))
            catch
            end
            _tui_pane_ref[] = ""
        end
        if haskey(ENV, "TMUX")
            try
                out = read(`tmux list-panes -F "#{pane_id} #{pane_current_command} #{pane_title}"`, String)
                cur_pane = try
                    strip(read(`tmux display-message -p "#{pane_id}"`, String))
                catch
                    ""
                end
                for line in split(strip(out), '\n')
                    parts = split(strip(line))
                    if !isempty(parts)
                        pid = parts[1]
                        if pid != cur_pane
                            line_str = lowercase(line)
                            if occursin("luajit", line_str) || occursin("jl_tui", line_str) || occursin("jl-assist", line_str)
                                try
                                    run(pipeline(`tmux kill-pane -t $pid`, devnull))
                                catch
                                end
                            end
                        end
                    end
                end
            catch
            end
        end
    elseif backend == :kitty
        if !isempty(_tui_pane_ref[])
            try
                run(pipeline(`kitten @ close-window --match id:$(_tui_pane_ref[])`, devnull))
            catch
            end
            _tui_pane_ref[] = ""
        end
    elseif backend == :rex
        if !isempty(_tui_pane_ref[])
            rex_bin = get(ENV, "JEMACH_REX_BIN", "rex")
            try
                if haskey(ENV, "JEMACH_REX_CLOSE_CMD")
                    cmd_str = replace(ENV["JEMACH_REX_CLOSE_CMD"], "{pane}" => _tui_pane_ref[])
                    run(pipeline(`sh -c $cmd_str`, devnull))
                else
                    run(pipeline(`$rex_bin kill-pane -t $(_tui_pane_ref[])`, devnull))
                end
            catch
            end
            _tui_pane_ref[] = ""
        end
    end
    return _tui_backend_ref[] = :none
end

function _open_tui_pane(; backend::Symbol = detect_backend(), width::Int = 65)
    tui_script = normpath(joinpath(@__DIR__, "..", "scripts", "jl_tui.lua"))
    proj_dir = _get_project_dir()
    sock = SOCKET_PATH[]
    st_file = STATE_FILE[]

    if isnothing(Sys.which("luajit"))
        @warn "luajit not found in PATH — cannot launch jEMach TUI automatically."
        return nothing
    end

    # Custom user override command template (works in any terminal/WM)
    if haskey(ENV, "JEMACH_SPLIT_CMD") && !isempty(strip(ENV["JEMACH_SPLIT_CMD"]))
        tpl = ENV["JEMACH_SPLIT_CMD"]
        cmd_str = replace(
            tpl,
            "{width}" => string(width),
            "{cwd}" => proj_dir,
            "{socket}" => sock,
            "{state}" => st_file,
            "{proj}" => proj_dir,
            "{tui_script}" => tui_script,
        )
        _tui_proc_ref[] = run(Cmd(`sh -c $cmd_str`; dir = proj_dir); wait = false)
        _tui_backend_ref[] = backend
        println("🚀 Custom jEMach TUI split launched ($backend)!")
        return nothing
    end

    if backend == :tmux
        try
            already_open = false
            if !isempty(_tui_pane_ref[])
                try
                    run(pipeline(`tmux display-message -t $(_tui_pane_ref[]) -p "#{pane_id}"`, devnull))
                    already_open = true
                catch
                    _tui_pane_ref[] = ""
                end
            end

            if already_open
                println("🚀 tmux TUI split already active ($(_tui_pane_ref[]))")
            else
                _close_tui_pane()
                cur_pane = try
                    strip(read(`tmux display-message -p "#{pane_id}"`, String))
                catch
                    ""
                end
                pane_arg = !isempty(cur_pane) ? cur_pane : "{left-of}"
                cmd = `tmux split-window -P -F "#{pane_id}" -h -l $width -c $proj_dir -e JEMACH_SOCKET=$sock -e JEMACH_STATE=$st_file -e JEMACH_PROJ=$proj_dir -e JEMACH_BACKEND=tmux luajit $tui_script $pane_arg $sock $st_file`
                pane_id = strip(read(cmd, String))
                _tui_pane_ref[] = pane_id
                _tui_backend_ref[] = :tmux
                println("🚀 tmux TUI split opened ($pane_id)!")
            end
        catch e
            @warn "Failed to open tmux TUI pane" exception = e
        end

    elseif backend == :zellij
        try
            direction_args = get(ENV, "JEMACH_ZELLIJ_FLOATING", "0") == "1" ? ["--floating"] : ["--direction", "right"]
            cmd = `zellij run $(direction_args) --name jEMach --cwd $proj_dir --close-on-exit -- env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=zellij luajit $tui_script zellij $sock $st_file`
            run(cmd; wait = false)
            _tui_backend_ref[] = :zellij
            println("🚀 Zellij TUI pane opened!")
        catch e
            @warn "Failed to open Zellij TUI pane" exception = e
        end

    elseif backend == :kitty
        try
            # Try Kitty remote control first (in-tab vsplit)
            rc_ok = false
            kitty_win_id = get(ENV, "KITTY_WINDOW_ID", "kitty")
            if !isnothing(Sys.which("kitten"))
                try
                    cmd = `kitten @ launch --type=window --location=vsplit --keep-focus --title=jEMach --cwd=$proj_dir --env JEMACH_SOCKET=$sock --env JEMACH_STATE=$st_file --env JEMACH_PROJ=$proj_dir --env JEMACH_BACKEND=kitty luajit $tui_script $kitty_win_id $sock $st_file`
                    win_id = strip(read(pipeline(cmd, stderr = devnull), String))
                    _tui_pane_ref[] = win_id
                    _tui_backend_ref[] = :kitty
                    rc_ok = true
                    println("🚀 Kitty TUI vsplit opened (window $win_id)!")
                catch
                    rc_ok = false
                end
            end

            # Fallback to companion Kitty OS window if remote control is disabled
            if !rc_ok
                cmd = `kitty --title=jEMach --directory=$proj_dir -o initial_window_width=$(width)c -o remember_window_size=no env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=kitty luajit $tui_script $kitty_win_id $sock $st_file`
                _tui_proc_ref[] = run(cmd; wait = false)
                _tui_backend_ref[] = :kitty
                println("🚀 Kitty companion TUI window opened! (Tip: set `allow_remote_control yes` in kitty.conf for in-tab vsplit)")
            end
        catch e
            @warn "Failed to open Kitty TUI window" exception = e
        end

    elseif backend == :ghostty
        try
            if haskey(ENV, "JEMACH_GHOSTTY_CMD") && !isempty(strip(ENV["JEMACH_GHOSTTY_CMD"]))
                tpl = ENV["JEMACH_GHOSTTY_CMD"]
                cmd_str = replace(
                    tpl,
                    "{width}" => string(width),
                    "{cwd}" => proj_dir,
                    "{socket}" => sock,
                    "{state}" => st_file,
                    "{proj}" => proj_dir,
                    "{tui_script}" => tui_script,
                )
                _tui_proc_ref[] = run(Cmd(`sh -c $cmd_str`; dir = proj_dir); wait = false)
                println("🚀 Ghostty jEMach TUI custom command launched!")
            elseif Sys.isapple()
                cmd = `open -na Ghostty.app --args --title=jEMach --working-directory=$proj_dir --window-width=$width --wait-after-command=false -e env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=ghostty luajit $tui_script ghostty $sock $st_file`
                _tui_proc_ref[] = run(cmd; wait = false)
                println("🚀 Ghostty jEMach TUI window opened!")
            else
                mode = lowercase(get(ENV, "JEMACH_GHOSTTY_MODE", "split"))
                if mode == "split" && _trigger_ghostty_dbus_split(proj_dir, sock, st_file, tui_script)
                    println("🚀 Ghostty TUI right-split opened!")
                elseif mode == "tab"
                    cmd = `ghostty +new-tab -e env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=ghostty luajit $tui_script ghostty $sock $st_file`
                    _tui_proc_ref[] = run(cmd; wait = false)
                    println("🚀 Ghostty jEMach TUI tab opened!")
                else
                    cmd = `ghostty --gtk-single-instance=false --title=jEMach --working-directory=$proj_dir --window-width=$width --wait-after-command=false -e env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=ghostty luajit $tui_script ghostty $sock $st_file`
                    _tui_proc_ref[] = run(cmd; wait = false)
                    println("🚀 Ghostty jEMach TUI window opened!")
                end
            end
            _tui_backend_ref[] = :ghostty
        catch e
            @warn "Failed to launch Ghostty TUI split/window." exception = e
        end

    elseif backend == :rex
        rex_bin = get(ENV, "JEMACH_REX_BIN", "rex")
        try
            if haskey(ENV, "JEMACH_REX_SPLIT_CMD") && !isempty(strip(ENV["JEMACH_REX_SPLIT_CMD"]))
                tpl = ENV["JEMACH_REX_SPLIT_CMD"]
                cmd_str = replace(
                    tpl,
                    "{width}" => string(width),
                    "{cwd}" => proj_dir,
                    "{socket}" => sock,
                    "{state}" => st_file,
                    "{proj}" => proj_dir,
                    "{tui_script}" => tui_script,
                )
                out = strip(read(`sh -c $cmd_str`, String))
                _tui_pane_ref[] = out
                _tui_backend_ref[] = :rex
                println("🚀 Rex TUI split opened!")
            elseif !isnothing(Sys.which(rex_bin))
                pane_arg = get(ENV, "REX_PANE_ID", "rex")
                opened = false
                # Probe candidate Rex CLI split subcommands (pane split vs tmux-compatible split-window)
                for candidate in (
                        `$rex_bin pane split --direction right --size $width --cwd $proj_dir -- env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=rex luajit $tui_script $pane_arg $sock $st_file`,
                        `$rex_bin split-window -h -l $width -c $proj_dir env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=rex luajit $tui_script $pane_arg $sock $st_file`,
                        `$rex_bin split --right --cwd $proj_dir -- env JEMACH_SOCKET=$sock JEMACH_STATE=$st_file JEMACH_PROJ=$proj_dir JEMACH_BACKEND=rex luajit $tui_script $pane_arg $sock $st_file`,
                    )
                    try
                        run(pipeline(candidate, stderr = devnull))
                        opened = true
                        break
                    catch
                    end
                end
                _tui_backend_ref[] = :rex
                if opened
                    println("🚀 Rex TUI split opened!")
                else
                    @info "Rex session detected. Open a Rex split and run:\n  ./scripts/jl-assist -i\n(Or customize ENV[\"JEMACH_REX_SPLIT_CMD\"])"
                end
            else
                @info "Rex backend selected (binary '$rex_bin' not yet in PATH). Open a split and run:\n  ./scripts/jl-assist -i"
            end
        catch e
            @warn "Failed to open Rex TUI split" exception = e
        end

    else
        @info "Terminal backend: $backend. To launch the interactive TUI in any terminal split or window, run:\n  ./scripts/jl-assist -i\n  # or directly:\n  luajit $(tui_script) standalone $(sock) $(st_file)"
    end
    return nothing
end

function publish_state()
    return try
        if _running[] && (isnothing(_server_ref[]) || !isopen(_server_ref[]) || !ispath(SOCKET_PATH[]))
            _start_socket_server()
        end
        state = _collect_state_dod!(_shared_workspace_table[])
        pkgs = _get_packages()
        body = _serialize_dod_body(state, pkgs)

        # Avoid redundant disk writes and network flooding when nothing except wall-clock time changed
        if body == _last_serialized_body[]
            return
        end
        _last_serialized_body[] = body
        json = "{\"timestamp\":" * string(round(Int, time())) * "," * body
        _last_serialized_json[] = json

        # Write to file (fallback / legacy) atomically
        temp_file = STATE_FILE[] * ".tmp"
        open(temp_file, "w") do f
            write(f, json)
        end
        mv(temp_file, STATE_FILE[]; force = true)

        # Broadcast to all UNIX domain socket subscribers
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

function start(; split::Bool = true, backend::Symbol = :auto, width::Int = 65, quiet::Bool = false)
    if backend != :auto
        _backend_override[] = backend
    end
    _load_procedures!()
    if _running[]
        if isnothing(_server_ref[]) || !isopen(_server_ref[]) || !ispath(SOCKET_PATH[])
            _start_socket_server()
        end
        !quiet && !split && @info "jEMach Watcher already running"
    else
        _running[] = true
        _start_socket_server()
        _task_ref[] = @async begin
            !quiet && @info "jEMach Watcher started — writing state to $(STATE_FILE[]) and socket $(SOCKET_PATH[]) [backend: $(detect_backend())]"
            while _running[]
                publish_state()
                sleep(UPDATE_INTERVAL)
            end
            _stop_socket_server()
            !quiet && @info "jEMach Watcher stopped"
        end
    end

    if split
        # Publish initial state immediately so the state file is present before TUI starts
        publish_state()
        _open_tui_pane(; backend = detect_backend(backend), width = width)
    end
    return nothing
end

function stop(; quiet::Bool = false)
    _running[] = false
    _stop_socket_server()
    _close_tui_pane()
    !quiet && @info "jEMach Watcher stopped and TUI panel closed."
    return nothing
end

"""
    ui(; backend::Symbol = :auto, width::Int = 65)

Open the interactive jEMach TUI split/window for the current terminal or multiplexer.
"""
function ui(; backend::Symbol = :auto, width::Int = 65)
    return start(; split = true, backend = backend, width = width, quiet = true)
end

"""
    backend(b::Symbol = :auto; split::Bool = true, width::Int = 65)

Switch the active jEMach terminal backend (e.g. `:ghostty`, `:kitty`, `:tmux`, `:zellij`, `:rex`)
and open/refresh the TUI panel.
"""
function backend(b::Symbol = :auto; split::Bool = true, width::Int = 65)
    if b != :auto
        _backend_override[] = b
    end
    if _running[]
        publish_state()
        if split && !_is_tui_open()
            _open_tui_pane(; backend = detect_backend(b), width = width)
        end
    else
        start(; split = split, backend = b, width = width)
    end
    return detect_backend(b)
end

function _is_tui_open()::Bool
    for c in _socket_clients
        isopen(c) && return true
    end
    if !isempty(_tui_pane_ref[]) && haskey(ENV, "TMUX")
        try
            run(pipeline(`tmux display-message -t $(_tui_pane_ref[]) -p "#{pane_id}"`, devnull))
            return true
        catch
        end
    end
    if !isnothing(_tui_proc_ref[]) && process_running(_tui_proc_ref[])
        return true
    end
    return false
end

"""
    toggle(; backend::Symbol = :auto, width::Int = 65)

Toggle the interactive jEMach TUI split/window open or closed while keeping the REPL watcher active.
"""
function toggle(; backend::Symbol = :auto, width::Int = 65)
    if _is_tui_open()
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
        _close_tui_pane()
        println("\e[2m◆ jEMach TUI closed (watcher remains active in background)\e[0m")
    else
        ui(; backend = backend, width = width)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# REPL command layer (shared by the `jemach>` mode and the `@jemach` macro)
# ---------------------------------------------------------------------------

const _JEMACH_COMMANDS = [
    "help", "ui", "toggle", "open", "close", "ws", "vars", "ls", "find", "show",
    "run", "make", "rec", "stop", "inspect", "save", "reload", "status", "shutdown",
]

function _print_jemach_help(io::IO = stdout)
    bold, cyan, dim, reset = "\e[1m", "\e[36m", "\e[2m", "\e[0m"
    rows = [
        ("ui | toggle", "Toggle the TUI split/window (also Alt+j)"),
        ("open | close", "Open / close the TUI panel"),
        ("ws [filter]", "Workspace table with memory sizes (also `workspace()`)"),
        ("ls [query] | find <q>", "List / search saved procedures"),
        ("show <name>", "Show a procedure card with its source"),
        ("run <name> [args...]", "Run a procedure with profiling (`run f(1, x=2)` works too)"),
        ("<name> [args...]", "Shortcut: run an existing procedure directly"),
        ("make <name> [N]", "Create a procedure from the last N commands (default 5)"),
        ("rec [name] | stop", "Start / stop recording a procedure (also Alt+r)"),
        ("inspect <expr> | i <expr>", "Deep inspection of a variable/function"),
        ("save", "Save a clean, replayable session script"),
        ("reload", "Reload procedures/ into Main"),
        ("status", "Watcher, socket and terminal diagnostics"),
        ("shutdown", "Stop the watcher and close the TUI"),
    ]
    println(io, bold * cyan * "jEMach REPL mode" * reset * dim * "  (Backspace on empty line → julia>, Tab completes)" * reset)
    for (c, d) in rows
        println(io, "  " * cyan * rpad(c, 26) * reset * " " * d)
    end
    return nothing
end

function _next_proc_name()::Symbol
    _load_procedures!()
    i = length(_procedures) + 1
    while haskey(_procedures, Symbol("proc_", i)) || isdefined(Main, Symbol("proc_", i))
        i += 1
    end
    return Symbol("proc_", i)
end

_esc_arg(a) = (a isa Expr && a.head == :kw) ? Expr(:kw, a.args[1], esc(a.args[2])) : esc(a)

function _split_call_args(args)
    params = Any[]
    positional = Any[]
    for a in args
        if a isa Expr && a.head == :parameters
            append!(params, a.args)
        else
            push!(positional, a)
        end
    end
    return params, positional
end

"""Build `run_procedure(:name, args...; kwargs...)` from a parsed call or symbol (unescaped)."""
function _run_expr(target)
    rp = GlobalRef(jEMach, :run_procedure)
    if target isa Symbol
        return Expr(:call, rp, QuoteNode(target))
    elseif target isa Expr && target.head == :call && target.args[1] isa Symbol
        params, positional = _split_call_args(target.args[2:end])
        call = Expr(:call, rp)
        isempty(params) || push!(call.args, Expr(:parameters, params...))
        push!(call.args, QuoteNode(target.args[1]))
        append!(call.args, positional)
        return call
    end
    throw(ArgumentError("expected a procedure name or call, got: $(target)"))
end

function _run_from_string(rest::AbstractString)
    s = strip(rest)
    target = try
        Meta.parse(s)
    catch
        nothing
    end
    if !(target isa Symbol || (target isa Expr && target.head == :call && target.args[1] isa Symbol))
        # `name 1 2` or `name 1, x=2` → `name(1, 2)` / `name(1, x=2)`
        m = match(r"^([A-Za-z_][A-Za-z0-9_!]*)\s+(.*)$"s, s)
        isnothing(m) && throw(ArgumentError("usage: run <name> [args...]  or  run name(args...)"))
        argstr = strip(m.captures[2])
        occursin(',', argstr) || (argstr = join(split(argstr), ", "))
        target = Meta.parse(m.captures[1] * "(" * argstr * ")")
    end
    return Base.invokelatest(Core.eval, Main, _run_expr(target))
end

"""
    _exec_command(line::AbstractString)

Execute one `jemach>` command line. Returns a value only when it is worth displaying
(e.g. the result of `run`, or a `ProcedureInfo` for `show`).
"""
function _exec_command(line::AbstractString)
    s = strip(line)
    isempty(s) && return nothing
    m = match(r"^(\S+)\s*(.*)$"s, s)
    cmd = lowercase(m.captures[1])
    rest = String(strip(m.captures[2]))

    if cmd in ("help", "?", "h")
        _print_jemach_help()
    elseif cmd in ("ui", "toggle")
        toggle()
    elseif cmd == "open"
        _is_tui_open() ? println("TUI is already open.") : ui()
    elseif cmd == "close"
        _is_tui_open() ? toggle() : println("TUI is not open.")
    elseif cmd in ("ws", "vars", "workspace")
        workspace(rest)
    elseif cmd in ("ls", "list", "procs", "find", "search")
        list_procedures(rest)
    elseif cmd == "show"
        isempty(rest) && throw(ArgumentError("usage: show <procedure>"))
        _load_procedures!()
        sym = Symbol(rest)
        haskey(_procedures, sym) || throw(ArgumentError("no procedure named '$rest'"))
        return _procedures[sym]
    elseif cmd == "run"
        isempty(rest) && throw(ArgumentError("usage: run <name> [args...]  or  run name(args...)"))
        return _run_from_string(rest)
    elseif cmd == "make"
        parts = split(rest)
        isempty(parts) && throw(ArgumentError("usage: make <name> [N]"))
        n = length(parts) >= 2 ? something(tryparse(Int, parts[2]), 0) : 0
        make_procedure(Symbol(parts[1]); last = n)
    elseif cmd in ("rec", "record")
        record(isempty(rest) ? _next_proc_name() : Symbol(rest))
    elseif cmd in ("stop", "record_stop")
        if _recording[]
            record_stop()
        else
            println("No recording in progress (use `shutdown` to stop the jEMach watcher).")
        end
    elseif cmd in ("inspect", "i")
        isempty(rest) && throw(ArgumentError("usage: inspect <expr>"))
        inspect_var(Main, rest)
    elseif cmd == "save"
        save_clean_session()
    elseif cmd in ("reload", "autoload")
        autoload_procedures!()
        publish_state()
        println("✓ Loaded $(length(_procedures)) procedure(s) into Main")
    elseif cmd in ("status", "info")
        status()
        info = terminal_info()
        for k in (:term, :term_program, :tmux, :zellij, :kitty, :ghostty, :rex)
            println("  ", rpad(string(k), 14), info[k])
        end
        println("  ", rpad("procedures", 14), length(_procedures), "   recording: ", _recording[] ? string(_record_name[]) : "no")
        println("  ", rpad("tui open", 14), _is_tui_open())
    elseif cmd in ("shutdown", "quit")
        stop()
    else
        _load_procedures!()
        if haskey(_procedures, Symbol(m.captures[1]))
            return _run_from_string(s)
        end
        println("Unknown jemach command '$(m.captures[1])'. Type `help` for the list of commands.")
    end
    return nothing
end

"""
    @jemach
    @jemach <command> [args...]

Without arguments, toggle the jEMach TUI panel. With arguments, run a `jemach>` command:

```julia
@jemach ls                 # list procedures
@jemach ls matrix          # search procedures
@jemach ws                 # workspace table
@jemach inspect df.col     # deep inspection
@jemach make myproc 4      # procedure from the last 4 commands
@jemach run myproc(10, x)  # run a procedure (arguments are evaluated in the caller)
@jemach rec myproc         # start recording …
@jemach stop               # … and stop
@jemach status
```
"""
macro jemach(args...)
    isempty(args) && return :($(GlobalRef(jEMach, :toggle))())
    cmd = lowercase(string(args[1]))
    rest = args[2:end]
    if cmd == "run" && !isempty(rest)
        target = rest[1]
        if target isa Expr && target.head == :call && target.args[1] isa Symbol
            params, positional = _split_call_args(target.args[2:end])
            call = Expr(:call, GlobalRef(jEMach, :run_procedure))
            isempty(params) || push!(call.args, Expr(:parameters, map(_esc_arg, params)...))
            push!(call.args, QuoteNode(target.args[1]))
            append!(call.args, map(_esc_arg, positional))
            return call
        else
            return Expr(:call, GlobalRef(jEMach, :run_procedure), QuoteNode(Symbol(string(target))), map(_esc_arg, rest[2:end])...)
        end
    elseif cmd in ("inspect", "i") && !isempty(rest)
        expr_str = join(map(string, rest), " ")
        return :($(GlobalRef(jEMach, :inspect_var))($__module__, $expr_str))
    end
    line = join(vcat([cmd], [a isa AbstractString ? String(a) : string(a) for a in rest]), " ")
    return :($(GlobalRef(jEMach, :_exec_command))($line))
end

"""
    @inspect expr

Deep-inspect `expr` (type, size, methods & return types, the REPL command that created it,
and documentation). Shorthand for `inspect_var(@__MODULE__, "expr")`.
"""
macro inspect(ex)
    return :($(GlobalRef(jEMach, :inspect_var))($__module__, $(string(ex))))
end

# ---------------------------------------------------------------------------
# Dedicated `jemach>` REPL mode with Tab completion
# ---------------------------------------------------------------------------

struct JEMachCompletionProvider <: LineEdit.CompletionProvider end

function _main_symbol_names()::Vector{String}
    out = String[]
    for sym in Base.invokelatest(names, Main; all = true, imported = true)
        n = string(sym)
        (_skip_name(n) || startswith(n, "#") || startswith(n, "_")) && continue
        push!(out, n)
    end
    return out
end

function _jemach_completions(partial::AbstractString)
    wm = match(r"(\S*)$", partial)
    word = isnothing(wm) ? "" : String(wm.captures[1])
    before = String(codeunits(partial)[1:(ncodeunits(partial) - ncodeunits(word))])
    words_before = split(before)
    proc_names = String[string(k) for k in keys(_procedures)]
    cands = if isempty(words_before)
        vcat(_JEMACH_COMMANDS, proc_names)
    else
        c = lowercase(words_before[1])
        if c in ("run", "show", "ls", "find") && length(words_before) == 1
            proc_names
        elseif c in ("inspect", "i", "ws", "vars")
            _main_symbol_names()
        else
            String[]
        end
    end
    matches = sort!(unique!(filter(x -> startswith(x, word), cands)))
    return matches, word
end

function LineEdit.complete_line(::JEMachCompletionProvider, s; hint::Bool = false)
    buf = LineEdit.buffer(s)
    partial = isdefined(REPL, :beforecursor) ? REPL.beforecursor(buf) : String(buf.data[1:position(buf)])
    matches, word = _jemach_completions(partial)
    return matches, word, !isempty(matches)
end

const _jemach_mode_ref = Ref{Any}(nothing)

function _enter_jemach_mode(s)
    mode = _jemach_mode_ref[]
    isnothing(mode) && return nothing
    buf = copy(LineEdit.buffer(s))
    return LineEdit.transition(s, mode) do
        LineEdit.state(s, mode).input_buffer = buf
    end
end

function _toggle_recording_key(s)
    _clear_repl_input_area(s)
    try
        _recording[] ? record_stop() : record(_next_proc_name())
    catch e
        @error "jEMach recording failed" exception = e
    end
    println(stdout)
    LineEdit.refresh_line(s)
    return :ok
end

function _install_jemach_mode!(repl)
    (hasproperty(repl, :interface) && isdefined(repl, :interface)) || return nothing
    iface = repl.interface
    any(m -> m isa LineEdit.Prompt && m.complete isa JEMachCompletionProvider, iface.modes) && return nothing
    main = iface.modes[1]
    main isa LineEdit.Prompt || return nothing

    jm = LineEdit.Prompt(
        "jemach> ";
        prompt_prefix = "\e[36m\e[1m",
        prompt_suffix = main.prompt_suffix,
        complete = JEMachCompletionProvider(),
        sticky = true,
    )
    jm.repl = repl
    hp = main.hist
    if hp isa REPL.REPLHistoryProvider
        hp.mode_mapping[:jemach] = jm
    end
    jm.hist = hp
    # Commands are evaluated on the REPL backend (proper `ans`, error display, Ctrl-C)
    jm.on_done = REPL.respond(line -> Expr(:call, GlobalRef(jEMach, :_exec_command), line), repl, main)

    prefix_prompt, prefix_keymap = LineEdit.setup_prefix_keymap(hp, jm)
    keymaps = Dict{Any, Any}[]
    if !isdefined(REPL, :History)
        push!(keymaps, last(LineEdit.setup_search_keymap(hp)))
    end
    push!(keymaps, Dict{Any, Any}("\er" => (s, o...) -> _toggle_recording_key(s)))
    push!(keymaps, REPL.mode_keymap(main), prefix_keymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults)
    jm.keymap_dict = LineEdit.keymap(keymaps)

    push!(iface.modes, jm)
    _jemach_mode_ref[] = jm

    use_bracket = isdefined(LineEdit, :bracket_insert_keymap) &&
        hasproperty(repl, :options) && hasproperty(repl.options, :auto_insert_closing_bracket) &&
        repl.options.auto_insert_closing_bracket && haskey(LineEdit.bracket_insert_keymap, '}')

    main_keymap = Dict{Any, Any}(
        '}' => function (s, o...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                return _enter_jemach_mode(s)
            elseif use_bracket
                return LineEdit.bracket_insert_keymap['}'](s, o...)
            else
                LineEdit.edit_insert(s, '}')
                isdefined(LineEdit, :check_show_hint) && LineEdit.check_show_hint(s)
                return nothing
            end
        end,
        "\em" => (s, o...) -> _enter_jemach_mode(s),
        "\er" => (s, o...) -> _toggle_recording_key(s),
    )
    main.keymap_dict = LineEdit.keymap_merge(main.keymap_dict, main_keymap)
    return jm
end

"""
    status()

Print whether the jEMach watcher is running, with the active backend, socket and state file.
"""
function status()
    b = detect_backend()
    return if _running[]
        println("jEMach Watcher is RUNNING [backend: $b]  →  socket: $(SOCKET_PATH[]), state: $(STATE_FILE[])")
    else
        println("jEMach Watcher is STOPPED [backend: $b]")
    end
end

function _setup_repl_hooks(repl)
    return @async begin
        # Wait briefly for REPL interface & OhMyREPL initialization
        for _ in 1:25
            if isdefined(Base, :active_repl_backend) && !isnothing(Base.active_repl_backend) &&
                    hasproperty(repl, :interface) && !isnothing(repl.interface)
                break
            end
            sleep(0.05)
        end
        try
            if isdefined(Base, :active_repl_backend) && !isnothing(Base.active_repl_backend)
                push!(
                    Base.active_repl_backend.ast_transforms,
                    function (ast)
                        @async (sleep(0.02); publish_state())
                        return ast
                    end
                )
            end
        catch
        end

        # Register Alt+j (\ej) keybinding in the julia> prompt to toggle TUI split
        try
            sleep(0.25) # let OhMyREPL finish installing its keymap first if present
            if hasproperty(repl, :interface) && !isnothing(repl.interface) && !isempty(repl.interface.modes)
                julia_mode = repl.interface.modes[1]
                le = parentmodule(typeof(julia_mode))
                toggle_keymap = Dict{Any, Any}(
                    "\ej" => function (s, o...)
                        @async toggle()
                        return :ok
                    end,
                )
                julia_mode.keymap_dict = Base.invokelatest(le.keymap_merge, julia_mode.keymap_dict, toggle_keymap)
            end
        catch
        end

        # Install the `jemach>` mode (`}` / Alt+m) and the Alt+r recording shortcut
        try
            Base.invokelatest(_install_jemach_mode!, repl)
        catch e
            @debug "jEMach: failed to install jemach> REPL mode" exception = e
        end
    end
end

function __init__()
    _load_zig_native!()
    hist_path = _history_path()
    if isfile(hist_path)
        HIST_START_POS[] = filesize(hist_path)
    else
        HIST_START_POS[] = 0
    end
    # Initialize unique session paths based on the project folder
    safe_name = _get_safe_name(_get_project_dir())
    STATE_FILE[] = "/tmp/jl_tui_state_" * safe_name * ".json"
    SOCKET_PATH[] = "/tmp/jemach_" * safe_name * ".sock"

    # Automatically clean up socket and close TUI pane when Julia exits
    atexit(() -> stop(quiet = true))

    # Make saved procedures callable (and `?`-documented) in Main right away.
    # Opt out with ENV["JEMACH_AUTOLOAD"] = "0".
    if get(ENV, "JEMACH_AUTOLOAD", "1") != "0"
        try
            autoload_procedures!()
        catch e
            @debug "jEMach: autoload of procedures failed" exception = e
        end
    end

    # Hook interactive REPL (instant AST refresh + Alt+j toggle shortcut)
    if isinteractive()
        if isdefined(Base, :active_repl) && !isnothing(Base.active_repl)
            _setup_repl_hooks(Base.active_repl)
        else
            Base.atreplinit(_setup_repl_hooks)
        end
    end

    return start(split = false, quiet = true)
end

# ---------------------------------------------------------------------------
# Precompilation of hot paths (reduces first-refresh latency after `using jEMach`)
# ---------------------------------------------------------------------------
precompile(_collect_state_dod!, (WorkspaceTable,))
precompile(_collect_module_items_dod!, (WorkspaceTable, Module, String, Bool))
precompile(_collect_children_dod!, (WorkspaceTable, Any, String, String, Int, Int))
precompile(_get_packages, ())
precompile(_serialize_dod_body, (WorkspaceTable, Vector{Dict{String, String}}))
precompile(_serialize_dod, (WorkspaceTable, Vector{Dict{String, String}}))
precompile(publish_state, ())
precompile(_parse_json_cmd, (String,))
precompile(_handle_socket_message, (String,))
precompile(_load_procedures!, ())
precompile(get_recent_commands, ())
precompile(_parse_history_bytes, (Vector{UInt8}, Bool, Int))
precompile(_write_json_str, (IOBuffer, String, Vector{UInt8}))
precompile(_write_json_str_julia, (IOBuffer, String))
precompile(detect_backend, ())
precompile(detect_backend, (Symbol,))
precompile(_value_preview, (Int,))
precompile(_value_preview, (Float64,))
precompile(_value_preview, (String,))
precompile(_value_preview, (Vector{Float64},))
precompile(_exec_command, (String,))
precompile(_jemach_completions, (String,))
precompile(workspace, (String,))
precompile(inspect_var, (Module, String))
precompile(Base.show, (Base.TTY, MIME"text/plain", WorkspaceTable))
precompile(Base.show, (IOContext{Base.TTY}, MIME"text/plain", WorkspaceTable))
precompile(Base.show, (IOContext{Base.TTY}, MIME"text/plain", ProcedureInfo))

end  # module jEMach
