#!/usr/bin/env bash
# wilted-scheduler.sh — launchd wrapper for bounded background-work scheduler ticks.
#
# Locking is Python fcntl only via processing_jobs.try_acquire_execution_lock.
# This wrapper intentionally does NOT use shell file locking — see scripts/wilted-nightly.sh
# for the legacy nightly path that still uses flock until it is retired.
#
# Install:
#   make install-launchd
#
# Logs (homelab convention — parsed by ldstatus once a WILTED-SCHED parser is registered):
#   ~/Library/Logs/homelab/wilted-scheduler/wilted-scheduler.log
#   ~/Library/Logs/homelab/wilted-scheduler/wilted-scheduler-YYYYMMDD-HHMMSS.log

set -euo pipefail

LOG_DIR="${HOME}/Library/Logs/homelab/wilted-scheduler"
AGG_LOG="${LOG_DIR}/wilted-scheduler.log"
RUN_LOG="${LOG_DIR}/wilted-scheduler-$(date '+%Y%m%d-%H%M%S').log"

REAL_SCRIPT="${BASH_SOURCE[0]}"
if [[ -L "$REAL_SCRIPT" ]]; then
    REAL_SCRIPT="$(readlink "$REAL_SCRIPT")"
fi
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export WILTED_PROJECT_ROOT="$PROJECT_ROOT"
export UV_PROJECT_ENVIRONMENT="${HOME}/.venvs/wilted"

WILTED_RUNTIME="${SCRIPT_DIR}/wilted-runtime.sh"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$AGG_LOG"
}

log "START: scheduler tick"
START_TIME=$(date +%s)

if /bin/bash "$WILTED_RUNTIME" scheduler tick >> "$RUN_LOG" 2>&1; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "completed successfully in ${ELAPSED}s"
else
    EXIT_CODE=$?
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "failed with exit code ${EXIT_CODE} after ${ELAPSED}s"
    # Deliberately NO email-alert here (unlike wilted-nightly.sh's failure branch):
    # this tick fires HOURLY, so mailing on every failure would send ~24/day the
    # moment FDA or the speech daemon wedges. The failure surface is the aggregate
    # log line above, the per-run $RUN_LOG, launchd's own StandardErrorPath capture,
    # and ldstatus. TODO: if a scheduler email is ever wanted, it MUST be throttled/
    # deduped (e.g. once per wedged streak). See HISTORY.md 2026-07-23.
    exit "$EXIT_CODE"
fi
