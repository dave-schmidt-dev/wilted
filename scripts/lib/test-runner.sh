#!/usr/bin/env bash
# Shared entry boundary for test and gate scripts.  The marker prevents the
# helper's child shell from recursively supervising itself.

WILTED_ACTIVE_SUPERVISOR_PID=""
WILTED_ACTIVE_LOGGER_PID=""
WILTED_ACTIVE_LOGGER_OPEN=0
WILTED_UI_LOCK_PID_FILE=""

wilted_start_supervisor() {
  "$@" &
  WILTED_ACTIVE_SUPERVISOR_PID="$!"
}

wilted_wait_active_supervisor() {
  local pid="${WILTED_ACTIVE_SUPERVISOR_PID:-}"
  local result=0
  [[ -n "$pid" ]] || return 0
  if wait "$pid"; then
    result=0
  else
    result=$?
  fi
  WILTED_ACTIVE_SUPERVISOR_PID=""
  return "$result"
}

wilted_signal_supervisor_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
}

wilted_reap_supervisor_pid() {
  local pid="$1" timeout_seconds="${2:-5}" attempt attempts
  [[ -n "$pid" ]] || return 0
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=5
  attempts=$((timeout_seconds * 10))
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf 'bounded supervisor cleanup deadline exceeded pid=%s seconds=%s\n' "$pid" "$timeout_seconds" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

wilted_stop_supervisor_pid() {
  wilted_signal_supervisor_pid "$1"
  wilted_reap_supervisor_pid "$1" "${2:-5}"
}

wilted_stop_active_supervisor() {
  local pid="${WILTED_ACTIVE_SUPERVISOR_PID:-}"
  WILTED_ACTIVE_SUPERVISOR_PID=""
  wilted_stop_supervisor_pid "$pid" "${1:-5}"
}

wilted_stop_active_ui_lock() {
  local lock_pid="" pid="${WILTED_ACTIVE_SUPERVISOR_PID:-}" timeout_seconds attempt attempts
  [[ -n "$WILTED_UI_LOCK_PID_FILE" ]] || return 0
  timeout_seconds="${WILTED_UI_LOCK_CLEANUP_TIMEOUT_SECONDS:-300}"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=300
  attempts=$((timeout_seconds * 10))
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    if [[ -s "$WILTED_UI_LOCK_PID_FILE" ]]; then
      lock_pid="$(cat "$WILTED_UI_LOCK_PID_FILE")"
      [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && break
      lock_pid=""
    fi
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      WILTED_ACTIVE_SUPERVISOR_PID=""
      WILTED_UI_LOCK_PID_FILE=""
      return 0
    fi
    sleep 0.1
  done
  if [[ -n "$lock_pid" ]]; then
    wilted_signal_supervisor_pid "$lock_pid"
  else
    printf 'UI lock PID publication deadline exceeded pid=%s seconds=%s\n' "$pid" "$timeout_seconds" >&2
    wilted_signal_supervisor_pid "$pid"
  fi
  WILTED_ACTIVE_SUPERVISOR_PID=""
  wilted_reap_supervisor_pid "$pid" "$timeout_seconds"
  WILTED_UI_LOCK_PID_FILE=""
}

wilted_start_logger() {
  local output_file="$1" stream_file="$2"
  mkfifo "$stream_file"
  tee "$output_file" <"$stream_file" >&2 &
  WILTED_ACTIVE_LOGGER_PID=$!
  exec 9>"$stream_file"
  WILTED_ACTIVE_LOGGER_OPEN=1
  rm -f "$stream_file"
}

wilted_finish_logger() {
  local result=0 attempt
  if [[ "$WILTED_ACTIVE_LOGGER_OPEN" == "1" ]]; then
    exec 9>&-
    WILTED_ACTIVE_LOGGER_OPEN=0
  fi
  if [[ -n "$WILTED_ACTIVE_LOGGER_PID" ]]; then
    for ((attempt = 0; attempt < 50; attempt += 1)); do
      ! kill -0 "$WILTED_ACTIVE_LOGGER_PID" 2>/dev/null && break
      sleep 0.1
    done
    if kill -0 "$WILTED_ACTIVE_LOGGER_PID" 2>/dev/null; then
      kill -TERM "$WILTED_ACTIVE_LOGGER_PID" 2>/dev/null || true
      sleep 0.1
      kill -KILL "$WILTED_ACTIVE_LOGGER_PID" 2>/dev/null || true
    fi
    wait "$WILTED_ACTIVE_LOGGER_PID" || result=$?
    WILTED_ACTIVE_LOGGER_PID=""
  fi
  return "$result"
}

wilted_run_ui_lock_fixture() {
  local command="$1"
  GATE_UI_TEST_LOCK_PID_FILE="$WILTED_UI_LOCK_PID_FILE" gate_ui_test_lock --label 'interrupt-fixture' \
    bash "$command" &
  WILTED_ACTIVE_SUPERVISOR_PID=$!
  wilted_wait_active_supervisor
  WILTED_UI_LOCK_PID_FILE=""
}

wilted_reexec_bounded() {
  local entrypoint="$1"
  shift
  local repo_root runner timeout_seconds

  [[ "${WILTED_BOUNDED_ENTRY:-0}" == "1" ]] && return 0
  repo_root="$(cd "$(dirname "$entrypoint")/.." && pwd)"
  runner="$repo_root/scripts/run-bounded.py"
  timeout_seconds="${WILTED_TEST_RUNNER_TIMEOUT_SECONDS:-1800}"
  [[ -f "$runner" ]] || {
    printf 'error: bounded runner is missing: %s\n' "$runner" >&2
    exit 127
  }
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
    printf 'error: WILTED_TEST_RUNNER_TIMEOUT_SECONDS must be a positive integer\n' >&2
    exit 2
  }

  local budget_args=(--timeout-seconds "$timeout_seconds")
  # Gates coordinate queues; each executable has its own work budget.
  if [[ "$(basename "$entrypoint")" == test-gate.sh && -z "${WILTED_TEST_RUNNER_TIMEOUT_SECONDS:-}" ]]; then budget_args=(--no-timeout); fi
  exec env WILTED_BOUNDED_ENTRY=1 \
    python3 "$runner" "${budget_args[@]}" -- bash "$entrypoint" "$@"
}

# Bash 3 shares xtrace and stderr. Trace source locations only, leaving command
# arguments (which can hold credentials) out of both the trace and the stream.
wilted_debug_leg() {
  local PS4='+ ' trace_dir="$repo_root/.logs/gate-debug"
  mkdir -p "$trace_dir" || return 1
  local trace_log
  trace_log="$(mktemp "$trace_dir/$name.XXXXXX")" || return 1
  wilted_trace_locations "$@" 6>>"$trace_log"
}

wilted_trace_locations() {
  set -T
  trap '{ set -x; : "${BASH_SOURCE[0]##*/}:${LINENO} ${FUNCNAME[0]}"; set +x; } 2>&6' DEBUG
  local rc=0
  "$@" || rc=$?
  trap - DEBUG
  set +T
  return "$rc"
}

# Print one host-state line before a hosted leg and refuse the leg, recording it
# as a failed preflight (the gate then exits 2), when a Touch ID prompt is pending
# or another Wilted hosted run is live. Returns 1 when the leg was refused.
wilted_host_state_preflight() {
  local name="$1" refused=0
  if [[ "${WILTED_HOST_STATE_CHECK:-1}" != 0 && ( "$native_self_test" != 1 || -n "${WILTED_HOST_STATE_PS:-}" ) ]]; then
    TMPDIR="$WILTED_TEMP_LEG_WORK" python3 "$repo_root/scripts/lib/host-state.py" "$name" "$$" || refused=$?
  fi
  [[ "$refused" -ne 0 ]] || return 0
  : >"$native_audit_root/preflight-refused"
  wilted_temp_audit_leg "$tmp_root" "$name" || true
  failed_legs=$((failed_legs + 1)); completed_legs=$((completed_legs + 1))
  status "native.leg.complete name=$name status=$refused reason=preflight-refused"
  return 1
}
