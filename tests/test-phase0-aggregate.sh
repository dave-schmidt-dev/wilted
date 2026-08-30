#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
phase0_script="$repo_root/scripts/test-phase0.sh"

expected_legs=(
  "assert-mac-first-docs"
  "test-contract-fixtures"
  "test-domain-contract"
  "test-cloudkit-contract"
  "test-article-extraction-probe"
  "test-speech-ipc-probe"
  "test-persistence-probe"
  "test-audio-contract-probe"
)
if [[ -f "$repo_root/tests/test-audio-contract-ios-build.sh" ]]; then
  expected_legs+=("test-audio-contract-ios-build")
fi
if [[ -f "$repo_root/tests/test-audio-budget-evidence.sh" ]]; then
  expected_legs+=("test-audio-budget-evidence")
fi
expected_legs+=("test-signed-speech-runtime")

expected_count="${#expected_legs[@]}"

run_phase0_self_test() {
  local output_file="$1"
  local force_leg="$2"

  set +e
  if [[ -n "$force_leg" ]]; then
    PHASE0_SELF_TEST=1 PHASE0_FORCE_FAIL_LEG="$force_leg" bash "$phase0_script" >"$output_file" 2>&1
  else
    PHASE0_SELF_TEST=1 bash "$phase0_script" >"$output_file" 2>&1
  fi
  local status=$?
  set -e
  printf '%s\n' "$status"
}

run_and_capture() {
  local label="$1"
  local output_file="$2"
  local status="$3"
  printf '%s\n' "meta-test[$label] status=$status"
  if [[ "$status" -ne 0 ]]; then
    cat "$output_file" >&2
  fi
}

assert_zero_exit() {
  local status="$1"
  local label="$2"
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "assertion failed: $label expected exit 0, got $status" >&2
    exit 1
  fi
}

assert_nonzero_exit() {
  local status="$1"
  local label="$2"
  if [[ "$status" -eq 0 ]]; then
    printf '%s\n' "assertion failed: $label expected nonzero exit" >&2
    exit 1
  fi
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  if ! grep -Fq "$pattern" "$file"; then
    printf '%s\n' "assertion failed: missing pattern '$pattern'" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_contains 'run_leg_async "assert-mac-first-docs" "$repo_root/scripts/assert-mac-first-docs.sh"' "$phase0_script"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wilted-phase0-agg.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

base_output="$tmp_dir/selftest.log"
forced_output="$tmp_dir/forced.log"

status="$(run_phase0_self_test "$base_output" "")"
run_and_capture "self" "$base_output" "$status"
assert_zero_exit "$status" "phase0 self-test"
assert_contains "phase0.passed count=${expected_count}" "$base_output"
if grep -Fq "phase0.failed" "$base_output"; then
  printf '%s\n' "assertion failed: unexpected phase0.failed in self-test success mode" >&2
  cat "$base_output" >&2
  exit 1
fi

forced_leg="test-contract-fixtures"
forced_status="$(run_phase0_self_test "$forced_output" "$forced_leg")"
run_and_capture "forced" "$forced_output" "$forced_status"
assert_nonzero_exit "$forced_status" "forced phase0 self-test"
assert_contains "phase0.failed count=1" "$forced_output"
assert_contains "phase0.leg.complete name=$forced_leg status=1 reason=self-test-forced-failure" "$forced_output"
assert_contains "forced_self_test_failure" "$forced_output"

printf '%s\n' "phase0 aggregate meta-test passed (self-test count=${expected_count})"
