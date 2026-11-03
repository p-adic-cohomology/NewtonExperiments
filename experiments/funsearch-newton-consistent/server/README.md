# Consistent score-server pool

This evaluator uses the same finite-field reference tables as [`funsearch-newton`](../../funsearch-newton/reference/): `plane_quintic_newton_polygons.tsv` and `known_plane_quintic_newton_polygons.tsv`. Both are loaded once per server process and define the fixed novelty set for that run.

Unlike the original experiment, a candidate generates `K` curves and receives an aggregate score after zeta-function deduplication. See the parent [README](../README.md) and [problem statement](../problem.md) for the interface and score formula.

## Check the evaluator

Use the managed launcher for checks and runs. It starts the score servers, waits for warm-up, passes their Unix socket paths to FunSearch, and cleans up after check mode.

```sh
experiments/funsearch-newton-consistent/server/run_funsearch.sh check \
  experiments/funsearch-newton-consistent
```

The default instance is `family=plane,d=5,p=7,k=16,curve_reward=log,lambda=0.25,beta=0.5,ss_codim=1`. To check another prime, pass the same fields with a different `p`:

```sh
experiments/funsearch-newton-consistent/server/run_funsearch.sh check \
  experiments/funsearch-newton-consistent \
  --instance 'family=plane,d=5,p=13,k=16,curve_reward=log,lambda=0.25,beta=0.5,ss_codim=1'
```

The command prints `score-server-ready` followed by the ready JSON from each server, then the FunSearch check result. A successful evaluator check returns status `OK`.

For a linked worktree, prepare the pinned dependencies first:

```sh
NEWTON_DERHAM_REV=59b331b818aaa7f169a33c42e600cbc6de9044f7 \
NEWTON_GPUFFM_REV=aec266ff4517e5a611b9d90fc71c44a2ca3a96cd \
NEWTON_SIBLING_ROOT=/path/to/maintenance/deps \
julia --project=. -e 'include("scripts/setup_deps.jl")'
```

## Server processes and environment

The launcher starts `FUNSEARCH_NEWTON_SERVERS` independent Julia processes, each with `--threads=1`; the default pool size is 2 and the accepted range is 1 through 16. Each process loads and warms the scorer before reporting ready. `FUNSEARCH_NEWTON_START_TIMEOUT_S` controls the readiness timeout (default 900 seconds).

The launcher exports the socket paths as a colon-separated `FUNSEARCH_NEWTON_SOCKET` list. Each evaluator process chooses one path deterministically from its process id and reconnects to that server as needed. Separate FunSearch evaluator processes can therefore use different score servers without enabling threaded DeRham evaluation. Each server evaluates its own requests serially. All processes append to the run's shared `curves.jsonl` under a file lock, preserving complete batches.

Useful overrides:

- `FUNSEARCH_NEWTON_SERVERS`: number of single-threaded score servers (default 2).
- `FUNSEARCH_NEWTON_START_TIMEOUT_S`: readiness timeout in seconds (default 900).
- `FUNSEARCH_BIN`: FunSearch CLI path (defaults to the selected pack's `bin/funsearch`).
- `FUNSEARCH_PACK`: FunSearch pack directory.
- `PYTHON_BIN`: Python 3.11 or newer (defaults to `python3.11`, then `python3`).
- `JULIA_BIN`: Julia executable (defaults to `/Users/jj-agents/.juliaup/bin/julia`).

On macOS, set `FS_DYLD_LIBRARY_PATH` to the evaluator's Julia library directory. The bash shebang strips `DYLD_*` variables, so this requires a FunSearch pack with `mx-44ng9` carrier support.

## Run artifacts and search launch

For a search, use the same launcher with `run`, the consistent experiment directory, and a run id:

```sh
experiments/funsearch-newton-consistent/server/run_funsearch.sh run \
  experiments/funsearch-newton-consistent --run-id quintic-p7-k16
```

The on-start hook attaches `curves.jsonl`, the combined server log, and `server-ready.json` to the run before invoking the pack's on-start hook. The ready file contains one record per server, including Julia version, thread count, load and warm-up timings, DeRham revision, precision provenance, and peak RSS. The on-finish hook runs the pack's finish hook and stops every server, even if the pack hook fails. Failed starts remove pending artifacts and stop all started servers.

`check` mode starts and stops the same pool but does not create a run directory. See [measurements.md](measurements.md) for the measured batch latencies and the approved process-pool fallback after threaded evaluation crashed.
