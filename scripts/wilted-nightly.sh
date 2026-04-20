#!/usr/bin/env bash
# wilted-nightly.sh — launchd wrapper for the nightly ingestion pipeline.
#
# Install:
#   make install-launchd
#
# Logs:
#   ~/Library/Logs/wilted-nightly/wilted.log                  (aggregate)
#   ~/Library/Logs/wilted-nightly/wilted-YYYYMMDD-HHMMSS.log  (per-run)

set -euo pipefail

LOCK_FILE="/tmp/wilted-nightly.lock"
LOG_DIR="${HOME}/Library/Logs/wilted-nightly"
AGG_LOG="${LOG_DIR}/wilted.log"
RUN_LOG="${LOG_DIR}/wilted-$(date '+%Y%m%d-%H%M%S').log"

# Resolve the project root — follow symlinks.
REAL_SCRIPT="${BASH_SOURCE[0]}"
if [[ -L "$REAL_SCRIPT" ]]; then
    REAL_SCRIPT="$(readlink "$REAL_SCRIPT")"
fi
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export WILTED_PROJECT_ROOT="$PROJECT_ROOT"

WILTED="uv run --project ${PROJECT_ROOT} python -m wilted.cli"
EMAIL_ALERT="${HOME}/.agent/bin/email-alert"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$AGG_LOG"
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
if $WILTED ingest >> "$RUN_LOG" 2>&1; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "completed successfully in ${ELAPSED}s"

    # Send email report if configured
    if $WILTED report --email >> "$RUN_LOG" 2>&1; then
        log "email report sent"
    fi
else
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "failed with exit code $? after ${ELAPSED}s"

    # Send failure notification if email-alert is available
    if [[ -x "$EMAIL_ALERT" ]]; then
        tail -20 "$RUN_LOG" | "$EMAIL_ALERT" \
            --subject "Wilted Nightly Failed" 2>/dev/null || true
    fi
    exit 1
fi
