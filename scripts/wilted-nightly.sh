#!/usr/bin/env bash
# wilted-nightly.sh — cron wrapper for the nightly ingestion pipeline.
#
# Runs discover → classify → report with flock-based locking so
# concurrent executions are skipped rather than stacked.
#
# Install in crontab:
#   0 2 * * * /path/to/wilted/scripts/wilted-nightly.sh
#
# Or with launchd (macOS):
#   See scripts/com.wilted.nightly.plist (if created)
#
# Logs go to /tmp/wilted.log (via wilted's own RotatingFileHandler).
# This script also logs a one-line summary to /tmp/wilted-nightly.log.

set -euo pipefail

LOCK_FILE="/tmp/wilted-nightly.lock"
LOG_FILE="/tmp/wilted-nightly.log"

# Resolve the project root (directory containing this script's parent).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export WILTED_PROJECT_ROOT="$PROJECT_ROOT"

# Use the project's uv-managed Python.
WILTED="uv run --project $PROJECT_ROOT python -m wilted.cli"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# --- Locking ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "SKIP: previous run still active"
    exit 0
fi

log "START: nightly ingestion"
START_TIME=$(date +%s)

# --- Pipeline ---
if $WILTED ingest 2>&1 | tee -a "$LOG_FILE"; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "DONE: completed in ${ELAPSED}s"
else
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "FAIL: exited with errors after ${ELAPSED}s"
    exit 1
fi
