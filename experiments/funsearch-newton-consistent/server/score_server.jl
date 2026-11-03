module FunSearchNewtonConsistentServer

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
const REFERENCE_PATH = normpath(joinpath(@__DIR__, "..", "..", "funsearch-newton", "reference", "plane_quintic_newton_polygons.tsv"))
const KNOWN_POLYGONS_PATH = normpath(joinpath(@__DIR__, "..", "..", "funsearch-newton", "reference", "known_plane_quintic_newton_polygons.tsv"))
const WARMUP_INSTANCE = "family=plane,d=5,p=7,k=1,curve_reward=log,lambda=0.25,beta=0.5,ss_codim=1"
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

# Novelty is judged against the Zenodo reference plus locally known polygons,
# both read once at load so the bonus stays fixed for a run.
const REFERENCE_POLYGONS = mergewith(
    union,
    _load_reference_table(REFERENCE_PATH),
    _load_reference_table(KNOWN_POLYGONS_PATH),
)

const MONOMIAL_INDEX = Dict(exponent => index for (index, exponent) in enumerate(MONOMIAL_EXPONENTS))
const VARIABLE_PERMUTATIONS = let maps = Vector{Int}[]
    for order in ((1, 2, 3), (1, 3, 2), (2, 1, 3), (2, 3, 1), (3, 1, 2), (3, 2, 1))
        push!(maps, [MONOMIAL_INDEX[(exponent[order[1]], exponent[order[2]], exponent[order[3]])]
                     for exponent in MONOMIAL_EXPONENTS])
    end
    maps
end

"""
Return the lexicographically least coefficient vector of the curve under the
six variable permutations and the rescalings x, y, z -> a x, b y, c z, with
the first nonzero coefficient scaled to one. Scaling all three variables by a
only multiplies the equation by a^5, so fixing a = 1 covers every rescaling.
"""
function _canonical_coefficients(p::Int, coefficients::Vector{Int})
    powers = [powermod(base, exponent, p) for base in 1:(p - 1), exponent in 0:5]
    best = Int[]
    permuted = similar(coefficients)
    candidate = similar(coefficients)
    for permutation in VARIABLE_PERMUTATIONS
        permuted[permutation] .= coefficients
        for b in 1:(p - 1), c in 1:(p - 1)
            for (index, (_, j, k)) in enumerate(MONOMIAL_EXPONENTS)
                candidate[index] = mod(widemul(permuted[index], powers[b, j + 1]) * powers[c, k + 1], p)
            end
            lead = invmod(candidate[findfirst(!iszero, candidate)], p)
            candidate .= mod.(widemul.(candidate, lead), p)
            if isempty(best) || candidate < best
                best = copy(candidate)
            end
        end
    end
    best
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

function _is_singular_plane_quintic(p::Int, coefficients::Vector{Int})
    field = Oscar.GF(p)
    ambient = Oscar.projective_space(field, [:x, :y, :z])
    ring = Oscar.homogeneous_coordinate_ring(ambient)
    variables = Oscar.gens(ring)
    polynomial = zero(ring)
    for (coefficient, exponents) in zip(coefficients, MONOMIAL_EXPONENTS)
        iszero(coefficient) && continue
        term = field(coefficient)
        for (variable, exponent) in zip(variables, exponents)
            term *= variable^exponent
        end
        polynomial += term
    end
    curve = Oscar.subscheme(ambient, polynomial)
    !Oscar.is_smooth(curve; algorithm=:affine_cone)
end

function _stable_hash52(value::AbstractString)
    state = UInt64(0xcbf29ce484222325)
    prime = UInt64(0x00000100000001b3)
    for byte in codeunits(value)
        state = (state ⊻ UInt64(byte)) * prime
    end
    state >> 12
end

_zeta_key(zeta::Vector{String}) = _stable_hash52(join(zeta, ','))

function _set_id(keys)
    ordered = sort!(unique!(UInt64[key for key in keys]))
    _stable_hash52(join(string.(ordered), ','))
