# Procedure metadata, discovery, AST parameterization, recording, execution & error tracking.

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
    last_run_cmd::String
    last_error::String
    last_error_detail::String
    last_error_line::Int
    last_error_cmd::String
    origin::Symbol # :disk, :modified, :live, :unloaded
    disk_code::String
    live_code::String
    edit_code::String
    imports_block::String
    disk_hash::UInt64
    live_hash::UInt64
    generation::Int
    last_args_str::String
    func_start_line::Int
    prev_time_ms::Float64
    prev_alloc_bytes::Int
    prev_generation::Int
    bench_samples::Int
    min_time_ms::Float64
    max_time_ms::Float64
    last_result_repr::String
end

function ProcedureInfo(
        name::Symbol,
        signature::AbstractString,
        file::AbstractString,
        doc::AbstractString,
        code::AbstractString,
        last_run_time_ms::Real,
        last_run_alloc_bytes::Integer,
        last_run_status::Symbol,
        last_run_at::AbstractString;
        origin::Symbol = isempty(file) ? :live : :disk,
        disk_code::AbstractString = isempty(file) ? "" : code,
        live_code::AbstractString = code,
        edit_code::AbstractString = code,
        imports_block::AbstractString = "",
        disk_hash::UInt64 = UInt64(0),
        live_hash::UInt64 = UInt64(0),
        generation::Int = 1,
        last_args_str::AbstractString = "",
        func_start_line::Int = 1,
        prev_time_ms::Real = 0.0,
        prev_alloc_bytes::Integer = 0,
        prev_generation::Int = 0,
        bench_samples::Int = 0,
        min_time_ms::Real = 0.0,
        max_time_ms::Real = 0.0,
        last_result_repr::AbstractString = "",
    )
    return ProcedureInfo(
        name, String(signature), String(file), String(doc), String(code),
        Float64(last_run_time_ms), Int(last_run_alloc_bytes), last_run_status, String(last_run_at),
        "", "", "", 0, "",
        origin, String(disk_code), String(live_code), String(edit_code), String(imports_block),
        disk_hash, live_hash, generation, String(last_args_str), func_start_line,
        Float64(prev_time_ms), Int(prev_alloc_bytes), prev_generation, bench_samples,
        Float64(min_time_ms), Float64(max_time_ms), String(last_result_repr)
    )
end

struct FailedCommandInfo
    id::Int
    cmd::String
    source::String
    proc_name::String
    error_msg::String
    error_detail::String
    error_line::Int
    failed_stmt::String
    timestamp::String
end

function Base.show(io::IO, p::ProcedureInfo)
    print(io, "ProcedureInfo(:$(p.name), \"$(p.signature)\", origin=:$(p.origin), status=:$(p.last_run_status))")
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

    origin_badge = if p.origin == :modified
        yellow * bold * "⚡ MODIFIED (v$(p.generation))" * reset
    elseif p.origin == :live
        cyan * bold * "◆ LIVE (in memory)" * reset
    elseif p.origin == :unloaded
        dim * "○ UNLOADED" * reset
    else
        green * "● DISK" * reset
    end

    status_badge = p.last_run_status == :ok ? (green * "✓ OK" * reset) :
        p.last_run_status == :error ? (red * "✗ ERROR" * reset) : (dim * "○ NEVER RUN" * reset)
    metrics_str = if p.last_run_status != :never
        s_info = p.bench_samples > 1 ? " [median of $(p.bench_samples): $(p.min_time_ms)–$(p.max_time_ms) ms]" : ""
        d_info = if p.prev_time_ms > 0.0 && p.last_run_time_ms > 0.0 && p.last_run_status == :ok
            pct = round(((p.last_run_time_ms - p.prev_time_ms) / p.prev_time_ms) * 100.0; digits = 1)
            vs_l = p.prev_generation > 0 && p.prev_generation != p.generation ? " vs v$(p.prev_generation)" : " vs prev"
            " ($(pct > 0 ? "+" : "")$(pct)%$(vs_l))"
        else
            ""
        end
        "$(p.last_run_time_ms) ms, $(Base.format_bytes(p.last_run_alloc_bytes))$(s_info)$(d_info) (at $(p.last_run_at))"
    else
        "-"
    end
    file_disp = isempty(p.file) ? "(memory only)" : p.file

    println(io, bold * cyan * "╭─ Procedure: " * string(p.name) * " " * ("─"^max(1, 50 - length(string(p.name)))) * "╮" * reset)
    println(io, "│ " * bold * "Signature: " * reset * cyan * p.signature * reset * "  " * origin_badge)
    println(io, "│ " * bold * "File:      " * reset * file_disp)
    println(io, "│ " * bold * "Status:    " * reset * status_badge * "  " * yellow * metrics_str * reset)
    !isempty(p.last_run_cmd) && println(io, "│ " * bold * "Last Call: " * reset * cyan * p.last_run_cmd * reset)
    if p.last_run_status == :error && !isempty(p.last_error)
        println(io, "│ " * bold * red * "Error:     " * reset * red * p.last_error * reset)
        if p.last_error_line > 0 && !isempty(p.last_error_cmd)
            println(io, "│ " * bold * red * "At Line $(p.last_error_line): " * reset * p.last_error_cmd)
        end
    end
    !isempty(p.doc) && println(io, "│ " * bold * "Doc:       " * reset * dim * replace(p.doc, '\n' => " ") * reset)
    if !isempty(strip(p.code))
        println(io, cyan * "├─ Source " * ("─"^58) * "┤" * reset)
        for (li, line) in enumerate(split(rstrip(p.code), '\n'))
            is_err_line = p.last_run_status == :error && p.last_error_line == li
            if is_err_line
                println(io, "│ " * red * bold * "✗" * lpad(string(li), 2) * " │ " * line * reset)
            else
                println(io, "│ " * dim * lpad(string(li), 3) * " │ " * reset * line)
            end
        end
    end
    if p.last_run_status == :error && !isempty(strip(p.last_error_detail))
        println(io, red * "├─ Error Detail " * ("─"^52) * "┤" * reset)
        for line in split(rstrip(p.last_error_detail), '\n')
            println(io, "│ " * red * line * reset)
        end
    end
    print(io, bold * cyan * "╰" * ("─"^67) * "╯" * reset)
    return nothing
end

const _procedures = Dict{Symbol, ProcedureInfo}()
const _proc_registry_epoch = Ref{UInt64}(1)
const _parsed_proc_mtimes = Dict{String, Float64}()
const _parsed_proc_names = Dict{String, Symbol}()
const _loaded_proc_mtimes = Dict{String, Float64}()
const _failed_commands = FailedCommandInfo[]
const _failed_cmd_seq = Ref{Int}(0)
const _cmd_outcomes = Dict{String, Symbol}()
const _cmd_outcome_order = String[]
const _MAX_FAILED_COMMANDS = 30
const _MAX_CMD_OUTCOMES = 200
const _recording = Ref{Bool}(false)
const _record_name = Ref{Symbol}(:proc)
const _record_start_pos = Ref{Int64}(0)
const _record_hist_idx = Ref{Int}(0)
const _orig_julia_prompt = Ref{Any}(nothing)
const _orig_julia_prefix = Ref{Any}(nothing)

