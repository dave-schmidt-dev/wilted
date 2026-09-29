#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test-runner.sh
source "$repo_root/scripts/lib/test-runner.sh"
WILTED_TEMP_LEAK_CHECKER="${WILTED_TEMP_LEAK_CHECKER:-$repo_root/scripts/check-temp-leaks.py}"
# shellcheck source=lib/test-temp-state.sh
source "$repo_root/scripts/lib/test-temp-state.sh"
# shellcheck source=lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
inherited_tmp="$(cd -P "${TMPDIR:?TMPDIR must be set}" 2>/dev/null && pwd)" || exit 1
audit_parent_input="${WILTED_PHASE0_TEMP_AUDIT_PARENT:-$repo_root/.logs}"
mkdir -p "$audit_parent_input"
audit_parent="$(cd -P "$audit_parent_input" 2>/dev/null && pwd)" || exit 1
audit_root="$(mktemp -d "$audit_parent/phase0-temp-audit.XXXXXX")" || exit 1
tmp_root=""

cleanup_phase0_initialization() {
  trap - EXIT INT TERM HUP
  wilted_temp_remove_owned_pair "$tmp_root" "$inherited_tmp" wilted-phase0. "$audit_root" "$audit_parent" phase0-temp-audit.
}

trap 'status=$?; cleanup_phase0_initialization; exit "$status"' EXIT
trap 'cleanup_phase0_initialization; exit 130' INT
trap 'cleanup_phase0_initialization; exit 143' TERM
trap 'cleanup_phase0_initialization; exit 129' HUP
wilted_temp_snapshot "$inherited_tmp" "$audit_root/parent-before.json"
wilted_sweep_stale_temp_dirs
tmp_root="$(mktemp -d "$inherited_tmp/wilted-phase0.XXXXXX")"
wilted_temp_mark_owned "$tmp_root"
phase0_self_test="${PHASE0_SELF_TEST:-0}"
bounded_runner="${WILTED_BOUNDED_RUNNER:-$repo_root/scripts/run-bounded.py}"
phase0_leg_timeout_seconds="${PHASE0_LEG_TIMEOUT_SECONDS:-1800}"
if [[ ! -d "$tmp_root" ]]; then
  printf '%s\n' 'error: unable to create validated phase-0 temp directory' >&2
  exit 1