end

const LOAD_TIME_SECONDS = (time_ns() - LOAD_STARTED_NS) / 1.0e9


struct InstanceConfig
    p::Int
    k::Int
    curve_reward::String
    lambda::Float64
    beta::Float64
    ss_codim::Int
end

function _parse_instance(instance)
    instance isa AbstractString || throw(ArgumentError("instance must be a string"))
    fields = Dict{String,String}()
    replacements = Dict("reward" => "curve_reward", "eps" => "none", "exclude_ss" => "ss_codim")
    for item in split(instance, ',')
        pair = split(strip(item), '='; limit=2)
        length(pair) == 2 || throw(ArgumentError("invalid instance field: $item"))
        key, value = strip.(pair)
        isempty(key) && throw(ArgumentError("instance field name is empty"))
        haskey(replacements, key) &&
            throw(ArgumentError("field $key is no longer supported; use $(replacements[key])"))
        key in ("family", "d", "p", "k", "curve_reward", "lambda", "beta", "ss_codim") ||
            throw(ArgumentError("unknown instance field: $key"))
        haskey(fields, key) && throw(ArgumentError("duplicate instance field: $key"))
        fields[key] = value
    end
    get(fields, "family", "plane") == "plane" || throw(ArgumentError("only family=plane is supported"))
    get(fields, "d", "5") == "5" || throw(ArgumentError("only degree d=5 is supported"))
    p = tryparse(Int, get(fields, "p", ""))
    p === nothing && throw(ArgumentError("instance p must be an integer"))
    p >= 2 && Oscar.is_prime(p) || throw(ArgumentError("instance p must be prime"))

    k = tryparse(Int, get(fields, "k", "16"))
    k !== nothing && 1 <= k <= 64 || throw(ArgumentError("k must be an integer from 1 through 64"))
    curve_reward = get(fields, "curve_reward", "log")
    curve_reward in ("log", "linear") || throw(ArgumentError("curve_reward must be log or linear"))
    lambda = tryparse(Float64, get(fields, "lambda", "0.25"))
    lambda !== nothing && isfinite(lambda) && lambda >= 0 ||
        throw(ArgumentError("lambda must be a finite nonnegative number"))
    beta = tryparse(Float64, get(fields, "beta", "0.5"))
    beta !== nothing && isfinite(beta) && beta >= 0 ||
        throw(ArgumentError("beta must be a finite nonnegative number"))
    ss_codim = tryparse(Int, get(fields, "ss_codim", "1"))
    ss_codim !== nothing && 0 <= ss_codim <= 12 ||
        throw(ArgumentError("ss_codim must be an integer from 0 through 12"))
    InstanceConfig(p, k, curve_reward, lambda, beta, ss_codim)
end

function _sample_result(
    k::Int,
    status::String,
    reason;
    coefficients=nothing,
    zeta=nothing,
    zeta_key=nothing,
    polygon=nothing,
    codim=nothing,
    supersingular=false,
    novel=false,
    canonical=nothing,
    duplicate_of=nothing,
    reward=0.0,
)
    (
        k=k,
        status=status,
        reason=reason,
        coefficients=coefficients,
        zeta=zeta,
        zeta_key=zeta_key,
        polygon=polygon,
        codim=codim,
        supersingular=supersingular,
        novel=novel,
        canonical=canonical,
        duplicate_of=duplicate_of,
        reward=Float64(reward),
    )
end

function _empty_signature()
    Float64[0.0, 0.0, 0.0, 0.0, Float64(_stable_hash52(""))]
end

function _invalid_batch_details(message, raw_samples=nothing; p=nothing)
    samples = raw_samples isa AbstractVector ? raw_samples : Any[]
    results = Any[
        _sample_result(
            index - 1,
            "INVALID",
            message;
            coefficients=samples[index] isa AbstractVector ? samples[index] : nothing,
        )
        for index in eachindex(samples)
    ]
    response = Dict{String,Any}(
        "status" => "INVALID",
        "score" => 0.0,
        "sig" => _empty_signature(),
        "msg" => message,
    )
    (response=response, p=p, samples=results, program_score=0.0, config=nothing)
