#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-phase0.XXXXXX")"
phase0_self_test="${PHASE0_SELF_TEST:-0}"
if [[ ! -d "$tmp_root" ]]; then
  printf '%s\n' 'error: unable to create validated phase-0 temp directory' >&2
  exit 1
fi
trap '[[ -d "$tmp_root" ]] && rm -rf "$tmp_root"' EXIT

forced_fail_leg="${PHASE0_FORCE_FAIL_LEG:-}"

declare -a leg_names=()
declare -a leg_pids=()
declare -a leg_dirs=()
declare -i failed_legs=0
declare -i total_legs=0

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

  (
    set +e
    bash "$script_path" >"$leg_dir/stdout.log" 2>"$leg_dir/stderr.log"
    status=$?
    set -e
    printf '%s\n' "$status" >"$leg_dir/status"
    printf 'phase0.leg.complete name=%s status=%s\n' "$name" "$status" >&2
  ) &
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
      if (( wait_status != 0 )); then
        :
      fi
    else
      wait_status=0
    fi

    if [[ -f "$leg_dir/status" ]]; then
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
  local args=("$@")

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
    set +e
    bash "$script_path" "${args[@]}" >"$leg_dir/stdout.log" 2>"$leg_dir/stderr.log"
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
run_leg_async "test-install-mac-app" "$repo_root/tests/test-install-mac-app.sh"
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
