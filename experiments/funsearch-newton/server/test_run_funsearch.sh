#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAUNCHER="$SCRIPT_DIR/run_funsearch.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/funsearch-launcher-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

PROBLEM_DIR="$TMP_ROOT/problem"
MOCK_JULIA="$TMP_ROOT/mock_julia.py"
MOCK_FUNSEARCH="$TMP_ROOT/mock_funsearch.py"
STATE_FILE="$TMP_ROOT/server-state.json"
MOCK_PACK="$TMP_ROOT/mock pack"
MOCK_BIN="$TMP_ROOT/mock bin"
PACK_START_LOG="$TMP_ROOT/pack-start.log"
PACK_FINISH_LOG="$TMP_ROOT/pack-finish.log"
STOP_PS_LOG="$TMP_ROOT/stop-ps.log"
mkdir -p "$PROBLEM_DIR/evaluator" "$MOCK_PACK/scripts" "$MOCK_BIN"

cat > "$MOCK_JULIA" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time
from pathlib import Path

args = sys.argv[1:]
def option(name):
    return args[args.index(name) + 1]

ready_path = Path(option("--ready-file"))
socket_path = Path(option("--socket"))
curves_path = Path(option("--curves"))
Path(os.environ["MOCK_LAUNCH_STATE"]).write_text(json.dumps({
    "pid": os.getpid(),
    "ready": str(ready_path),
    "socket": str(socket_path),
    "curves": str(curves_path),
}))

mode = os.environ.get("MOCK_JULIA_MODE", "ready")
if mode == "exit":
    print("mock score server startup failure", file=sys.stderr)
    raise SystemExit(23)
if mode == "ready":
    ready_path.write_text(json.dumps({"pid": os.getpid()}) + "\n")
time.sleep(60)
PY

cat > "$MOCK_FUNSEARCH" <<'PY'
#!/usr/bin/env python3
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

args = sys.argv[1:]
def option(name):
    return args[args.index(name) + 1]

start_hook = option("--on-start")
finish_hook = option("--on-finish")
run_id = option("--run-id")
problem = Path(args[args.index("start") + 1])
start_parts = shlex.split(start_hook)
finish_parts = shlex.split(finish_hook)
if start_parts[:2] != ["sh", "-c"] or finish_parts[:2] != ["sh", "-c"]:
    raise SystemExit("launcher did not pass shell hook chains")
if "attach_run_artifacts.sh" not in start_parts[2] or "scripts/on-start.sh" not in start_parts[2]:
    raise SystemExit(f"start hook is missing an artifact or pack lifecycle hook: {start_parts[2]!r}")
if "scripts/on-finish.sh" not in finish_parts[2] or "stop_score_server.sh" not in finish_parts[2]:
    raise SystemExit("finish hook is missing a pack or server lifecycle hook")
pending_curves = Path(json.loads(Path(os.environ["MOCK_LAUNCH_STATE"]).read_text())["curves"])
mode = os.environ.get("MOCK_FUNSEARCH_MODE", "complete")

if mode == "fail-before-start-hook":
    # The engine can create this regular preflight log before its start hook
    # runs. The launcher must remove it when startup fails.
    pending_curves.touch()
    print("mock engine failed before start hook", file=sys.stderr)
    raise SystemExit(17)

run_dir = problem / "runs" / run_id
run_dir.mkdir(parents=True)
pending_curves.touch()
if mode == "fail-attach":
    pending_curves.unlink()
quoted_run_dir = shlex.quote(str(run_dir))
# The engine appends FS_RUN_DIR as the final argument for both hooks, and it
# still runs the finish hook after a failed start hook.
start_result = subprocess.run(start_hook + " " + quoted_run_dir, shell=True)
finish_result = subprocess.run(finish_hook + " " + quoted_run_dir, shell=True)
if start_result.returncode:
    print(f"mock run start hook failed with {start_result.returncode}", file=sys.stderr)
    raise SystemExit(start_result.returncode)
if finish_result.returncode:
    print(f"mock run finish hook failed with {finish_result.returncode}", file=sys.stderr)
    raise SystemExit(finish_result.returncode)
