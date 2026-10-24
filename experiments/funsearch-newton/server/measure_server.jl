include("score_server.jl")

using .FunSearchNewtonServer
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

function _measure(samples)
    samples >= 20 || throw(ArgumentError("at least 20 smooth curves are required"))
    Random.seed!(20261024)
    warmup_started_ns = time_ns()
    warmup = FunSearchNewtonServer.score_instance(
        FunSearchNewtonServer.WARMUP_INSTANCE,
        FunSearchNewtonServer.FERMAT_COEFFICIENTS,
    )
    warmup_seconds = (time_ns() - warmup_started_ns) / 1.0e9
    warmup["status"] == "OK" || throw(ErrorException("warm-up failed: $(warmup["msg"])"))

    instance = "family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true"
    elapsed = Float64[]
    attempts = 0
    last_reported = 0
    while length(elapsed) < samples && attempts < 500
        _kaimon_cancelled() && throw(InterruptException())
        attempts += 1
        coefficients = rand(0:6, 21)
        started_ns = time_ns()
        response = FunSearchNewtonServer.score_instance(instance, coefficients)
        seconds = (time_ns() - started_ns) / 1.0e9
        response["status"] == "OK" && push!(elapsed, seconds)
        if length(elapsed) >= last_reported + 5
            last_reported = length(elapsed)
            _kaimon_progress("measured $last_reported/$samples smooth p=7 curves")
        end
    end
    length(elapsed) == samples || throw(ErrorException("only $(length(elapsed)) smooth curves found in $attempts attempts"))

    source_path = pathof(DeRham)
    source_root = dirname(dirname(source_path))
    commit = strip(read(`git -C $source_root rev-parse HEAD`, String))
    Dict{String,Any}(
        "julia_version" => string(VERSION),
        "sysimage" => get(ENV, "KAIMON_CITY_SYSIMAGE", "off"),
        "julia_image_file" => unsafe_string(Base.JLOptions().image_file),
        "load_time_seconds" => FunSearchNewtonServer.LOAD_TIME_SECONDS,
        "warmup_first_call_seconds" => warmup_seconds,
        "steady_p7_samples" => samples,
        "steady_p7_attempts" => attempts,
        "steady_p7_median_seconds" => _median(elapsed),
        "steady_p7_seconds" => elapsed,
        "peak_rss_bytes" => Int(Sys.maxrss()),
        "DeRham_path" => source_path,
        "DeRham_commit" => commit,
        "precision_provenance" => FunSearchNewtonServer._precision_provenance(),
    )
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    samples = isempty(ARGS) ? 20 : parse(Int, ARGS[1])
    println(JSON.json(_measure(samples)))
end
