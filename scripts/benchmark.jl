# Run: julia --startup-file=no --project=. scripts/benchmark.jl [samples]
# Measures warm snapshot collection and encoding without third-party packages.
using jEMach
jEMach.stop(quiet = true)

module SnapshotBenchmark
using jEMach
using Printf

function measure(f, samples)
    for _ in 1:5
        f()
    end
    timings = Float64[]
    allocations = Int[]
    for _ in 1:samples
        GC.gc()
        result = @timed f()
        push!(timings, result.time * 1000)
        push!(allocations, result.bytes)
    end
    mid = cld(samples, 2)
    return sort(timings)[mid], sort(allocations)[mid]
end

function main(samples = 31)
    samples > 0 || error("samples must be positive")
    println("Julia: ", VERSION, " | OS: ", Sys.KERNEL, " | CPU: ", Sys.CPU_NAME)
    println("Native JSON accelerator: ", jEMach._zig_escape_json_ptr[] != C_NULL)
    println("Samples per operation: ", samples, " (median; compilation excluded)")
    println("variables,nodes,payload_bytes,collect_ms,collect_alloc_bytes,encode_ms,encode_alloc_bytes")
    table = jEMach.WorkspaceTable()
    packages = jEMach._get_packages()
    previous = 0
    for count in (0, 100, 1000)
        for i in (previous + 1):count
            Core.eval(Main, Expr(:(=), Symbol("bench_value_", i), Float64(i)))
        end
        previous = count
        collect_ms, collect_bytes = measure(() -> Base.invokelatest(jEMach._collect_state_dod!, table), samples)
        @assert count == 0 || "bench_value_$count" in table.names "benchmark bindings were not visible"
        encode_ms, encode_bytes = measure(() -> jEMach._serialize_dod(table, packages), samples)
        payload = jEMach._serialize_dod(table, packages)
        @printf("%d,%d,%d,%.4f,%d,%.4f,%d\n", count, length(table.names), ncodeunits(payload),
            collect_ms, collect_bytes, encode_ms, encode_bytes)
    end
end
end

SnapshotBenchmark.main(isempty(ARGS) ? 31 : parse(Int, ARGS[1]))
