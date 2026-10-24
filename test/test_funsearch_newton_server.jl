include(joinpath(@__DIR__, "..", "experiments", "funsearch-newton", "server", "score_server.jl"))

using .FunSearchNewtonServer
using JSON
using Sockets

@testset "FunSearch Newton score server" begin
    server_module = FunSearchNewtonServer
    fermat = server_module.FERMAT_COEFFICIENTS
    instance(p, extra="") = "family=plane,d=5,p=$p,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true$extra"

    @test length(server_module.MONOMIAL_EXPONENTS) == 21
    @test [collect(exponent) for exponent in server_module.MONOMIAL_EXPONENTS] == DeRham.gen_exp_vec(3, 5, :lex)
    @test fermat[[1, 6, 21]] == [1, 1, 1]
    @test server_module._server_arguments(["--socket", "score.sock", "--ready-file", "ready.json", "--curves", "curves.jsonl"]) == Dict(
        "socket" => "score.sock",
        "ready-file" => "ready.json",
        "curves" => "curves.jsonl",
    )

    @testset "Invalid inputs" begin
        response = score_instance(instance(7), zeros(Int, 21))
        @test response["status"] == "INVALID"
        @test response["score"] == 0.0
        @test occursin("zero polynomial", response["msg"])
        @test score_instance(instance(7), zeros(Int, 20))["status"] == "INVALID"
        out_of_range = copy(fermat)
        out_of_range[1] = 7
        @test score_instance(instance(7), out_of_range)["status"] == "INVALID"
        @test score_instance("family=plane,d=5,p=4", fermat)["status"] == "INVALID"
    end

    @testset "Known smooth and singular curves" begin
        supersingular = score_instance(instance(7), fermat)
        @test supersingular["status"] == "OK"
        @test supersingular["score"] == 0.0
        @test supersingular["msg"] == "supersingular (excluded)"
        @test supersingular["sig"] == [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]

        ordinary = score_instance(instance(11), fermat)
        @test ordinary["status"] == "OK"
        @test ordinary["score"] == 0.0
        @test ordinary["msg"] == ""
        @test ordinary["sig"] == zeros(6)

        singular_coefficients = zeros(Int, 21)
        singular_coefficients[21] = 1
        singular = score_instance(instance(7), singular_coefficients)
        @test singular["status"] == "INVALID"
        @test singular["msg"] == "curve is singular"
    end

    @testset "Reward modes" begin
        mixed = server_module.InstanceConfig(7, "mixed", 0.5, 0.01, true)
        depth = server_module.InstanceConfig(7, "depth", 0.5, 0.01, true)
        novelty = server_module.InstanceConfig(7, "novelty", 0.5, 0.01, true)
        @test server_module._reward_score(5, true, mixed) == 5.5
        @test server_module._reward_score(5, true, depth) == 5.0
        @test server_module._reward_score(5, true, novelty) == 1.05
        @test server_module._reward_score(12, true, mixed; supersingular_excluded=true) == 0.0
    end

    @testset "Unix socket round trip and append-only retention" begin
        mktempdir() do directory
            socket_path = joinpath(directory, "score.sock")
            ready_path = joinpath(directory, "ready.json")
            curves_path = joinpath(directory, "curves.jsonl")
            write(curves_path, "existing-run-line\n")
            server = server_module.start_server(socket_path, ready_path, curves_path)
            try
                @test isfile(ready_path)
                ready = JSON.parse(read(ready_path, String))
                @test ready["status"] == "ready"
                @test ready["precision_provenance"]["path"] == "table"
                @test ready["precision_provenance"]["N_m"] == [4, 4]
                @test ready["DeRham_commit"] == "59b331b818aaa7f169a33c42e600cbc6de9044f7"

                connection = Sockets.connect(socket_path)
                request = Dict(
                    "program_id" => "unit-test-program",
                    "instance" => instance(7),
                    "coeffs" => zeros(Int, 21),
                )
                write(connection, JSON.json(request))
                write(connection, '\n')
                flush(connection)
                response = JSON.parse(readline(connection))
                close(connection)

                @test response["status"] == "INVALID"
                rows = readlines(curves_path)
                @test rows[1] == "existing-run-line"
                @test length(rows) == 2
                record = JSON.parse(rows[2])
                @test record["program_id"] == "unit-test-program"
                @test record["p"] == 7
                @test record["status"] == "INVALID"
                @test record["slopes"] === nothing
                @test record["reward"] == 0.0
                @test record["wall_time_seconds"] >= 0.0
                @test endswith(record["timestamp"], "Z")
            finally
                server_module.stop_server(server)
            end
        end
    end
end
