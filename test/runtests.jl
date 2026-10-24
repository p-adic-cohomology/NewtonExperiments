using Test
using DataFrames
using DeRham
using NewtonExperiments
using Random

include("setup_deps_paths.jl")

struct FakeNewtonPolygon
    slopes
    slopelengths
    values
    slopesbefore
end

@testset "NewtonExperiments.jl" begin
    @testset "Result tables" begin
        df = empty_results_dataframe()
        np = FakeNewtonPolygon([0, 1], [1, 1], [0, 1], [0, 1])

        update_df(df, 3, 3, 5, np, "x^3 + y^3 + z^3")
        @test nrow(df) == 1
        @test names(df) == ["n", "d", "p", "slopes", "slopelengths", "values", "slopesbefore", "polystr"]

        update_results!(df, 3, 3, 5, np, "x^3 + y^3 + z^3")
        @test nrow(df) == 1
    end

    @testset "S choices match experiment conventions" begin
        @test derham_S(6, 3; algorithm=:varbyvar) == [5]
        @test derham_S(6, 3) == [0, 1, 2]
        @test derham_S(3, 4) == [0, 1, 2]
        @test gpu_derham_S(6, 3) == [5]
    end

    @testset "Local DeRham API" begin
        f = DeRham.fermat_hypersurface(3, 3, 5)
        np = DeRham.newton_polygon(f, S=derham_S(3, 3), fastevaluation=true, algorithm=:depthfirst)
        @test np != false

        df = update_df(empty_results_dataframe(), 3, 3, 5, np, f)
        @test nrow(df) == 1
        @test df.n[1] == 3
        @test df.d[1] == 3
        @test df.p[1] == 5
    end

    @testset "Experiment dispatch" begin
        experiment(n, d, p, N, df; kwargs...) = update_df(df, n, d, p, FakeNewtonPolygon([0], [1], [0], [0]), "f")
        df = run_experiment(experiment, 3, 3, 5, 1)
        @test nrow(df) == 1
    end

    @testset "Local experiment wrappers" begin
        Random.seed!(1)
        df = run_experiment(:cpu_vector_fast_random, 3, 3, 5, 1)
        @test df isa DataFrame
        @test names(df) == names(empty_results_dataframe())
    end
end
