#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        "Usage: run_funsearch.sh check PROBLEM [--instance STRING]" \
        "       run_funsearch.sh run PROBLEM [--instance STRING] [--run-id ID] [--set KEY=VALUE]..." \
        "On macOS, set FS_DYLD_LIBRARY_PATH to the evaluator's Julia lib directory; the bash shebang strips DYLD_* variables." \
        "This requires a FunSearch pack with mx-44ng9."
}

if (($# < 2)); then
    usage >&2
    exit 2
fi

MODE=$1
PROBLEM_DIR=$(cd "$2" && pwd)
shift 2
INSTANCE="family=plane,d=5,p=7,reward=logmixed,beta=0.5,eps=0.01,exclude_ss=true"
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
SERVER_COUNT=${FUNSEARCH_NEWTON_SERVERS:-2}

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
if [[ ! "$SERVER_COUNT" =~ ^[1-9][0-9]*$ ]] || ((SERVER_COUNT > 16)); then
    printf 'FUNSEARCH_NEWTON_SERVERS must be an integer from 1 through 16\n' >&2
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
READY_PATH="$RUNTIME_DIR/ready.json"
SERVER_LOG="$RUNTIME_DIR/server.log"
SOCKET_PATHS=()
READY_FILES=()
SERVER_PIDS=()
if [[ "$MODE" == check ]]; then
    CURVES_PATH="$RUNTIME_DIR/curves.jsonl"
else
    : > "$PENDING_LOG"
    SERVER_LOG=$PENDING_LOG
fi

KEEP_SERVER=0
cleanup_local() {
    if [[ "$KEEP_SERVER" == 1 ]]; then
        return
    fi
    for index in "${!SERVER_PIDS[@]}"; do
        pid=${SERVER_PIDS[$index]}
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            for _ in {1..10}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        rm -f "${SOCKET_PATHS[$index]}" "${READY_FILES[$index]}"
    done
    rm -f "$READY_PATH" "$RUNTIME_DIR/server-pids" "$RUNTIME_DIR/server-sockets" "$CURVES_PATH"
    if [[ "$MODE" == run ]]; then
        rm -f "$PENDING_CURVES" "$PENDING_LOG"
    fi
    [[ "$MODE" == check ]] && rm -f "$SERVER_LOG"
    rmdir "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup_local EXIT
trap 'exit 130' INT TERM

for ((index = 1; index <= SERVER_COUNT; ++index)); do
    socket_path="$RUNTIME_DIR/score-$index.sock"
    ready_file="$RUNTIME_DIR/ready-$index.json"
    SOCKET_PATHS+=("$socket_path")
    READY_FILES+=("$ready_file")
    nohup "$JULIA_BIN" --threads=1 --project="$REPO_ROOT" "$SCRIPT_DIR/score_server.jl" \
        --socket "$socket_path" --ready-file "$ready_file" --curves "$CURVES_PATH" \
        >>"$SERVER_LOG" 2>&1 </dev/null &
    SERVER_PIDS+=("$!")
done
printf '%s\n' "${SERVER_PIDS[@]}" > "$RUNTIME_DIR/server-pids"
printf '%s\n' "${SOCKET_PATHS[@]}" > "$RUNTIME_DIR/server-sockets"

DEADLINE=$((SECONDS + START_TIMEOUT))
while true; do
    all_ready=1
    for index in "${!SERVER_PIDS[@]}"; do
        if [[ ! -s "${READY_FILES[$index]}" ]]; then
            all_ready=0
            if ! kill -0 "${SERVER_PIDS[$index]}" 2>/dev/null; then
                cat "$SERVER_LOG" >&2
                printf 'Score server %s exited before writing its ready file\n' "$((index + 1))" >&2
                exit 1
            fi
        fi
    done
    if ((all_ready)); then
        jq -s --argjson count "$SERVER_COUNT" '{status:"ready",server_count:$count,servers:.}' \
            "${READY_FILES[@]}" > "$READY_PATH"
        break
    fi
    if ((SECONDS >= DEADLINE)); then
        cat "$SERVER_LOG" >&2
        printf 'Score server pool did not become ready within %s seconds\n' "$START_TIMEOUT" >&2
        exit 1
    fi
    sleep 1
done

if [[ "$MODE" == check ]]; then
    printf 'score-server-ready: '
    cat "$READY_PATH"
fi

SOCKET_LIST=$(printf '%s:' "${SOCKET_PATHS[@]}")
export FUNSEARCH_NEWTON_SOCKET=${SOCKET_LIST%:}
if [[ "$MODE" == check ]]; then
    make -C "$PROBLEM_DIR/evaluator" init_probe FS_PACK="$PACK_DIR"
    "$PROBLEM_DIR/evaluator/init_probe" "$INSTANCE"
    run_funsearch check "$PROBLEM_DIR" --instance "$INSTANCE"
    exit $?
fi

# FunSearch appends FS_RUN_DIR as the final positional argument when it runs
# each hook; both helpers use that argument to locate the completed run.
printf -v START_HOOK_BODY '%q %q %q %q "$1" && %q "$1"' \
    "$SCRIPT_DIR/attach_run_artifacts.sh" "$PENDING_CURVES" "$PENDING_LOG" \
    "$READY_PATH" "$PACK_DIR/scripts/on-start.sh"
printf -v START_HOOK 'sh -c %q fs-hook' "$START_HOOK_BODY"
printf -v FINISH_HOOK_BODY \
    '%q "$1"; pack_status=$?; %q %q %q %q "$1"; stop_status=$?; [ "$pack_status" -eq 0 ] && [ "$stop_status" -eq 0 ]' \
    "$PACK_DIR/scripts/on-finish.sh" "$SCRIPT_DIR/stop_score_server.sh" \
    "$RUNTIME_DIR" "$PENDING_CURVES" "$PENDING_LOG"
printf -v FINISH_HOOK 'sh -c %q fs-hook' "$FINISH_HOOK_BODY"

RUN_OUTPUT=$(run_funsearch run start "$PROBLEM_DIR" \
    --instance "$INSTANCE" --run-id "$RUN_ID" \
    --on-start "$START_HOOK" --on-finish "$FINISH_HOOK" \
    "${RUN_OPTIONS[@]+"${RUN_OPTIONS[@]}"}")
printf '%s\n' "$RUN_OUTPUT"
KEEP_SERVER=1
