using Test
using jEMach

const Sockets = jEMach.Sockets

@testset "jEMach World-Age & Workspace Visibility" begin
    tmp_pkg_dir = mktempdir()
    orig_load_path = copy(LOAD_PATH)
    tmp_out_path, tmp_out_io = mktemp()
    close(tmp_out_io)
    try
        # Create a brand-new external package directory to load AFTER jEMach.__init__
        pkg_src_dir = joinpath(tmp_pkg_dir, "LateDynPkg", "src")
        mkpath(pkg_src_dir)
        write(
            joinpath(pkg_src_dir, "LateDynPkg.jl"),
            """
            module LateDynPkg
            export dyn_func, dyn_const
            const dyn_const = 123
            dyn_func(x) = x * 2
            end
            """,
        )
        push!(LOAD_PATH, tmp_pkg_dir)

        sleep(0.15)
        @test jEMach._running[]

        # Connect a UNIX socket subscriber early and stream received frames via an async reader
        sock_client = Sockets.connect(jEMach.SOCKET_PATH[])
        sock_frames = Channel{String}(32)
        @async begin
            try
                while isopen(sock_client) && !eof(sock_client)
                    line = readline(sock_client)
                    !isempty(line) && put!(sock_frames, line)
                end
            catch
            end
        end
        write(sock_client, "SUB\n")
        flush(sock_client)
        # Wait for initial snapshot pushed on SUB
        initial_line = timedwait(() -> isready(sock_frames), 2.0) == :ok ? take!(sock_frames) : ""
        @test !isempty(initial_line)

        # Spawn a background task in __init__'s world age and trigger it AFTER new bindings/loads
        trigger = Channel{Nothing}(1)
        result_ch = Channel{Any}(1)
        @async begin
            take!(trigger)
            try
                jEMach._last_serialized_body[] = ""
                jEMach.publish_state()
                syms = jEMach._main_symbol_names()
                is_g = jEMach._is_global_or_type(:LateTestStruct)
                p_def = jEMach._default_param_str(:late_x)
                next_p = jEMach._next_proc_name()
                open(tmp_out_path, "w") do io
                    redirect_stdout(io) do
                        jEMach.workspace("late_x")
                        jEMach.inspect_var(Main, "late_fn")
                    end
                end
                out_str = read(tmp_out_path, String)
                put!(result_ch, (; ok = true, syms, is_g, p_def, next_p, out_str))
            catch e
                put!(result_ch, (; ok = false, err = sprint(showerror, e, catch_backtrace())))
            end
        end

        # Evaluate variables, functions, structs, UTF-8 values, local submodule, and packages AFTER __init__
        Core.eval(Main, :(late_x = 42))
        Core.eval(Main, :(late_arr = [1.0, 2.5, 3.75]))
        Core.eval(Main, :(late_dict = Dict("α" => 1, "żółć" => 2)))
        Core.eval(Main, :(struct LateTestStruct; a::Int; b::String; end))
        Core.eval(Main, :(late_inst = LateTestStruct(7, "zażółć gęślą jaźń")))
        Core.eval(Main, :(late_fn(u) = u + 1))
        Core.eval(Main, :(pl_str_long = repeat("zażółć gęślą jaźń σ→∞ ", 5)))
        Core.eval(Main, :(σ_bardzo_długa_nazwa_zmiennej_utf8 = "ż"^57 * "ółęć"))
        Core.eval(Main, :(module LateLocalMod; local_val = 99; local_fn(x) = 2x; end))
        Core.eval(Main, :(using Random))
        Core.eval(Main, :(using LateDynPkg))

        # Verify __init__'s OWN background watcher loop updates STATE_FILE and socket broadcast automatically
        json_text = ""
        latest_sock_frame = ""
        deadline = time() + 3.0
        while time() < deadline
            if isfile(jEMach.STATE_FILE[])
                json_text = read(jEMach.STATE_FILE[], String)
            end
            while isready(sock_frames)
                latest_sock_frame = take!(sock_frames)
            end
            if occursin("\"LateDynPkg\"", json_text) && occursin("\"LateDynPkg\"", latest_sock_frame)
                break
            end
            sleep(0.05)
        end
        close(sock_client)
        @test isfile(jEMach.STATE_FILE[])

        for expected in (
            "\"late_x\"",
            "\"late_arr\"",
            "\"late_dict\"",
            "\"LateTestStruct\"",
            "\"late_inst\"",
            "\"late_fn\"",
            "\"pl_str_long\"",
            "\"σ_bardzo_długa_nazwa_zmiennej_utf8\"",
            "\"LateLocalMod\"",
            "\"local_val\"",
            "\"local_fn\"",
            "\"Random\"",
            "\"LateDynPkg\"",
            "\"dyn_func\"",
            "\"dyn_const\"",
        )
            @test occursin(expected, json_text)
            @test occursin(expected, latest_sock_frame)
        end
        @test !occursin("\"<?>\"", json_text)

        # Next wake the old-world @async task to verify direct helper calls from earlier world ages
        put!(trigger, nothing)
        res = take!(result_ch)
        if !res.ok
            @error "Async world-age check failed" res.err
        end
        @test res.ok
        @test "late_x" in res.syms
        @test "LateTestStruct" in res.syms
        @test "Random" in res.syms
        @test "LateDynPkg" in res.syms
        @test res.is_g === true
        @test res.p_def == ("late_x = 42", true)
        @test res.next_p isa Symbol
        @test occursin("late_x", res.out_str)
        @test occursin("late_fn", res.out_str)

        @testset "UTF-8 preview & table truncation safety" begin
            for s in (
                "a"^56 * "żółć",
                "ż"^60 * "ć",
                "zażółć gęślą jaźń σ→∞ "^4,
            )
                prev = jEMach._value_preview(s)
                @test !occursin("<?>", prev)
            end

            tbl = jEMach.WorkspaceTable()
            jEMach._add_entry!(
                tbl,
                "σ_długa_nazwa_utf8_zmienna",
                "variable",
                "Dict{String, CustomUtf8TypeName_śćż}",
                "\"zażółć gęślą jaźń\"",
                "σ_długa_nazwa_utf8_zmienna",
                "Main",
                0,
                -1,
                false,
            )
            rendered = sprint(show, MIME("text/plain"), tbl)
            @test occursin("…", rendered)
        end
    finally
        empty!(LOAD_PATH)
        append!(LOAD_PATH, orig_load_path)
        jEMach.stop()
        rm(jEMach.STATE_FILE[]; force = true)
        rm(tmp_out_path; force = true)
        rm(tmp_pkg_dir; recursive = true, force = true)
    end