print("mock run complete")
PY

cat > "$MOCK_PACK/scripts/on-start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RUN_DIR=$1
[[ -f "$RUN_DIR/curves.jsonl" ]]
[[ -f "$RUN_DIR/server-ready.json" ]]
printf '%s\n' "$RUN_DIR" >> "$PACK_START_LOG"
if [[ ${MOCK_PACK_START_FAIL:-0} == 1 ]]; then
    printf '%s\n' "mock pack on-start failure" >&2
    exit 18
fi
SH

cat > "$MOCK_PACK/scripts/on-finish.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RUN_DIR=$1
printf '%s\n' "$RUN_DIR" >> "$PACK_FINISH_LOG"
if [[ ${MOCK_PACK_FINISH_FAIL:-0} == 1 ]]; then
    printf '%s\n' "mock pack on-finish failure" >&2
    exit 19
fi
SH

REAL_PS=$(command -v ps)
cat > "$MOCK_BIN/ps" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == command= ]]; then
        printf '%s\n' called >> "$STOP_PS_LOG"
    fi
done
exec "$REAL_PS" "$@"
SH

chmod +x "$MOCK_JULIA" "$MOCK_FUNSEARCH" "$MOCK_PACK/scripts/on-start.sh" \
    "$MOCK_PACK/scripts/on-finish.sh" "$MOCK_BIN/ps"

PYTHON_BIN=$(command -v python3.11 || command -v python3)
export FUNSEARCH_BIN="$MOCK_FUNSEARCH"
export PYTHON_BIN
export JULIA_BIN="$MOCK_JULIA"
export MOCK_LAUNCH_STATE="$STATE_FILE"
export FUNSEARCH_PACK="$MOCK_PACK"
export PACK_START_LOG PACK_FINISH_LOG STOP_PS_LOG REAL_PS
export PATH="$MOCK_BIN:$PATH"

assert_clean_runtime() {
    local pending_curves=$1 pending_log=$2 state_file=$3
    [[ ! -e "$pending_curves" && ! -L "$pending_curves" ]]
    [[ ! -e "$pending_log" && ! -L "$pending_log" ]]
    if [[ -f "$state_file" ]]; then
        local runtime_dir pid state
        runtime_dir=$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["socket"].rsplit("/",1)[0])' "$state_file")
        pid=$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$state_file")
        [[ ! -e "$runtime_dir" ]]
        state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
        [[ -z "$state" || "$state" == Z* ]]
    fi
}

run_id=retryable
pending_curves="$PROBLEM_DIR/runs/.$run_id.curves.jsonl"
pending_log="$PROBLEM_DIR/runs/.$run_id.server.log"

# A server that exits before readiness must leave no process or runtime dir.
rm -f "$STATE_FILE"
if MOCK_JULIA_MODE=exit MOCK_FUNSEARCH_MODE=complete \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=2 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$run_id"; then
    echo "expected an early server exit to fail" >&2
    exit 1
fi
assert_clean_runtime "$pending_curves" "$pending_log" "$STATE_FILE"

# Readiness timeout follows the same cleanup path.
rm -f "$STATE_FILE"
if MOCK_JULIA_MODE=wait MOCK_FUNSEARCH_MODE=complete \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=1 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$run_id"; then
    echo "expected readiness timeout to fail" >&2
    exit 1
fi
assert_clean_runtime "$pending_curves" "$pending_log" "$STATE_FILE"

# A failed engine start may leave a regular curves file before its hook runs.
# The next attempt with the same run id must be able to complete successfully.
rm -f "$STATE_FILE"
if MOCK_JULIA_MODE=ready MOCK_FUNSEARCH_MODE=fail-before-start-hook \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=3 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$run_id"; then
    echo "expected a pre-hook engine failure" >&2
    exit 1
fi
assert_clean_runtime "$pending_curves" "$pending_log" "$STATE_FILE"

rm -f "$STATE_FILE" "$PACK_START_LOG"
attach_fail_run_id="$run_id-attach-fail"
if MOCK_JULIA_MODE=ready MOCK_FUNSEARCH_MODE=fail-attach \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=3 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$attach_fail_run_id" \
    >"$TMP_ROOT/fail-attach.out" 2>&1; then
    echo "expected an artifact attach failure" >&2
    exit 1
