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

    @testset "Newton strata polygons" begin
        NS = NewtonExperiments.NewtonStrata

        vertices = Tuple{Int64,Int64}[(0, 0), (2, 0), (4, 1), (6, 3)]
        derham_polygon = DeRham.SlopesPolygon(vertices)
        polygon = NS.from_slopes_polygon(derham_polygon)
        @test polygon.slopes == [0 // 1, 1 // 2, 1 // 1]
        @test polygon.slopelengths == [2, 2, 2]
        @test NS.integer_values(polygon) == derham_polygon.values
        @test NS.polygon_value(polygon, 3) == 1 // 2
        @test NS.to_slopes_polygon(polygon) == derham_polygon

        nonintegral = NS.SlopeMultiplicityPolygon([1 // 3, 2 // 3], [1, 1])
        @test NS.is_symmetric(nonintegral)
        @test !NS.has_integral_breakpoints(nonintegral)

        ordinary = NS.SlopeMultiplicityPolygon([0, 1], [6, 6])
        supersingular = NS.SlopeMultiplicityPolygon([1 // 2], [12])
        @test NS.is_ordinary(ordinary)
        @test !NS.is_supersingular(ordinary)
        @test NS.is_supersingular(supersingular)
        @test !NS.is_ordinary(supersingular)
        @test NS.lies_on_or_above(supersingular, ordinary)
        @test !NS.lies_on_or_above(ordinary, supersingular)
        @test NS.lies_on_or_above(ordinary, ordinary)
        @test NS.codim(ordinary) == 0
        @test NS.codim(supersingular) == 6 * 7 ÷ 2 - fld(6^2, 4)

        function generic_p_rank_polygon(g, f)
            remaining = g - f
            slopes = Rational{Int}[]
            lengths = Int[]
            if f > 0
                push!(slopes, 0 // 1)
                push!(lengths, f)
            end
            if remaining == 1
                push!(slopes, 1 // 2)
                push!(lengths, 2)
            elseif remaining > 1
                push!(slopes, 1 // remaining, (remaining - 1) // remaining)
                append!(lengths, (remaining, remaining))
            end
            if f > 0
                push!(slopes, 1 // 1)
                push!(lengths, f)
            end
            NS.SlopeMultiplicityPolygon(slopes, lengths)
        end

        for f in 0:6
            generic = generic_p_rank_polygon(6, f)
            @test NS.is_valid_symmetric_polygon(generic)
            @test NS.p_rank(generic) == f
            @test NS.codim(generic) == 6 - f
        end

        references = [
            (Rational{Int}[0, 1 // 3, 1 // 2, 2 // 3, 1], [1, 3, 4, 3, 1], 7),
            (Rational{Int}[1 // 4, 1 // 2, 3 // 4], [4, 4, 4], 8),
            (Rational{Int}[2 // 5, 1 // 2, 3 // 5], [5, 2, 5], 11),
            (Rational{Int}[1 // 3, 2 // 3], [6, 6], 9),
        ]
        reference_polygons = [NS.SlopeMultiplicityPolygon(slopes, lengths)
                              for (slopes, lengths, _) in references]
        for ((_, _, expected_codim), reference) in zip(references, reference_polygons)
            @test NS.is_valid_symmetric_polygon(reference)
            @test NS.codim(reference) == expected_codim
        end

        genus_six = NS.enumerate_symmetric_polygons(6)
        @test length(genus_six) == 20
        @test length(unique(genus_six)) == 20
        @test all(NS.is_valid_symmetric_polygon, genus_six)
        @test all(sum(polygon.slopelengths) == 12 for polygon in genus_six)
        @test all(reference -> reference in genus_six, reference_polygons)

        for g in 1:4
            polygons = NS.enumerate_symmetric_polygons(g)
            chain_lengths = Dict{NS.SlopeMultiplicityPolygon,Int}()
            function longest_chain(polygon)
                haskey(chain_lengths, polygon) && return chain_lengths[polygon]
                lower = [candidate for candidate in polygons
                         if candidate != polygon && NS.lies_on_or_above(polygon, candidate)]
                rank = isempty(lower) ? 0 : 1 + maximum(longest_chain(candidate) for candidate in lower)
                chain_lengths[polygon] = rank
                rank
            end
            for polygon in polygons
                @test NS.codim(polygon) == longest_chain(polygon)
            end
        end
    end
end
