using Documenter, TarFS

makedocs(
    sitename = "TarFS.jl",
    modules  = [TarFS],
    format   = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
    pages    = ["Home" => "index.md"],
    # remotes = nothing,  # uncomment if Documenter complains about the Git remote
)

deploydocs(
    repo = "github.com/JBlaschke/TarFS.jl.git",
    devbranch = "main",        # match your actual default branch
    push_preview = false,      # true if you want per-PR doc previews
)