fi
attach_fail_curves="$PROBLEM_DIR/runs/.$attach_fail_run_id.curves.jsonl"
attach_fail_log="$PROBLEM_DIR/runs/.$attach_fail_run_id.server.log"
assert_clean_runtime "$attach_fail_curves" "$attach_fail_log" "$STATE_FILE"
[[ ! -s "$PACK_START_LOG" ]]
grep -q "Pending curve log is missing" "$TMP_ROOT/fail-attach.out"

rm -f "$STATE_FILE" "$PACK_START_LOG" "$PACK_FINISH_LOG" "$STOP_PS_LOG"
start_fail_run_id="$run_id-start-fail"
if MOCK_JULIA_MODE=ready MOCK_FUNSEARCH_MODE=complete MOCK_PACK_START_FAIL=1 \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=3 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$start_fail_run_id" \
    >"$TMP_ROOT/fail-start.out" 2>&1; then
    echo "expected the failed pack on-start hook to fail the run" >&2
    exit 1
fi
start_fail_curves="$PROBLEM_DIR/runs/.$start_fail_run_id.curves.jsonl"
start_fail_log="$PROBLEM_DIR/runs/.$start_fail_run_id.server.log"
assert_clean_runtime "$start_fail_curves" "$start_fail_log" "$STATE_FILE"
[[ "$(cat "$PACK_START_LOG")" == "$PROBLEM_DIR/runs/$start_fail_run_id" ]]
[[ "$(cat "$PACK_FINISH_LOG")" == "$PROBLEM_DIR/runs/$start_fail_run_id" ]]
[[ -s "$STOP_PS_LOG" ]]
grep -q "mock pack on-start failure" "$TMP_ROOT/fail-start.out"
grep -q "mock run start hook failed" "$TMP_ROOT/fail-start.out"

rm -f "$STATE_FILE"
rm -f "$PACK_START_LOG" "$PACK_FINISH_LOG" "$STOP_PS_LOG"
output=$(MOCK_JULIA_MODE=ready MOCK_FUNSEARCH_MODE=complete \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=3 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$run_id")
[[ "$output" == *"mock run complete"* ]]
assert_clean_runtime "$pending_curves" "$pending_log" "$STATE_FILE"
[[ -s "$PROBLEM_DIR/runs/$run_id/curves.jsonl" ]]
[[ -f "$PROBLEM_DIR/runs/$run_id/server-ready.json" ]]
[[ "$(cat "$PACK_START_LOG")" == "$PROBLEM_DIR/runs/$run_id" ]]
[[ "$(cat "$PACK_FINISH_LOG")" == "$PROBLEM_DIR/runs/$run_id" ]]
[[ -s "$STOP_PS_LOG" ]]

rm -f "$STATE_FILE" "$PACK_START_LOG" "$PACK_FINISH_LOG" "$STOP_PS_LOG"
if MOCK_JULIA_MODE=ready MOCK_FUNSEARCH_MODE=complete MOCK_PACK_FINISH_FAIL=1 \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=3 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$run_id-finish-fail" \
    >"$TMP_ROOT/fail-finish.out" 2>&1; then
    echo "expected the failed pack finish hook to fail the run" >&2
    exit 1
fi
finish_pending_curves="$PROBLEM_DIR/runs/.$run_id-finish-fail.curves.jsonl"
finish_pending_log="$PROBLEM_DIR/runs/.$run_id-finish-fail.server.log"
assert_clean_runtime "$finish_pending_curves" "$finish_pending_log" "$STATE_FILE"
[[ -s "$PACK_FINISH_LOG" ]]
[[ -s "$STOP_PS_LOG" ]]
grep -q "mock pack on-finish failure" "$TMP_ROOT/fail-finish.out"
grep -q "mock run finish hook failed" "$TMP_ROOT/fail-finish.out"

echo "launcher lifecycle tests passed: readiness, cleanup, hook chaining, attach failure, start failure, finish failure"
