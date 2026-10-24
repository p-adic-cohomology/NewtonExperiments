using TOML

function validate_sibling_project(sibling, package, uuid)
    package_project = TOML.parsefile(joinpath(sibling, "Project.toml"))
    get(package_project, "name", nothing) == package || error("Unexpected package in $sibling")
    get(package_project, "uuid", nothing) == uuid || error("Unexpected UUID for $package in $sibling")
    return nothing
end

function normalize_revision_pin(value, revision_env)
    revision = lowercase(strip(value))
    isempty(revision) && return ""
    occursin(r"^[0-9a-f]{40}$", revision) ||
        error("$revision_env must be a full 40-character commit SHA, got: $revision")
    return revision
end

function validate_sibling_revision(sibling, package, expected_revision, revision_env)
    isempty(expected_revision) && return nothing

    actual_revision = strip(read(`git -C $sibling rev-parse HEAD`, String))
    actual_revision == expected_revision || error(
        "$package checkout mismatch: $revision_env requests $expected_revision, but $sibling is at $actual_revision",
    )
    tracked_changes = strip(read(`git -C $sibling status --porcelain --untracked-files=no`, String))
    isempty(tracked_changes) || error(
        "$package checkout is not clean: tracked changes in $sibling: $tracked_changes",
    )
    println("$package pinned to $actual_revision")
    return nothing
end

function with_project_directory(action, project_root)
    return cd(action, project_root)
end

function shared_checkout_root(project_root, repo_directories)
    configured = get(ENV, "NEWTON_SIBLING_ROOT", "")
    !isempty(configured) && return abspath(configured)

    common_git_dir = try
        strip(read(pipeline(`git -C $project_root rev-parse --git-common-dir`, stderr=devnull), String))
    catch
        ""
    end
    if !isempty(common_git_dir)
        common_git_dir = isabspath(common_git_dir) ? common_git_dir : joinpath(project_root, common_git_dir)
        common_repo_root = dirname(realpath(common_git_dir))
        return dirname(common_repo_root)
    end

    fallback = dirname(project_root)
    all(isdir(joinpath(fallback, directory)) for directory in repo_directories) && return fallback
    error("Cannot locate sibling checkouts; set NEWTON_SIBLING_ROOT to their containing directory")
end

function relative_dependency_paths(siblings_root, project_root, repo_directories)
    return [relpath(joinpath(siblings_root, directory), project_root) for directory in repo_directories]
end
