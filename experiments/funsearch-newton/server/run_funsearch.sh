#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        "Usage: run_funsearch.sh check PROBLEM [--instance STRING]" \
        "       run_funsearch.sh run PROBLEM [--instance STRING] [--run-id ID] [--set KEY=VALUE]..."
}

if (($# < 2)); then
    usage >&2
    exit 2
fi

MODE=$1
PROBLEM_DIR=$(cd "$2" && pwd)
shift 2
INSTANCE="family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true"
RUN_ID=""
RUN_OPTIONS=()

while (($#)); do
    case "$1" in
        --instance)
            (($# >= 2)) || { usage >&2; exit 2; }
            INSTANCE=$2
            shift 2
            ;;
        --run-id)
            (($# >= 2)) || { usage >&2; exit 2; }
            RUN_ID=$2
            shift 2
            ;;
        --set)
            (($# >= 2)) || { usage >&2; exit 2; }
            RUN_OPTIONS+=(--set "$2")
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$MODE" != check && "$MODE" != run ]]; then
    usage >&2
    exit 2
fi
if [[ "$MODE" == check && ( -n "$RUN_ID" || ${#RUN_OPTIONS[@]} -gt 0 ) ]]; then
    printf '%s\n' "check mode accepts only --instance" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
PACK_DIR=${FUNSEARCH_PACK:-/Users/Shared/Developer/ai/city/math-city/packs/funsearch}
export FUNSEARCH_PACK="$PACK_DIR"
FUNSEARCH_BIN=${FUNSEARCH_BIN:-$PACK_DIR/bin/funsearch}
PYTHON_BIN=${PYTHON_BIN:-}
if [[ -z "$PYTHON_BIN" ]]; then
    if command -v python3.11 >/dev/null 2>&1; then
        PYTHON_BIN=$(command -v python3.11)
    elif command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN=$(command -v python3)
    fi
fi
JULIA_BIN=${JULIA_BIN:-/Users/jj-agents/.juliaup/bin/julia}
START_TIMEOUT=${FUNSEARCH_NEWTON_START_TIMEOUT_S:-900}

if [[ ! -x "$FUNSEARCH_BIN" ]]; then
    printf 'FunSearch CLI is not executable: %s\n' "$FUNSEARCH_BIN" >&2
    exit 1
fi
if [[ ! -x "$PYTHON_BIN" ]] ||
   ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
    printf '%s\n' "Python 3.11 or newer is required; set PYTHON_BIN to its executable" >&2
    exit 1
fi
if [[ ! -x "$JULIA_BIN" ]]; then
    printf 'Julia executable is not executable: %s\n' "$JULIA_BIN" >&2
    exit 1
fi
if [[ ! "$START_TIMEOUT" =~ ^[0-9]+$ ]] || ((START_TIMEOUT < 1)); then
    printf 'FUNSEARCH_NEWTON_START_TIMEOUT_S must be a positive integer\n' >&2
    exit 2
fi

run_funsearch() {
    "$PYTHON_BIN" "$FUNSEARCH_BIN" "$@"
}

if [[ "$MODE" == run ]]; then
    if [[ -z "$RUN_ID" ]]; then
        RUN_ID="newton-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    fi
    if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
        printf 'Run id must contain only letters, digits, dot, underscore, or hyphen\n' >&2
        exit 2
    fi
    RUN_DIR="$PROBLEM_DIR/runs/$RUN_ID"
    PENDING_CURVES="$PROBLEM_DIR/runs/.${RUN_ID}.curves.jsonl"
    PENDING_LOG="$PROBLEM_DIR/runs/.${RUN_ID}.server.log"
    if [[ -e "$RUN_DIR" || -L "$RUN_DIR" || -e "$PENDING_CURVES" || -L "$PENDING_CURVES" ||
          -e "$PENDING_LOG" || -L "$PENDING_LOG" ]]; then
        printf 'Run id already has output: %s\n' "$RUN_ID" >&2
        exit 1
    fi
    mkdir -p "$PROBLEM_DIR/runs"
    CURVES_PATH=$PENDING_CURVES
fi

RUNTIME_PARENT=${TMPDIR:-/tmp}
RUNTIME_DIR=$(mktemp -d "${RUNTIME_PARENT%/}/fsn.XXXXXX")
SOCKET_PATH="$RUNTIME_DIR/score.sock"
READY_PATH="$RUNTIME_DIR/ready.json"
SERVER_LOG="$RUNTIME_DIR/server.log"
if [[ "$MODE" == check ]]; then
    CURVES_PATH="$RUNTIME_DIR/curves.jsonl"
else
    : > "$PENDING_LOG"
    SERVER_LOG=$PENDING_LOG
fi

SERVER_PID=""
KEEP_SERVER=0
cleanup_local() {
    if [[ "$KEEP_SERVER" == 1 ]]; then
        return
    fi
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        for _ in {1..10}; do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET_PATH" "$READY_PATH"
    if [[ "$MODE" == run ]]; then
        rm -f "$PENDING_CURVES"
    fi
    rm -f "$SERVER_LOG"
    rmdir "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup_local EXIT
trap 'exit 130' INT TERM

nohup "$JULIA_BIN" --project="$REPO_ROOT" "$SCRIPT_DIR/score_server.jl" \
    --socket "$SOCKET_PATH" --ready-file "$READY_PATH" --curves "$CURVES_PATH" \
    >"$SERVER_LOG" 2>&1 </dev/null &
SERVER_PID=$!

DEADLINE=$((SECONDS + START_TIMEOUT))
while [[ ! -s "$READY_PATH" ]]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat "$SERVER_LOG" >&2
        printf '%s\n' "Score server exited before writing its ready file" >&2
        exit 1
    fi
    if ((SECONDS >= DEADLINE)); then
        cat "$SERVER_LOG" >&2
        printf 'Score server did not become ready within %s seconds\n' "$START_TIMEOUT" >&2
        exit 1
    fi
    sleep 1
done

if [[ "$MODE" == check ]]; then
    printf 'score-server-ready: '
    cat "$READY_PATH"
fi

export FUNSEARCH_NEWTON_SOCKET="$SOCKET_PATH"
if [[ "$MODE" == check ]]; then
    make -C "$PROBLEM_DIR/evaluator" init_probe FS_PACK="$PACK_DIR"
    "$PROBLEM_DIR/evaluator/init_probe" "$INSTANCE"
    run_funsearch check "$PROBLEM_DIR" --instance "$INSTANCE"
    exit $?
fi

printf -v START_HOOK '%q ' "$SCRIPT_DIR/attach_run_artifacts.sh" \
    "$PENDING_CURVES" "$PENDING_LOG" "$READY_PATH"
START_HOOK=${START_HOOK% }
# FunSearch appends FS_RUN_DIR as the final positional argument when it runs
# each hook; both helpers use that argument to locate the completed run.
printf -v FINISH_HOOK '%q ' "$SCRIPT_DIR/stop_score_server.sh" \
    "$SERVER_PID" "$RUNTIME_DIR" "$SOCKET_PATH" "$PENDING_CURVES" "$PENDING_LOG"
FINISH_HOOK=${FINISH_HOOK% }

RUN_OUTPUT=$(run_funsearch run start "$PROBLEM_DIR" \
    --instance "$INSTANCE" --run-id "$RUN_ID" \
    --on-start "$START_HOOK" --on-finish "$FINISH_HOOK" \
    "${RUN_OPTIONS[@]+"${RUN_OPTIONS[@]}"}")
printf '%s\n' "$RUN_OUTPUT"
KEEP_SERVER=1