end

function _sample_reward(codim::Int, supersingular::Bool, config::InstanceConfig)
    adjusted_codim = supersingular ? config.ss_codim : codim
    config.curve_reward == "log" ? log2(1 + adjusted_codim) : Float64(adjusted_codim)
end

function _score_sample(
    config::InstanceConfig,
    raw_coefficients,
    k::Int;
    curve_builder=_build_curve,
    zeta_builder=DeRham.zeta_coefficients,
    polygon_builder=DeRham.newton_polygon,
    reference_polygons=REFERENCE_POLYGONS,
)
    raw_coefficients isa AbstractVector ||
        return _sample_result(k, "INVALID", "sample coefficients must be an array of 21 integers")
    length(raw_coefficients) == length(MONOMIAL_EXPONENTS) ||
        return _sample_result(k, "INVALID", "sample must contain exactly 21 integers"; coefficients=raw_coefficients)
    all(value -> value isa Integer && !(value isa Bool), raw_coefficients) ||
        return _sample_result(k, "INVALID", "sample coefficients must contain only integers"; coefficients=raw_coefficients)
    coefficients = try
        Int[value for value in raw_coefficients]
    catch error
        return _sample_result(
            k,
            "INVALID",
            "sample coefficients must fit in Int: $(sprint(showerror, error))";
            coefficients=raw_coefficients,
        )
    end
    all(value -> 0 <= value < config.p, coefficients) ||
        return _sample_result(k, "INVALID", "sample coefficients must lie in 0:p-1"; coefficients=coefficients)
    any(!iszero, coefficients) ||
        return _sample_result(k, "INVALID", "the zero polynomial is invalid"; coefficients=coefficients)

    curve = try
        curve_builder(config.p, coefficients)
    catch error
        return _sample_result(
            k,
            "ERROR",
            "could not construct curve: $(sprint(showerror, error))";
            coefficients=coefficients,
        )
    end
    zeta = try
        zeta_builder(
            curve;
            S=[0, 1, 2],
            fastevaluation=true,
            algorithm=:depthfirst,
            use_gpu=false,
        )
    catch error
        singular = try
            _is_singular_plane_quintic(config.p, coefficients)
        catch smoothness_error
            return _sample_result(
                k,
                "ERROR",
                "DeRham zeta evaluation failed and singularity check failed: $(sprint(showerror, smoothness_error))";
                coefficients=coefficients,
            )
        end
        singular && return _sample_result(k, "INVALID", "curve is singular"; coefficients=coefficients)
        return _sample_result(
            k,
            "ERROR",
            "DeRham zeta evaluation failed for a smooth curve: $(sprint(showerror, error))";
            coefficients=coefficients,
        )
    end
    if zeta === false
        singular = try
            _is_singular_plane_quintic(config.p, coefficients)
        catch error
            return _sample_result(
                k,
                "ERROR",
                "DeRham returned no zeta function; singularity check failed: $(sprint(showerror, error))";
                coefficients=coefficients,
            )
        end
        singular && return _sample_result(k, "INVALID", "curve is singular"; coefficients=coefficients)
        return _sample_result(k, "ERROR", "DeRham returned no zeta function for a smooth curve"; coefficients=coefficients)
    end
    zeta_values = try
        String[string(value) for value in collect(zeta)]
    catch error
        return _sample_result(
            k,
            "ERROR",
            "could not serialize zeta coefficients: $(sprint(showerror, error))";
            coefficients=coefficients,
        )
    end
    polygon = try
        polygon_builder(config.p, zeta)
    catch error
        return _sample_result(
            k,
            "ERROR",
            "could not derive Newton polygon from zeta coefficients: $(sprint(showerror, error))";
            coefficients=coefficients,
            zeta=zeta_values,
        )
    end
    if polygon === false
        singular = try
            _is_singular_plane_quintic(config.p, coefficients)
        catch error
            return _sample_result(
                k,
                "ERROR",
                "polygon conversion failed; singularity check failed: $(sprint(showerror, error))";
                coefficients=coefficients,
                zeta=zeta_values,
            )
        end
        singular && return _sample_result(k, "INVALID", "curve is singular"; coefficients=coefficients, zeta=zeta_values)
        return _sample_result(k, "ERROR", "no Newton polygon was returned for a smooth curve"; coefficients=coefficients, zeta=zeta_values)
    end
    polygon = try
        polygon isa NewtonStrata.SlopeMultiplicityPolygon ? polygon : NewtonStrata.from_slopes_polygon(polygon)
    catch error
        return _sample_result(
            k,
            "ERROR",
            "invalid DeRham polygon: $(sprint(showerror, error))";
            coefficients=coefficients,
            zeta=zeta_values,
        )
    end
    codim = try
        NewtonStrata.codim(polygon)
    catch error
        return _sample_result(
            k,
            "ERROR",
            "could not compute Newton-stratum codimension: $(sprint(showerror, error))";
            coefficients=coefficients,
            zeta=zeta_values,
            polygon=polygon,
        )
    end
    supersingular = NewtonStrata.is_supersingular(polygon)
    polygon_key = _polygon_key(NewtonStrata.integer_values(polygon))
    novel = !(polygon_key in get(reference_polygons, config.p, Set{String}()))
    canonical = nothing
    if !NewtonStrata.is_ordinary(polygon)
        canonical = try
            _canonical_coefficients(config.p, coefficients)
        catch error
            return _sample_result(
                k,
                "ERROR",
                "could not retain canonical coefficients: $(sprint(showerror, error))";
                coefficients=coefficients,
                zeta=zeta_values,
                polygon=polygon,
                codim=codim,
                supersingular=supersingular,
                novel=novel,
            )
        end
    end
    _sample_result(
        k,
        "OK",
        nothing;
        coefficients=coefficients,
        zeta=zeta_values,
        zeta_key=_zeta_key(zeta_values),
        polygon=polygon,
        codim=codim,
        supersingular=supersingular,
        novel=novel,
        canonical=canonical,
        reward=_sample_reward(codim, supersingular, config),
    )
