#!/usr/bin/env bash
# wilted-nightly.sh — launchd wrapper for the nightly ingestion pipeline.
#
# Install:
#   make install-launchd
#
# Logs (homelab convention — parsed by ldstatus as the WILTED agent):
#   ~/Library/Logs/homelab/wilted-nightly/wilted.log                  (aggregate)
#   ~/Library/Logs/homelab/wilted-nightly/wilted-YYYYMMDD-HHMMSS.log  (per-run)
#
# Each Wilted invocation goes through wilted-runtime.sh, which retrieves only
# the dedicated runtime token and removes BWS state before starting Wilted.

set -euo pipefail

LOCK_FILE="/tmp/wilted-nightly.lock"
LOG_DIR="${HOME}/Library/Logs/homelab/wilted-nightly"
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

# Keep the venv outside iCloud (~/Documents is iCloud-synced, which sets UF_HIDDEN on
# .venv and breaks Python 3.13's .pth handling). See HISTORY.md.
export UV_PROJECT_ENVIRONMENT="${HOME}/.venvs/wilted"

WILTED_RUNTIME="${SCRIPT_DIR}/wilted-runtime.sh"
EMAIL_ALERT="${HOME}/.agent/bin/email-alert"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$AGG_LOG"
}

# --- Locking ---
# Legacy nightly path still uses shell flock; the bounded scheduler tick uses
# Python fcntl only via processing_jobs.try_acquire_execution_lock.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "SKIP: previous run still active"
    exit 0
fi

log "START: nightly ingestion"
START_TIME=$(date +%s)

# --- Pipeline ---
# Invoke the runtime through /bin/bash (which holds Full Disk Access) rather than
# direct-exec: launchd cannot exec a script resident under ~/Documents (TCC blocks
# it, exit 126). See scripts/wilted-scheduler.sh for the same pattern.
if /bin/bash "$WILTED_RUNTIME" ingest >> "$RUN_LOG" 2>&1; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "completed successfully in ${ELAPSED}s"

    # Send email report if configured
    if /bin/bash "$WILTED_RUNTIME" report --email >> "$RUN_LOG" 2>&1; then
        log "email report sent"
    fi
else
    INGEST_STATUS=$?
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "failed with exit code ${INGEST_STATUS} after ${ELAPSED}s"

    # Send failure notification if email-alert is available
    if [[ -x "$EMAIL_ALERT" ]]; then
        tail -20 "$RUN_LOG" | "$EMAIL_ALERT" \
            --subject "Wilted Nightly Failed" 2>/dev/null || true
    fi
    exit "$INGEST_STATUS"
fi
