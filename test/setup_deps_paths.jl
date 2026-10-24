using Test

include(joinpath(@__DIR__, "..", "scripts", "setup_deps_paths.jl"))

const SETUP_REPO_DIRECTORIES = ["GPUFiniteFieldMatrices.jl", "DeRham.jl"]

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

        wrong_revision = string(expected_revision[1] == '0' ? '1' : '0', expected_revision[2:end])
        @test_throws ErrorException validate_sibling_revision(sibling, "ExpectedSibling", wrong_revision, "EXPECTED_REV")
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
