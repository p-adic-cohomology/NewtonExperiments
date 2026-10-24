module FunSearchNewtonServer

const LOAD_STARTED_NS = time_ns()
const MAX_REQUEST_BYTES = 64 * 1024
const MAX_ACTIVE_CLIENTS = 64
const SOCKET_UMASK_LOCK = ReentrantLock()

using Dates
using DeRham
using JSON
using Oscar
using Random
using Sockets

include(joinpath(@__DIR__, "..", "..", "..", "src", "NewtonStrata.jl"))

const MONOMIAL_EXPONENTS = [(i, j, 5 - i - j) for i in 0:5 for j in 0:(5 - i)]
const GENUS = 6
const REFERENCE_PATH = normpath(joinpath(@__DIR__, "..", "reference", "plane_quintic_newton_polygons.tsv"))
const WARMUP_INSTANCE = "family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true"
const FERMAT_COEFFICIENTS = let coefficients = zeros(Int, 21)
    coefficients[[1, 6, 21]] .= 1
    coefficients
end

function _parse_ratio(value::AbstractString)
    parts = split(strip(value), '/')
    if length(parts) == 1
        return parse(Int, parts[1]) // 1
    elseif length(parts) == 2
        return parse(Int, parts[1]) // parse(Int, parts[2])
    end
    throw(ArgumentError("invalid rational value: $value"))
end

_format_ratio(value::Rational) = denominator(value) == 1 ? string(numerator(value)) : "$(numerator(value))/$(denominator(value))"
_polygon_key(values) = join(_format_ratio.(values), ';')

function _load_reference_table(path::AbstractString)
    lines = readlines(path)
    isempty(lines) && throw(ArgumentError("reference table is empty: $path"))
    header = split(first(lines), '\t')
    indices = Dict(name => findfirst(==(name), header) for name in ("p", "polygon_values"))
    any(isnothing, Base.values(indices)) && throw(ArgumentError("reference table is missing p or polygon_values"))
    polygons = Dict{Int,Set{String}}()
    for (offset, line) in enumerate(lines[2:end])
        line_number = offset + 1
        isempty(strip(line)) && continue
        fields = split(line, '\t')
        length(fields) >= maximum(Int.(collect(values(indices)))) ||
            throw(ArgumentError("reference row $line_number is incomplete"))
        p = parse(Int, fields[indices["p"]])
        polygon_values = _parse_ratio.(split(fields[indices["polygon_values"]], ';'))
        push!(get!(polygons, p, Set{String}()), _polygon_key(polygon_values))
    end
    polygons
end

const REFERENCE_POLYGONS = _load_reference_table(REFERENCE_PATH)
const LOAD_TIME_SECONDS = (time_ns() - LOAD_STARTED_NS) / 1.0e9

struct InstanceConfig
    p::Int
    reward::String
    beta::Float64
    eps::Float64
    exclude_ss::Bool
end

function _reward_score(codimension::Int, novel::Bool, config::InstanceConfig; supersingular_excluded=false)
    supersingular_excluded && return 0.0
    if config.reward == "mixed"
        codimension + config.beta * Int(novel)
    elseif config.reward == "depth"
        Float64(codimension)
    else
        Int(novel) + config.eps * codimension
    end
end

function _parse_instance(instance)
    instance isa AbstractString || throw(ArgumentError("instance must be a string"))
    fields = Dict{String,String}()
    for item in split(instance, ',')
        pair = split(strip(item), '='; limit=2)
        length(pair) == 2 || throw(ArgumentError("invalid instance field: $item"))
        key, value = strip.(pair)
        isempty(key) && throw(ArgumentError("instance field name is empty"))
        haskey(fields, key) && throw(ArgumentError("duplicate instance field: $key"))
        fields[key] = value
    end
    get(fields, "family", "plane") == "plane" || throw(ArgumentError("only family=plane is supported"))
    get(fields, "d", "5") == "5" || throw(ArgumentError("only degree d=5 is supported"))
    p = tryparse(Int, get(fields, "p", ""))
    p === nothing && throw(ArgumentError("instance p must be an integer"))
    p >= 2 && Oscar.is_prime(p) || throw(ArgumentError("instance p must be prime"))
    reward = get(fields, "reward", "mixed")
    reward in ("mixed", "depth", "novelty") || throw(ArgumentError("unknown reward mode: $reward"))
    beta = tryparse(Float64, get(fields, "beta", "0.5"))
    eps = tryparse(Float64, get(fields, "eps", "0.01"))
    beta !== nothing && isfinite(beta) && beta >= 0 || throw(ArgumentError("beta must be a finite nonnegative number"))
    eps !== nothing && isfinite(eps) && eps >= 0 || throw(ArgumentError("eps must be a finite nonnegative number"))
    exclude_value = lowercase(get(fields, "exclude_ss", "true"))
    exclude_value in ("true", "false") || throw(ArgumentError("exclude_ss must be true or false"))
    InstanceConfig(p, reward, beta, eps, exclude_value == "true")
