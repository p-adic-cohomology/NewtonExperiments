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

function _canonical_json(value)
    if value isa AbstractDict
        keys_sorted = sort!(collect(keys(value)); by=string)
        return "{" * join(
            (JSON.json(string(key)) * ":" * _canonical_json(value[key]) for key in keys_sorted),
            ",",
        ) * "}"
    elseif value isa AbstractVector || value isa Tuple
        return "[" * join((_canonical_json(item) for item in value), ",") * "]"
    end
    JSON.json(value)
end

_request_cache_key(instance, samples, program_id=nothing) =
    string(_stable_hash52(_canonical_json((instance, program_id, samples))); base=16)

_default_near_dup_index_path(curves_path::AbstractString) =
    normpath(joinpath(dirname(String(curves_path)), "near-dup-index.jsonl"))

function _near_dup_cache_path(index_path::AbstractString)
    path = String(index_path)
    stem, extension = splitext(path)
    extension == ".jsonl" ? stem * ".cache.jsonl" : path * ".cache.jsonl"
end

const LOAD_TIME_SECONDS = (time_ns() - LOAD_STARTED_NS) / 1.0e9


struct InstanceConfig
    p::Int
    k::Int
    curve_reward::String
    lambda::Float64
    beta::Float64
    ss_codim::Int
    near_dup::Float64
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
        key in ("family", "d", "p", "k", "curve_reward", "lambda", "beta", "ss_codim", "near_dup") ||
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
    near_dup = tryparse(Float64, get(fields, "near_dup", "0"))
    near_dup !== nothing && isfinite(near_dup) && 0 <= near_dup <= 1 ||
        throw(ArgumentError("near_dup must be a finite number from 0 through 1"))
    InstanceConfig(p, k, curve_reward, lambda, beta, ss_codim, near_dup)
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

function _message_with_tokens(header::String, tokens)
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

function _score_message(score::Float64, distinct::Int, k::Int, tokens)
    header = "S=$(string(round(score; sigdigits=6))) distinct=$distinct/$k"
    _message_with_tokens(header, tokens)
end

function _near_duplicate_message(overlap_count::Int, total::Int, score::Float64, tokens)
    earlier_score = string(round(score; digits=4))
    header = "near-dup: $overlap_count/$total classes in an earlier program (S=$earlier_score); find new classes or score higher"
    _message_with_tokens(header, tokens)
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

function _instance_key(config::InstanceConfig)
    join((
        "family=plane",
        "d=5",
        "p=$(config.p)",
        "k=$(config.k)",
        "curve_reward=$(config.curve_reward)",
        "lambda=$(config.lambda)",
        "beta=$(config.beta)",
        "ss_codim=$(config.ss_codim)",
        "near_dup=$(config.near_dup)",
    ), ',')
end

function _nonordinary_keys(details)
    sort!(unique!(String[
        string(sample.zeta_key)
        for sample in details.samples
        if sample.status == "OK" && !NewtonStrata.is_ordinary(sample.polygon)
    ]))
end

const NEAR_DUP_CACHE_MAX_ENTRIES = 4096

mutable struct NearDuplicateStore
    path::String
    cache_path::String
    lock_path::String
    records::Vector{Dict{String,Any}}
    cache::Dict{String,Dict{String,Any}}
    cache_order::Vector{String}
    cache_head::Int
    cache_capacity::Int
    cache_file_records::Int
    by_instance_key::Dict{Tuple{String,String},Vector{Dict{String,Any}}}
    best_by_instance_key::Dict{Tuple{String,String},Dict{String,Any}}
    record_positions::IdDict{Dict{String,Any},Int}
    index_offset::Int64
    cache_offset::Int64
    cache_file_identity::Union{Nothing,Tuple{UInt64,UInt64}}
    lock::ReentrantLock
end

function _near_dup_cache_file_identity(path::AbstractString)
    isfile(path) || return nothing
    metadata = stat(path)
    (UInt64(metadata.device), UInt64(metadata.inode))
end

