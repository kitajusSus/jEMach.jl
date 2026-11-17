using Documenter
using jEMach

makedocs(
    sitename = "jEMach.jl - Notebook",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true"
    ),
    modules = [jEMach],
    warnonly = [:missing_docs],
    pages = [
        "System Log" => "index.md",
        "REPL Auto-Hook (startup.jl)" => "startup.md",
        "IPC & Socket Architecture" => "ipc.md",
        "Type Introspection & Inspection" => "types.md",
        "Development" => "development.md",
        "Performance" => "performance.md",
    ]
)

deploydocs(
    repo = "github.com/kitajusSus/jEMach.jl.git",
)
