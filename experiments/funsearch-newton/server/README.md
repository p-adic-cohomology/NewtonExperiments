# Resident score server

`score_server.jl` loads DeRham, Oscar, the NewtonStrata module, and the plane-quintic reference table once. It scores line-delimited JSON requests over a Unix domain socket and serializes all evaluations through one queue. Keep one server process per run; it is the only writer to that run's `curves.jsonl`.

Each request object has `coeffs` and `instance` fields and an optional `program_id` field. The prime `p` is part of the `instance` string, such as `family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true`. The response object has `status`, `score`, `sig`, and `msg`. A valid curve returns `status: "OK"`; a malformed instance or coefficient vector, or a singular curve, returns `status: "INVALID"`. Unexpected DeRham or retention failures return `status: "ERROR"`. Request lines are limited to 64 KiB, and the server serves at most 64 clients at a time; excess connections are closed.

The instance supports `family=plane` and `d=5` (both defaults) and requires a prime `p`. Unknown fields are rejected. `reward` defaults to `mixed`, which scores `codim + beta × novel`; `depth` scores `codim`, and `novelty` scores `novel + eps × codim`. Here `novel` means the polygon is absent from the reference table. The defaults are `beta=0.5` and `eps=0.01`; both must be finite and nonnegative. `exclude_ss` defaults to `true`, assigning supersingular curves a score of zero; set it to `false` to score them normally.

For a degree-five curve, coefficients are ordered by the exponent vectors returned by `DeRham.gen_exp_vec(3, 5, :lex)` in DeRham 59b331b. With variables `(x, y, z)`, this begins `z^5, yz^4, y^2z^3, …, y^5, xz^4, xyz^3, …, x^5`. The server pins this order as increasing `x` exponent, then increasing `y` exponent; `z` has the remaining degree. Fermat's curve has nonzero coefficients at indices 1, 6, and 21.

Launch from the NewtonExperiments project directory:

```sh
julia --project=. experiments/funsearch-newton/server/score_server.jl \
  --socket /tmp/funsearch-newton.sock \
  --ready-file /tmp/funsearch-newton.ready \
  --curves experiments/funsearch-newton/runs/<run-id>/curves.jsonl
```

The same paths can be supplied through `FUNSEARCH_NEWTON_SOCKET`, `FUNSEARCH_NEWTON_READY`, and `FUNSEARCH_NEWTON_CURVES`. The ready file is written after imports, reference loading, the Fermat p=7 warm-up score, and precision provenance capture. It records load time, first-call latency, DeRham source path and commit, the p=7 precision path and `r_m`/`N_m`/`M`, selected sysimage, and peak RSS.

Every parsed JSON object request, including invalid inputs and singular curves, is appended and flushed as one JSON line. Malformed JSON lines, oversized lines, and parsed non-object values receive an error response but are not retained. Existing `curves.jsonl` content is preserved. Each row records the program id when supplied, instance, prime, coefficients, status, slopes, lengths, polygon values, codimension, novelty, reward, elapsed scoring time, and UTC timestamp.

The Unix socket is created with mode `0600` so access does not depend on the process umask. The ready file is written only after warm-up and precision capture; if startup fails after binding the socket, the listener, worker tasks, socket path, and ready file are cleaned up.

If DeRham throws while evaluating a curve, the server independently checks projective smoothness with Oscar. Singular curves return `INVALID`; failures on smooth curves remain `ERROR`.

Run `measure_server.jl` with an optional sample count (minimum 20) to record cold module load, Fermat warm-up latency, median scoring time over random smooth quintics at p=7, peak RSS, and DeRham precision provenance. The script skips singular random samples, aborts on evaluation errors, and does not write to a run's curve log.

For a linked worktree, run `include("scripts/setup_deps.jl")` before the Julia package tests. Restore dependency-path edits to `Project.toml` and `Manifest.toml` before committing.

For an evaluator check without starting a search, use the managed launcher:

~~~sh
experiments/funsearch-newton/server/run_funsearch.sh check \
  experiments/funsearch-newton \
  --instance 'family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true'
~~~

It starts the resident server, waits for the ready file, runs funsearch check,
and stops the server. Set FUNSEARCH_BIN to choose the FunSearch CLI,
FUNSEARCH_PACK to choose its pack directory, PYTHON_BIN to choose Python 3.11+
(the default is python3.11), and JULIA_BIN to choose Julia or the documented
per-worktree Julia wrapper. The ready wait defaults to 900 seconds and can be
changed with FUNSEARCH_NEWTON_START_TIMEOUT_S.

To start a search when authorized, use run instead of check and supply a run id:

~~~sh
experiments/funsearch-newton/server/run_funsearch.sh run \
  experiments/funsearch-newton --run-id quintic-p7-baseline \
  --instance 'family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true'
~~~

The launcher starts the server before funsearch run start, then uses the run's
start and finish hooks to move the preflight curve log into the run, retain
server-ready.json and server.log, and stop the server at completion. The run
directory is created only by FunSearch; a pending log path under runs/ lets the
seed preflight be retained without claiming the run id early. The evaluator
logs its fs_init connection time to worker stderr.
