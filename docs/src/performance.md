# Measuring performance

Run from the repository root:

```bash
julia --startup-file=no --project=. scripts/benchmark.jl
# Optional sample count:
julia --startup-file=no --project=. scripts/benchmark.jl 51
```

The script prints Julia version, OS, CPU target, native JSON accelerator status,
and CSV results for 0, 100 and 1000 additional scalar bindings in `Main`.
For each workload it warms both operations, then reports median time and allocated
bytes for workspace collection and JSON encoding separately. It collects garbage
before each sample, outside the timed region. Existing bindings, loaded modules,
project dependencies and local REPL history can affect payload size and timings.

These are warm microbenchmarks. They exclude Julia startup, compilation, file and
socket IO, rendering, terminal latency and idle CPU usage. They do not establish
latency guarantees, zero allocation, zero-copy transport, or zero CPU consumption.
Arrays, tables and custom `show` methods should be benchmarked with representative
workspaces before making performance claims for those workloads.

For idle CPU measurements, record both the Julia and LuaJIT processes over a
specified interval, including OS and terminal versions. Measure with and without
a subscriber separately. The watcher sleeps between checks and skips collection
without subscribers; a connected TUI still triggers periodic introspection even
if no state is ultimately broadcast.