end

@testset "Error Tracking, Diagnostics & JSON State" begin
    proj_dir = jEMach._get_project_dir()
    proc_dir = joinpath(proj_dir, "procedures")
    proc_dir_existed = isdir(proc_dir)
    mkpath(proc_dir)
    err_proc_path = joinpath(proc_dir, "test_div_err_proc.jl")
    bad_syntax_path = joinpath(proc_dir, "test_broken_syntax_proc.jl")
    made_import_proc_path = joinpath(proc_dir, "test_make_import_proc.jl")
    tmp_err_out = tempname()

    try
        jEMach.start(split = false, quiet = true)
        jEMach._clear_failed_commands!()
        empty!(jEMach._cmd_outcomes)

        # 1. Valid procedure that fails at runtime on line 3
        write(err_proc_path, """
function test_div_err_proc(a, b)
    x = a + 1
    y = div(x, b)
    return y
end
""")
        # 2. Broken syntax procedure detected on load
        write(bad_syntax_path, """
function test_broken_syntax_proc(x)
    z = (x + 1
end
""")

        jEMach._load_procedures!()

        p_err = get(jEMach._procedures, :test_div_err_proc, nothing)
        @test p_err !== nothing
        @test p_err.last_run_status == :never

        p_syn = get(jEMach._procedures, :test_broken_syntax_proc, nothing)
        @test p_syn !== nothing
        @test p_syn.last_run_status == :error
        @test !isempty(p_syn.last_error)
        @test p_syn.last_error_line >= 1

        # Trigger runtime error in procedure (records error on ProcedureInfo and rethrows)
        @test_throws DivideError redirect_stdout(devnull) do
            jEMach.run_procedure(:test_div_err_proc, 10, 0)
        end
        @test p_err.last_run_status == :error
        @test occursin("test_div_err_proc(10, 0)", p_err.last_run_cmd)
        @test occursin("DivideError", p_err.last_error)
        @test occursin("Stacktrace", p_err.last_error_detail)
        @test p_err.last_error_line == 3
        @test occursin("div(x, b)", p_err.last_error_cmd)

        rendered_err_card = sprint(show, MIME("text/plain"), p_err)
        @test occursin("Last Call:", rendered_err_card)
        @test occursin("DivideError", rendered_err_card)
        @test occursin("✗", rendered_err_card)
        @test occursin("Error Detail", rendered_err_card)

        # Running with valid args clears the error fields on the procedure
        res = redirect_stdout(devnull) do
            jEMach.run_procedure(:test_div_err_proc, 11, 3)
        end
        @test res == 4
        @test p_err.last_run_status == :ok
        @test p_err.last_error == ""
        @test p_err.last_error_detail == ""
        @test p_err.last_error_line == 0
        @test p_err.last_error_cmd == ""
        @test occursin("test_div_err_proc(11, 3)", p_err.last_run_cmd)

        # 3. REPL / TUI eval outcomes & failed command capture (including multi-line & parse error)
        ok_cmd = "let v = 42; v + 8; end"
        multi_bad = "tmp_a = 10\ntmp_a + nonexistent_sym_for_test"
        syn_bad = "broken_expr_test = (1 +"

        redirect_stdout(devnull) do
            jEMach._repl_eval(ok_cmd; silent = false, record_history = false)
            jEMach._repl_eval(multi_bad; silent = false, record_history = false)
            jEMach._repl_eval(syn_bad; silent = false, record_history = false)
        end
        @test get(jEMach._cmd_outcomes, ok_cmd, :none) == :ok
        @test get(jEMach._cmd_outcomes, multi_bad, :none) == :error
        @test get(jEMach._cmd_outcomes, syn_bad, :none) == :error
        @test any(fc -> fc.cmd == multi_bad && fc.error_line == 2 && occursin("UndefVarError", fc.error_msg), jEMach._failed_commands)
        @test any(fc -> fc.cmd == syn_bad && !isempty(fc.error_msg), jEMach._failed_commands)

        # 4. JSON state serialization includes error fields, failed_commands, and history_statuses
        jEMach.publish_state()
        json_str = read(jEMach.STATE_FILE[], String)
        @test occursin("\"failed_commands\":[", json_str)
        @test occursin("\"history_statuses\":[", json_str)
        @test occursin("\"last_run_cmd\":", json_str)
        @test occursin("\"last_error_detail\":", json_str)
        @test occursin("\"last_error_line\":", json_str)
        @test occursin("nonexistent_sym_for_test", json_str)

        # 5. jemach> errors command runs and renders diagnostics
        open(tmp_err_out, "w") do io
            redirect_stdout(io) do
                jEMach._exec_command("errors")
            end
        end
        err_cmd_out = read(tmp_err_out, String)
        @test occursin("test_broken_syntax_proc", err_cmd_out) || occursin("Failed Commands", err_cmd_out)

        # 6. Dismiss individual failed command and clear all
        first_id = jEMach._failed_commands[1].id
        jEMach._dismiss_failed_command!(first_id)
        @test !any(fc -> fc.id == first_id, jEMach._failed_commands)
        jEMach._clear_failed_commands!()
        @test isempty(jEMach._failed_commands)

        # 7. make_procedure hoists top-level `using`/`import` above docstring and binds nested fn args locally
        generated_code = redirect_stdout(devnull) do
            jEMach.make_procedure(
                :test_make_import_proc;
                commands = [
                    "using Random",
                    "scale_k = 10",
                    "local_helper(a, b) = a * b + 1",
                    "out = local_helper(scale_k, 3) + (Rnd === Random ? 0 : 1)",
                    "import Random as Rnd",
                ],
                save = true,
            )
        end
        @test generated_code !== nothing
        p_imp = get(jEMach._procedures, :test_make_import_proc, nothing)
        @test p_imp !== nothing
        @test p_imp.last_run_status == :never
        # `using Random` and `import Random as Rnd` must appear before `"""` docstring and NOT inside function
        doc_pos = findfirst("\"\"\"", generated_code)
        @test doc_pos !== nothing
        using_random_pos = findfirst("using Random", generated_code)
        import_rnd_pos = findfirst("import Random as Rnd", generated_code)
        @test using_random_pos !== nothing && first(using_random_pos) < first(doc_pos)
        @test import_rnd_pos !== nothing && first(import_rnd_pos) < first(doc_pos)
        @test occursin("local_helper(a, b)", split(generated_code, "function ")[2])
        # `a`, `b`, `Random`, `Rnd` must NOT leak into outer signature
        @test p_imp.signature == "test_make_import_proc(scale_k = 10)"

        # 8. jemach> mode executes `<proc>(args...)` directly without space & supports `clear()`
        res_direct = redirect_stdout(devnull) do
            jEMach._exec_command("test_make_import_proc(4)")
        end
        @test res_direct == 13
        res_spaced = redirect_stdout(devnull) do
            jEMach._exec_command("test_make_import_proc (5)")
        end
        @test res_spaced == 16
        redirect_stdout(devnull) do
            jEMach._exec_command("clear()")
        end

        # 9. JSON state includes `history_prev_count` and accurate `needs_args`
        jEMach.publish_state()
        json_str2 = read(jEMach.STATE_FILE[], String)
        @test occursin("\"history_prev_count\":", json_str2)
        @test occursin("\"needs_args\":true", json_str2)
        @test occursin("\"needs_args\":false", json_str2)

        # 10. get_split_history separates pre-session from current-session commands via HIST_START_POS
        tmp_hist = tempname()
        old_hist_env = get(ENV, "JULIA_HISTORY", nothing)
        old_start_pos = jEMach.HIST_START_POS[]
        try
            ENV["JULIA_HISTORY"] = tmp_hist
            prev_text = "# time: 2026-01-01 10:00:00 UTC\n# mode: julia\n\told_cmd_1 = 1\n# time: 2026-01-01 10:01:00 UTC\n# mode: julia\n\told_cmd_2 = 2\n"
            curr_text = "# time: 2026-11-14 15:00:00 UTC\n# mode: julia\n\tnew_cmd_1 = 3\n"
            write(tmp_hist, prev_text * curr_text)
            jEMach.HIST_START_POS[] = ncodeunits(prev_text)
            jEMach._invalidate_hist_cache!()
            sp = jEMach.get_split_history(limit = 50)
            @test sp.prev_count == 2
            @test sp.commands == ["old_cmd_1 = 1", "old_cmd_2 = 2", "new_cmd_1 = 3"]
            @test jEMach.get_session_commands() == ["new_cmd_1 = 3"]
        finally
            jEMach.HIST_START_POS[] = old_start_pos
            if isnothing(old_hist_env)
                delete!(ENV, "JULIA_HISTORY")
            else
                ENV["JULIA_HISTORY"] = old_hist_env
            end
            jEMach._invalidate_hist_cache!()
            rm(tmp_hist; force = true)
        end
    finally
        rm(err_proc_path; force = true)
        rm(bad_syntax_path; force = true)
        rm(made_import_proc_path; force = true)
        rm(tmp_err_out; force = true)
        if !proc_dir_existed && isdir(proc_dir) && isempty(readdir(proc_dir))
            rm(proc_dir; force = true)
        end
        jEMach._clear_failed_commands!()
        empty!(jEMach._cmd_outcomes)
        jEMach._load_procedures!()
        jEMach.stop()
        rm(jEMach.STATE_FILE[]; force = true)
    end
