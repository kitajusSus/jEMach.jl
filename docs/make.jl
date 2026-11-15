using Documenter
using jEMach

makedocs(
    sitename = "jEMach.jl - Technical Notebook",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true"
    ),
    modules = [jEMach],
    pages = [
        "System Log" => "index.md",
        "REPL Auto-Hook (startup.jl)" => "startup.md",
        "IPC & Socket Architecture" => "ipc.md",
        "Type Introspection & Inspection" => "types.md"
    ]
        deploydocs(
        repo = "github.com/kitajusSus/jEMach.jl.git",
    )
)