end

function _invalid_details(message; p=nothing, coefficients=nothing)
    response = Dict{String,Any}(
        "status" => "INVALID",
        "score" => 0.0,
        "sig" => Float64[],
        "msg" => message,
    )
    (
        response=response,
        p=p,
        coefficients=coefficients,
        polygon=nothing,
        codim=nothing,
        novel=nothing,
        reward=0.0,
    )
end

function _error_details(message; p=nothing, coefficients=nothing)
    response = Dict{String,Any}(
        "status" => "ERROR",
        "score" => 0.0,
        "sig" => Float64[],
        "msg" => message,
    )
    (
        response=response,
        p=p,
        coefficients=coefficients,
        polygon=nothing,
        codim=nothing,
        novel=nothing,
        reward=0.0,
    )
end

function _build_curve(p::Int, coefficients::Vector{Int})
    field = Oscar.GF(p)
    ring, _ = Oscar.polynomial_ring(field, ["x", "y", "z"])
    context = Oscar.MPolyBuildCtx(ring)
    for (coefficient, exponent) in zip(coefficients, MONOMIAL_EXPONENTS)
        iszero(coefficient) && continue
        Oscar.push_term!(context, field(coefficient), collect(exponent))
    end
    Oscar.finish(context)
end

function _score_details(instance, coefficients; curve_builder=_build_curve)
    raw_coefficients = coefficients isa AbstractVector ? coefficients : nothing
    config = try
        _parse_instance(instance)
    catch error
        return _invalid_details(sprint(showerror, error); coefficients=raw_coefficients)
    end
    raw_coefficients isa Vector ||
        return _invalid_details("coeffs must be an array of 21 integers"; p=config.p, coefficients=raw_coefficients)
    length(raw_coefficients) == length(MONOMIAL_EXPONENTS) ||
        return _invalid_details("coeffs must contain exactly 21 integers"; p=config.p, coefficients=raw_coefficients)
    all(value -> value isa Integer && !(value isa Bool), raw_coefficients) ||
        return _invalid_details("coeffs must contain only integers"; p=config.p, coefficients=raw_coefficients)
    parsed_coefficients = try
        Int[value for value in raw_coefficients]
    catch error
        return _invalid_details("coefficients must fit in Int: $(sprint(showerror, error))"; p=config.p, coefficients=raw_coefficients)
    end
    all(value -> 0 <= value < config.p, parsed_coefficients) ||
        return _invalid_details("coefficients must lie in 0:p-1"; p=config.p, coefficients=parsed_coefficients)
    any(!iszero, parsed_coefficients) ||
        return _invalid_details("the zero polynomial is invalid"; p=config.p, coefficients=parsed_coefficients)

    curve = try
        curve_builder(config.p, parsed_coefficients)
    catch error
        return _error_details("could not construct curve: $(sprint(showerror, error))"; p=config.p, coefficients=parsed_coefficients)
    end
    derham_polygon = try
        DeRham.newton_polygon(
            curve;
            S=[0, 1, 2],
            fastevaluation=true,
            algorithm=:depthfirst,
            use_gpu=false,
        )
    catch error
        if error isa UndefVarError && error.var === :verbose
            return _invalid_details("curve is singular"; p=config.p, coefficients=parsed_coefficients)
        end
        return _error_details("DeRham evaluation failed: $(sprint(showerror, error))"; p=config.p, coefficients=parsed_coefficients)
    end
    derham_polygon === false &&
        return _invalid_details("curve is singular"; p=config.p, coefficients=parsed_coefficients)

    polygon = try
        NewtonStrata.from_slopes_polygon(derham_polygon)
    catch error
        return _error_details("invalid DeRham polygon: $(sprint(showerror, error))"; p=config.p, coefficients=parsed_coefficients)
    end
    codimension = try
        NewtonStrata.codim(polygon)
    catch error
        return _error_details("could not compute Newton-stratum codimension: $(sprint(showerror, error))"; p=config.p, coefficients=parsed_coefficients)
    end
    key = _polygon_key(NewtonStrata.integer_values(polygon))
    novel = !(key in get(REFERENCE_POLYGONS, config.p, Set{String}()))
    supersingular_excluded = config.exclude_ss && NewtonStrata.is_supersingular(polygon)
    reward = _reward_score(codimension, novel, config; supersingular_excluded=supersingular_excluded)
    signature = Float64[Float64(NewtonStrata.polygon_value(polygon, x)) for x in 1:GENUS]
    message = supersingular_excluded ? "supersingular (excluded)" : ""
    response = Dict{String,Any}(
        "status" => "OK",
        "score" => Float64(reward),
        "sig" => signature,
        "msg" => message,
    )
    (
        response=response,
        p=config.p,
        coefficients=parsed_coefficients,
        polygon=polygon,
        codim=codimension,
        novel=novel,
        reward=Float64(reward),
    )