end

function _sample_token(sample, config::InstanceConfig)
    sample.status == "INVALID" && return "i"
    sample.status == "ERROR" && return "e"
    adjusted_codim = sample.supersingular ? config.ss_codim : sample.codim
    token = string(adjusted_codim)
    sample.supersingular && (token *= "ss")
    sample.duplicate_of !== nothing && (token *= "d")
    token
end

function _score_message(score::Float64, distinct::Int, k::Int, tokens)
    header = "S=$(string(round(score; sigdigits=6))) distinct=$distinct/$k"
    parts = String[header]
    for index in eachindex(tokens)
        candidate = join((parts..., tokens[index]), " ")
        if ncodeunits(candidate) <= 255
            push!(parts, tokens[index])
            continue
        end
        omitted = length(tokens) - index + 1
        marker = "+$omitted more"
        while ncodeunits(join((parts..., marker), " ")) > 255 && length(parts) > 1
            pop!(parts)
            omitted += 1
            marker = "+$omitted more"
        end
        push!(parts, marker)
        return join(parts, " ")
    end
    join(parts, " ")
end

function _coefficient_cache_key(raw_coefficients, p::Int)
    raw_coefficients isa AbstractVector || return nothing
    length(raw_coefficients) == length(MONOMIAL_EXPONENTS) || return nothing
    all(value -> value isa Integer && !(value isa Bool), raw_coefficients) || return nothing
    coefficients = try
        Int[value for value in raw_coefficients]
    catch
        return nothing
    end
    all(value -> 0 <= value < p, coefficients) || return nothing
    lead = findfirst(!iszero, coefficients)
    lead === nothing && return nothing
    normalizer = invmod(coefficients[lead], p)
    normalized = Int[mod(widemul(value, normalizer), p) for value in coefficients]
    Tuple(normalized)
