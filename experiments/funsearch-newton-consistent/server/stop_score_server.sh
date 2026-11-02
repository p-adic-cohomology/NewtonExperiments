#!/usr/bin/env bash
set -euo pipefail

if (($# != 6)); then
    printf 'Usage: stop_score_server.sh PID RUNTIME_DIR SOCKET PENDING_CURVES PENDING_LOG RUN_DIR\n' >&2
    exit 2
fi

SERVER_PID=$1
RUNTIME_DIR=$2
SOCKET_PATH=$3
PENDING_CURVES=$4
PENDING_LOG=$5
RUN_DIR=$6

matches_server() {
    local command
    command=$(ps -p "$SERVER_PID" -o command= 2>/dev/null) || return 1
    [[ "$command" == *score_server.jl* && "$command" == *"$SOCKET_PATH"* ]]
}

if matches_server; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    for _ in {1..15}; do
        matches_server || break
        sleep 1
    done
    if matches_server; then
        kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi
fi

if [[ -n "$RUN_DIR" && ! -d "$RUN_DIR" ]]; then
    printf 'Run directory disappeared before server shutdown: %s\n' "$RUN_DIR" >&2
    exit 1
fi
if [[ -L "$PENDING_CURVES" ]]; then rm -f "$PENDING_CURVES"; fi
if [[ -L "$PENDING_LOG" ]]; then rm -f "$PENDING_LOG"; fi
rm -f "$SOCKET_PATH" "$RUNTIME_DIR/ready.json"
rmdir "$RUNTIME_DIR" 2>/dev/null || true
