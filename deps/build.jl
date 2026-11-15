let zig_dir = normpath(joinpath(@__DIR__, "..", "zig"))
    zig_exe = Sys.which("zig")
    if !isnothing(zig_exe) && isfile(joinpath(zig_dir, "build.zig"))
        try
            run(Cmd(`$zig_exe build -Doptimize=ReleaseFast`; dir = zig_dir))
            @info "Built jEMach Zig native accelerator in $(joinpath(zig_dir, "zig-out", "lib"))."
        catch e
            @warn "jEMach: Zig build failed; using pure-Julia fallbacks." exception = e
        end
    else
        @info "jEMach: `zig` compiler not found; using pure-Julia implementations."
    end
end
