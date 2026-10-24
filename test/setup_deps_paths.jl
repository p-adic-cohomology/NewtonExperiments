using Test

include(joinpath(@__DIR__, "..", "scripts", "setup_deps_paths.jl"))

const SETUP_REPO_DIRECTORIES = ["GPUFiniteFieldMatrices.jl", "DeRham.jl"]
const SETUP_DEPS_SCRIPT = normpath(joinpath(@__DIR__, "..", "scripts", "setup_deps.jl"))
const SETUP_DEPS_PATHS = normpath(joinpath(@__DIR__, "..", "scripts", "setup_deps_paths.jl"))

function create_test_sibling(parent, directory, package, uuid)
    sibling = joinpath(parent, directory)
    mkpath(joinpath(sibling, "src"))
    write(
        joinpath(sibling, "Project.toml"),
        "name = \"$package\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
    )
    write(joinpath(sibling, "src", "$package.jl"), "module $package\nend\n")
    run(`git -C $sibling init --quiet`)
    run(`git -C $sibling config user.name setup-deps-path-tests`)
    run(`git -C $sibling config user.email setup-deps-path-tests@example.invalid`)
    run(`git -C $sibling add Project.toml src/$package.jl`)
    run(`git -C $sibling commit --quiet -m initial`)
    revision = strip(read(`git -C $sibling rev-parse HEAD`, String))
    return sibling, revision
end

function alternate_revision(revision)
    return string(revision[1] == '0' ? '1' : '0', revision[2:end])
end

function create_setup_deps_fixture(root)
    project_root = joinpath(root, "project")
    scripts = joinpath(project_root, "scripts")
    mkpath(scripts)
    write(
        joinpath(project_root, "Project.toml"),
        "name = \"SetupDepsFixture\"\nuuid = \"58bbd6f2-1fb0-4a42-a45b-e18fef6f7f1c\"\nversion = \"0.1.0\"\n[deps]\nPkg = \"44cfe95a-1eb2-52ea-b672-e2afdf69b78f\"\n",
    )
    cp(SETUP_DEPS_SCRIPT, joinpath(scripts, "setup_deps.jl"))
    cp(SETUP_DEPS_PATHS, joinpath(scripts, "setup_deps_paths.jl"))
    runner = joinpath(root, "run_setup_deps.jl")
    script_path = joinpath(scripts, "setup_deps.jl")
    write(runner, "include($(repr(script_path)))\n")
    return project_root, runner
end

function install_git_network_guard(root)
    git_executable = Sys.which("git")
    git_executable === nothing && error("git is required for setup-deps path tests")
    bin = joinpath(root, "git-guard-bin")
    mkpath(bin)
    marker = joinpath(root, "git-network-calls")
    wrapper = joinpath(bin, "git")
    wrapper_contents = """#!/bin/sh
for argument in "\$@"; do
    if [ "\$argument" = "clone" ] || [ "\$argument" = "fetch" ]; then
        printf '%s\\n' "\$*" >> "\$GIT_CALL_LOG"
        exit 97
    fi
done
exec "\$REAL_GIT" "\$@"
"""
    write(wrapper, wrapper_contents)
    chmod(wrapper, 0o755)
    environment = [
        "PATH" => string(bin, ":", get(ENV, "PATH", "")),
        "REAL_GIT" => git_executable,
        "GIT_CALL_LOG" => marker,
        "JULIA_PKG_OFFLINE" => "true",
    ]
    return environment, marker
end

