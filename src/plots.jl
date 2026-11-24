# Plot & PNG artifact capture for terminal graphics preview (Ghostty / Kitty / tmux).

struct PlotEntry
    id::Int
    title::String
    timestamp::String
    filepath::String
    width::Int
    height::Int
    bytes::Int
end

const _plots = PlotEntry[]
const _plot_seq = Ref{Int}(0)
const _last_plot_oid = Ref{UInt64}(UInt64(0))
const _plots_lock = ReentrantLock()
const _MAX_PLOTS = 24

function _png_dimensions(data::Vector{UInt8})::Tuple{Int, Int}
    length(data) < 24 && return (0, 0)
    # PNG magic: 89 50 4E 47 0D 0A 1A 0A, followed by 4-byte length + "IHDR"
    if data[1] == 0x89 && data[2] == 0x50 && data[3] == 0x4e && data[4] == 0x47 &&
            data[13] == UInt8('I') && data[14] == UInt8('H') && data[15] == UInt8('D') && data[16] == UInt8('R')
        w = (Int(data[17]) << 24) | (Int(data[18]) << 16) | (Int(data[19]) << 8) | Int(data[20])
        h = (Int(data[21]) << 24) | (Int(data[22]) << 16) | (Int(data[23]) << 8) | Int(data[24])
        return (max(0, w), max(0, h))
    end
    return (0, 0)
end

function _is_plot_candidate(val)::Bool
    isnothing(val) && return false
    (val isa Number || val isa Bool || val isa AbstractChar || val isa AbstractString ||
        val isa Symbol || val isa Module || val isa Function || val isa DataType ||
        val isa UnionAll || val isa Tuple || val isa NamedTuple || val isa AbstractDict ||
        val isa WorkspaceTable || val isa ProcedureInfo) && return false
    if val isa AbstractArray
        el = eltype(val)
        (el <: Number || el <: AbstractString || el <: Symbol || el === Any) && return false
    end
    return try
        Base.invokelatest(showable, MIME("image/png"), val)
    catch
        false
    end
end

"""
    capture_plot(val; title = "") -> Union{PlotEntry, Nothing}

Render `val` as `image/png` into the active jEMach session plot gallery so it can be
viewed directly inside Ghostty / Kitty / TUI `[5] Plots` tab or exported to disk.
"""
function capture_plot(val; title::AbstractString = "")::Union{PlotEntry, Nothing}
    isnothing(val) && return nothing
    ok_png = try
        Base.invokelatest(showable, MIME("image/png"), val)
    catch
        false
    end
    !ok_png && return nothing

    png_bytes = try
        buf = IOBuffer()
        Base.invokelatest(show, buf, MIME("image/png"), val)
        take!(buf)
    catch
        UInt8[]
    end
    length(png_bytes) < 24 && return nothing

    sess_dir = _ensure_session!()
    plots_dir = joinpath(sess_dir, "plots")
    if !isdir(plots_dir)
        mkpath(plots_dir; mode = 0o700)
    end

    return lock(_plots_lock) do
        _plot_seq[] += 1
        id = _plot_seq[]
        fpath = joinpath(plots_dir, "plot_$(id).png")
        write(fpath, png_bytes)
        try
            chmod(fpath, 0o600)
        catch
        end
        w, h = _png_dimensions(png_bytes)
        clean_title = strip(replace(String(title), '\n' => ' '))
        isempty(clean_title) && (clean_title = string(typeof(val)))
        clean_title = _truncate_chars(clean_title, 90)
        ts = Dates.format(Dates.now(), "HH:MM:SS")
        entry = PlotEntry(id, clean_title, ts, fpath, w, h, length(png_bytes))
        pushfirst!(_plots, entry)
        _last_plot_oid[] = objectid(val)
        while length(_plots) > _MAX_PLOTS
            old = pop!(_plots)
            rm(old.filepath; force = true)
        end
        return entry
    end
end

function _maybe_capture_plot!(val, cmd_str::AbstractString = "")::Bool
    !_is_plot_candidate(val) && return false
    oid = objectid(val)
    oid == _last_plot_oid[] && return false
    entry = capture_plot(val; title = cmd_str)
    return !isnothing(entry)
end

function _export_plot(id::Int, custom_name::AbstractString = "")::String
    entry = lock(_plots_lock) do
        idx = findfirst(p -> p.id == id, _plots)
        isnothing(idx) ? nothing : _plots[idx]
    end
    if isnothing(entry) || !isfile(entry.filepath)
        println("\e[31m✗ Plot #$id is no longer available.\e[0m")
        return ""
    end
    out_dir = joinpath(_get_project_dir(), "plots")
    !isdir(out_dir) && mkpath(out_dir)
    fname = strip(String(custom_name))
    if isempty(fname)
        ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
        fname = "plot_$(id)_$(ts).png"
    elseif !endswith(lowercase(fname), ".png")
        fname *= ".png"
    end
    fname = replace(fname, r"[^A-Za-z0-9_.\-]" => "_")
    dest = joinpath(out_dir, fname)
    cp(entry.filepath, dest; force = true)
    rel = relpath(dest, _get_project_dir())
    println("\e[32m✓ Exported plot #$id to $rel\e[0m")
    return rel
end

function _delete_plot!(id::Int)
    lock(_plots_lock) do
        for p in _plots
            p.id == id && rm(p.filepath; force = true)
        end
        filter!(p -> p.id != id, _plots)
    end
    publish_state()
    return nothing
end

function _clear_plots!()
    lock(_plots_lock) do
        for p in _plots
            rm(p.filepath; force = true)
        end
        empty!(_plots)
        _last_plot_oid[] = UInt64(0)
    end
    publish_state()
    return nothing
end
