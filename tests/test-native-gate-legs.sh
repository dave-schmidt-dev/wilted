#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Meta-tests for the WILTED_GATE_LEGS single-leg filter in scripts/test-gate.sh.
# They run the gate in its self-test mode, which stubs every leg, so no app,
# simulator or XCUITest is launched. (tests/test-native-gate.sh is at the file
# size ceiling, so the filter cases live here.)
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/test-gate.sh"
# shellcheck source=../scripts/lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
wilted_sweep_stale_temp_dirs
tmp_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-native-gate-legs.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

# Usage: run_case <label> <output file> [env assignments...]; echoes the exit status.
run_case() {
  local label="$1" output="$2" result
  shift 2
  mkdir -p "$tmp_dir/$label-parent"
  set +e
  env TMPDIR="$tmp_dir/$label-parent" NATIVE_SELF_TEST=1 WILTED_MAC_UI=0 \
    WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$tmp_dir/diagnostics/$label" \
    "$@" bash "$gate" >"$output" 2>&1
  result=$?
  set -e
  printf 'meta-test[%s] status=%s\n' "$label" "$result" >&2
  printf '%s\n' "$result"
}

assert_contains() {
  grep -Fq -- "$1" "$2" || { printf 'assertion failed: missing %s\n' "$1" >&2; cat "$2" >&2; exit 1; }
}

assert_absent() {
  if grep -Fq -- "$1" "$2"; then printf 'assertion failed: unexpected %s\n' "$1" >&2; cat "$2" >&2; exit 1; fi
}

# Unknown, empty and malformed names fail closed before any leg starts.
for case_spec in 'unknown|no-such-leg' 'mixed|wiltedkit-tests,no-such-leg' 'empty-value|' 'empty-name|wiltedkit-tests,,playback-tests'; do
  label="${case_spec%%|*}" value="${case_spec#*|}"
  log="$tmp_dir/$label.log"
  [[ "$(run_case "$label" "$log" "WILTED_GATE_LEGS=$value")" -ne 0 ]] || { cat "$log" >&2; exit 1; }
  assert_contains 'native.error' "$log"
  assert_absent 'native.leg.start' "$log"
  assert_absent 'native.simulator.sweep' "$log"
  assert_absent 'native.passed' "$log"
done
assert_contains 'unknown leg in WILTED_GATE_LEGS: "no-such-leg"' "$tmp_dir/unknown.log"
assert_contains 'WILTED_GATE_LEGS is set but empty' "$tmp_dir/empty-value.log"

# One leg runs, the rest are named as skipped, and the pass line is qualified.
log="$tmp_dir/single.log"
[[ "$(run_case single "$log" WILTED_GATE_LEGS=wiltedkit-tests)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.start name=wiltedkit-tests' "$log"
[[ "$(grep -c '^native.leg.start' "$log")" -eq 1 ]] || { cat "$log" >&2; exit 1; }
[[ "$(grep -c '^native.leg.skipped' "$log")" -eq 8 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.skipped name=macos-ui-tests reason=not-in-WILTED_GATE_LEGS' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=1 deferred_legs=0' "$log"
assert_contains 'native.filtered selected=wiltedkit-tests skipped=xcodegen-reproducible cloudsync-tests' "$log"
assert_contains 'receipt=never' "$log"
assert_contains 'native.passed count=1 filtered=8' "$log"
if grep -Eq '^native\.passed count=[0-9]+$' "$log"; then
  printf '%s\n' 'assertion failed: a filtered run emitted the unqualified native.passed line' >&2
  exit 1
fi

# A failing unit leg keeps its xcresult in .logs, as the UI legs always have.
assert_contains 'if [[ "$name" == macos-* || "$name" == ios-* ]]; then' "$gate"

# An app leg brings the XcodeGen leg that generates its project.
log="$tmp_dir/app-leg.log"
[[ "$(run_case app-leg "$log" WILTED_GATE_LEGS=macos-unit-tests)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.start name=xcodegen-reproducible' "$log"
assert_contains 'native.leg.start name=macos-unit-tests' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=2 deferred_legs=0' "$log"

# Selecting the screen-seizing leg without the opt-in still defers it, and says so.
log="$tmp_dir/deferred.log"
[[ "$(run_case deferred "$log" WILTED_GATE_LEGS=playback-tests,macos-ui-tests)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.deferred name=macos-ui-tests' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=1 deferred_legs=1' "$log"
assert_contains 'native.passed count=1 deferred=1 filtered=7' "$log"

# An unfiltered run is unchanged: nine stubbed legs, no filter lines.
log="$tmp_dir/full.log"
[[ "$(run_case full "$log" WILTED_MAC_UI=1)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.complete failed_legs=0 total_legs=9 deferred_legs=0' "$log"
assert_contains 'native.passed count=9' "$log"
assert_absent 'native.filtered' "$log"
assert_absent 'native.leg.skipped' "$log"

# A failing leg that re-enables errexit before returning (xcode_test_leg does) must
# still reach retention and native.leg.complete instead of ending the gate. Runs the
# real run_leg body with its collaborators stubbed.
harness="$tmp_dir/run-leg-harness.sh"
{
  printf '%s\n' 'set -Eeuo pipefail' 'tmp_root="$1"; native_self_test=0; declare -i completed_legs=0 failed_legs=0'
  printf '%s\n' 'status() { printf "%s\n" "$*"; }' 'wilted_temp_prepare_leg() { WILTED_TEMP_LEG_WORK="$tmp_root"; }'
  printf '%s\n' 'is_deferred_leg() { return 1; }' 'is_forced_failure() { return 1; }' 'is_forced_zero() { return 1; }'
  printf '%s\n' 'wilted_start_logger() { exec 9>"$1"; }' 'wilted_finish_logger() { exec 9>&-; }'
  printf '%s\n' 'wilted_temp_audit_leg() { return 0; }' 'clear_ui_failure_bundle() { echo "cleared $1"; }'
  printf '%s\n' 'retain_ui_failure_bundle() { echo "retained $1"; }' 'errexit_leg() { set -e; return 3; }'
  sed -n '/^run_leg() {/,/^}/p' "$gate"
  printf '%s\n' 'run_leg macos-unit-tests none errexit_leg' 'echo "after failed_legs=$failed_legs"'
} >"$harness"
mkdir -p "$tmp_dir/run-leg-root"
bash "$harness" "$tmp_dir/run-leg-root" >"$tmp_dir/run-leg.log" 2>&1 || { cat "$tmp_dir/run-leg.log" >&2; exit 1; }
assert_contains 'retained macos-unit-tests' "$tmp_dir/run-leg.log"
assert_contains 'native.leg.complete name=macos-unit-tests status=3' "$tmp_dir/run-leg.log"
assert_contains 'after failed_legs=1' "$tmp_dir/run-leg.log"

printf '%s\n' 'native gate leg filter test passed'
