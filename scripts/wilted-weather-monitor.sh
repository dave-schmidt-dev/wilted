#!/usr/bin/env bash
# wilted-weather-monitor.sh — one-shot NWS zone+county alert poll wrapper.
#
# Runs `python -m wilted.station_runtime.weather_monitor`, which performs a
# single combined zone+county poll (SR-5), pre-generates + submits a bulletin
# interruption through the station controller if a new/escalated alert
# qualifies, and exits with the poll's TRUE outcome.
#
# INV-6 (extended to this module, Plan A task 4.2): a wrapper that exits 0
# regardless of whether anything actually ran is the exact C1 bug class this
# pattern exists to prevent -- see wilted-nightly.sh's `python -m wilted.cli`
# history (no `__main__` guard -> exited 0 every night having run nothing)
# and tests/test_weather_monitor.py's wrapper gate test, which drives the
# module's `__main__` entrypoint hermetically and asserts a real, non-hardcoded
# exit code.
#
# This is a standalone, single-poll health-check/manual-run path (for an
# external scheduler or a manual invocation), NOT how WeatherMonitor is meant
# to run continuously -- the station controller's own long-running process is
# expected to embed a WeatherMonitor instance directly as a background thread
# (see weather_monitor.py's module docstring; wiring that in is a later
# integration task).
#
# Install (manual, no launchd target added by this task):
#   scripts/wilted-weather-monitor.sh [--zone VAZ526] [--county VAC153] [--debug]
#
# Logs:
#   ~/Library/Logs/wilted-weather-monitor/wilted-weather-monitor.log                  (aggregate)
#   ~/Library/Logs/wilted-weather-monitor/wilted-weather-monitor-YYYYMMDD-HHMMSS.log  (per-run)

set -euo pipefail

LOCK_FILE="/tmp/wilted-weather-monitor.lock"
LOG_DIR="${HOME}/Library/Logs/wilted-weather-monitor"
AGG_LOG="${LOG_DIR}/wilted-weather-monitor.log"
RUN_LOG="${LOG_DIR}/wilted-weather-monitor-$(date '+%Y%m%d-%H%M%S').log"

# Resolve the project root — follow symlinks (mirrors wilted-nightly.sh).
REAL_SCRIPT="${BASH_SOURCE[0]}"
if [[ -L "$REAL_SCRIPT" ]]; then
    REAL_SCRIPT="$(readlink "$REAL_SCRIPT")"
fi
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export WILTED_PROJECT_ROOT="$PROJECT_ROOT"

# Keep the venv outside iCloud (~/Documents is iCloud-synced). See HISTORY.md.
export UV_PROJECT_ENVIRONMENT="${HOME}/.venvs/wilted"

WILTED_WEATHER_MONITOR="uv run --project ${PROJECT_ROOT} python -m wilted.station_runtime.weather_monitor"
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

log "START: weather monitor poll"
START_TIME=$(date +%s)

# --- Poll ---
if $WILTED_WEATHER_MONITOR "$@" >> "$RUN_LOG" 2>&1; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "completed successfully in ${ELAPSED}s"
else
    # Capture $? as the FIRST command in this branch, before anything else
    # (including arithmetic assignment) can overwrite it.
    EXIT_CODE=$?
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "failed with exit code ${EXIT_CODE} after ${ELAPSED}s"

    # Send failure notification if email-alert is available
    if [[ -x "$EMAIL_ALERT" ]]; then
        tail -20 "$RUN_LOG" | "$EMAIL_ALERT" \
            --subject "Wilted Weather Monitor Failed" 2>/dev/null || true
    fi
    exit "$EXIT_CODE"
fi
