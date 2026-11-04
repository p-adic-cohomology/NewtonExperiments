#!/usr/bin/env bash
set -euo pipefail

if (($# != 5)); then
    printf 'Usage: attach_run_artifacts.sh PENDING_CURVES PENDING_NEAR_DUP_INDEX PENDING_LOG READY_FILE RUN_DIR\n' >&2
    exit 2
fi

PENDING_CURVES=$1
PENDING_NEAR_DUP_INDEX=$2
PENDING_NEAR_DUP_CACHE="${PENDING_NEAR_DUP_INDEX%.jsonl}.cache.jsonl"
PENDING_NEAR_DUP_LOCK="$PENDING_NEAR_DUP_INDEX.lock"
PENDING_LOG=$3
READY_FILE=$4
RUN_DIR=$5
RUN_ID=$(basename "$RUN_DIR")

[[ -d "$RUN_DIR" ]] || { printf 'Run directory does not exist: %s\n' "$RUN_DIR" >&2; exit 1; }
[[ -s "$READY_FILE" ]] || { printf 'Server ready record is missing: %s\n' "$READY_FILE" >&2; exit 1; }
[[ -f "$PENDING_CURVES" ]] || { printf 'Pending curve log is missing: %s\n' "$PENDING_CURVES" >&2; exit 1; }
[[ -f "$PENDING_NEAR_DUP_INDEX" ]] || { printf 'Pending near-duplicate index is missing: %s\n' "$PENDING_NEAR_DUP_INDEX" >&2; exit 1; }
[[ -f "$PENDING_NEAR_DUP_CACHE" ]] || { printf 'Pending near-duplicate cache is missing: %s\n' "$PENDING_NEAR_DUP_CACHE" >&2; exit 1; }
[[ -f "$PENDING_NEAR_DUP_LOCK" ]] || { printf 'Pending near-duplicate lock is missing: %s\n' "$PENDING_NEAR_DUP_LOCK" >&2; exit 1; }

mv "$PENDING_CURVES" "$RUN_DIR/curves.jsonl"
ln -s "$RUN_ID/curves.jsonl" "$PENDING_CURVES"
mv "$PENDING_NEAR_DUP_INDEX" "$RUN_DIR/near-dup-index.jsonl"
ln -s "$RUN_ID/near-dup-index.jsonl" "$PENDING_NEAR_DUP_INDEX"
mv "$PENDING_NEAR_DUP_CACHE" "$RUN_DIR/near-dup-index.cache.jsonl"
ln -s "$RUN_ID/near-dup-index.cache.jsonl" "$PENDING_NEAR_DUP_CACHE"
mv "$PENDING_NEAR_DUP_LOCK" "$RUN_DIR/near-dup-index.jsonl.lock"
ln -s "$RUN_ID/near-dup-index.jsonl.lock" "$PENDING_NEAR_DUP_LOCK"
if [[ -f "$PENDING_LOG" ]]; then
    mv "$PENDING_LOG" "$RUN_DIR/server.log"
    ln -s "$RUN_ID/server.log" "$PENDING_LOG"
fi
cp "$READY_FILE" "$RUN_DIR/server-ready.json"
