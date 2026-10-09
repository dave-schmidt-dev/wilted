# shellcheck shell=bash
# Each worker owns its log, temporary parent, supervisor and result receipt.
# The parent alone aggregates receipts, including workers that died unexpectedly.
wilted_gate_parallel_pids=()
wilted_gate_parallel_names=()

wilted_gate_stop_parallel() {
  local pid
  for pid in "${wilted_gate_parallel_pids[@]:-}"; do
    [[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${wilted_gate_parallel_pids[@]:-}"; do
    [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
  done
  wilted_gate_parallel_pids=()
}

wilted_gate_parallel_worker() {
  trap - EXIT INT TERM HUP
  local name="$1" mode="$2" fn="$3" dependency="$4" dependency_pid="${5:-}"
  wilted_worker_result="$tmp_root/$1.result"
  completed_legs=0; failed_legs=0; deferred_legs=0; deferred_leg_names=()
  worker_cleanup() {
    local rc=$?
    trap - EXIT; trap '' INT TERM HUP
    wilted_stop_active_ui_lock
    wilted_stop_active_supervisor 300
    wilted_finish_logger || true
    # No registry is shared by parallel workers, and no worker deletes parent roots.
    if [[ ! -f "$wilted_worker_result" ]]; then printf '1 1 0\n' >"$wilted_worker_result"; fi
    exit "$rc"
  }
  trap worker_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if [[ -n "$dependency" ]]; then
    local waited=0
    while [[ ! -f "$tmp_root/$dependency.result" ]]; do
      if [[ -z "$dependency_pid" ]] || ! kill -0 "$dependency_pid" 2>/dev/null; then
        # A successful worker can publish its receipt between our file probe
        # and liveness check. Its authoritative receipt wins that race.
        [[ ! -f "$tmp_root/$dependency.result" ]] || break
        status "native.leg.complete name=$name status=1 reason=dependency-dead dependency=$dependency"
        printf '1 1 0\n' >"$wilted_worker_result.tmp"; mv "$wilted_worker_result.tmp" "$wilted_worker_result"
        exit 0
      fi
      (( waited % 15 != 0 )) || status "native.wait name=$name dependency=$dependency waited=${waited}s"
      sleep 1; waited=$((waited + 1))
    done
    local dependency_failed ignored ignored2
    read -r dependency_failed ignored ignored2 <"$tmp_root/$dependency.result"
    if [[ "$dependency_failed" != 0 ]]; then
      status "native.leg.complete name=$name status=1 reason=dependency-failed dependency=$dependency"
      printf '1 1 0\n' >"$wilted_worker_result.tmp"; mv "$wilted_worker_result.tmp" "$wilted_worker_result"
      exit 0
    fi
  fi
  run_leg "$name" "$mode" "$fn"
  printf '%s %s %s\n' "$failed_legs" "$completed_legs" "$deferred_legs" >"$wilted_worker_result.tmp"
  mv "$wilted_worker_result.tmp" "$wilted_worker_result"
}

wilted_gate_parallel_launch() {
  local name="$1" dependency="" dependency_pid="" i
  case "$name" in
    macos-*|ios-*|watchos-build) is_deferred_leg "$name" || dependency=xcodegen-reproducible ;;
  esac
  if [[ -n "$dependency" ]]; then
    for i in "${!wilted_gate_parallel_names[@]}"; do
      if [[ "${wilted_gate_parallel_names[$i]}" == "$dependency" ]]; then dependency_pid="${wilted_gate_parallel_pids[$i]}"; break; fi
    done
  fi
  wilted_gate_parallel_worker "$1" "$2" "$3" "$dependency" "$dependency_pid" &
  wilted_gate_parallel_pids+=("$!"); wilted_gate_parallel_names+=("$name")
}

wilted_gate_parallel_collect() {
  local i name rc failures count deferred
  for i in "${!wilted_gate_parallel_pids[@]}"; do
    name="${wilted_gate_parallel_names[$i]}"; rc=0
    wait "${wilted_gate_parallel_pids[$i]}" || rc=$?
    # wait has reaped this exact child. Publish a failed dependency receipt
    # even after SIGKILL, before a dependent can mistake the old PID for live.
    if [[ ! -f "$tmp_root/$name.result" ]]; then
      printf '1 1 0\n' >"$tmp_root/$name.result.parent-tmp"
      mv "$tmp_root/$name.result.parent-tmp" "$tmp_root/$name.result"
    fi
    wilted_gate_parallel_pids[$i]=""
    if [[ "$rc" != 0 || ! -f "$tmp_root/$name.result" ]]; then
      status "native.worker.failed name=$name status=$rc"
      failures=1; count=1; deferred=0
    else
      read -r failures count deferred <"$tmp_root/$name.result"
    fi
    failed_legs=$((failed_legs + failures)); completed_legs=$((completed_legs + count))
    deferred_legs=$((deferred_legs + deferred))
    [[ "$deferred" == 0 ]] || deferred_leg_names+=("$name")
  done
  wilted_gate_parallel_pids=()
}