fi
[[ -f "$bounded_runner" ]] || {
  printf 'error: bounded runner is missing: %s\n' "$bounded_runner" >&2
  exit 127
}
[[ "$phase0_leg_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  printf 'error: PHASE0_LEG_TIMEOUT_SECONDS must be a positive integer\n' >&2
  exit 2
}

forced_fail_leg="${PHASE0_FORCE_FAIL_LEG:-}"

declare -a leg_names=()
declare -a leg_pids=()
declare -a leg_dirs=()
declare -i failed_legs=0
declare -i total_legs=0

stop_active_legs() {
  local i pid
  for pid in "${leg_pids[@]:-}"; do
    wilted_signal_supervisor_pid "$pid"
  done
  for i in "${!leg_pids[@]}"; do
    pid="${leg_pids[$i]}"
    wilted_reap_supervisor_pid "$pid"
    leg_pids[$i]=""
  done
}

cleanup_phase0() {
  local status=$?
  trap - EXIT INT TERM HUP
  wilted_stop_active_supervisor
  stop_active_legs
  wilted_temp_remove_owned_child "$tmp_root" "$inherited_tmp" wilted-phase0. || true
  tmp_root=""
  wilted_temp_finish_audit "$inherited_tmp" "$audit_root" "$audit_root/parent-before.json" phase0-parent "$audit_parent" phase0-temp-audit. || true
  audit_root=""
  return "$status"
}

verify_parent_temp_audit() {
  wilted_temp_remove_owned_child "$tmp_root" "$inherited_tmp" wilted-phase0. || return 1
  tmp_root=""
  wilted_temp_snapshot "$inherited_tmp" "$audit_root/parent-after.json"
  wilted_temp_compare "$audit_root/parent-before.json" "$audit_root/parent-after.json" phase0-parent
}

trap 'status=$?; cleanup_phase0; exit "$status"' EXIT
trap 'cleanup_phase0; exit 130' INT
trap 'cleanup_phase0; exit 143' TERM
trap 'cleanup_phase0; exit 129' HUP

is_forced_fail_leg() {
  [[ "${forced_fail_leg}" == "$1" ]]
}

print_leg_status() {
  printf '%s\n' "$1" >&2
}

record_leg_failure() {
  local name="$1"
  local leg_dir="$2"
  local status="$3"

  if [[ "$status" != "0" ]]; then
    printf '%s\n' "phase0.leg.failed name=$name status=$status" >&2
    printf '%s\n' "--- $name failure detail ---" >&2
    if [[ -f "$leg_dir/stderr.log" ]]; then
      cat "$leg_dir/stderr.log" >&2 || true
    fi
    if [[ -f "$leg_dir/stdout.log" ]]; then
      cat "$leg_dir/stdout.log" >&2 || true
    fi
    if [[ -f "$leg_dir/reason" ]]; then
      cat "$leg_dir/reason" >&2 || true
    fi
  fi
}

run_leg_async() {
  local name="$1"
  local script_path="$2"
  local idx="${#leg_names[@]}"
  local leg_dir="$tmp_root/$name"
  local leg_tmp="$leg_dir/work"
  local pid=""
  local status=0

  mkdir -p "$leg_dir"
  mkdir -p "$leg_tmp"
  wilted_temp_snapshot "$leg_tmp" "$leg_dir/before.json"
  leg_names[idx]="$name"
  leg_dirs[idx]="$leg_dir"

  print_leg_status "phase0.leg.start name=$name"

  if [[ ! -f "$script_path" ]]; then
    status=127
    leg_pids[idx]=""
    printf '%s\n' "$status" >"$leg_dir/status"
    printf '%s\n' "missing_script=$script_path" >"$leg_dir/reason"
    print_leg_status "phase0.leg.complete name=$name status=$status reason=missing-script"
    ((total_legs += 1))
    return
  fi

  if is_forced_fail_leg "$name"; then
    status=1
    leg_pids[idx]=""
    printf '%s\n' "$status" >"$leg_dir/status"
    printf '%s\n' "forced_self_test_failure" >"$leg_dir/reason"
    print_leg_status "phase0.leg.complete name=$name status=$status reason=self-test-forced-failure"
    ((total_legs += 1))
    return
  fi

  if [[ "$phase0_self_test" == "1" ]]; then
    status=0
    leg_pids[idx]=""
    printf '%s\n' "$status" >"$leg_dir/status"
    print_leg_status "phase0.leg.complete name=$name status=$status reason=self-test-skipped"
    ((total_legs += 1))
    return
  fi

  env TMPDIR="$leg_tmp" python3 "$bounded_runner" --timeout-seconds "$phase0_leg_timeout_seconds" -- \
    bash "$script_path" >"$leg_dir/stdout.log" 2>"$leg_dir/stderr.log" &
  pid=$!

  leg_pids[idx]="$pid"
  ((total_legs += 1))
}

collect_parallel_legs() {
  local i
  local wait_status=0
  for i in "${!leg_pids[@]}"; do
    local pid="${leg_pids[$i]}"
    local name="${leg_names[$i]}"
    local leg_dir="${leg_dirs[$i]}"
    local status

    if [[ -n "$pid" ]]; then
      set +e
      wait "$pid"
      wait_status=$?
      set -e
      leg_pids[$i]=""
      status="$wait_status"
      printf '%s\n' "$status" > "$leg_dir/status"
      printf 'phase0.leg.complete name=%s status=%s\n' "$name" "$status" >&2
    elif [[ -f "$leg_dir/status" ]]; then
      status="$(cat "$leg_dir/status")"
    else
      status=1
      printf '%s\n' "phase0.leg.complete name=$name status=$status reason=missing-status-file" >&2
      printf '%s\n' "$status" > "$leg_dir/status"
    fi

    if [[ "$status" != "0" ]]; then
      ((failed_legs += 1))
      record_leg_failure "$name" "$leg_dir" "$status"
    fi
    wilted_temp_snapshot "$leg_dir/work" "$leg_dir/after.json" || status=1
    if ! wilted_temp_compare "$leg_dir/before.json" "$leg_dir/after.json" "phase0-leg-$name"; then
      status=1
      ((failed_legs += 1))
    fi
  done
}

run_leg_sync() {
  local name="$1"
  local script_path="$2"
  shift 2

  local leg_dir="$tmp_root/$name"
  local leg_tmp="$leg_dir/work"
  local status=0
  local status_file="$leg_dir/status"

  mkdir -p "$leg_dir"
  mkdir -p "$leg_tmp"
  wilted_temp_snapshot "$leg_tmp" "$leg_dir/before.json"
  ((total_legs += 1))

  print_leg_status "phase0.leg.start name=$name"

  if [[ ! -f "$script_path" ]]; then
    status=127
  elif is_forced_fail_leg "$name"; then
    status=1
    printf '%s\n' "forced_self_test_failure" >"$leg_dir/reason"
  elif [[ "$phase0_self_test" == "1" ]]; then
    status=0
  else
    wilted_start_supervisor env TMPDIR="$leg_tmp" python3 "$bounded_runner" --timeout-seconds "$phase0_leg_timeout_seconds" -- \
      bash "$script_path" "$@" >"$leg_dir/stdout.log" 2>"$leg_dir/stderr.log"
    set +e
    wilted_wait_active_supervisor
    status=$?
    set -e
  fi

  printf '%s\n' "$status" > "$status_file"
  if [[ "$status" == "0" ]]; then
    print_leg_status "phase0.leg.complete name=$name status=$status"
  elif is_forced_fail_leg "$name"; then
    print_leg_status "phase0.leg.complete name=$name status=$status reason=self-test-forced-failure"
  elif [[ ! -f "$script_path" ]]; then
    print_leg_status "phase0.leg.complete name=$name status=$status reason=missing-script"
  else
    print_leg_status "phase0.leg.complete name=$name status=$status"
  fi

  if [[ "$status" != "0" ]]; then
    ((failed_legs += 1))
    record_leg_failure "$name" "$leg_dir" "$status"
  fi
  wilted_temp_snapshot "$leg_tmp" "$leg_dir/after.json" || status=1
  if ! wilted_temp_compare "$leg_dir/before.json" "$leg_dir/after.json" "phase0-leg-$name"; then
    status=1
    ((failed_legs += 1))
  fi
}

if [[ -n "${PHASE0_INTERRUPT_TEST_LEG:-}" ]]; then
  case "${PHASE0_INTERRUPT_TEST_MODE:-}" in
    async) run_leg_async "interrupt-fixture" "$PHASE0_INTERRUPT_TEST_LEG" ;;
    sync) run_leg_sync "interrupt-fixture" "$PHASE0_INTERRUPT_TEST_LEG" ;;
    *)
      printf '%s\n' 'error: PHASE0_INTERRUPT_TEST_MODE must be async or sync' >&2
      exit 2
      ;;
  esac
  collect_parallel_legs
  exit "$failed_legs"
