#!/usr/bin/env bash
set -euo pipefail

if (($# != 4)); then
    printf 'Usage: attach_run_artifacts.sh PENDING_CURVES PENDING_LOG READY_FILE RUN_DIR\n' >&2
    exit 2
fi

PENDING_CURVES=$1
PENDING_LOG=$2
READY_FILE=$3
RUN_DIR=$4
RUN_ID=$(basename "$RUN_DIR")

[[ -d "$RUN_DIR" ]] || { printf 'Run directory does not exist: %s\n' "$RUN_DIR" >&2; exit 1; }
[[ -s "$READY_FILE" ]] || { printf 'Server ready record is missing: %s\n' "$READY_FILE" >&2; exit 1; }
[[ -f "$PENDING_CURVES" ]] || { printf 'Pending curve log is missing: %s\n' "$PENDING_CURVES" >&2; exit 1; }

mv "$PENDING_CURVES" "$RUN_DIR/curves.jsonl"
ln -s "$RUN_ID/curves.jsonl" "$PENDING_CURVES"
if [[ -f "$PENDING_LOG" ]]; then
    mv "$PENDING_LOG" "$RUN_DIR/server.log"
    ln -s "$RUN_ID/server.log" "$PENDING_LOG"
fi
cp "$READY_FILE" "$RUN_DIR/server-ready.json"
