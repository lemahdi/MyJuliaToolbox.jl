using Pkg
Pkg.activate(@__DIR__)
# Ensure the local package is available in the docs environment
pkgpath = normpath(joinpath(@__DIR__, ".."))
Pkg.develop(PackageSpec(path=pkgpath))
Pkg.instantiate()

using Documenter
using MyJuliaToolbox

makedocs(
    sitename = "MyJuliaToolbox.jl",
    modules = [MyJuliaToolbox],
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
    ],
    format = Documenter.HTML(),
    repo = "https://github.com/lemahdi/MyJuliaToolbox.jl",
)

println("Documentation build finished. Output in docs/build/index.html or docs/build/latest/index.html.")