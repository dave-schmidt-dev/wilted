#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Meta-tests for the opt-in `watchos-build` leg (scripts/lib/native-gate-watch.sh).
# They run the gate in its self-test mode, which stubs every leg, so no build or
# simulator is started.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/test-gate.sh"
watch_lib="$repo_root/scripts/lib/native-gate-watch.sh"
# shellcheck source=../scripts/lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
wilted_sweep_stale_temp_dirs
# shellcheck source=../scripts/lib/test-temp-state.sh
source "$repo_root/scripts/lib/test-temp-state.sh"
tmp_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-native-gate-watch.XXXXXX")"; wilted_temp_mark_owned "$tmp_dir"
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

# The leg is selectable and brings the XcodeGen leg that generates its project.
log="$tmp_dir/select.log"
[[ "$(run_case select "$log" WILTED_GATE_LEGS=watchos-build)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.start name=xcodegen-reproducible' "$log"
assert_contains 'native.leg.start name=watchos-build' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=2 deferred_legs=0' "$log"
assert_contains 'native.passed count=2 filtered=8' "$log"
assert_absent 'native.leg.skipped name=watchos-build' "$log"

# It fails the gate when the leg fails.
log="$tmp_dir/fail.log"
[[ "$(run_case fail "$log" WILTED_GATE_LEGS=watchos-build NATIVE_FORCE_FAIL_LEG=watchos-build)" -ne 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$log"

# The self-test stubs the build, so check statically that a failed build fails
# the leg instead of falling through to status=0.
assert_contains 'if ! run_with_build_cache xcode native-watchos-build' "$watch_lib"

# An unknown name still fails closed and the error names the new leg as known.
log="$tmp_dir/unknown.log"
[[ "$(run_case unknown "$log" WILTED_GATE_LEGS=no-such-leg)" -ne 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'unknown leg in WILTED_GATE_LEGS: "no-such-leg"' "$log"
assert_contains 'watchos-build' "$log"
assert_absent 'native.leg.start' "$log"

# The default gate is unchanged: the opt-in leg neither runs nor shows as skipped.
log="$tmp_dir/full.log"
[[ "$(run_case full "$log" WILTED_MAC_UI=1)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.passed count=9' "$log"
assert_absent 'watchos-build' "$log"

# The real leg builds the WiltedWatch scheme for the watchOS simulator SDK and
# creates no simulator, so there is none to delete on any exit path.
assert_contains '-scheme WiltedWatch' "$watch_lib"
assert_contains "generic/platform=watchOS Simulator" "$watch_lib"
if grep -Eq 'gate_sim_create|create_gate_simulator|simctl (create|boot)' "$watch_lib"; then
  printf '%s\n' 'assertion failed: the watchos-build leg must not create simulators' >&2
  exit 1
fi
assert_contains 'leg_watchos_build()' "$watch_lib"
assert_contains 'native-gate-watch.sh' "$gate"

printf '%s\n' 'native gate watchos-build test passed'