function _read_jsonl_records_from(path::AbstractString, offset::Int64)
    if !isfile(path)
        return Dict{String,Any}[], Int64(0), offset > 0
    end
    reset = filesize(path) < offset
    start_offset = reset ? Int64(0) : offset
    records = Dict{String,Any}[]
    final_offset = start_offset
    open(path, "r") do input
        seek(input, start_offset)
        for (line_number, line) in enumerate(eachline(input))
            isempty(strip(line)) && continue
            parsed = JSON.parse(line)
            parsed isa AbstractDict || throw(ArgumentError("JSONL record $line_number in $path is not an object"))
            push!(records, Dict{String,Any}(string(key) => value for (key, value) in parsed))
        end
        final_offset = Int64(position(input))
    end
    records, final_offset, reset
end

function _index_store_record!(store::NearDuplicateStore, record::Dict{String,Any})
    store.record_positions[record] = length(store.records)
    instance = string(get(record, "instance", ""))
    seen = Set{String}()
    for raw_key in get(record, "nonordinary_keys", Any[])
        key = string(raw_key)
        key in seen && continue
        push!(seen, key)
        posting = get!(store.by_instance_key, (instance, key)) do
            Dict{String,Any}[]
        end
        push!(posting, record)
        best = get(store.best_by_instance_key, (instance, key), nothing)
        score = Float64(get(record, "score", Inf))
        if best === nothing || score > Float64(get(best, "score", Inf))
            store.best_by_instance_key[(instance, key)] = record
        end
    end
    nothing
end

function _cache_store_record!(store::NearDuplicateStore, record::Dict{String,Any})
    cache_key = string(get(record, "cache_key", ""))
    isempty(cache_key) && return
    if haskey(store.cache, cache_key)
        store.cache[cache_key] = record
        return
    end

    store.cache[cache_key] = record
    push!(store.cache_order, cache_key)
    while length(store.cache_order) - store.cache_head + 1 > store.cache_capacity
        evicted = store.cache_order[store.cache_head]
        delete!(store.cache, evicted)
        store.cache_head += 1
    end
    if store.cache_head > store.cache_capacity && store.cache_head > length(store.cache_order) ÷ 2
        deleteat!(store.cache_order, 1:(store.cache_head - 1))
        store.cache_head = 1
    end
    nothing
end

function _compact_near_dup_cache!(store::NearDuplicateStore)
    retained_keys = String[]
    for index in store.cache_head:length(store.cache_order)
        cache_key = store.cache_order[index]
        haskey(store.cache, cache_key) && push!(retained_keys, cache_key)
    end

    temporary_path, temporary_io = mktemp(dirname(store.cache_path))
    try
        for cache_key in retained_keys
            println(temporary_io, JSON.json(store.cache[cache_key]))
        end
        flush(temporary_io)
        close(temporary_io)
        mv(temporary_path, store.cache_path; force=true)
        store.cache_order = retained_keys
        store.cache_head = 1
        store.cache_file_records = length(retained_keys)
        store.cache_offset = Int64(filesize(store.cache_path))
        store.cache_file_identity = _near_dup_cache_file_identity(store.cache_path)
    catch
        isopen(temporary_io) && close(temporary_io)
        isfile(temporary_path) && rm(temporary_path; force=true)
        rethrow()
    end
    nothing
end

function _refresh_store!(store::NearDuplicateStore)
    cache_file_identity = _near_dup_cache_file_identity(store.cache_path)
    cache_file_replaced = cache_file_identity != store.cache_file_identity
    cache_records, cache_offset, cache_reset =
        _read_jsonl_records_from(
            store.cache_path,
            cache_file_replaced ? Int64(0) : store.cache_offset,
        )
    cache_reset |= cache_file_replaced
    index_records, index_offset, index_reset =
        _read_jsonl_records_from(store.path, store.index_offset)
    if index_reset && !cache_reset
        cache_records, cache_offset, _ =
            _read_jsonl_records_from(store.cache_path, Int64(0))
        cache_reset = true
    end

    if cache_reset
        empty!(store.cache)
        empty!(store.cache_order)
        store.cache_head = 1
        store.cache_file_records = 0
    end
    if index_reset
        empty!(store.records)
        empty!(store.by_instance_key)
        empty!(store.best_by_instance_key)
        empty!(store.record_positions)
    end

    for record in cache_records
        _cache_store_record!(store, record)
    end
    store.cache_file_records += length(cache_records)
    for record in index_records
        push!(store.records, record)
        _index_store_record!(store, record)
    end
    store.cache_offset = cache_offset
    store.cache_file_identity = cache_file_identity
    store.index_offset = index_offset

    if store.cache_file_records > 2 * store.cache_capacity
        _compact_near_dup_cache!(store)
    end
    store