end

function _copy_cached_sample(sample, k::Int; coefficients=sample.coefficients)
    merge(
        sample,
        (
            k=k,
            coefficients=coefficients === nothing ? nothing : copy(coefficients),
            zeta=sample.zeta === nothing ? nothing : copy(sample.zeta),
            canonical=sample.canonical === nothing ? nothing : copy(sample.canonical),
        ),
    )
end

function _score_details(
    instance,
    raw_samples;
    curve_builder=_build_curve,
    zeta_builder=DeRham.zeta_coefficients,
    polygon_builder=DeRham.newton_polygon,
    reference_polygons=REFERENCE_POLYGONS,
)
    raw_samples isa AbstractVector || return _invalid_batch_details("samples must be an array")
    config = try
        _parse_instance(instance)
    catch error
        return _invalid_batch_details(sprint(showerror, error), raw_samples)
    end
    length(raw_samples) == config.k ||
        return _invalid_batch_details(
            "expected $(config.k) samples, received $(length(raw_samples))",
            raw_samples;
            p=config.p,
        )

    sample_cache = Dict{Tuple,Any}()
    results = Any[]
    sizehint!(results, length(raw_samples))
    for index in eachindex(raw_samples)
        raw_coefficients = raw_samples[index]
        cache_key = _coefficient_cache_key(raw_coefficients, config.p)
        if cache_key !== nothing && haskey(sample_cache, cache_key)
            preserved_coefficients = Int[value for value in raw_coefficients]
            push!(results, _copy_cached_sample(
                sample_cache[cache_key],
                index - 1;
                coefficients=preserved_coefficients,
            ))
            continue
        end
        sample = _score_sample(
            config,
            raw_coefficients,
            index - 1;
            curve_builder=curve_builder,
            zeta_builder=zeta_builder,
            polygon_builder=polygon_builder,
            reference_polygons=reference_polygons,
        )
        push!(results, sample)
        cache_key !== nothing && sample.status == "OK" && (sample_cache[cache_key] = sample)
    end
    first_by_key = Dict{UInt64,Int}()
    distinct_keys = UInt64[]
    nonordinary_keys = Set{UInt64}()
    total_reward = 0.0
    maximum_reward = 0.0
    any_novel = false
    for index in eachindex(results)
        sample = results[index]
        sample.status == "OK" || continue
        any_novel |= sample.novel
        key = sample.zeta_key::UInt64
        if haskey(first_by_key, key)
            results[index] = merge(sample, (duplicate_of=first_by_key[key], reward=0.0))
            continue
        end
        first_by_key[key] = sample.k
        push!(distinct_keys, key)
        total_reward += sample.reward
        maximum_reward = max(maximum_reward, sample.reward)
        !NewtonStrata.is_ordinary(sample.polygon) && push!(nonordinary_keys, key)
    end

    ok_count = count(sample -> sample.status == "OK", results)
    has_error = any(sample -> sample.status == "ERROR", results)
    status = has_error ? "ERROR" : ok_count == 0 ? "INVALID" : "OK"
    mean_term = total_reward / config.k
    program_score = status == "OK" ?
        mean_term + config.lambda * maximum_reward + config.beta * Int(any_novel) :
        0.0
    isfinite(program_score) || (status = "ERROR"; program_score = 0.0)
    signature = Float64[
        mean_term,
        maximum_reward,
        length(distinct_keys) / config.k,
        length(nonordinary_keys) / config.k,
        Float64(_set_id(distinct_keys)),
    ]
    tokens = [_sample_token(sample, config) for sample in results]
    message = _score_message(program_score, length(distinct_keys), config.k, tokens)
    response = Dict{String,Any}(
        "status" => status,
        "score" => program_score,
        "sig" => signature,
        "msg" => message,
    )
    (response=response, p=config.p, samples=results, program_score=program_score, config=config)
