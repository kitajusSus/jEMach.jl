# Terminal & multiplexer backend detection, split lifecycle, and public watcher controls.

const _backend_override = Ref{Symbol}(:auto)

"""
    detect_backend(preferred::Symbol = :auto) -> Symbol

Detect the active terminal multiplexer or terminal emulator backend (`:rex`, `:zellij`,
`:tmux`, `:kitty`, `:ghostty`, or `:standalone`).
"""
function detect_backend(preferred::Symbol = :auto)::Symbol
    preferred != :auto && return preferred
    _backend_override[] != :auto && return _backend_override[]

    env_b = strip(lowercase(get(ENV, "JEMACH_BACKEND", "")))
    !isempty(env_b) && env_b != "auto" && return Symbol(env_b)

    if haskey(ENV, "REX_SESSION") || haskey(ENV, "REX") || haskey(ENV, "REX_PANE_ID") ||
            haskey(ENV, "REX_SOCKET") || haskey(ENV, "GHOSTTY_REX")
        return :rex
    elseif haskey(ENV, "ZELLIJ") || haskey(ENV, "ZELLIJ_SESSION_NAME") || haskey(ENV, "ZELLIJ_PANE_ID")
        return :zellij
    elseif haskey(ENV, "TMUX") && !isempty(ENV["TMUX"])
        return :tmux
    end

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
    return Dict{Symbol, Any}(
        :backend => detect_backend(),
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

function _expand_split_template(tpl::AbstractString, width::Int, proj_dir::String, sock::String, st_file::String, tui_script::String)::String
    return replace(
        tpl,
        "{width}" => string(width),
        "{cwd}" => proj_dir,
        "{socket}" => sock,
        "{state}" => st_file,
        "{proj}" => proj_dir,
        "{tui_script}" => tui_script,
    )
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
        comm == "ghostty" && return pid
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
        !isnothing(m) && (win_path = "/com/mitchellh/ghostty/window/" * m.captures[1])
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

    if !isnothing(_tui_proc_ref[])
        try
            process_running(_tui_proc_ref[]) && kill(_tui_proc_ref[])
        catch
        end
        _tui_proc_ref[] = nothing
    end

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
                    !isempty(parts) || continue
                    pid = parts[1]
                    line_str = lowercase(line)
                    if pid != cur_pane && (occursin("luajit", line_str) || occursin("jl_tui", line_str) || occursin("jl-assist", line_str))
                        try
                            run(pipeline(`tmux kill-pane -t $pid`, devnull))
                        catch
                        end
                    end
                end
            catch
            end
        end
    elseif backend == :kitty && !isempty(_tui_pane_ref[])
        try
            run(pipeline(`kitten @ close-window --match id:$(_tui_pane_ref[])`, devnull))
        catch
        end
        _tui_pane_ref[] = ""
    elseif backend == :rex && !isempty(_tui_pane_ref[])
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

    if haskey(ENV, "JEMACH_SPLIT_CMD") && !isempty(strip(ENV["JEMACH_SPLIT_CMD"]))
        cmd_str = _expand_split_template(ENV["JEMACH_SPLIT_CMD"], width, proj_dir, sock, st_file, tui_script)
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
                end
            end
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
                cmd_str = _expand_split_template(ENV["JEMACH_GHOSTTY_CMD"], width, proj_dir, sock, st_file, tui_script)
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
                cmd_str = _expand_split_template(ENV["JEMACH_REX_SPLIT_CMD"], width, proj_dir, sock, st_file, tui_script)
                _tui_pane_ref[] = strip(read(`sh -c $cmd_str`, String))
                _tui_backend_ref[] = :rex
                println("🚀 Rex TUI split opened!")
            elseif !isnothing(Sys.which(rex_bin))
                pane_arg = get(ENV, "REX_PANE_ID", "rex")
                opened = false
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
                opened ? println("🚀 Rex TUI split opened!") : @info "Rex session detected. Open a Rex split and run:\n  ./scripts/jl-assist -i\n(Or customize ENV[\"JEMACH_REX_SPLIT_CMD\"])"
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

function start(; split::Bool = true, backend::Symbol = :auto, width::Int = 65, quiet::Bool = false)
    backend != :auto && (_backend_override[] = backend)
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
                Base.invokelatest(publish_state)
                sleep(UPDATE_INTERVAL)
            end
            _stop_socket_server()
            !quiet && @info "jEMach Watcher stopped"
        end
    end

    if split
        Base.invokelatest(publish_state)
        _open_tui_pane(; backend = detect_backend(backend), width = width)
    end
    return nothing
end

function stop(; quiet::Bool = false)
    _running[] = false
    _last_serialized_body[] = ""
    _stop_socket_server()
    _close_tui_pane()
    !quiet && @info "jEMach Watcher stopped and TUI panel closed."
    return nothing
end

"""
    ui(; backend::Symbol = :auto, width::Int = 65)

Open the interactive jEMach TUI split/window for the current terminal or multiplexer.
"""
ui(; backend::Symbol = :auto, width::Int = 65) = start(; split = true, backend = backend, width = width, quiet = true)

"""
    backend(b::Symbol = :auto; split::Bool = true, width::Int = 65)

Switch the active jEMach terminal backend (e.g. `:ghostty`, `:kitty`, `:tmux`, `:zellij`, `:rex`)
and open/refresh the TUI panel.
"""
function backend(b::Symbol = :auto; split::Bool = true, width::Int = 65)
    b != :auto && (_backend_override[] = b)
    if _running[]
        publish_state()
        split && !_is_tui_open() && _open_tui_pane(; backend = detect_backend(b), width = width)
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
    !isnothing(_tui_proc_ref[]) && process_running(_tui_proc_ref[]) && return true
    return false
end

"""
    toggle(; backend::Symbol = :auto, width::Int = 65)

Toggle the interactive jEMach TUI split/window open or closed while keeping the REPL watcher active.
"""
function toggle(; backend::Symbol = :auto, width::Int = 65)
    if _is_tui_open()
        _disconnect_socket_clients!()
        _close_tui_pane()
        println("\e[2m◆ jEMach TUI closed (watcher remains active in background)\e[0m")
    else
        ui(; backend = backend, width = width)
    end
    return nothing
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
