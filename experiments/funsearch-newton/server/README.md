# Resident score server

`score_server.jl` loads DeRham, Oscar, the NewtonStrata module, and the plane-quintic reference table once. It scores line-delimited JSON requests over a Unix domain socket and serializes all evaluations through one queue. Keep one server process per run; it is the only writer to that run's `curves.jsonl`.

The request object has `p`, `coeffs`, `instance`, and optional `program_id` fields. The response object has `status`, `score`, `sig`, and `msg`. A valid curve returns `status: "OK"`; a malformed instance or coefficient vector, or a singular curve, returns `status: "INVALID"`. Unexpected DeRham or retention failures return `status: "ERROR"`.

For a degree-five curve, coefficients are ordered by the exponent vectors returned by `DeRham.gen_exp_vec(3, 5, :lex)` in DeRham 59b331b. With variables `(x, y, z)`, this begins `z^5, yz^4, y^2z^3, …, y^5, xz^4, xyz^3, …, x^5`. The server pins this order as increasing `x` exponent, then increasing `y` exponent; `z` has the remaining degree. Fermat's curve has nonzero coefficients at indices 1, 6, and 21.

Launch from the NewtonExperiments project directory:

```sh
julia --project=. experiments/funsearch-newton/server/score_server.jl \
  --socket /tmp/funsearch-newton.sock \
  --ready-file /tmp/funsearch-newton.ready \
  --curves experiments/funsearch-newton/runs/<run-id>/curves.jsonl
```

The same paths can be supplied through `FUNSEARCH_NEWTON_SOCKET`, `FUNSEARCH_NEWTON_READY`, and `FUNSEARCH_NEWTON_CURVES`. The ready file is written after imports, reference loading, the Fermat p=7 warm-up score, and precision provenance capture. It records load time, first-call latency, DeRham source path and commit, the p=7 precision path and `r_m`/`N_m`/`M`, selected sysimage, and peak RSS.

Every request, including invalid and singular curves, is appended and flushed as one JSON line. Existing `curves.jsonl` content is preserved. Each row records the program id when supplied, instance, prime, coefficients, status, slopes, lengths, polygon values, codimension, novelty, reward, elapsed scoring time, and UTC timestamp.

DeRham 59b331b's non-smooth basis path contains an undefined `verbose` reference where it intends to return `false`. The server maps that specific `UndefVarError` to `INVALID`, matching DeRham's documented non-smooth result; other evaluation exceptions remain `ERROR`.

Run `measure_server.jl` with an optional sample count (minimum 20) to record cold module load, Fermat warm-up latency, median scoring time over random smooth quintics at p=7, peak RSS, and DeRham precision provenance. The script skips singular random samples and does not write to a run's curve log.

For a linked worktree, run `include("scripts/setup_deps.jl")` before the Julia package tests. Restore dependency-path edits to `Project.toml` and `Manifest.toml` before committing.