end

function score_instance(instance, samples)
    _score_details(instance, samples).response
end

const BATCH_COUNTER = Threads.Atomic{UInt64}(0)

function _new_batch_id()
    sequence = Threads.atomic_add!(BATCH_COUNTER, UInt64(1))
    string(getpid(), "-", time_ns(), "-", sequence)
end

function _retention_record(details, sample, request, elapsed_seconds, batch_id, timestamp)
    polygon = sample.polygon
    Dict{String,Any}(
        "program_id" => get(request, "program_id", nothing),
        "p" => details.p,
        "k" => sample.k,
        "coeffs" => sample.coefficients,
        "canonical_coeffs" => sample.canonical,
        "instance" => get(request, "instance", nothing),
        "status" => sample.status,
        "reason" => sample.reason,
        "slopes" => polygon === nothing ? nothing : _format_ratio.(polygon.slopes),
        "lengths" => polygon === nothing ? nothing : polygon.slopelengths,
        "polygon_values" => polygon === nothing ? nothing : _format_ratio.(NewtonStrata.integer_values(polygon)),
        "codim" => sample.codim,
        "novel" => sample.status == "OK" ? sample.novel : nothing,
        "reward" => sample.reward,
        "sample_reward" => sample.reward,
        "program_score" => details.program_score,
        "zeta" => sample.zeta,
        "zeta_key" => sample.zeta_key === nothing ? nothing : Float64(sample.zeta_key),
        "duplicate_of" => sample.duplicate_of,
        "batch_id" => batch_id,
        "wall_time_seconds" => elapsed_seconds,
        "timestamp" => timestamp,
    )
end

function _append_records(path::AbstractString, records)
    isempty(records) && return nothing
    mkpath(dirname(abspath(path)))
    open(path, "a") do output
        descriptor = Base.fd(output)
        ccall(:flock, Cint, (Cint, Cint), descriptor, Cint(2)) == 0 ||
            throw(ErrorException("could not lock curve retention file"))
        try
            for record in records
                write(output, JSON.json(record))
                write(output, '\n')
            end
            flush(output)
        finally
            ccall(:flock, Cint, (Cint, Cint), descriptor, Cint(8))
        end
    end
    nothing
end

function _request_response(request, curves_path::AbstractString; kwargs...)
    request isa AbstractDict || return Dict{String,Any}(
        "status" => "ERROR", "score" => 0.0, "sig" => _empty_signature(), "msg" => "request must be a JSON object",
    )
    started_ns = time_ns()
    details = _score_details(
        get(request, "instance", nothing),
        get(request, "samples", nothing);
        kwargs...,
    )
    elapsed_seconds = (time_ns() - started_ns) / 1.0e9
    batch_id = _new_batch_id()
    timestamp = string(Dates.now(Dates.UTC), "Z")
    records = [
        _retention_record(details, sample, request, elapsed_seconds, batch_id, timestamp)
        for sample in details.samples
    ]
    try
        _append_records(curves_path, records)
    catch error
        return Dict{String,Any}(
            "status" => "ERROR",
            "score" => 0.0,
            "sig" => _empty_signature(),
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
        "reference_tables" => [REFERENCE_PATH, KNOWN_POLYGONS_PATH],
        "peak_rss_bytes" => Int(Sys.maxrss()),
        "sysimage" => get(ENV, "KAIMON_CITY_SYSIMAGE", "off"),
        "julia_image_file" => unsafe_string(Base.JLOptions().image_file),
        "julia_version" => string(VERSION),
        "thread_count" => Threads.nthreads(),
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
    warmup_response = score_instance(WARMUP_INSTANCE, [FERMAT_COEFFICIENTS])
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
    FunSearchNewtonConsistentServer.main()
end
