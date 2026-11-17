@testset "RPC JSON validation" begin
    parse_cmd = jEMach._parse_json_cmd
    @test parse_cmd(raw"""{"cmd":"insert","text":"\u017c\ud83d\ude00\b\f\/"}""")["text"] == "ż😀\b\f/"
    @test parse_cmd("CMD {\"history\":false,\"move_left\":1e1}") == Dict("history" => false, "move_left" => 10.0)
    for bad in ("{\"cmd\":\"eval\",\"code\":\"error()\",}",
            "{\"cmd\":\"eval\" \"code\":\"error()\"}",
            raw"""{"cmd":"eval","code":"\q"}""", raw"""{"text":"\ud800"}""",
            "{\"cmd\":\"eval\"} trailing", "{\"n\":01}", "{\"n\":1.e2}")
        @test isempty(parse_cmd(bad))
    end
end

@testset "Session restart and ownership" begin
    jEMach.stop(quiet = true)
    for _ in 1:3
        jEMach.start(split = false, quiet = true)
        path = jEMach.SOCKET_PATH[]
        dir = dirname(path)
        @test (stat(dir).mode & 0o777) == 0o700
        @test (stat(path).mode & 0o777) == 0o600
        @test read(joinpath(dir, "project"), String) == realpath(jEMach._get_project_dir())
        # Give a previous watcher time to wake: it must not close this server.
        sleep(jEMach.UPDATE_INTERVAL + 0.05)
        client = Sockets.connect(path)
        close(client)
        jEMach.stop(quiet = true)
        @test !ispath(dir)
    end
end

@testset "Independent REPLs in one project" begin
    mktempdir() do dir
        children = Base.Process[]
        ready_paths = [joinpath(dir, "ready-$i") for i in 1:2]
        stop_paths = [joinpath(dir, "stop-$i") for i in 1:2]
        project = dirname(Base.active_project())
        try
            for i in 1:2
                code = """
                using jEMach
                tui_smoke_value = 123
                write($(repr(ready_paths[i])), jEMach.SOCKET_PATH[])
                while !isfile($(repr(stop_paths[i])))
                    sleep(0.02)
                end
                jEMach.stop(quiet=true)
                """
                cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $code`
                push!(children, run(pipeline(cmd; stdout = devnull); wait = false))
            end
            @test timedwait(() -> all(isfile, ready_paths) || any(process_exited, children), 30.0) == :ok
            @test all(isfile, ready_paths)
            all(isfile, ready_paths) || error("child REPL failed to start")
            paths = read.(ready_paths, String)
            @test paths[1] != paths[2]
            @test all(ispath, paths)
            # Each socket executes only in its own Julia process.
            markers = [joinpath(dir, "marker-$i") for i in 1:2]
            for i in 1:2
                client = Sockets.connect(paths[i])
                code = "write($(repr(markers[i])), string(getpid()))"
                buf = IOBuffer()
                write(buf, "{\"cmd\":\"eval_silent\",\"code\":")
                jEMach._write_json_str(buf, code)
                write(buf, "}\n")
                write(client, take!(buf))
                close(client)
            end
            @test timedwait(() -> all(isfile, markers), 5.0) == :ok
            @test read(markers[1], String) != read(markers[2], String)

            luajit = Sys.which("luajit")
            if !isnothing(luajit)
                discover = joinpath(@__DIR__, "..", "scripts", "discover_session.lua")
                ambiguous = pipeline(`$luajit $discover $project`; stdout = devnull, stderr = devnull)
                @test !success(ambiguous)
                write(stop_paths[1], "stop")
                @test timedwait(() -> process_exited(children[1]), 5.0) == :ok
                @test !ispath(paths[1])
                @test ispath(paths[2])
                @test first(split(read(`$luajit $discover $project`, String), '\n')) == paths[2]
                python = Sys.which("python3")
                if !isnothing(python)
                    smoke = joinpath(@__DIR__, "tui_smoke.py")
                    state = joinpath(dirname(paths[2]), "state.json")
                    @test success(pipeline(`$python $smoke $(paths[2]) $state`; stdout = stdout, stderr = stderr))
                    @test success(pipeline(`$python $smoke $(paths[2]) $state --launcher`; stdout = stdout, stderr = stderr))
                end
                # Discovery from a different project must not cross-attach.
                @test !success(pipeline(`$luajit $discover $dir`; stdout = devnull, stderr = devnull))
            end
        finally
            for stop_path in stop_paths
                write(stop_path, "stop")
            end
            for child in children
                if timedwait(() -> process_exited(child), 5.0) != :ok
                    kill(child)
                end
                wait(child)
            end
        end
    end
end

@testset "tmux pane ownership" begin
    mktempdir() do dir
        mock = joinpath(dir, "tmux")
        log_path = joinpath(dir, "commands")
        write(mock, raw"""#!/bin/sh
        printf '%s\n' "$*" >> "$JEMACH_TEST_LOG"
        if [ "$1" = list-panes ]; then
            printf '%%42 luajit jEMach\n%%99 luajit jEMach\n'
        fi
        """)
        chmod(mock, 0o700)
        old_backend = jEMach._tui_backend_ref[]
        old_pane = jEMach._tui_pane_ref[]
        try
            withenv("PATH" => dir * ":" * ENV["PATH"], "TMUX" => "mock", "JEMACH_TEST_LOG" => log_path) do
                jEMach._tui_backend_ref[] = :tmux
                jEMach._tui_pane_ref[] = "%42"
                jEMach._close_tui_pane()
                @test readlines(log_path) == ["kill-pane -t %42"]
                jEMach._close_tui_pane()
                @test readlines(log_path) == ["kill-pane -t %42"]
            end
        finally
            jEMach._tui_backend_ref[] = old_backend
            jEMach._tui_pane_ref[] = old_pane
        end
    end
end

@testset "TUI modules" begin
    luajit = Sys.which("luajit")
    if isnothing(luajit)
        @test_skip "LuaJIT is not installed"
    else
        @test success(`$luajit $(joinpath(@__DIR__, "tui.lua"))`)
    end
end
