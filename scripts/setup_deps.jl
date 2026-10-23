using Pkg
using TOML

project_root = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(project_root; io=devnull)

repos = [
    ("GPUFiniteFieldMatrices.jl", "GPUFiniteFieldMatrices", "465031f1-b347-4f72-85f6-baf667cdf853", "https://github.com/UCSD-computational-number-theory/GPUFiniteFieldMatrices.jl.git"),
    ("DeRham.jl", "DeRham", "0ea6bb9e-09b2-4dc0-b975-f97753fde228", "https://github.com/UCSD-computational-number-theory/DeRham.jl.git"),
]

function shared_checkout_root(project_root)
    configured = get(ENV, "NEWTON_SIBLING_ROOT", "")
    !isempty(configured) && return abspath(configured)

    common_git_dir = try
        strip(read(`git -C $project_root rev-parse --git-common-dir`, String))
    catch
        ""
    end
    if !isempty(common_git_dir)
        common_git_dir = isabspath(common_git_dir) ? common_git_dir : joinpath(project_root, common_git_dir)
        common_repo_root = dirname(realpath(common_git_dir))
        return dirname(common_repo_root)
    end

    fallback = dirname(project_root)
    all(isdir(joinpath(fallback, repo[1])) for repo in repos) && return fallback
    error("Cannot locate sibling checkouts; set NEWTON_SIBLING_ROOT to their containing directory")
end

siblings_root = shared_checkout_root(project_root)
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

Pkg.develop([
    Pkg.PackageSpec(path=relpath(joinpath(siblings_root, directory), project_root))
    for (directory, _, _, _) in repos
])
Pkg.instantiate()