end

@testset "Live Procedures, Zig Scanner & In-REPL Lifecycle" begin
    proc_dir = joinpath(jEMach._get_project_dir(), "procedures")
    proc_dir_existed = isdir(proc_dir)
    base_file = joinpath(proc_dir, "test_live_lifecycle_proc.jl")
    clone_file = joinpath(proc_dir, "test_live_lifecycle_v2.jl")
    live_file = joinpath(proc_dir, "test_pure_live_fn.jl")

    try
        # 1. Zig ABI layout & Zig vs Pure-Julia source scanner parity
        @test sizeof(jEMach._ZigProcScanResult) == 24
        sample_src = """
        # Generated by jEMach on 2026-11-14 15:00:00

        using Statistics

        \"\"\"
            sample(x)
        \"\"\"
        function sample(x)
            return mean(x)
        end
        """
        scan_j = jEMach._scan_proc_source_julia(sample_src)
        scan_z = jEMach._scan_proc_source(sample_src)
        @test scan_j.has_doc
        @test scan_j.has_imports
        @test scan_j.func_line == 8
        @test startswith(scan_j.edit_code, "function sample(x)")
        @test endswith(scan_j.edit_code, "end")
        @test scan_z.has_doc == scan_j.has_doc
        @test scan_z.has_imports == scan_j.has_imports
        @test scan_z.func_line == scan_j.func_line
        @test scan_z.edit_code == scan_j.edit_code
        @test scan_z.imports_block == "using Statistics"

        # 2. Disk creation initializes :disk origin, clean edit_code & last_args tracking
        redirect_stdout(devnull) do
            jEMach.make_procedure(
                :test_live_lifecycle_proc;
                commands = ["x = 5", "y = x * 2 + 1"],
                save = true,
            )
        end
        p = jEMach._procedures[:test_live_lifecycle_proc]
        @test p.origin == :disk
        @test p.generation == 1
        @test startswith(p.edit_code, "function test_live_lifecycle_proc(")
        @test p.func_start_line > 1
        res1 = redirect_stdout(devnull) do
            jEMach.run_procedure(:test_live_lifecycle_proc, 7)
        end
        @test res1 == 15
        @test p.last_args_str == "7"

        # 3. REPL redefinition marks procedure :modified without touching disk
        edited_src = """
        function test_live_lifecycle_proc(x = 5)
            return x * 100
        end
        """
        jEMach._repl_eval(edited_src; silent = true)
        @test p.origin == :modified
        @test p.generation >= 2
        @test occursin("x * 100", p.code)
        @test occursin("x * 2 + 1", read(base_file, String))

        # 4. _load_procedures! and run_procedure must NOT clobber :modified code
        jEMach._load_procedures!(; eval_in_main = false)
        @test p.origin == :modified
        res_mod = redirect_stdout(devnull) do
            jEMach.run_procedure(:test_live_lifecycle_proc, 4)
        end
        @test res_mod == 400

        # 5. edit_procedure returns clean body
        @test startswith(jEMach.edit_procedure(:test_live_lifecycle_proc), "function test_live_lifecycle_proc")

        # 6. Saving renamed live function creates a new disk file, keeping disk original
        renamed_src = """
        function test_live_lifecycle_v2(x = 5)
            return x * 1000
        end
        """
        jEMach._repl_eval(renamed_src; silent = true)
        @test haskey(jEMach._procedures, :test_live_lifecycle_v2)
        p_live = jEMach._procedures[:test_live_lifecycle_v2]
        @test p_live.origin == :live
        @test isempty(p_live.file)
        saved_rel = redirect_stdout(devnull) do
            jEMach.save_procedure(:test_live_lifecycle_v2)
        end
        @test saved_rel == "procedures/test_live_lifecycle_v2.jl"
        @test isfile(clone_file)
        @test p_live.origin == :disk
        @test Base.invokelatest(Main.test_live_lifecycle_v2, 3) == 3000

        # 7. Reloading :modified procedure restores disk behavior & resets generation
        redirect_stdout(devnull) do
            jEMach._exec_command("reload test_live_lifecycle_proc")
        end
        @test p.origin == :disk
        @test p.generation == 1
        res_reloaded = redirect_stdout(devnull) do
            jEMach.run_procedure(:test_live_lifecycle_proc, 4)
        end
        @test res_reloaded == 9

        # 8. Pure live function in Main can be edited, saved as new name, and inspected in JSON
        jEMach._repl_eval("test_pure_live_fn(a, b) = a + b + 10"; silent = true)
        @test haskey(jEMach._procedures, :test_pure_live_fn)
        @test jEMach._procedures[:test_pure_live_fn].origin == :live
        redirect_stdout(devnull) do
            jEMach._exec_command("save test_pure_live_fn as test_pure_live_fn")
        end
        @test isfile(live_file)
        @test jEMach._procedures[:test_pure_live_fn].origin == :disk

        # 9. JSON payload emits new procedure lifecycle fields
        jEMach.publish_state()
        json_out = read(jEMach.STATE_FILE[], String)
        @test occursin("\"origin\":\"disk\"", json_out)
        @test occursin("\"edit_code\":", json_out)
        @test occursin("\"generation\":", json_out)
        @test occursin("\"func_start_line\":", json_out)
        @test occursin("\"last_args\":", json_out)

        # 10. Qualified method overrides like Base.show do NOT hijack _procedures
        before_keys = Set(keys(jEMach._procedures))
        jEMach._capture_repl_definitions!("Base.string(x::Int) = string(x)")
        @test Set(keys(jEMach._procedures)) == before_keys

        # 11. Lazy procedure indexing does NOT evaluate top-level side effects until run/reload
        lazy_file = joinpath(proc_dir, "test_lazy_unloaded_proc.jl")
        try
            mkpath(proc_dir)
            write(
                lazy_file,
                """
                # Lazy startup test procedure
                test_lazy_side_effect_var = [30, 71, 86]
                function test_lazy_unloaded_proc(x = 2)
                    return sum(test_lazy_side_effect_var) + x
                end
                """,
            )
            jEMach._load_procedures!(; eval_in_main = false)
            @test !Base.invokelatest(isdefined, Main, :test_lazy_side_effect_var)
            @test !Base.invokelatest(isdefined, Main, :test_lazy_unloaded_proc)
            @test haskey(jEMach._procedures, :test_lazy_unloaded_proc)
            @test jEMach._procedures[:test_lazy_unloaded_proc].origin == :unloaded

            lazy_res = redirect_stdout(devnull) do
                jEMach.run_procedure(:test_lazy_unloaded_proc, 10)
            end
            @test lazy_res == 197
            @test Base.invokelatest(isdefined, Main, :test_lazy_side_effect_var)
            @test jEMach._procedures[:test_lazy_unloaded_proc].origin == :disk
        finally
            rm(lazy_file; force = true)
            delete!(jEMach._procedures, :test_lazy_unloaded_proc)
        end

        # 12. _get_packages resolves dependencies via Project.toml/Manifest.toml without eager Pkg load
        pkgs = jEMach._get_packages()
        @test any(d -> d["name"] == "jEMach", pkgs)

        # 13. Concurrent publish_state() calls are serialized safely via _publish_lock
        @sync for _ in 1:6
            @async jEMach.publish_state()
        end
        @test isfile(jEMach.STATE_FILE[])

        # 14. World-age cached package collection returns identical columns across repeated calls
        t1 = jEMach._collect_state_dod!(jEMach.WorkspaceTable())
        t2 = jEMach._collect_state_dod!(jEMach.WorkspaceTable())
        @test t1.names == t2.names
        @test t1.parent_indices == t2.parent_indices

        # 15. Fast _value_preview handles large arrays and dicts cleanly
        arr_prev = jEMach._value_preview(zeros(1000))
        dict_prev = jEMach._value_preview(Dict(i => i for i in 1:100))
        @test occursin("1000", arr_prev)
        @test occursin("100 entries", dict_prev)

        # 16. Backend command helpers produce valid commands and environment arguments
        env_cmd = jEMach._tui_env_cmd("/tmp/tui.lua", "ghostty", "/tmp/proj", "/tmp/s.sock", "/tmp/st.json", :ghostty)
        @test "JEMACH_BACKEND=ghostty" in env_cmd.exec
        @test "luajit" in env_cmd.exec
    finally
        rm(base_file; force = true)
        rm(clone_file; force = true)
        rm(live_file; force = true)
        if !proc_dir_existed && isdir(proc_dir) && isempty(readdir(proc_dir))
            rm(proc_dir; force = true)
        end
        for s in (:test_live_lifecycle_proc, :test_live_lifecycle_v2, :test_pure_live_fn)
            delete!(jEMach._procedures, s)
        end
        jEMach._clear_failed_commands!()
        empty!(jEMach._cmd_outcomes)
        jEMach._load_procedures!()
        jEMach.stop()
        rm(jEMach.STATE_FILE[]; force = true)
    end
end
