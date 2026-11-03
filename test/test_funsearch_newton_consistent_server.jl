include(joinpath(@__DIR__, "..", "experiments", "funsearch-newton-consistent", "server", "score_server.jl"))
include(joinpath(@__DIR__, "..", "experiments", "funsearch-newton-consistent", "server", "measure_server.jl"))

using .FunSearchNewtonConsistentServer
using .FunSearchNewtonConsistentMeasureServer
using JSON
using Random
using Sockets
using Test

const server_module = FunSearchNewtonConsistentServer
const strata = server_module.NewtonStrata
const NONORDINARY_FIXTURES = Dict{Int,Vector{Int}}()

function test_instance(p; k=16, curve_reward="log", lambda=0.25, beta=0.5, ss_codim=1)
    "family=plane,d=5,p=$p,k=$k,curve_reward=$curve_reward,lambda=$lambda,beta=$beta,ss_codim=$ss_codim"
end

function tagged_coefficients(tag, p=7)
    coefficients = zeros(Int, 21)
    coefficients[1] = tag
    coefficients[6] = mod(tag + 1, p)
    coefficients[21] = mod(tag + 2, p)
    coefficients
end

function test_polygons()
    polygons = strata.enumerate_symmetric_polygons(6)
    ordinary = first(polygon for polygon in polygons if strata.is_ordinary(polygon))
    supersingular = first(polygon for polygon in polygons if strata.is_supersingular(polygon))
    codim_two = first(
        polygon for polygon in polygons
        if strata.codim(polygon) == 2 && !strata.is_supersingular(polygon)
    )
    codim_four = first(
        polygon for polygon in polygons
        if strata.codim(polygon) == 4 && !strata.is_supersingular(polygon)
    )
    (ordinary=ordinary, supersingular=supersingular, codim_two=codim_two, codim_four=codim_four)
end

function polygon_key(polygon)
    server_module._polygon_key(strata.integer_values(polygon))
end

function stub_builders(polygons)
    by_id = Dict(
        1 => polygons.codim_two,
        2 => polygons.supersingular,
        3 => polygons.codim_four,
        4 => polygons.ordinary,
    )
    known = Set([polygon_key(polygons.codim_two), polygon_key(polygons.supersingular), polygon_key(polygons.ordinary)])
    reference = Dict(7 => known)
    curve_builder = (p, coefficients) -> coefficients[1]
    zeta_builder = (curve; kwargs...) -> [curve]
    polygon_builder = (p, zeta) -> by_id[Int(first(zeta))]
    (curve_builder=curve_builder, zeta_builder=zeta_builder, polygon_builder=polygon_builder, reference=reference)
end

function polynomial_multiply(a, b, p)
    result = Dict{NTuple{3,Int},Int}()
    for (exponent_a, coefficient_a) in a, (exponent_b, coefficient_b) in b
        exponent = ntuple(index -> exponent_a[index] + exponent_b[index], 3)
        result[exponent] = mod(get(result, exponent, 0) + coefficient_a * coefficient_b, p)
    end
    result
end

function polynomial_power(polynomial, exponent, p)
    result = Dict((0, 0, 0) => 1)
    for _ in 1:exponent
        result = polynomial_multiply(result, polynomial, p)
    end
    result
end

function linear_form(matrix, row, p)
    result = Dict{NTuple{3,Int},Int}()
    for column in 1:3
        coefficient = mod(matrix[row, column], p)
        coefficient == 0 && continue
        exponent = ntuple(index -> index == column ? 1 : 0, 3)
        result[exponent] = coefficient
    end
    result
end

