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
# shellcheck source=lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
# Phase 0 legs run in parallel and some mint their own wilted-* temp roots; a
# killed prior aggregate run leaves those behind with no trap left to run.
# Sweep before this run mints its own, same 24h cutoff so a genuinely
# concurrent phase-0 run's directories (minutes old) are never touched.
wilted_sweep_stale_temp_dirs
tmp_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-phase0.XXXXXX")"
phase0_self_test="${PHASE0_SELF_TEST:-0}"
bounded_runner="$repo_root/scripts/run-bounded.py"
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
  wilted_stop_active_supervisor
  stop_active_legs
  [[ -d "$tmp_root" ]] && rm -rf "$tmp_root"
}

trap cleanup_phase0 EXIT
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
  local pid=""
  local status=0

  mkdir -p "$leg_dir"
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

  python3 "$bounded_runner" --timeout-seconds "$phase0_leg_timeout_seconds" -- \
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
  done
}

run_leg_sync() {
  local name="$1"
  local script_path="$2"
  shift 2

  local leg_dir="$tmp_root/$name"
  local status=0
  local status_file="$leg_dir/status"

  mkdir -p "$leg_dir"
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
    wilted_start_supervisor python3 "$bounded_runner" --timeout-seconds "$phase0_leg_timeout_seconds" -- \
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
run_leg_async "assert-mac-first-docs" "$repo_root/scripts/assert-mac-first-docs.sh"
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
run_leg_async "test-git-hooks" "$repo_root/tests/test-git-hooks.sh"
run_leg_async "test-simulator-cleanup" "$repo_root/tests/test-simulator-cleanup.sh"
run_leg_async "test-native-ui-receipt" "$repo_root/tests/test-native-ui-receipt.sh"
run_leg_async "test-release-wrappers" "$repo_root/tests/test-release-wrappers.sh"
run_leg_async "test-file-size" "$repo_root/tests/test-file-size.sh"
if [[ -f "$repo_root/tests/test-audio-contract-ios-build.sh" ]]; then
  run_leg_async "test-audio-contract-ios-build" "$repo_root/tests/test-audio-contract-ios-build.sh"
fi
if [[ -f "$repo_root/tests/test-audio-budget-evidence.sh" ]]; then
  run_leg_async "test-audio-budget-evidence" "$repo_root/tests/test-audio-budget-evidence.sh"
fi

collect_parallel_legs

run_leg_sync "test-signed-speech-runtime" "$repo_root/tests/test-signed-speech-runtime.sh" \
  --harness "$repo_root/Probes/SignedSpeechRuntimeProbe/fake-speech-socket-harness.py"

print_leg_status "phase0.complete failed_legs=${failed_legs} total_legs=${total_legs}"
if (( failed_legs > 0 )); then
  print_leg_status "phase0.failed count=${failed_legs}"
  exit 1
fi
print_leg_status "phase0.passed count=${total_legs}"
