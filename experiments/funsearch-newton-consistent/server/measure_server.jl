if !isdefined(@__MODULE__, :FunSearchNewtonConsistentServer)
    include("score_server.jl")
end

module FunSearchNewtonConsistentMeasureServer

using ..FunSearchNewtonConsistentServer
using DeRham
using JSON
using Random

function _median(values)
    ordered = sort(values)
    middle = length(ordered) ÷ 2
    isodd(length(ordered)) ? ordered[middle + 1] : (ordered[middle] + ordered[middle + 1]) / 2
end

function _kaimon_cancelled()
    isdefined(Main, :KaimonGate) || return false
    gate = getfield(Main, :KaimonGate)
    isdefined(gate, :is_cancelled) && gate.is_cancelled()
end

function _kaimon_progress(message)
    isdefined(Main, :KaimonGate) || return nothing
    gate = getfield(Main, :KaimonGate)
    isdefined(gate, :progress) && gate.progress(message)
    nothing
end

function _record_measurement_sample!(elapsed, response, seconds)
    status = get(response, "status", nothing)
    if status == "OK"
        push!(elapsed, seconds)
        return true
    elseif status == "INVALID"
        return false
    elseif status == "ERROR"
        message = get(response, "msg", "unknown evaluation error")
        throw(ErrorException("evaluation failed during measurement: $message"))
    end
    throw(ErrorException("unexpected score response status during measurement: $(repr(status))"))
end

function _percentile(values, fraction)
    ordered = sort(values)
    ordered[clamp(ceil(Int, fraction * length(ordered)), 1, length(ordered))]
end

function _measure(p, batches)
    p in (7, 11, 13) || throw(ArgumentError("p must be one of 7, 11, or 13"))
    batches >= 10 || throw(ArgumentError("at least 10 batches are required for p90"))
    rng = MersenneTwister(20261103 + p)
    warmup_started_ns = time_ns()
    warmup_instance = "family=plane,d=5,p=$p,k=1,curve_reward=log,lambda=0.25,beta=0.5,ss_codim=1"
    warmup = FunSearchNewtonConsistentServer.score_instance(
        warmup_instance,
        [FunSearchNewtonConsistentServer.FERMAT_COEFFICIENTS],
    )
    warmup_seconds = (time_ns() - warmup_started_ns) / 1.0e9
    warmup["status"] == "OK" || throw(ErrorException("warm-up failed: $(warmup["msg"])"))

    instance = "family=plane,d=5,p=$p,k=16,curve_reward=log,beta=0.5,lambda=0.25,ss_codim=1"
    elapsed = Float64[]
    attempts = 0
    while length(elapsed) < batches && attempts < batches * 10
        _kaimon_cancelled() && throw(InterruptException())
        attempts += 1
        samples = [rand(rng, 0:(p - 1), 21) for _ in 1:16]
        started_ns = time_ns()
        response = FunSearchNewtonConsistentServer.score_instance(instance, samples)
        seconds = (time_ns() - started_ns) / 1.0e9
        _record_measurement_sample!(elapsed, response, seconds)
        _kaimon_progress("measured $(length(elapsed))/$batches p=$p K=16 batches with $(Threads.nthreads()) threads")
    end
    length(elapsed) == batches || throw(ErrorException("only $(length(elapsed)) valid batches found in $attempts attempts"))

    source_path = pathof(DeRham)
    source_root = dirname(dirname(source_path))
    commit = strip(read(`git -C $source_root rev-parse HEAD`, String))
    Dict{String,Any}(
        "julia_version" => string(VERSION),
        "sysimage" => get(ENV, "KAIMON_CITY_SYSIMAGE", "off"),
        "julia_image_file" => unsafe_string(Base.JLOptions().image_file),
        "load_time_seconds" => FunSearchNewtonConsistentServer.LOAD_TIME_SECONDS,
        "warmup_first_call_seconds" => warmup_seconds,
        "p" => p,
        "thread_count" => Threads.nthreads(),
        "batch_k" => 16,
        "measured_batches" => batches,
        "attempts" => attempts,
        "batch_latency_min_seconds" => minimum(elapsed),
        "batch_latency_median_seconds" => _median(elapsed),
        "batch_latency_p90_seconds" => _percentile(elapsed, 0.9),
        "batch_latency_max_seconds" => maximum(elapsed),
        "batch_latency_seconds" => elapsed,
        "peak_rss_bytes" => Int(Sys.maxrss()),
        "DeRham_path" => source_path,
        "DeRham_commit" => commit,
        "precision_provenance" => FunSearchNewtonConsistentServer._precision_provenance(),
    )
end

function main(args=ARGS)
    p_argument = isempty(args) ? "all" : args[1]
    batches = length(args) < 2 ? 10 : parse(Int, args[2])
    if p_argument == "all"
        println(JSON.json([_measure(p, batches) for p in (7, 11, 13)]))
    else
        println(JSON.json(_measure(parse(Int, p_argument), batches)))
    end
end

end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    FunSearchNewtonConsistentMeasureServer.main()
end