function transform_curve(coefficients, matrix, p)
    forms = [linear_form(matrix, row, p) for row in 1:3]
    powers = [[polynomial_power(forms[row], exponent, p) for exponent in 0:5] for row in 1:3]
    result = Dict{NTuple{3,Int},Int}()
    for (index, (i, j, k)) in enumerate(server_module.MONOMIAL_EXPONENTS)
        term = polynomial_multiply(
            polynomial_multiply(powers[1][i + 1], powers[2][j + 1], p),
            powers[3][k + 1],
            p,
        )
        for (exponent, coefficient) in term
            result[exponent] = mod(get(result, exponent, 0) + coefficients[index] * coefficient, p)
        end
    end
    [get(result, exponent, 0) for exponent in server_module.MONOMIAL_EXPONENTS]
end

function determinant_mod(matrix, p)
    mod(
        matrix[1, 1] * (matrix[2, 2] * matrix[3, 3] - matrix[2, 3] * matrix[3, 2]) -
        matrix[1, 2] * (matrix[2, 1] * matrix[3, 3] - matrix[2, 3] * matrix[3, 1]) +
        matrix[1, 3] * (matrix[2, 1] * matrix[3, 2] - matrix[2, 2] * matrix[3, 1]),
        p,
    )
end

function random_invertible_matrix(rng, p)
    while true
        matrix = rand(rng, 0:(p - 1), 3, 3)
        determinant_mod(matrix, p) != 0 && return matrix
    end
end

function random_nonordinary_curve(p, rng)
    if p == 7
        coefficients = copy(server_module.FERMAT_COEFFICIENTS)
        coefficients[15] = 2
        return coefficients
    end
    for _ in 1:100
        coefficients = rand(rng, 0:(p - 1), 21)
        any(!iszero, coefficients) || continue
        details = server_module._score_details(test_instance(p; k=1), [coefficients])
        sample = only(details.samples)
        details.response["status"] == "OK" && sample.codim > 0 && return coefficients
    end
    error("failed to find a smooth nonordinary curve at p=$p")
end

