using Pkg

project_root = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(project_root; io=devnull)

repos = [
    ("GPUFiniteFieldMatrices.jl", "GPUFiniteFieldMatrices", "465031f1-b347-4f72-85f6-baf667cdf853", "https://github.com/UCSD-computational-number-theory/GPUFiniteFieldMatrices.jl.git", "NEWTON_GPUFFM_REV"),
    ("DeRham.jl", "DeRham", "0ea6bb9e-09b2-4dc0-b975-f97753fde228", "https://github.com/UCSD-computational-number-theory/DeRham.jl.git", "NEWTON_DERHAM_REV"),
]

include(joinpath(@__DIR__, "setup_deps_paths.jl"))

repo_directories = first.(repos)
siblings_root = shared_checkout_root(project_root, repo_directories)
mkpath(siblings_root)

for (directory, package, uuid, url, revision_env) in repos
    sibling = joinpath(siblings_root, directory)
    expected_revision = lowercase(strip(get(ENV, revision_env, "")))
    if !isempty(expected_revision)
        occursin(r"^[0-9a-f]{40}$", expected_revision) ||
            error("$revision_env must be a full 40-character commit SHA, got: $expected_revision")
    end

    if !isdir(sibling)
        if isempty(expected_revision)
            run(`git clone --depth 1 --branch main $url $sibling`)
        else
            staging_root = mktempdir(siblings_root; prefix=".$directory-")
            staged_sibling = joinpath(staging_root, directory)
            try
                mkpath(staged_sibling)
                run(`git -C $staged_sibling init --quiet`)
                run(`git -C $staged_sibling remote add origin $url`)
                run(`git -C $staged_sibling fetch --depth 1 origin $expected_revision`)
                run(`git -C $staged_sibling checkout --detach FETCH_HEAD`)
                validate_sibling_project(staged_sibling, package, uuid)
                validate_sibling_revision(staged_sibling, package, expected_revision, revision_env)
                mv(staged_sibling, sibling)
            finally
                rm(staging_root; recursive=true, force=true)
            end
        end
    end

    validate_sibling_project(sibling, package, uuid)
    validate_sibling_revision(sibling, package, expected_revision, revision_env)
end

relative_paths = relative_dependency_paths(siblings_root, project_root, repo_directories)
with_project_directory(project_root) do
    Pkg.develop([Pkg.PackageSpec(path=path) for path in relative_paths])
    Pkg.instantiate()
end