function run_setup_deps_fixture(project_root, runner, environment)
    log = string(runner, ".log")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$project_root $runner`
    exit_code = withenv(environment...) do
        open(log, "w") do output
            process = run(pipeline(ignorestatus(command), stdout=output, stderr=output))
            process.exitcode
        end
    end
    return exit_code, read(log, String)
end

@testset "Sibling package identity validation" begin
    mktempdir() do sibling
        package = "ExpectedSibling"
        uuid = "12345678-1234-1234-1234-123456789abc"
        write(joinpath(sibling, "Project.toml"), "name = \"$package\"\nuuid = \"$uuid\"\n")

        @test validate_sibling_project(sibling, package, uuid) === nothing
        @test_throws ErrorException validate_sibling_project(sibling, "OtherSibling", uuid)
        @test_throws ErrorException validate_sibling_project(sibling, package, "different-uuid")
    end
end

@testset "Revision pin normalization" begin
    valid_revision = repeat("a", 40)
    @test normalize_revision_pin("  $(uppercase(valid_revision)) \n", "NEWTON_DERHAM_REV") == valid_revision
    @test normalize_revision_pin(" \t\n ", "NEWTON_GPUFFM_REV") == ""

    malformed_revisions = [
        "abc1234",
        "g" * repeat("0", 39),
        repeat("a", 39),
        repeat("a", 41),
    ]
    for revision_env in ("NEWTON_DERHAM_REV", "NEWTON_GPUFFM_REV")
        for revision in malformed_revisions
            exception = try
                normalize_revision_pin(revision, revision_env)
                nothing
            catch err
                err
            end
            message = exception === nothing ? "" : sprint(showerror, exception)
            @test exception isa ErrorException
            @test occursin(revision_env, message)
        end
    end
end

@testset "Sibling revision validation" begin
    mktempdir() do sibling
        run(`git -C $sibling init --quiet`)
        run(`git -C $sibling config user.name setup-path-tests`)
        run(`git -C $sibling config user.email setup-path-tests@example.invalid`)
        write(joinpath(sibling, "seed.txt"), "seed\n")
        run(`git -C $sibling add seed.txt`)
        run(`git -C $sibling commit --quiet -m initial`)

        expected_revision = strip(read(`git -C $sibling rev-parse HEAD`, String))
        @test validate_sibling_revision(sibling, "ExpectedSibling", expected_revision, "EXPECTED_REV") === nothing

        write(joinpath(sibling, "Manifest.toml"), "local manifest\n")
        @test validate_sibling_revision(sibling, "ExpectedSibling", expected_revision, "EXPECTED_REV") === nothing

        wrong_revision = alternate_revision(expected_revision)
        @test_throws ErrorException validate_sibling_revision(sibling, "ExpectedSibling", wrong_revision, "EXPECTED_REV")

        write(joinpath(sibling, "seed.txt"), "modified\n")
        exception = try
            validate_sibling_revision(sibling, "ExpectedSibling", expected_revision, "EXPECTED_REV")
            nothing
        catch err
            err
        end
        message = exception === nothing ? "" : sprint(showerror, exception)
        @test exception isa ErrorException
        @test occursin("ExpectedSibling", message)
        @test occursin(sibling, message)
        @test occursin("tracked changes", message)
    end
end

@testset "Dependency setup rejects malformed pins before cloning" begin
    for revision_env in ("NEWTON_GPUFFM_REV", "NEWTON_DERHAM_REV")
        mktempdir() do root
            project_root, runner = create_setup_deps_fixture(root)
            environment, network_marker = install_git_network_guard(root)
            siblings_root = joinpath(root, "not-created")
            pins = Dict(
                "NEWTON_GPUFFM_REV" => "",
                "NEWTON_DERHAM_REV" => "",
            )
            pins[revision_env] = "abc1234"
            append!(environment, [
                "NEWTON_SIBLING_ROOT" => siblings_root,
                "NEWTON_GPUFFM_REV" => pins["NEWTON_GPUFFM_REV"],
                "NEWTON_DERHAM_REV" => pins["NEWTON_DERHAM_REV"],
            ])

            exit_code, output = run_setup_deps_fixture(project_root, runner, environment)
            @test exit_code != 0
            @test occursin("$revision_env must be a full 40-character commit SHA", output)
            @test !isfile(network_marker)
            @test !ispath(siblings_root)
        end
    end
end

@testset "Dependency setup rejects mismatched existing pinned checkouts" begin
    mktempdir() do root
        project_root, runner = create_setup_deps_fixture(root)
        siblings_root = joinpath(root, "siblings")
        mkpath(siblings_root)
        gpu_checkout, gpu_revision = create_test_sibling(
            siblings_root,
            "GPUFiniteFieldMatrices.jl",
            "GPUFiniteFieldMatrices",
            "465031f1-b347-4f72-85f6-baf667cdf853",
        )
        _, derham_revision = create_test_sibling(
            siblings_root,
            "DeRham.jl",
            "DeRham",
            "0ea6bb9e-09b2-4dc0-b975-f97753fde228",
        )
        environment, network_marker = install_git_network_guard(root)
        append!(environment, [
            "NEWTON_SIBLING_ROOT" => siblings_root,
            "NEWTON_GPUFFM_REV" => alternate_revision(gpu_revision),
            "NEWTON_DERHAM_REV" => alternate_revision(derham_revision),
        ])

        exit_code, output = run_setup_deps_fixture(project_root, runner, environment)
        @test exit_code != 0
        @test occursin("GPUFiniteFieldMatrices checkout mismatch", output)
        @test occursin(gpu_checkout, output)
        @test !isfile(network_marker)
    end
end

@testset "Dependency setup paths" begin
    mktempdir() do temporary_root
        temporary_root = realpath(temporary_root)
        siblings_root = joinpath(temporary_root, "repositories")
        project_root = joinpath(siblings_root, "NewtonExperiments")
        mkpath(project_root)
        foreach(directory -> mkpath(joinpath(siblings_root, directory)), SETUP_REPO_DIRECTORIES)

        run(`git -C $project_root init --quiet`)
        run(`git -C $project_root config user.name setup-path-tests`)
        run(`git -C $project_root config user.email setup-path-tests@example.invalid`)
        write(joinpath(project_root, "seed.txt"), "seed\n")
        run(`git -C $project_root add seed.txt`)
        run(`git -C $project_root commit --quiet -m initial`)

        worktree_root = joinpath(temporary_root, "worktrees", "NewtonExperiments")
        mkpath(dirname(worktree_root))
        run(`git -C $project_root worktree add --quiet -b setup-path-test $worktree_root`)

        withenv("NEWTON_SIBLING_ROOT" => "") do
            @test realpath(shared_checkout_root(project_root, SETUP_REPO_DIRECTORIES)) == realpath(siblings_root)
            @test realpath(shared_checkout_root(worktree_root, SETUP_REPO_DIRECTORIES)) == realpath(siblings_root)

            for checkout in (project_root, worktree_root)
                relative_paths = relative_dependency_paths(siblings_root, checkout, SETUP_REPO_DIRECTORIES)
                resolved_paths = normpath.(joinpath.(Ref(checkout), relative_paths))
                expected_paths = joinpath.(Ref(siblings_root), SETUP_REPO_DIRECTORIES)
                @test resolved_paths == expected_paths
                @test all(path -> !isabspath(path), relative_paths)

                resolved_from_project = with_project_directory(checkout) do
                    normpath.(joinpath.(Ref(pwd()), relative_paths))
                end
                @test resolved_from_project == expected_paths
            end
        end

        override_root = joinpath(temporary_root, "configured-siblings")
        withenv("NEWTON_SIBLING_ROOT" => override_root) do
            @test shared_checkout_root(worktree_root, SETUP_REPO_DIRECTORIES) == override_root
        end

        fallback_root = joinpath(temporary_root, "fallback")
        fallback_project = joinpath(fallback_root, "NewtonExperiments")
        mkpath(fallback_project)
        foreach(directory -> mkpath(joinpath(fallback_root, directory)), SETUP_REPO_DIRECTORIES)
        withenv("NEWTON_SIBLING_ROOT" => "") do
            @test shared_checkout_root(fallback_project, SETUP_REPO_DIRECTORIES) == fallback_root
        end
    end
end