end

function _with_store_lock(action::Function, store::NearDuplicateStore)
    lock(store.lock) do
        open(store.lock_path, "a") do lock_file
            descriptor = Base.fd(lock_file)
            ccall(:flock, Cint, (Cint, Cint), descriptor, Cint(2)) == 0 ||
                throw(ErrorException("could not lock near-duplicate index"))
            try
                _refresh_store!(store)
                action()
            finally
                ccall(:flock, Cint, (Cint, Cint), descriptor, Cint(8))
            end
        end
    end
end

function NearDuplicateStore(
    index_path::AbstractString;
    cache_capacity::Integer=NEAR_DUP_CACHE_MAX_ENTRIES,
)
    cache_capacity > 0 || throw(ArgumentError("cache_capacity must be positive"))
    path = abspath(index_path)
    mkpath(dirname(path))
    cache_path = _near_dup_cache_path(path)
    store = NearDuplicateStore(
        path,
        cache_path,
        path * ".lock",
        Dict{String,Any}[],
        Dict{String,Dict{String,Any}}(),
        String[],
        1,
        Int(cache_capacity),
        0,
        Dict{Tuple{String,String},Vector{Dict{String,Any}}}(),
        Dict{Tuple{String,String},Dict{String,Any}}(),
        IdDict{Dict{String,Any},Int}(),
        Int64(0),
        Int64(0),
        nothing,
        ReentrantLock(),
    )
    _with_store_lock(store) do
        nothing
    end
    store
end

function _truncate_file(path::AbstractString, offset::Int64)
    open(path, "a+") do output
        truncate(output, offset)
        flush(output)
    end
    nothing
end

function _near_duplicate_search_keys(
    store::NearDuplicateStore,
    instance::String,
    candidate_keys::Vector{String},
    minimum_overlap::Int,
    minimum_score::Float64,
)
    minimum_overlap > 0 || return String[]
    active_keys = String[]
    for key in candidate_keys
        best = get(store.best_by_instance_key, (instance, key), nothing)
        best === nothing && continue
        minimum_score <= Float64(get(best, "score", Inf)) + 1.0e-9 || continue
        push!(active_keys, key)
    end
    length(active_keys) >= minimum_overlap || return String[]

    # Any record meeting the overlap threshold must contain at least one of
    # these N - minimum_overlap + 1 least common keys.
    if minimum_overlap > 1
        sort!(active_keys; by=key -> (length(get(store.by_instance_key, (instance, key), Dict{String,Any}[])), key))
        resize!(active_keys, length(active_keys) - minimum_overlap + 1)
    end
    active_keys
end

function _find_near_duplicate(details, store::NearDuplicateStore)
    config = details.config
    config === nothing && return nothing
    get(details.response, "status", nothing) == "OK" || return nothing
    config.near_dup > 0 || return nothing
    candidate_keys = _nonordinary_keys(details)
    isempty(candidate_keys) && return nothing
    instance = _instance_key(config)
    minimum_overlap = findfirst(
        count -> count / length(candidate_keys) >= config.near_dup,
        1:length(candidate_keys),
    )
    minimum_overlap === nothing && return nothing
    search_keys = _near_duplicate_search_keys(
        store,
        instance,
        candidate_keys,
        minimum_overlap,
        details.program_score,
    )
    isempty(search_keys) && return nothing

    candidate_records = IdDict{Dict{String,Any},Nothing}()
    if minimum_overlap == 1
        for key in search_keys
            record = get(store.best_by_instance_key, (instance, key), nothing)
            record === nothing || (candidate_records[record] = nothing)
        end
    else
        for key in search_keys
            for record in get(store.by_instance_key, (instance, key), Dict{String,Any}[])
                previous_score = Float64(get(record, "score", Inf))
                details.program_score <= previous_score + 1.0e-9 || continue
                candidate_records[record] = nothing
            end
        end
    end

    best = nothing
    best_position = typemax(Int)
    for record in keys(candidate_records)
        previous_score = Float64(get(record, "score", Inf))
        details.program_score <= previous_score + 1.0e-9 || continue
        record_keys = Set(string.(get(record, "nonordinary_keys", Any[])))
        overlap_count = count(key -> key in record_keys, candidate_keys)
        overlap = overlap_count / length(candidate_keys)
        overlap >= config.near_dup || continue
        previous_score = Float64(get(record, "score", Inf))
        details.program_score <= previous_score + 1.0e-9 || continue
        position = get(store.record_positions, record, typemax(Int))
        if best === nothing || overlap > best.overlap || (overlap == best.overlap && position < best_position)
            best = (
                record=record,
                overlap_count=overlap_count,
                total=length(candidate_keys),
                overlap=overlap,
                score=previous_score,
            )
            best_position = position
        end
    end
    best
