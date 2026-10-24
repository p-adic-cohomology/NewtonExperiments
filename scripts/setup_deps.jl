using Pkg
using TOML

project_root = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(project_root; io=devnull)

repos = [
    ("GPUFiniteFieldMatrices.jl", "GPUFiniteFieldMatrices", "465031f1-b347-4f72-85f6-baf667cdf853", "https://github.com/UCSD-computational-number-theory/GPUFiniteFieldMatrices.jl.git"),
    ("DeRham.jl", "DeRham", "0ea6bb9e-09b2-4dc0-b975-f97753fde228", "https://github.com/UCSD-computational-number-theory/DeRham.jl.git"),
]

include(joinpath(@__DIR__, "setup_deps_paths.jl"))

repo_directories = first.(repos)
siblings_root = shared_checkout_root(project_root, repo_directories)
mkpath(siblings_root)

for (directory, package, uuid, url) in repos
    sibling = joinpath(siblings_root, directory)
    if !isdir(sibling)
        run(`git clone --depth 1 --branch main $url $sibling`)
    end

    package_project = TOML.parsefile(joinpath(sibling, "Project.toml"))
    get(package_project, "name", nothing) == package || error("Unexpected package in $sibling")
    get(package_project, "uuid", nothing) == uuid || error("Unexpected UUID for $package in $sibling")
end

relative_paths = relative_dependency_paths(siblings_root, project_root, repo_directories)
with_project_directory(project_root) do
    Pkg.develop([Pkg.PackageSpec(path=path) for path in relative_paths])
    Pkg.instantiate()
end
