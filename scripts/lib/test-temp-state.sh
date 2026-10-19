#!/usr/bin/env bash
# Snapshot and audit a gate's inherited temporary root. Callers retain output
# under their already-owned root (or .logs) and never use this helper to sweep.

wilted_temp_snapshot() {
  local root="$1" output="$2"
  python3 "$WILTED_TEMP_LEAK_CHECKER" snapshot "$root" "$output"
}

wilted_temp_compare() {
  local before="$1" after="$2" label="$3"
  # $$ is the pid wilted_temp_mark_owned records, so only other live runs' roots are exempt.
  python3 "$WILTED_TEMP_LEAK_CHECKER" compare "$before" "$after" --label "$label" --owner-pid "$$"
}

wilted_temp_mark_owned() {
  local root="$1"
  local canonical_root started
  [[ -d "$root" && ! -L "$root" ]] || return 1
  canonical_root="$(cd -P "$root" 2>/dev/null && pwd)" || return 1
  [[ -n "$canonical_root" && -d "$canonical_root" && ! -L "$canonical_root" ]] || return 1
  started="$(ps -o lstart= -p "$$" 2>/dev/null)" || return 1
  printf 'pid=%s\nstarted=%s\npath=%s\n' "$$" "$started" "$canonical_root" >"$canonical_root/.wilted-temp-owned"
}

wilted_temp_owned_child() {
  local candidate="$1" parent="$2" prefix="$3" canonical="" canonical_parent=""
  [[ -n "$candidate" && -n "$parent" && -d "$candidate" && ! -L "$candidate" ]] || return 1
  canonical="$(cd -P "$candidate" 2>/dev/null && pwd)" || return 1
  [[ "$canonical" == "$candidate" ]] || return 1
  canonical_parent="$(cd -P "$canonical/.." 2>/dev/null && pwd)" || return 1
  [[ "$canonical_parent" == "$parent" && "$(basename -- "$canonical")" == "$prefix"* ]]
}

wilted_temp_remove_owned_child() {
  wilted_temp_owned_child "$1" "$2" "$3" || return 1
  rm -rf -- "$1"
}

wilted_temp_remove_owned_pair() {
  wilted_temp_remove_owned_child "$1" "$2" "$3" || true
  wilted_temp_remove_owned_child "$4" "$5" "$6" || true
}

wilted_temp_prepare_parent() {
  mkdir -p "$1" && cd -P "$1" 2>/dev/null && pwd
}

wilted_temp_save_output_streams() { exec 7>&1 8>&2; }

wilted_temp_restore_output_streams() { exec 1>&7 2>&8; }

wilted_temp_close_output_streams() { exec 7>&- 8>&-; }

wilted_temp_cleanup_native_gate() {
  local root="$1" parent="$2" audit="$3" audit_parent="$4"
  wilted_temp_restore_output_streams
  wilted_stop_active_ui_lock
  wilted_stop_active_supervisor
  wilted_finish_logger || true
  if declare -F wilted_gate_stop_parallel >/dev/null; then wilted_gate_stop_parallel; fi
  cleanup_mac_test_hosts
  wilted_temp_remove_owned_child "$root" "$parent" wilted-native-gate. || true
  wilted_temp_finish_audit "$parent" "$audit" "$audit/parent-before.json" native-parent "$audit_parent" native-temp-audit. || true
  wilted_temp_close_output_streams
}

wilted_temp_finish_audit() {
  local root="$1" audit="$2" before="$3" label="$4" parent="$5" prefix="$6" status=0
  wilted_temp_owned_child "$audit" "$parent" "$prefix" || return 1
  if [[ -f "$before" ]]; then
    wilted_temp_snapshot "$root" "$audit/parent-after.json" || status=1
    wilted_temp_compare "$before" "$audit/parent-after.json" "$label" || status=1
  fi
  wilted_temp_remove_owned_child "$audit" "$parent" "$prefix" || status=1
  return "$status"
}

wilted_temp_prepare_leg() {
  local container="$1" name="$2" root
  root="$container/legs/$name"
  WILTED_TEMP_LEG_WORK="$root/work"
  mkdir -p "$WILTED_TEMP_LEG_WORK"
  wilted_temp_snapshot "$WILTED_TEMP_LEG_WORK" "$root/before.json"
}

wilted_temp_audit_leg() {
  local container="$1" name="$2" root work
  root="$container/legs/$name"
  work="$root/work"
  wilted_temp_snapshot "$work" "$root/after.json" || return 1
  wilted_temp_compare "$root/before.json" "$root/after.json" "native-leg-$name"
}

