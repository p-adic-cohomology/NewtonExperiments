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
mkdir -p "$PROBLEM_DIR/evaluator"

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
Path(os.environ["MOCK_LAUNCH_STATE"]).write_text(json.dumps({
    "pid": os.getpid(),
    "ready": str(ready_path),
    "socket": str(socket_path),
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
pending_curves = Path(shlex.split(start_hook)[1])
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
quoted_run_dir = shlex.quote(str(run_dir))
# The engine appends FS_RUN_DIR as the final argument for both hooks.
subprocess.run(start_hook + " " + quoted_run_dir, shell=True, check=True)
subprocess.run(finish_hook + " " + quoted_run_dir, shell=True, check=True)
print("mock run complete")
PY

chmod +x "$MOCK_JULIA" "$MOCK_FUNSEARCH"

PYTHON_BIN=$(command -v python3.11 || command -v python3)
export FUNSEARCH_BIN="$MOCK_FUNSEARCH"
export PYTHON_BIN
export JULIA_BIN="$MOCK_JULIA"
export MOCK_LAUNCH_STATE="$STATE_FILE"

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

rm -f "$STATE_FILE"
output=$(MOCK_JULIA_MODE=ready MOCK_FUNSEARCH_MODE=complete \
    FUNSEARCH_NEWTON_START_TIMEOUT_S=3 "$LAUNCHER" run "$PROBLEM_DIR" --run-id "$run_id")
[[ "$output" == *"mock run complete"* ]]
assert_clean_runtime "$pending_curves" "$pending_log" "$STATE_FILE"
[[ -s "$PROBLEM_DIR/runs/$run_id/curves.jsonl" ]]
[[ -f "$PROBLEM_DIR/runs/$run_id/server-ready.json" ]]

echo "launcher lifecycle tests passed: readiness, failure cleanup, retry, finish hook"