end

function score_instance(instance, coefficients)
    _score_details(instance, coefficients).response
end

function _retention_record(details, request, elapsed_seconds)
    polygon = details.polygon
    Dict{String,Any}(
        "program_id" => get(request, "program_id", nothing),
        "p" => details.p,
        "coeffs" => details.coefficients,
        "instance" => get(request, "instance", nothing),
        "status" => details.response["status"],
        "slopes" => polygon === nothing ? nothing : _format_ratio.(polygon.slopes),
        "lengths" => polygon === nothing ? nothing : polygon.slopelengths,
        "polygon_values" => polygon === nothing ? nothing : _format_ratio.(NewtonStrata.integer_values(polygon)),
        "codim" => details.codim,
        "novel" => details.novel,
        "reward" => details.reward,
        "wall_time_seconds" => elapsed_seconds,
        "timestamp" => string(Dates.now(Dates.UTC), "Z"),
    )
end

function _append_record(path::AbstractString, record)
    mkpath(dirname(abspath(path)))
    open(path, "a") do output
        write(output, JSON.json(record))
        write(output, '\n')
        flush(output)
    end
    nothing
end

function _request_response(request, curves_path::AbstractString)
    request isa AbstractDict || return Dict{String,Any}(
        "status" => "ERROR", "score" => 0.0, "sig" => Float64[], "msg" => "request must be a JSON object",
    )
    started_ns = time_ns()
    details = _score_details(get(request, "instance", nothing), get(request, "coeffs", nothing))
    elapsed_seconds = (time_ns() - started_ns) / 1.0e9
    try
        _append_record(curves_path, _retention_record(details, request, elapsed_seconds))
    catch error
        return Dict{String,Any}(
            "status" => "ERROR",
            "score" => 0.0,
            "sig" => Float64[],
            "msg" => "curve retention failed: $(sprint(showerror, error))",
        )
    end
    details.response
end

function _response_for_line(line::AbstractString, curves_path::AbstractString)
    request = try
        JSON.parse(line)
    catch error
        return Dict{String,Any}(
            "status" => "ERROR",
            "score" => 0.0,
            "sig" => Float64[],
            "msg" => "malformed JSON request: $(sprint(showerror, error))",
        )
    end
    _request_response(request, curves_path)
end

struct PendingRequest
    line::String
    reply::Channel{Dict{String,Any}}
end

function _read_request_line(connection, max_bytes::Int=MAX_REQUEST_BYTES)
    bytes = UInt8[]
    sizehint!(bytes, min(max_bytes, 4096))
    while true
        byte = try
            read(connection, UInt8)
        catch error
            error isa EOFError || rethrow()
            return isempty(bytes) ? nothing : String(bytes)
        end
        byte == 0x0a && return String(bytes)
        length(bytes) == max_bytes && return :too_large
        push!(bytes, byte)
    end
end

