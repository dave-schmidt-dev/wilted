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
# Ingestion stderr is captured briefly in a mode-0600 temporary file solely to
# classify a safe EINTR retry; it is never copied to logs or notifications.

set -euo pipefail

LOCK_DIR="/tmp/wilted-nightly.lockdir"
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
readonly EINTR_EXIT_STATUS=126
readonly MAX_EINTR_RETRIES=1
RUNTIME_STDERR=""

mkdir -p "$LOG_DIR"

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"
    printf '%s\n' "$line" >> "$AGG_LOG"
    printf '%s\n' "$line" >> "$RUN_LOG"
}

remove_runtime_stderr() {
    if [[ -n "$RUNTIME_STDERR" ]]; then
        rm -f -- "$RUNTIME_STDERR" 2>/dev/null || true
        RUNTIME_STDERR=""
    fi
}

cleanup() {
    remove_runtime_stderr
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

# --- Locking ---
# Use mkdir as a portable lock (macOS has no flock). The bounded scheduler
# tick uses Python fcntl via processing_jobs.try_acquire_execution_lock.
LOCK_DIR="/tmp/wilted-nightly.lockdir"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "SKIP: previous run still active"
    exit 0
fi
trap cleanup EXIT

log "START: nightly ingestion"
START_TIME=$(date +%s)

# --- Pipeline ---
# Invoke the runtime through /bin/bash (which holds Full Disk Access) rather than
# direct-exec: launchd cannot exec a script resident under ~/Documents (TCC blocks
# it, exit 126). See scripts/wilted-scheduler.sh for the same pattern.
run_ingest() {
    local eintr_retries=0
    local ingest_status

    while true; do
        if ! RUNTIME_STDERR="$(mktemp "${TMPDIR:-/tmp}/wilted-nightly-stderr.XXXXXX" 2>/dev/null)"; then
            return 126
        fi
        if ! chmod 600 "$RUNTIME_STDERR" 2>/dev/null; then
            remove_runtime_stderr
            return 126
        fi

        # Preserve stdout in the per-run log; stderr stays isolated for safe
        # classification and is never copied into the log or alert body.
        if /bin/bash "$WILTED_RUNTIME" ingest >> "$RUN_LOG" 2>"$RUNTIME_STDERR"; then
            remove_runtime_stderr
            return 0
        else
            ingest_status=$?
        fi

        if [[ "$ingest_status" -eq "$EINTR_EXIT_STATUS" && "$eintr_retries" -lt "$MAX_EINTR_RETRIES" ]] &&
            awk '
                BEGIN { seen = 0; invalid = 0 }
                /^[[:space:]]*(Interrupted system call|EINTR|EINTR: Interrupted system call)[[:space:]]*$/ { seen = 1; next }
                { invalid = 1 }
                END { exit !(seen && !invalid) }
            ' "$RUNTIME_STDERR" >/dev/null 2>&1; then
            remove_runtime_stderr
            eintr_retries=$((eintr_retries + 1))
            log "retrying after interrupted ingestion (attempt ${eintr_retries}/${MAX_EINTR_RETRIES})"
            continue
        fi
        remove_runtime_stderr
        return "$ingest_status"
    done
}

if run_ingest; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "completed successfully in ${ELAPSED}s"

    # Prune the terminal processing-job ledger. Non-fatal: a prune failure must
    # never block or skip the email report below, so it lives in its own
    # if/else rather than being chained with && / relying on set -e.
    if /bin/bash "$WILTED_RUNTIME" db prune >> "$RUN_LOG" 2>&1; then
        log "ledger prune completed"
    else
        PRUNE_STATUS=$?
        log "ledger prune failed with exit code ${PRUNE_STATUS} (non-fatal, continuing)"
    fi

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
