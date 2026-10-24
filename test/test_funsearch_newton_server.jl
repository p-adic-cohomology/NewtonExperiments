include(joinpath(@__DIR__, "..", "experiments", "funsearch-newton", "server", "score_server.jl"))

using .FunSearchNewtonServer
using JSON
using Sockets

@testset "FunSearch Newton score server" begin
    server_module = FunSearchNewtonServer
    fermat = server_module.FERMAT_COEFFICIENTS
    instance(p; exclude_ss=true) = "family=plane,d=5,p=$p,reward=mixed,beta=0.5,eps=0.01,exclude_ss=$exclude_ss"
    function request_line(socket_path, line)
        connection = Sockets.connect(socket_path)
        try
            write(connection, line)
            write(connection, '\n')
            flush(connection)
            JSON.parse(readline(connection))
        finally
            close(connection)
        end
    end

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

    @testset "Bounded request lines" begin
        @test server_module._read_request_line(IOBuffer("{}\n")) == "{}"
        @test server_module._read_request_line(IOBuffer("x"^(server_module.MAX_REQUEST_BYTES + 1))) == :too_large
    end

    @testset "Ready-file publication does not follow symlinks" begin
        mktempdir() do directory
            target_path = joinpath(directory, "target.json")
            ready_path = joinpath(directory, "ready.json")
            write(target_path, "preserve this target")
            symlink(target_path, ready_path)

            server_module._write_ready_file(ready_path, Dict("status" => "ready"))

            @test read(target_path, String) == "preserve this target"
            @test !islink(ready_path)
            @test JSON.parse(read(ready_path, String))["status"] == "ready"
        end
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
                @test (stat(socket_path).mode & 0o777) == 0o600

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

                positive_connection = Sockets.connect(socket_path)
                positive_request = Dict(
                    "program_id" => "positive-score-program",
                    "instance" => instance(7; exclude_ss=false),
                    "coeffs" => fermat,
                )
                write(positive_connection, JSON.json(positive_request))
                write(positive_connection, '\n')
                flush(positive_connection)
                positive_response = JSON.parse(readline(positive_connection))
                close(positive_connection)

                @test positive_response["status"] == "OK"
                @test positive_response["score"] > 0.0
                @test positive_response["sig"] == [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
                rows = readlines(curves_path)
                @test rows[1] == "existing-run-line"
                @test length(rows) == 3
                record = JSON.parse(rows[2])
                @test record["program_id"] == "unit-test-program"
                @test record["p"] == 7
                @test record["status"] == "INVALID"
                @test record["slopes"] === nothing
                @test record["reward"] == 0.0
                @test record["wall_time_seconds"] >= 0.0
                @test endswith(record["timestamp"], "Z")
                positive_record = JSON.parse(rows[3])
                @test positive_record["program_id"] == "positive-score-program"
                @test positive_record["status"] == "OK"
                @test positive_record["codim"] > 0
                @test positive_record["reward"] > 0.0
            finally
                server_module.stop_server(server)
            end
            @test !ispath(socket_path)
            @test !ispath(ready_path)
        end
    end

    @testset "Socket protocol errors are not retained" begin
        mktempdir() do directory
            socket_path = joinpath(directory, "score.sock")
            ready_path = joinpath(directory, "ready.json")
            curves_path = joinpath(directory, "curves.jsonl")
            server = server_module.start_server(socket_path, ready_path, curves_path)
            try
                malformed = request_line(socket_path, "not-json")
                @test malformed["status"] == "ERROR"
                @test occursin("malformed JSON", malformed["msg"])

                non_object = request_line(socket_path, "[]")
                @test non_object["status"] == "ERROR"
                @test occursin("JSON object", non_object["msg"])

                oversized = request_line(socket_path, "x"^(server_module.MAX_REQUEST_BYTES + 1))
                @test oversized["status"] == "ERROR"
                @test occursin("exceeds", oversized["msg"])
            finally
                server_module.stop_server(server)
            end
            @test !isfile(curves_path)
        end
    end

    @testset "Concurrent clients receive and retain their own requests" begin
        mktempdir() do directory
            socket_path = joinpath(directory, "score.sock")
            ready_path = joinpath(directory, "ready.json")
            curves_path = joinpath(directory, "curves.jsonl")
            server = server_module.start_server(socket_path, ready_path, curves_path)
            requests = [
                Dict("program_id" => "concurrent-$i", "instance" => instance(7; exclude_ss=false),
                     "coeffs" => isodd(i) ? zeros(Int, 21) : fermat)
                for i in 1:4
            ]
            expected = ["INVALID", "OK", "INVALID", "OK"]
            connections = [Sockets.connect(socket_path) for _ in requests]
            try
                for (connection, request) in zip(connections, requests)
                    write(connection, JSON.json(request))
                    write(connection, '\n')
                    flush(connection)
                end
                responses = [JSON.parse(readline(connection)) for connection in connections]
                @test [response["status"] for response in responses] == expected
            finally
                foreach(close, connections)
                server_module.stop_server(server)
            end

            rows = JSON.parse.(readlines(curves_path))
            @test length(rows) == length(requests)
            retained = Dict(row["program_id"] => row["status"] for row in rows)
            @test retained == Dict(request["program_id"] => expected[i] for (i, request) in enumerate(requests))
        end
    end

    @testset "Startup failure cleans bound resources" begin
        mktempdir() do directory
            socket_path = joinpath(directory, "score.sock")
            ready_path = joinpath(directory, "ready.json")
            curves_path = joinpath(directory, "curves.jsonl")
            server = nothing
            startup_error = nothing
            try
                server = server_module._start_server(
                    socket_path,
                    ready_path,
                    curves_path,
                    (path, record) -> error("injected ready-file failure"),
                )
            catch caught
                startup_error = caught
            end
            server !== nothing && server_module.stop_server(server)

            @test startup_error isa ErrorException
            if startup_error !== nothing
                @test occursin("injected ready-file failure", sprint(showerror, startup_error))
            end
            @test !ispath(socket_path)
            @test !ispath(ready_path)
        end
    end
end
