#!/usr/bin/env bash
set -euo pipefail

if (($# != 5)); then
    printf 'Usage: stop_score_server.sh RUNTIME_DIR PENDING_CURVES PENDING_NEAR_DUP_INDEX PENDING_LOG RUN_DIR\n' >&2
    exit 2
fi

RUNTIME_DIR=$1
PENDING_CURVES=$2
PENDING_NEAR_DUP_INDEX=$3
PENDING_NEAR_DUP_CACHE="${PENDING_NEAR_DUP_INDEX%.jsonl}.cache.jsonl"
PENDING_NEAR_DUP_LOCK="$PENDING_NEAR_DUP_INDEX.lock"
PENDING_LOG=$4
RUN_DIR=$5
PID_FILE="$RUNTIME_DIR/server-pids"
SOCKET_FILE="$RUNTIME_DIR/server-sockets"

matches_server() {
    local pid=$1 socket=$2 command
    command=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
    [[ "$command" == *score_server.jl* && "$command" == *"$socket"* ]]
}

if [[ -f "$PID_FILE" && -f "$SOCKET_FILE" ]]; then
    server_pids=()
    socket_paths=()
    while IFS= read -r value; do server_pids+=("$value"); done < "$PID_FILE"
    while IFS= read -r value; do socket_paths+=("$value"); done < "$SOCKET_FILE"
    for index in "${!server_pids[@]}"; do
        pid=${server_pids[$index]}
        socket=${socket_paths[$index]}
        if matches_server "$pid" "$socket"; then
            kill -TERM "$pid" 2>/dev/null || true
            for _ in {1..15}; do
                matches_server "$pid" "$socket" || break
                sleep 1
            done
            if matches_server "$pid" "$socket"; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$socket" "$RUNTIME_DIR/ready-$((index + 1)).json"
    done
fi

if [[ -n "$RUN_DIR" && ! -d "$RUN_DIR" ]]; then
    printf 'Run directory disappeared before server shutdown: %s\n' "$RUN_DIR" >&2
    exit 1
fi
if [[ -L "$PENDING_CURVES" ]]; then rm -f "$PENDING_CURVES"; fi
if [[ -L "$PENDING_NEAR_DUP_INDEX" ]]; then rm -f "$PENDING_NEAR_DUP_INDEX"; fi
if [[ -L "$PENDING_NEAR_DUP_CACHE" ]]; then rm -f "$PENDING_NEAR_DUP_CACHE"; fi
if [[ -L "$PENDING_NEAR_DUP_LOCK" ]]; then rm -f "$PENDING_NEAR_DUP_LOCK"; fi
if [[ -L "$PENDING_LOG" ]]; then rm -f "$PENDING_LOG"; fi
rm -f "$RUNTIME_DIR/ready.json" "$PID_FILE" "$SOCKET_FILE"
rmdir "$RUNTIME_DIR" 2>/dev/null || true