end

function _near_duplicate_response(details, match)
    config = details.config::InstanceConfig
    tokens = [_sample_token(sample, config) for sample in details.samples]
    Dict{String,Any}(
        "status" => "INVALID",
        "score" => 0.0,
        "sig" => _empty_signature(),
        "msg" => _near_duplicate_message(match.overlap_count, match.total, match.score, tokens),
    )
end

const BATCH_COUNTER = Threads.Atomic{UInt64}(0)

function _new_batch_id()
    sequence = Threads.atomic_add!(BATCH_COUNTER, UInt64(1))
    string(getpid(), "-", time_ns(), "-", sequence)
end

function _retention_record(
    details,
    sample,
    request,
    elapsed_seconds,
    batch_id,
    timestamp;
    program_status=details.response["status"],
    near_duplicate_of=nothing,
    near_dup_overlap=nothing,
)
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
        "near_duplicate_of" => near_duplicate_of,
        "near_dup_overlap" => near_dup_overlap,
        "program_status" => program_status,
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

function _request_response(
    request,
    curves_path::AbstractString;
    near_dup_index_path=nothing,
    near_dup_store=nothing,
    kwargs...,
)
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
    cache_instance = details.config === nothing ? get(request, "instance", nothing) : _instance_key(details.config)
    cache_key = _request_cache_key(
        cache_instance,
        get(request, "samples", nothing),
        get(request, "program_id", nothing),
    )
    index_path = near_dup_index_path === nothing ? _default_near_dup_index_path(curves_path) : String(near_dup_index_path)
    store = near_dup_store === nothing ? NearDuplicateStore(index_path) : near_dup_store
    batch_id = _new_batch_id()
    timestamp = string(Dates.now(Dates.UTC), "Z")
    _with_store_lock(store) do
        cached = get(store.cache, cache_key, nothing)
        if cached !== nothing
            cached_response = Dict{String,Any}(
                string(key) => value for (key, value) in cached["response"]
            )
            records = [
                _retention_record(
                    details,
                    sample,
                    request,
                    elapsed_seconds,
                    batch_id,
                    timestamp;
                    program_status=get(cached, "program_status", cached_response["status"]),
                    near_duplicate_of=get(cached, "near_duplicate_of", nothing),
                    near_dup_overlap=get(cached, "near_dup_overlap", nothing),
                )
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
            return cached_response
        end

        match = _find_near_duplicate(details, store)
        response = match === nothing ? details.response : _near_duplicate_response(details, match)
        program_status = response["status"]
        near_duplicate_of = match === nothing ? nothing : string(get(match.record, "batch_id", ""))
        near_dup_overlap = match === nothing ? nothing : match.overlap
        records = [
            _retention_record(
                details,
                sample,
                request,
                elapsed_seconds,
                batch_id,
                timestamp;
                program_status=program_status,
                near_duplicate_of=near_duplicate_of,
                near_dup_overlap=near_dup_overlap,
            )
            for sample in details.samples
        ]
        cache_record = Dict{String,Any}(
            "cache_key" => cache_key,
            "response" => response,
            "program_status" => program_status,
            "near_duplicate_of" => near_duplicate_of,
            "near_dup_overlap" => near_dup_overlap,
        )
        index_record = if details.response["status"] == "OK" &&
                           match === nothing &&
                           details.config !== nothing &&
                           details.config.near_dup > 0
            Dict{String,Any}(
                "batch_id" => batch_id,
                "instance" => _instance_key(details.config),
                "nonordinary_keys" => _nonordinary_keys(details),
                "score" => details.program_score,
                "timestamp" => timestamp,
            )
        else
            nothing
        end
        old_index_offset = store.index_offset
        old_cache_offset = store.cache_offset
        try
            if index_record !== nothing
                _append_records(store.path, [index_record])
            end
            _append_records(store.cache_path, [cache_record])
        catch error
            try
                _truncate_file(store.path, old_index_offset)
                _truncate_file(store.cache_path, old_cache_offset)
            catch
            end
            return Dict{String,Any}(
                "status" => "ERROR",
                "score" => 0.0,
                "sig" => _empty_signature(),
                "msg" => "near-duplicate index persistence failed: $(sprint(showerror, error))",
            )
        end
        try
            _append_records(curves_path, records)
        catch error
            try
                _truncate_file(store.path, old_index_offset)
                _truncate_file(store.cache_path, old_cache_offset)
            catch
            end
            return Dict{String,Any}(
                "status" => "ERROR",
                "score" => 0.0,
                "sig" => _empty_signature(),
                "msg" => "curve retention failed: $(sprint(showerror, error))",
            )
        end
        if index_record !== nothing
            push!(store.records, index_record)
            _index_store_record!(store, index_record)
            store.index_offset = Int64(filesize(store.path))
        end
        store.cache_offset = Int64(filesize(store.cache_path))
        store.cache_file_identity = _near_dup_cache_file_identity(store.cache_path)
        store.cache_file_records += 1
        _cache_store_record!(store, cache_record)
        if store.cache_file_records > 2 * store.cache_capacity
            _compact_near_dup_cache!(store)
        end
        response
    end
end

function _response_for_line(line::AbstractString, curves_path::AbstractString; near_dup_store=nothing)
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
    _request_response(request, curves_path; near_dup_store=near_dup_store)
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

function _process_loop(request_queue, curves_path, near_dup_store)
    for pending in request_queue
        response = try
            _response_for_line(pending.line, curves_path; near_dup_store=near_dup_store)
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
    near_dup_index_path::AbstractString=_default_near_dup_index_path(curves_path),
)
    for path in (socket_path, ready_path)
        isempty(path) && throw(ArgumentError("socket and ready paths must be nonempty"))
    end
    ispath(socket_path) && throw(ArgumentError("socket path already exists: $socket_path"))
    rm(ready_path; force=true)
    near_dup_store = NearDuplicateStore(near_dup_index_path)
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
        process_task = @async _process_loop(request_queue, curves_path, near_dup_store)
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