@testset "Consistent FunSearch Newton server" begin
    polygons = test_polygons()
    stubs = stub_builders(polygons)

    @testset "Instance grammar and defaults" begin
        defaults = server_module._parse_instance("family=plane,d=5,p=7")
        @test defaults.k == 16
        @test defaults.curve_reward == "log"
        @test defaults.lambda == 0.25
        @test defaults.beta == 0.5
        @test defaults.ss_codim == 1
        @test server_module._parse_instance("p=7,k=1").k == 1
        @test server_module._parse_instance("p=7,k=64").k == 64
        for invalid in ("p=7,k=0", "p=7,k=65", "p=7,curve_reward=depth", "p=7,lambda=-1",
                        "p=7,lambda=Inf", "p=7,beta=NaN", "p=7,ss_codim=-1", "p=7,ss_codim=13")
            @test_throws ArgumentError server_module._parse_instance(invalid)
        end
        @test_throws ArgumentError server_module._parse_instance("p=7,k=1,k=2")
        @test_throws ArgumentError server_module._parse_instance("p=7,unknown=1")
        for (field, replacement) in (("reward=mixed", "curve_reward"), ("eps=0.01", "none"),
                                     ("exclude_ss=true", "ss_codim"))
            error = try
                server_module._parse_instance("p=7,$field")
                nothing
            catch caught
                caught
            end
            @test error isa ArgumentError
            @test occursin(replacement, sprint(showerror, error))
        end
    end

    @testset "K-sample score, zeta dedupe, and signature" begin
        samples = [
            tagged_coefficients(1),
            tagged_coefficients(1),
            tagged_coefficients(2),
            tagged_coefficients(3),
            tagged_coefficients(4),
        ]
        details = server_module._score_details(
            test_instance(7; k=5),
            samples;
            curve_builder=stubs.curve_builder,
            zeta_builder=stubs.zeta_builder,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        )
        response = details.response
        mean_term = (log2(3) + 1 + log2(5)) / 5
        expected_score = mean_term + 0.25 * log2(5) + 0.5
        @test response["status"] == "OK"
        @test response["score"] ≈ expected_score
        @test response["sig"][1] ≈ mean_term
        @test response["sig"][2] ≈ log2(5)
        @test response["sig"][3] == 4 / 5
        @test response["sig"][4] == 3 / 5
        @test details.samples[2].duplicate_of == 0
        @test details.samples[2].reward == 0.0
        @test details.samples[1].zeta == ["1"]
        @test length(response["sig"]) == 5
        @test all(isfinite, response["sig"])
        @test ncodeunits(response["msg"]) <= 255
        @test all(byte -> byte <= 0x7f, codeunits(response["msg"]))

        reordered = server_module._score_details(
            test_instance(7; k=5),
            samples[[3, 1, 4, 2, 5]];
            curve_builder=stubs.curve_builder,
            zeta_builder=stubs.zeta_builder,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        )
        @test reordered.response["sig"][5] == response["sig"][5]
        @test reordered.response["sig"][3:4] == response["sig"][3:4]
        @test reordered.response["score"] ≈ response["score"]

        linear = server_module._score_details(
            test_instance(7; k=5, curve_reward="linear"),
            samples;
            curve_builder=stubs.curve_builder,
            zeta_builder=stubs.zeta_builder,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        )
        @test linear.response["score"] ≈ 2.9

        no_supersingular_reward = server_module._score_details(
            test_instance(7; k=5, curve_reward="linear", ss_codim=0),
            samples;
            curve_builder=stubs.curve_builder,
            zeta_builder=stubs.zeta_builder,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        )
        @test no_supersingular_reward.samples[3].reward == 0.0
        @test no_supersingular_reward.response["score"] ≈ 2.7
    end

    @testset "Repeated coefficient vectors reuse successful scoring" begin
        curve_calls = Ref(0)
        zeta_calls = Ref(0)
        polygon_calls = Ref(0)
        curve_builder = (p, coefficients) -> (curve_calls[] += 1; coefficients[1])
        zeta_builder = (curve; kwargs...) -> (zeta_calls[] += 1; [curve])
        polygon_builder = (p, zeta) -> (polygon_calls[] += 1; stubs.polygon_builder(p, zeta))
        first_curve = tagged_coefficients(1)
        second_curve = tagged_coefficients(2)
        details = server_module._score_details(
            test_instance(7; k=4, lambda=0, beta=0),
            [first_curve, copy(first_curve), second_curve, copy(second_curve)];
            curve_builder=curve_builder,
            zeta_builder=zeta_builder,
            polygon_builder=polygon_builder,
            reference_polygons=stubs.reference,
        )

        @test details.response["status"] == "OK"
        @test (curve_calls[], zeta_calls[], polygon_calls[]) == (2, 2, 2)
        @test [sample.k for sample in details.samples] == collect(0:3)
        @test details.samples[2].duplicate_of == 0
        @test details.samples[4].duplicate_of == 2
        @test details.samples[2].coefficients == details.samples[1].coefficients
        @test details.samples[2].coefficients !== details.samples[1].coefficients
        @test details.samples[2].reward == 0.0
        @test details.samples[4].reward == 0.0
    end

    @testset "Invalid and failed samples" begin
        valid = tagged_coefficients(1)
        invalid = zeros(Int, 21)
        partly_invalid = server_module._score_details(
            test_instance(7; k=2, lambda=0, beta=0),
            [valid, invalid];
            curve_builder=stubs.curve_builder,
            zeta_builder=stubs.zeta_builder,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        )
        @test partly_invalid.response["status"] == "OK"
        @test partly_invalid.response["score"] ≈ log2(3) / 2
        @test partly_invalid.samples[2].status == "INVALID"
        @test endswith(partly_invalid.response["msg"], "i")

        all_invalid = server_module._score_details(
            test_instance(7; k=2),
            [invalid, invalid];
            curve_builder=stubs.curve_builder,
            zeta_builder=stubs.zeta_builder,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        )
        @test all_invalid.response["status"] == "INVALID"
        @test all_invalid.response["score"] == 0.0
        @test all(isfinite, all_invalid.response["sig"])

        smooth_failure = copy(server_module.FERMAT_COEFFICIENTS)
        smooth_failure[1] = 5
        failing_zeta = (curve; kwargs...) -> curve == 5 ? error("injected zeta failure") : [curve]
        evaluation_error = server_module._score_details(
            test_instance(7; k=2),
            [valid, smooth_failure];
            curve_builder=stubs.curve_builder,
            zeta_builder=failing_zeta,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        )
        @test evaluation_error.response["status"] == "ERROR"
        @test evaluation_error.samples[2].status == "ERROR"
        @test occursin("injected zeta failure", evaluation_error.samples[2].reason)
        @test occursin("e", evaluation_error.response["msg"])

        oversized_message = server_module._score_details(
            test_instance(7; k=64),
            fill(tagged_coefficients(2), 64);
            curve_builder=stubs.curve_builder,
            zeta_builder=stubs.zeta_builder,
            polygon_builder=stubs.polygon_builder,
            reference_polygons=stubs.reference,
        ).response["msg"]
        @test ncodeunits(oversized_message) <= 255
        @test occursin(r"\+\d+ more$", oversized_message)
    end

    @testset "Per-sample retention records" begin
        mktempdir() do directory
            curves_path = joinpath(directory, "curves.jsonl")
            request = Dict{String,Any}(
                "program_id" => "test-program",
                "instance" => test_instance(7; k=2, lambda=0, beta=0),
                "samples" => [tagged_coefficients(1), tagged_coefficients(1)],
            )
            response = server_module._request_response(
                request,
                curves_path;
                curve_builder=stubs.curve_builder,
                zeta_builder=stubs.zeta_builder,
                polygon_builder=stubs.polygon_builder,
                reference_polygons=stubs.reference,
            )
            records = JSON.parse.(readlines(curves_path))
            @test response["status"] == "OK"
            @test length(records) == 2
            @test [record["k"] for record in records] == [0, 1]
            @test records[1]["program_id"] == "test-program"
            @test records[1]["zeta"] == ["1"]
            @test records[1]["zeta_key"] == records[2]["zeta_key"]
            @test records[1]["duplicate_of"] === nothing
            @test records[2]["duplicate_of"] == 0
            @test records[2]["sample_reward"] == 0.0
            @test records[1]["program_score"] == records[2]["program_score"]
            @test records[1]["batch_id"] == records[2]["batch_id"]
            @test !isempty(records[1]["batch_id"])
        end
    end

    @testset "PGL3 transforms preserve zeta classes at p=7, 11, 13" begin
        for p in (7, 11, 13)
            rng = MersenneTwister(0x50474c33 + p)
            base = random_nonordinary_curve(p, rng)
            NONORDINARY_FIXTURES[p] = copy(base)
            transformed = [
                transform_curve(base, random_invertible_matrix(rng, p), p)
                for _ in 1:3
            ]
            details = server_module._score_details(test_instance(p; k=4), [base, transformed...])
            @test details.response["status"] == "OK"
            @test all(sample.status == "OK" for sample in details.samples)
            @test all(sample.codim > 0 for sample in details.samples)
            @test length(unique(sample.zeta_key for sample in details.samples)) == 1
            @test details.response["sig"][3] == 1 / 4
        end
    end

    @testset "24 real samples retain in input order" begin
        singular_indices = (
            findfirst(==((5, 0, 0)), server_module.MONOMIAL_EXPONENTS),
            findfirst(==((4, 1, 0)), server_module.MONOMIAL_EXPONENTS),
        )
        all_samples = Any[]
        sample_details = Dict{Int,Any}()
        for p in (7, 11, 13)
            rng = MersenneTwister(0x53455249414c + p)
            base = NONORDINARY_FIXTURES[p]
            transformed = [
                transform_curve(base, random_invertible_matrix(rng, p), p)
                for _ in 1:2
            ]
            singular_curves = Vector{Int}[]
            for coefficient in 1:4
                singular = zeros(Int, 21)
                singular[singular_indices[1]] = 1
                singular[singular_indices[2]] = coefficient
                push!(singular_curves, singular)
            end
            samples = [copy(server_module.FERMAT_COEFFICIENTS), copy(base), transformed..., singular_curves...]
            @test length(samples) == 8
            instance = test_instance(p; k=length(samples))
            details = server_module._score_details(instance, samples)
            @test details.response["status"] == "OK"
            @test length(details.samples) == 8

            request = Dict{String,Any}(
                "program_id" => "thread-equivalence-p$p",
                "instance" => instance,
                "samples" => samples,
            )
            timestamp = "2026-01-01T00:00:00Z"
            records = [
                server_module._retention_record(details, sample, request, 1.0, "serial-batch", timestamp)
                for sample in details.samples
            ]
            @test [record["k"] for record in records] == collect(0:7)
            @test all(record["batch_id"] == "serial-batch" for record in records)
            sample_details[p] = details.samples
            append!(all_samples, details.samples)
        end
        @test length(all_samples) == 24
        @test any(sample -> sample.status == "INVALID", all_samples)
        @test any(sample -> sample.status == "OK" && sample.supersingular, all_samples)
        @test any(sample -> sample.status == "OK" && sample.codim == 0, sample_details[11])
        @test any(sample -> sample.status == "OK" && sample.codim > 0, sample_details[7])
    end

    @testset "Measurement sample classification" begin
        elapsed = Float64[]
        @test FunSearchNewtonConsistentMeasureServer._record_measurement_sample!(
            elapsed,
            Dict("status" => "OK"),
            0.25,
        )
        @test elapsed == [0.25]
        @test !FunSearchNewtonConsistentMeasureServer._record_measurement_sample!(
            elapsed,
            Dict("status" => "INVALID"),
            0.5,
        )
        @test elapsed == [0.25]
        @test_throws ErrorException FunSearchNewtonConsistentMeasureServer._record_measurement_sample!(
            elapsed,
            Dict("status" => "ERROR", "msg" => "stub failed"),
            1.0,
        )
    end

    @testset "Socket batch round trip and cleanup" begin
        mktempdir() do directory
            socket_path = joinpath(directory, "score.sock")
            ready_path = joinpath(directory, "ready.json")
            curves_path = joinpath(directory, "curves.jsonl")
            server = server_module.start_server(socket_path, ready_path, curves_path)
            connection = nothing
            try
                @test isfile(ready_path)
                ready = JSON.parse(read(ready_path, String))
                @test ready["status"] == "ready"
                @test ready["julia_version"] == string(VERSION)
                @test ready["thread_count"] == Threads.nthreads()
                @test occursin("funsearch-newton/reference", join(ready["reference_tables"], " "))
                connection = Sockets.connect(socket_path)
                request = Dict{String,Any}(
                    "program_id" => "socket-program",
                    "instance" => test_instance(7; k=2, lambda=0, beta=0),
                    "samples" => [server_module.FERMAT_COEFFICIENTS, server_module.FERMAT_COEFFICIENTS],
                )
                write(connection, JSON.json(request))
                write(connection, '\n')
                flush(connection)
                response = JSON.parse(readline(connection))
                @test response["status"] == "OK"
                @test length(response["sig"]) == 5
                @test ncodeunits(response["msg"]) <= 255
                records = JSON.parse.(readlines(curves_path))
                @test length(records) == 2
                @test records[1]["batch_id"] == records[2]["batch_id"]
                @test records[2]["duplicate_of"] == 0
            finally
                connection !== nothing && close(connection)
                server_module.stop_server(server)
            end
            @test !ispath(socket_path)
            @test !ispath(ready_path)
        end
    end

    @testset "Concurrent real score servers retain complete batches" begin
        mktempdir() do directory
            repository = normpath(joinpath(@__DIR__, ".."))
            server_script = joinpath(repository, "experiments", "funsearch-newton-consistent", "server", "score_server.jl")
            curves_path = joinpath(directory, "curves.jsonl")
            socket_paths = [joinpath(directory, "score-$index.sock") for index in 1:2]
            ready_paths = [joinpath(directory, "ready-$index.json") for index in 1:2]
            log_paths = [joinpath(directory, "server-$index.log") for index in 1:2]
            server_processes = Any[]
            server_logs = IO[]
            try
                for index in 1:2
                    log = open(log_paths[index], "w")
                    push!(server_logs, log)
                    command = `$(Base.julia_cmd()) --threads=1 --project=$repository $server_script --socket $(socket_paths[index]) --ready-file $(ready_paths[index]) --curves $curves_path`
                    push!(server_processes, run(pipeline(command, stdout=log, stderr=log); wait=false))
                end

                deadline = time() + 180
                while time() < deadline && !all(isfile, ready_paths)
                    any(process -> !process_running(process), server_processes) && break
                    sleep(0.1)
                end
                ready = all(path -> isfile(path) && filesize(path) > 0, ready_paths)
                @test ready
                if !ready
                    foreach(flush, server_logs)
                    error("score-server children failed to become ready: " * join(read.(log_paths, String), "\n"))
                end
                @test all(JSON.parse(read(path, String))["thread_count"] == 1 for path in ready_paths)

                batch_size = 16
                instance = test_instance(7; k=batch_size, lambda=0, beta=0)
                program_ids = [repeat("x", 8192) * "-server-$index" for index in 1:2]
                submit = function (socket_path, program_id)
                    connection = Sockets.connect(socket_path)
                    try
                        request = Dict{String,Any}(
                            "program_id" => program_id,
                            "instance" => instance,
                            "samples" => [copy(server_module.FERMAT_COEFFICIENTS) for _ in 1:batch_size],
                        )
                        write(connection, JSON.json(request))
                        write(connection, '\n')
                        flush(connection)
                        JSON.parse(readline(connection))
                    finally
                        close(connection)
                    end
                end
                requests = Task[]
                for index in 1:2
                    push!(requests, @async submit(socket_paths[index], program_ids[index]))
                end
                responses = fetch.(requests)
                @test all(response["status"] == "OK" for response in responses)

                records = JSON.parse.(readlines(curves_path))
                @test length(records) == 2 * batch_size
                @test Set(record["program_id"] for record in records) == Set(program_ids)
                groups = Vector{Any}[]
                for record in records
                    if isempty(groups) || last(last(groups))["batch_id"] != record["batch_id"]
                        push!(groups, Any[])
                    end
                    push!(last(groups), record)
                end
                @test length(groups) == 2
                for group in groups
                    @test length(group) == batch_size
                    @test length(Set(record["batch_id"] for record in group)) == 1
                    @test length(Set(record["program_id"] for record in group)) == 1
                    @test [record["k"] for record in group] == collect(0:(batch_size - 1))
                end
            finally
                for process in server_processes
                    process_running(process) && kill(process)
                    try
                        wait(process)
                    catch
                    end
                end
                foreach(close, filter(isopen, server_logs))
            end
        end
    end

    @testset "Request-line limits and startup arguments" begin
        @test server_module._read_request_line(IOBuffer("{}\n")) == "{}"
        @test server_module._read_request_line(IOBuffer("x"^(server_module.MAX_REQUEST_BYTES + 1))) == :too_large
        @test server_module._server_arguments([
            "--socket", "score.sock",
            "--ready-file", "ready.json",
            "--curves", "curves.jsonl",
        ]) == Dict("socket" => "score.sock", "ready-file" => "ready.json", "curves" => "curves.jsonl")
        @test_throws ArgumentError server_module._server_arguments(["--socket", "score.sock"])
    end
end