function _client_loop(connection, request_queue)
    try
        while true
            line = _read_request_line(connection)
            line === nothing && break
            if line === :too_large
                write(connection, JSON.json(Dict{String,Any}(
                    "status" => "ERROR",
                    "score" => 0.0,
                    "sig" => Float64[],
                    "msg" => "request line exceeds the $(MAX_REQUEST_BYTES)-byte limit",
                )))
                write(connection, '\n')
                flush(connection)
                break
            end
            isempty(strip(line)) && continue
            reply = Channel{Dict{String,Any}}(1)
            try
                put!(request_queue, PendingRequest(line, reply))
                response = take!(reply)
                write(connection, JSON.json(response))
                write(connection, '\n')
                flush(connection)
            catch
                break
            end
        end
    catch
    finally
        close(connection)
    end
    nothing
end

function _accept_loop(listener, request_queue, client_slots, client_connections, clients_lock)
    while isopen(listener)
        connection = try
            accept(listener)
        catch
            isopen(listener) && rethrow()
            break
        end
        if !isready(client_slots)
            close(connection)
            continue
        end
        take!(client_slots)
        lock(clients_lock) do
            push!(client_connections, connection)
        end
        @async begin
            try
                _client_loop(connection, request_queue)
            finally
                lock(clients_lock) do
                    delete!(client_connections, connection)
                end
                put!(client_slots, nothing)
            end
        end
    end
    nothing
end

function _close_client_connections(client_connections, clients_lock)
    connections = lock(clients_lock) do
        collect(client_connections)
    end
    for connection in connections
        try
            close(connection)
        catch
        end
    end
    nothing
end

function _process_loop(request_queue, curves_path)
    for pending in request_queue
        response = try
            _response_for_line(pending.line, curves_path)
        catch error
            Dict{String,Any}(
                "status" => "ERROR",
                "score" => 0.0,
                "sig" => Float64[],
                "msg" => "request processing failed: $(sprint(showerror, error))",
            )
        end
        try
            put!(pending.reply, response)
        catch
        end
    end
    nothing
end

function _precision_provenance()
    curve = _build_curve(7, FERMAT_COEFFICIENTS)
    basis = DeRham.get_basis_of_cohomology(curve)
    _, relative_precision, series_precision, algorithm_precision =
        DeRham.calculate_precision_information(curve, basis)
    series_precision == [4, 4] || throw(ErrorException("unexpected DeRham precision for plane quintic at p=7: $series_precision"))
    Dict{String,Any}(
        "dimension_n" => 2,
        "degree_d" => 5,
        "p" => 7,
        "path" => "table",
        "r_m" => relative_precision,
        "N_m" => series_precision,
        "M" => algorithm_precision,
        "DeRham_function" => "series_precision",
    )
end

function _ready_record(warmup_seconds::Float64, warmup_response, precision)
    source_path = pathof(DeRham)
    source_root = dirname(dirname(source_path))
    commit = try
        strip(read(`git -C $source_root rev-parse HEAD`, String))
    catch
        "unknown"
    end
    Dict{String,Any}(
        "status" => "ready",
        "load_time_seconds" => LOAD_TIME_SECONDS,
        "warmup_first_call_seconds" => warmup_seconds,
        "warmup_status" => warmup_response["status"],
        "DeRham_path" => source_path,
        "DeRham_commit" => commit,
        "precision_provenance" => precision,
        "peak_rss_bytes" => Int(Sys.maxrss()),
        "sysimage" => get(ENV, "KAIMON_CITY_SYSIMAGE", "off"),
        "julia_image_file" => unsafe_string(Base.JLOptions().image_file),
        "julia_version" => string(VERSION),
        "ready_at" => string(Dates.now(Dates.UTC), "Z"),
    )
end

function _write_ready_file(path::AbstractString, record)
    destination = abspath(path)
    temporary_path, output = mktemp(dirname(destination))
    try
        write(output, JSON.json(record))
        write(output, '\n')
        flush(output)
        close(output)
        # A same-directory rename publishes the complete file without following a replaced symlink.
        mv(temporary_path, destination; force=true)
    catch
        isopen(output) && close(output)
        ispath(temporary_path) && rm(temporary_path; force=true)
        rethrow()
    end
    nothing
end

function _listen_private_socket(socket_path::AbstractString)
    lock(SOCKET_UMASK_LOCK) do
        previous_umask = ccall(:umask, Cint, (Cint,), Cint(0o177))
        try
            Sockets.listen(socket_path)
        finally
            ccall(:umask, Cint, (Cint,), previous_umask)
        end
    end
end