fi

run_leg_async "test-build-with-cache" "$repo_root/tests/test-build-with-cache.sh"
run_leg_async "test-bounded-entry" "$repo_root/tests/test-bounded-entry.sh"
run_leg_async "test-no-global-tmp" "$repo_root/tests/test-no-global-tmp.sh"
run_leg_async "assert-mac-first-docs" "$repo_root/tests/test-mac-first-docs.sh"
run_leg_async "test-contract-fixtures" "$repo_root/tests/test-contract-fixtures.sh"
run_leg_async "test-domain-contract" "$repo_root/tests/test-domain-contract.sh"
run_leg_async "test-cloudkit-contract" "$repo_root/tests/test-cloudkit-contract.sh"
run_leg_async "test-article-extraction-probe" "$repo_root/tests/test-article-extraction-probe.sh"
run_leg_async "test-speech-ipc-probe" "$repo_root/tests/test-speech-ipc-probe.sh"
run_leg_async "test-persistence-probe" "$repo_root/tests/test-persistence-probe.sh"
run_leg_async "test-audio-contract-probe" "$repo_root/tests/test-audio-contract-probe.sh"
run_leg_async "test-audit-walkthrough" "$repo_root/tests/test-audit-walkthrough.sh"
run_leg_async "test-pipeline-worker" "$repo_root/tests/test-pipeline-worker.sh"
run_leg_async "test-preparation-runtime" "$repo_root/tests/test-preparation-runtime.sh"
run_leg_async "test-install-mac-app" "$repo_root/tests/test-install-mac-app.sh"
run_leg_async "test-temp-sweep" "$repo_root/tests/test-temp-sweep.sh"
run_leg_async "test-storage-retention" "$repo_root/tests/test-storage-retention.sh"
run_leg_async "test-temp-leaks" "$repo_root/tests/test-temp-leaks.sh"
run_leg_async "test-git-hooks" "$repo_root/tests/test-git-hooks.sh"
run_leg_async "test-simulator-cleanup" "$repo_root/tests/test-simulator-cleanup.sh"
run_leg_async "test-native-ui-receipt" "$repo_root/tests/test-native-ui-receipt.sh"
run_leg_async "test-release-wrappers" "$repo_root/tests/test-release-wrappers.sh"
run_leg_async "test-file-size" "$repo_root/tests/test-file-size.sh"
run_leg_async "test-attended-library-sync" "$repo_root/tests/test-attended-library-sync.sh"
if [[ -f "$repo_root/tests/test-audio-contract-ios-build.sh" ]]; then
  run_leg_async "test-audio-contract-ios-build" "$repo_root/tests/test-audio-contract-ios-build.sh"
fi
if [[ -f "$repo_root/tests/test-audio-budget-evidence.sh" ]]; then
  run_leg_async "test-audio-budget-evidence" "$repo_root/tests/test-audio-budget-evidence.sh"
fi

collect_parallel_legs

run_leg_sync "test-signed-speech-runtime" "$repo_root/tests/test-signed-speech-runtime.sh" \
  --harness "$repo_root/Probes/SignedSpeechRuntimeProbe/fake-speech-socket-harness.py"

verify_parent_temp_audit

print_leg_status "phase0.complete failed_legs=${failed_legs} total_legs=${total_legs}"
if (( failed_legs > 0 )); then
  print_leg_status "phase0.failed count=${failed_legs}"
  exit 1
fi
print_leg_status "phase0.passed count=${total_legs}"