start_server(
    socket_path::AbstractString,
    ready_path::AbstractString,
    curves_path::AbstractString;
    near_dup_index_path::AbstractString=_default_near_dup_index_path(curves_path),
) = _start_server(socket_path, ready_path, curves_path, _write_ready_file, near_dup_index_path)

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
        "near-dup-index" => get(ENV, "FUNSEARCH_NEWTON_NEAR_DUP_INDEX", ""),
    )
    index = 1
    while index <= length(args)
        name = replace(args[index], r"^--" => "")
        haskey(options, name) || throw(ArgumentError("unknown server option: $(args[index])"))
        index < length(args) || throw(ArgumentError("missing value for --$name"))
        options[name] = args[index + 1]
        index += 2
    end
    all(!isempty, (options["socket"], options["ready-file"], options["curves"])) ||
        throw(ArgumentError("provide --socket, --ready-file, and --curves (or their FUNSEARCH_NEWTON_* environment variables)"))
    isempty(options["near-dup-index"]) &&
        (options["near-dup-index"] = _default_near_dup_index_path(options["curves"]))
    options
end

function main(args=ARGS)
    options = _server_arguments(args)
    server = start_server(
        options["socket"],
        options["ready-file"],
        options["curves"];
        near_dup_index_path=options["near-dup-index"],
    )
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