_wilted_full_run_owned_dir() {
  local candidate="$1" expected="$2" canonical=""
  [[ -n "$candidate" && -n "$expected" && -d "$candidate" && ! -L "$candidate" ]] || return 1
  canonical="$(cd -P "$candidate" 2>/dev/null && pwd)" || return 1
  [[ "$canonical" == "$expected" ]]
}

_wilted_full_run_owned_audit() {
  local candidate="$1" expected_parent="$2" canonical=""
  [[ -n "$candidate" && -n "$expected_parent" && "$candidate" == "$expected_parent"/full-run-temp-audit.* ]] || return 1
  _wilted_full_run_owned_dir "$candidate" "$candidate" || return 1
  canonical="$(cd -P "$candidate/.." 2>/dev/null && pwd)" || return 1
  [[ "$canonical" == "$expected_parent" ]]
}

_wilted_full_run_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Read a lock's owner record into wilted_full_run_lock_pid and
# wilted_full_run_lock_started. Legacy locks carry only a bare first-line pid
# and therefore have no start time; malformed or vanished records fail.
_wilted_full_run_read_owner() {
  local file="$1" content="" first="" line="" pid="" started=""
  wilted_full_run_lock_pid=""
  wilted_full_run_lock_started=""
  [[ -f "$file" ]] || return 1
  content="$(cat "$file" 2>/dev/null)" || return 1
  first="${content%%$'\n'*}"
  if [[ "$first" =~ ^[1-9][0-9]*$ ]]; then
    wilted_full_run_lock_pid="$first"
    wilted_full_run_lock_started=""
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      pid=*) pid="${line#pid=}" ;;
      started=*) started="${line#started=}" ;;
    esac
  done <<<"$content"
  pid="$(_wilted_full_run_trim "$pid")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  wilted_full_run_lock_pid="$pid"
  wilted_full_run_lock_started="$(_wilted_full_run_trim "$started")"
  return 0
}

# Print a lock directory's age in seconds; fail when stat cannot report it.
_wilted_full_run_lock_age() {
  local lock="$1" mtime="" now=""
  if mtime="$(stat -f %m "$lock" 2>/dev/null)" && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    :
  elif mtime="$(stat -c %Y "$lock" 2>/dev/null)" && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    :
  else
    return 1
  fi
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$(( now - mtime ))"
}

# Best-effort owner and lock age for wait/timeout lines: never fatal.
_wilted_full_run_lock_snapshot() {
  local lock="$1" age=""
  wilted_full_run_wait_owner="unknown"
  wilted_full_run_wait_age="unknown"
  if [[ ! -e "$lock/pid" ]]; then
    wilted_full_run_wait_owner="none"
  elif _wilted_full_run_read_owner "$lock/pid"; then
    wilted_full_run_wait_owner="$wilted_full_run_lock_pid"
  fi
  if age="$(_wilted_full_run_lock_age "$lock" 2>/dev/null)"; then
    wilted_full_run_wait_age="${age}s"
  fi
}

_wilted_full_run_abandon_lock() {
  local lock="$1" recovery="$2"
  mv "$lock" "$recovery/abandoned" 2>/dev/null || [[ ! -e "$lock" ]] || return 1
  rm -rf -- "$recovery/abandoned" || return 1
  rmdir "$recovery"
}