function _start_server(
    socket_path::AbstractString,
    ready_path::AbstractString,
    curves_path::AbstractString,
    ready_writer,
)
    for path in (socket_path, ready_path)
        isempty(path) && throw(ArgumentError("socket and ready paths must be nonempty"))
    end
    ispath(socket_path) && throw(ArgumentError("socket path already exists: $socket_path"))
    rm(ready_path; force=true)
    warmup_started_ns = time_ns()
    warmup_response = score_instance(WARMUP_INSTANCE, FERMAT_COEFFICIENTS)
    warmup_seconds = (time_ns() - warmup_started_ns) / 1.0e9
    warmup_response["status"] == "OK" || throw(ErrorException("built-in warm-up curve failed: $(warmup_response["msg"])"))
    precision = _precision_provenance()
    ready_record = _ready_record(warmup_seconds, warmup_response, precision)
    mkpath(dirname(abspath(socket_path)))
    mkpath(dirname(abspath(ready_path)))
    listener = _listen_private_socket(socket_path)
    request_queue = Channel{PendingRequest}(32)
    client_slots = Channel{Nothing}(MAX_ACTIVE_CLIENTS)
    for _ in 1:MAX_ACTIVE_CLIENTS
        put!(client_slots, nothing)
    end
    client_connections = Set{Any}()
    clients_lock = ReentrantLock()
    accept_task = nothing
    process_task = nothing
    try
        chmod(socket_path, 0o600)
        accept_task = @async _accept_loop(listener, request_queue, client_slots, client_connections, clients_lock)
        process_task = @async _process_loop(request_queue, curves_path)
        ready_writer(ready_path, ready_record)
    catch
        isopen(listener) && close(listener)
        if accept_task !== nothing
            try
                wait(accept_task)
            catch
            end
        end
        _close_client_connections(client_connections, clients_lock)
        isopen(request_queue) && close(request_queue)
        if process_task !== nothing
            try
                wait(process_task)
            catch
            end
        end
        for _ in 1:MAX_ACTIVE_CLIENTS
            take!(client_slots)
        end
        rm(socket_path; force=true)
        rm(ready_path; force=true)
        rethrow()
    end
    (
        listener=listener,
        request_queue=request_queue,
        accept_task=accept_task,
        process_task=process_task,
        client_slots=client_slots,
        client_connections=client_connections,
        clients_lock=clients_lock,
        client_slots_drained=Ref(false),
        socket_path=String(socket_path),
        ready_path=String(ready_path),
        ready_record=ready_record,
    )
end

start_server(socket_path::AbstractString, ready_path::AbstractString, curves_path::AbstractString) =
    _start_server(socket_path, ready_path, curves_path, _write_ready_file)

function stop_server(server)
    isopen(server.listener) && close(server.listener)
    try
        wait(server.accept_task)
    catch
    end
    _close_client_connections(server.client_connections, server.clients_lock)
    isopen(server.request_queue) && close(server.request_queue)
    try
        wait(server.process_task)
    catch
    end
    if !server.client_slots_drained[]
        for _ in 1:MAX_ACTIVE_CLIENTS
            take!(server.client_slots)
        end
        server.client_slots_drained[] = true
    end
    rm(server.socket_path; force=true)
    rm(server.ready_path; force=true)
    nothing
end

function _server_arguments(args)
    options = Dict{String,String}(
        "socket" => get(ENV, "FUNSEARCH_NEWTON_SOCKET", ""),
        "ready-file" => get(ENV, "FUNSEARCH_NEWTON_READY", ""),
        "curves" => get(ENV, "FUNSEARCH_NEWTON_CURVES", ""),
    )
    index = 1
    while index <= length(args)
        name = replace(args[index], r"^--" => "")
        haskey(options, name) || throw(ArgumentError("unknown server option: $(args[index])"))
        index < length(args) || throw(ArgumentError("missing value for --$name"))
        options[name] = args[index + 1]
        index += 2
    end
    all(!isempty, Base.values(options)) ||
        throw(ArgumentError("provide --socket, --ready-file, and --curves (or their FUNSEARCH_NEWTON_* environment variables)"))
    options
end

function main(args=ARGS)
    options = _server_arguments(args)
    server = start_server(options["socket"], options["ready-file"], options["curves"])
    println(JSON.json(server.ready_record))
    try
        wait(server.process_task)
    finally
        stop_server(server)
    end
end

export score_instance, start_server, stop_server

end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    FunSearchNewtonServer.main()
end
