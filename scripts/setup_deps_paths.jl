function shared_checkout_root(project_root, repo_directories)
    configured = get(ENV, "NEWTON_SIBLING_ROOT", "")
    !isempty(configured) && return abspath(configured)

    common_git_dir = try
        command = Cmd(["git", "-C", project_root, "rev-parse", "--git-common-dir"])
        strip(read(pipeline(command, stderr=devnull), String))
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

function with_project_directory(action, project_root)
    return cd(action, project_root)
end