_wilted_full_run_worker() {
  # This body is launched asynchronously below, which provides its subshell.
  # An additional function subshell would hide its trapped PID from the caller.
  # Bash 3.2 unwinds this function's locals before running its EXIT trap for
  # an asynchronous function. These globals live in the worker subshell until
  # that trap has completed; the parent shell cannot observe them.
  trap - EXIT INT TERM RETURN
  wilted_full_run_repo_input="$1"
  wilted_full_run_repo=""
  wilted_full_run_root=""
  wilted_full_run_audit=""
  wilted_full_run_audit_parent=""
  wilted_full_run_build=""
  wilted_full_run_lock=""
  wilted_full_run_runner=""
  wilted_full_run_lock_pid=""
  wilted_full_run_lock_started=""
  wilted_full_run_lock_probe=""
  wilted_full_run_lock_status=0
  wilted_full_run_lock_age=""
  wilted_full_run_lock_stale_reason=""
  # The owner writes its record immediately after mkdir, so a record-less lock
  # older than this belongs to a killed owner rather than a live one.
  wilted_full_run_lock_grace=10
  wilted_full_run_lock_timeout=5400
  wilted_full_run_owner_pid=""
  wilted_full_run_owner_started=""
  wilted_full_run_wait_started=0
  wilted_full_run_wait_elapsed=0
  wilted_full_run_wait_next=0
  wilted_full_run_wait_owner=""
  wilted_full_run_wait_age=""
  wilted_full_run_supervisor=""
  wilted_full_run_lock_owned=0
  wilted_full_run_recovery_owned=0
  wilted_full_run_release_wait=0
  wilted_full_run_launching=0
  wilted_full_run_signal_status=0
  wilted_full_run_recovery=""
  shift
  cleanup_full_run() {
    local result=$? audit_status=0
    trap - EXIT
    trap '' INT TERM
    # The bounded supervisor reaps its complete tree before it returns. Never
    # delete a parent root or release the gate lock while that cleanup runs.
    if [[ -n "$wilted_full_run_supervisor" ]]; then
      kill -TERM "$wilted_full_run_supervisor" 2>/dev/null || true
      wait "$wilted_full_run_supervisor" 2>/dev/null || true
    fi
    if [[ -n "$wilted_full_run_audit" ]]; then
      if _wilted_full_run_owned_audit "$wilted_full_run_audit" "$wilted_full_run_audit_parent" && [[ -f "$wilted_full_run_audit/before.json" ]]; then
        wilted_temp_snapshot "$wilted_full_run_root" "$wilted_full_run_audit/after.json" || audit_status=1
        wilted_temp_compare "$wilted_full_run_audit/before.json" "$wilted_full_run_audit/after.json" full-validate || audit_status=1
      else
        audit_status=1
      fi
    fi
    if [[ "$wilted_full_run_lock_owned" == 1 ]]; then
      # Release under the recovery guard: an observer that is judging this lock stale holds the
      # guard from its pid read to its move, so it can never see the lock vanish (or be replaced
      # by a new owner's) in between. A guard stuck past 5 s belongs to a crashed observer, whose
      # waiters give up on their own, so release without it rather than hang.
      wilted_full_run_release_wait=0
      until mkdir "$wilted_full_run_recovery" 2>/dev/null; do
        (( ++wilted_full_run_release_wait <= 250 )) || break
        sleep .02
      done
      (( wilted_full_run_release_wait <= 250 )) && wilted_full_run_recovery_owned=1
      _wilted_full_run_owned_dir "$wilted_full_run_lock" "$wilted_full_run_repo/.build/full-run.lock" && rm -rf -- "$wilted_full_run_lock" || audit_status=1
    fi
    if [[ "$wilted_full_run_recovery_owned" == 1 ]]; then
      _wilted_full_run_owned_dir "$wilted_full_run_recovery" "$wilted_full_run_repo/.build/full-run.lock.recovery" && rm -rf -- "$wilted_full_run_recovery" || audit_status=1
    fi
    if [[ -n "$wilted_full_run_audit" ]]; then
      _wilted_full_run_owned_audit "$wilted_full_run_audit" "$wilted_full_run_audit_parent" && rm -rf -- "$wilted_full_run_audit" || audit_status=1
    fi
    (( audit_status == 0 )) || result=1
    exit "$result"
  }
  trap cleanup_full_run EXIT
  wilted_full_run_repo="$(cd -P "$wilted_full_run_repo_input" 2>/dev/null && pwd)" || exit 1
  wilted_full_run_root="${TMPDIR:?TMPDIR must be set}"
  trap 'wilted_full_run_signal_status=130; [[ "$wilted_full_run_launching" == 1 ]] || exit 130' INT
  trap 'wilted_full_run_signal_status=143; [[ "$wilted_full_run_launching" == 1 ]] || exit 143' TERM
  mkdir -p "$wilted_full_run_repo/.logs" "$wilted_full_run_repo/.build"
  wilted_full_run_build="$(cd -P "$wilted_full_run_repo/.build" 2>/dev/null && pwd)" || exit 1
  [[ "$wilted_full_run_build" == "$wilted_full_run_repo/.build" ]] || exit 1
  wilted_full_run_lock="$wilted_full_run_build/full-run.lock"
  wilted_full_run_recovery="$wilted_full_run_lock.recovery"
  # Bash 3.2 has no BASHPID; this reports this worker, even for a background call.
  wilted_full_run_owner_pid="$(exec sh -c 'echo "$PPID"')"
  wilted_full_run_owner_started="$(LC_ALL=C TZ=UTC0 /bin/ps -o lstart= -p "$wilted_full_run_owner_pid" 2>/dev/null)" || wilted_full_run_owner_started=""
  wilted_full_run_owner_started="$(_wilted_full_run_trim "$wilted_full_run_owner_started")"
  if [[ -z "$wilted_full_run_owner_started" ]]; then
    printf 'temp.full-run.error reason=owner-identity-unavailable\n' >&2
    exit 1
  fi
  until mkdir "$wilted_full_run_lock" 2>/dev/null; do
    if [[ -n "${WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS:-}" ]]; then
      [[ "$WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || exit 2
      wilted_full_run_lock_timeout="$WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS"
    fi
    if [[ "$wilted_full_run_wait_started" == 0 ]]; then
      wilted_full_run_wait_started="$(date +%s)"
      wilted_full_run_wait_next=0
    fi
    # Serialize stale recovery and re-read the owner under that guard. Two
    # observers of a dead PID must not delete a newly acquired live lock.
    if mkdir "$wilted_full_run_recovery" 2>/dev/null; then
      wilted_full_run_recovery_owned=1
      _wilted_full_run_owned_dir "$wilted_full_run_recovery" "$wilted_full_run_repo/.build/full-run.lock.recovery" || exit 1
      if [[ ! -d "$wilted_full_run_lock" ]]; then
        # The owner released it before this observer took the guard: acquire at once.
        rmdir "$wilted_full_run_recovery" || exit 1
        wilted_full_run_recovery_owned=0
        continue
      fi
      wilted_full_run_lock_stale_reason=""
      if [[ -f "$wilted_full_run_lock/pid" ]]; then
        _wilted_full_run_read_owner "$wilted_full_run_lock/pid" || exit 1
        if wilted_full_run_lock_probe="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$wilted_full_run_lock_pid" 2>&1)"; then wilted_full_run_lock_status=0; else wilted_full_run_lock_status=$?; fi
        if (( wilted_full_run_lock_status == 1 )); then
          # Gone already means an unguarded release (guard stuck past its 5 s bound) beat us to it.
          wilted_full_run_lock_stale_reason="owner-exited"
        elif (( wilted_full_run_lock_status != 0 )); then
          exit 1
        elif [[ -z "$wilted_full_run_lock_probe" ]]; then
          exit 1
        elif [[ -n "$wilted_full_run_lock_started" ]]; then
          wilted_full_run_lock_probe="$(_wilted_full_run_trim "$wilted_full_run_lock_probe")"
          if [[ "$wilted_full_run_lock_probe" != "$wilted_full_run_lock_started" ]]; then
            wilted_full_run_lock_stale_reason="recycled-pid"
          fi
        fi
      elif wilted_full_run_lock_age="$(_wilted_full_run_lock_age "$wilted_full_run_lock" 2>/dev/null)"; then
        if (( wilted_full_run_lock_age >= wilted_full_run_lock_grace )); then
          wilted_full_run_lock_stale_reason="no-owner-record"
        fi
      fi
      if [[ -n "$wilted_full_run_lock_stale_reason" ]]; then
        if [[ "$wilted_full_run_lock_stale_reason" == "no-owner-record" ]]; then
          printf 'temp.full-run.stale reason=no-owner-record lock_age=%ss\n' "$wilted_full_run_lock_age" >&2
        else
          printf 'temp.full-run.stale reason=%s owner_pid=%s\n' "$wilted_full_run_lock_stale_reason" "$wilted_full_run_lock_pid" >&2
        fi
        _wilted_full_run_abandon_lock "$wilted_full_run_lock" "$wilted_full_run_recovery" || exit 1
        wilted_full_run_recovery_owned=0
        continue
      fi
      rmdir "$wilted_full_run_recovery"
      wilted_full_run_recovery_owned=0
    fi
    wilted_full_run_wait_elapsed=$(( $(date +%s) - wilted_full_run_wait_started ))
    _wilted_full_run_lock_snapshot "$wilted_full_run_lock"
    if (( wilted_full_run_wait_elapsed >= wilted_full_run_lock_timeout )); then
      printf 'temp.full-run.timeout waited=%ss owner_pid=%s lock_age=%s limit=%ss remedy="wait for the run holding .build/full-run.lock or raise WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS"\n' \
        "$wilted_full_run_wait_elapsed" "$wilted_full_run_wait_owner" "$wilted_full_run_wait_age" "$wilted_full_run_lock_timeout" >&2
      exit 1
    fi
    if (( wilted_full_run_wait_elapsed == 0 || wilted_full_run_wait_elapsed >= wilted_full_run_wait_next )); then
      printf 'temp.full-run.wait seconds=%s owner_pid=%s lock_age=%s limit=%ss raise=WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS\n' \
        "$wilted_full_run_wait_elapsed" "$wilted_full_run_wait_owner" "$wilted_full_run_wait_age" "$wilted_full_run_lock_timeout" >&2
      wilted_full_run_wait_next=$(( wilted_full_run_wait_elapsed + 10 ))
    fi
    sleep 1
  done
  wilted_full_run_lock_owned=1
  # Write the record atomically so an observer never reads an empty pid file.
  printf 'pid=%s\nstarted=%s\n' "$wilted_full_run_owner_pid" "$wilted_full_run_owner_started" >"$wilted_full_run_lock/pid.tmp" || exit 1
  mv -f "$wilted_full_run_lock/pid.tmp" "$wilted_full_run_lock/pid" || exit 1
  wilted_full_run_audit_parent="$(cd -P "$wilted_full_run_repo/.logs" 2>/dev/null && pwd)" || exit 1
  wilted_full_run_audit="$(mktemp -d "$wilted_full_run_audit_parent/full-run-temp-audit.XXXXXX")" || exit 1
  wilted_full_run_audit="$(cd -P "$wilted_full_run_audit" 2>/dev/null && pwd)" || exit 1
  _wilted_full_run_owned_audit "$wilted_full_run_audit" "$wilted_full_run_audit_parent" || exit 1
  wilted_temp_snapshot "$wilted_full_run_root" "$wilted_full_run_audit/before.json" || exit 1
  wilted_full_run_runner="$wilted_full_run_repo/scripts/run-bounded.py"
  [[ -f "$wilted_full_run_runner" ]] || exit 1
  wilted_full_run_launching=1
  local budget_args=(--no-timeout)
  if [[ -n "${WILTED_FULL_RUN_TIMEOUT_SECONDS:-}" ]]; then budget_args=(--timeout-seconds "$WILTED_FULL_RUN_TIMEOUT_SECONDS"); fi
  WILTED_FULL_RUN_LOCK_HELD=1 python3 "$wilted_full_run_runner" "${budget_args[@]}" -- "$@" &
  wilted_full_run_supervisor=$!
  wilted_full_run_launching=0
  (( wilted_full_run_signal_status == 0 )) || exit "$wilted_full_run_signal_status"
  local status=0
  if wait "$wilted_full_run_supervisor"; then status=0; else status=$?; fi
  wilted_full_run_supervisor=""
  exit "$status"
}

wilted_full_run() {
  if [[ "${WILTED_FULL_RUN_LOCK_HELD:-0}" == "1" ]]; then shift; "$@"; return $?; fi
  local worker="" status=0 signal_name="" signal_status=0 caller_pid
  local saved_int saved_term
  saved_int="$(trap -p INT)"
  saved_term="$(trap -p TERM)"
  caller_pid="$(exec sh -c 'echo "$PPID"')"
  # Record a signal even in the small launch window, then forward it once the
  # isolated worker PID is known. EXIT and RETURN remain the caller's traps.
  [[ "$saved_int" == "trap -- '' SIGINT" ]] || trap '[[ -n "$signal_name" ]] || { signal_name=INT; signal_status=130; }; [[ -z "$worker" ]] || kill -TERM "$worker" 2>/dev/null || true' INT
  [[ "$saved_term" == "trap -- '' SIGTERM" ]] || trap '[[ -n "$signal_name" ]] || { signal_name=TERM; signal_status=143; }; [[ -z "$worker" ]] || kill -TERM "$worker" 2>/dev/null || true' TERM
  _wilted_full_run_worker "$@" &
  worker=$!
  [[ -z "$signal_name" ]] || kill -TERM "$worker" 2>/dev/null || true
  if wait "$worker"; then status=0; else status=$?; fi
  if [[ -n "$signal_name" ]]; then
    # A trapped signal interrupts wait before the worker's EXIT cleanup ends.
    while :; do
      if wait "$worker"; then status=0; else status=$?; fi
      kill -0 "$worker" 2>/dev/null || break
    done
    [[ "$status" -eq 1 ]] || status="$signal_status"
  fi
  trap - INT TERM
  [[ -z "$saved_int" ]] || eval "$saved_int"
  [[ -z "$saved_term" ]] || eval "$saved_term"
  # Deliver the original signal only after the group, audits and lock cleanup.
  # The caller's handler (or default action) then runs in its original shell.
  [[ -z "$signal_name" || "$status" -eq 1 ]] || kill -s "$signal_name" "$caller_pid"
  return "$status"
}
