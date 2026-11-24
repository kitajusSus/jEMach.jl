# Each Julia process owns a private, short UNIX socket path. Discovery reads
# project metadata only after the socket is listening; no shared "latest" file.
const _session_dir = Ref{String}("")

_runtime_root() = "/tmp/jemach-$(ccall(:getuid, Cuint, ()))"

function _ensure_session!()
    !isempty(_session_dir[]) && isdir(_session_dir[]) && return _session_dir[]
    root = _runtime_root()
    try
        mkdir(root; mode = 0o700)
    catch
        isdir(root) || rethrow()
    end
    info = lstat(root)
    if !isdir(info) || islink(root) || info.uid != ccall(:getuid, Cuint, ()) || (info.mode & 0o077) != 0
        error("jEMach runtime directory must be owned by this user with mode 0700: $root")
    end
    dir = mktempdir(root; prefix = "session-", cleanup = false)
    _session_dir[] = dir
    SOCKET_PATH[] = joinpath(dir, "repl.sock")
    STATE_FILE[] = joinpath(dir, "state.json")
    return dir
end

function _advertise_session!()
    # Write metadata and project last so discovering clients see a fully initialized session.
    meta_path = joinpath(_session_dir[], "meta")
    open(meta_path * ".tmp", "w"; lock = false) do io
        write(io, "pid=", string(getpid()), "\nstarted=", Dates.format(Dates.now(), "HH:MM:SS"), "\n")
    end
    mv(meta_path * ".tmp", meta_path; force = true)

    path = joinpath(_session_dir[], "project")
    open(path * ".tmp", "w"; lock = false) do io
        write(io, realpath(_get_project_dir()))
    end
    mv(path * ".tmp", path; force = true)
    return nothing
end

function _cleanup_session!()
    dir = _session_dir[]
    isempty(dir) && return nothing
    # Remove only files/subdirs we own, never recursively remove an arbitrary root directory.
    plots_dir = joinpath(dir, "plots")
    if isdir(plots_dir) && !islink(plots_dir)
        for f in readdir(plots_dir)
            endswith(f, ".png") && rm(joinpath(plots_dir, f); force = true)
        end
        try
            rm(plots_dir)
        catch
        end
    end
    for name in ("project", "project.tmp", "meta", "meta.tmp", "state.json", "state.json.tmp", "repl.sock")
        rm(joinpath(dir, name); force = true)
    end
    try
        rm(dir)
    catch
    end
    _session_dir[] = ""
    return nothing
end
