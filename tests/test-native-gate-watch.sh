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
mkdir -p "$tmp_dir/diagnostics/select/watchos-build.xcresult"
printf '%s\n' stale >"$tmp_dir/diagnostics/select/watchos-build.xcresult/stale"
[[ "$(run_case select "$log" WILTED_GATE_LEGS=watchos-build)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.start name=xcodegen-reproducible' "$log"
assert_contains 'native.leg.start name=watchos-build' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=2 deferred_legs=0' "$log"
assert_contains 'native.passed count=2 filtered=8' "$log"
assert_absent 'native.leg.skipped name=watchos-build' "$log"
[[ ! -e "$tmp_dir/diagnostics/select/watchos-build.xcresult" ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.ui-leg.failure-bundle-cleared leg=watchos-build' "$log"

# It fails the gate when the leg fails.
log="$tmp_dir/fail.log"
[[ "$(run_case fail "$log" WILTED_GATE_LEGS=watchos-build NATIVE_FORCE_FAIL_LEG=watchos-build)" -ne 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$log"
assert_contains 'self_test_watchos_failure_evidence' "$tmp_dir/diagnostics/fail/watchos-build.xcresult/self-test-evidence"
assert_contains "native.ui-leg.failure-bundle leg=watchos-build path=$tmp_dir/diagnostics/fail/" "$log"
log="$tmp_dir/zero.log"
[[ "$(run_case zero "$log" WILTED_GATE_LEGS=watchos-build NATIVE_FORCE_ZERO_TEST_LEG=watchos-build)" -ne 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'self_test_watchos_zero_test_evidence' "$tmp_dir/diagnostics/zero/watchos-build.xcresult/self-test-evidence"

# The self-test stubs the build, so check statically that a failed build fails
# the leg instead of falling through to status=0.
assert_contains 'xcode_test_leg watchos-build' "$watch_lib"

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

# The hosted suite must build, test and export real views on an owned Watch.
assert_contains 'create_watch_gate_simulator' "$watch_lib"
assert_contains 'platform=watchOS Simulator,id=$udid' "$watch_lib"
assert_contains 'export_watch_captures "$result_bundle"' "$watch_lib"
assert_contains 'WiltedWatchTests' "$repo_root/scripts/lib/native-gate-staging.sh"
assert_contains 'WiltedWatchTests' "$repo_root/project.yml"
for method in testNowPlayingCapture testUpNextCapture testSpeedCapture testSleepCapture; do
  assert_contains "$method" "$repo_root/WiltedWatchTests/WatchScreenCaptureTests.swift"
done
for count in 0 3; do
  log="$tmp_dir/count-$count.log"
  [[ "$(run_case "count-$count" "$log" WILTED_GATE_LEGS=watchos-build NATIVE_SELF_TEST_WATCH_COUNT="$count")" -ne 0 ]] || { cat "$log" >&2; exit 1; }
done
log="$tmp_dir/summary.log"
[[ "$(run_case summary "$log" WILTED_GATE_LEGS=watchos-build NATIVE_FORCE_FAILED_RESULT_SUMMARY_LEG=watchos-build)" -ne 0 ]] || { cat "$log" >&2; exit 1; }

assert_contains 'leg_watchos_build()' "$watch_lib"
assert_contains 'native-gate-watch.sh' "$gate"
assert_absent 'b6-2026-10-07' "$watch_lib"
assert_absent 'current.xcresult' "$watch_lib"

# Exercise attachment export, complete-set validation and failed-set retention.
python3 - "$tmp_dir" <<'PYCODE'
import json
from pathlib import Path
import struct
import sys
import zlib
root = Path(sys.argv[1])
names = ["watch-now-playing.png", "watch-up-next.png", "watch-speed.png", "watch-sleep.png"]
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
def png(width, height, blank=False):
    image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    raw = b"".join(b"\0" + bytes((row + value) % 256 if not blank else 0 for value in range(width * 3)) for row in range(height))
    return image + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
for case in ["complete", "missing", "duplicate", "blank", "corrupt", "wrong-width", "wrong-viewport", "clipped-option"]:
    fixture = root / ("attachments-" + case); fixture.mkdir()
    attachments = [{"exportedFileName": str(i) + ".png", "suggestedHumanReadableName": name[:-4] + "_0_12345678-1234-1234-1234-123456789ABC.png"} for i, name in enumerate(names)]
    for i, height in enumerate([4, 4, 8, 12]): (fixture / (str(i) + ".png")).write_bytes(png(4, height))
    if case == "missing": attachments.pop()
    if case == "duplicate": attachments.append(attachments[0])
    if case == "blank": (fixture / "0.png").write_bytes(png(4, 4, blank=True))
    if case == "corrupt": (fixture / "0.png").write_bytes(png(4, 4)[:-5])
    if case == "wrong-width": (fixture / "2.png").write_bytes(png(5, 8))
    if case == "wrong-viewport": (fixture / "1.png").write_bytes(png(4, 5))
    if case == "clipped-option": (fixture / "2.png").write_bytes(png(4, 4))
    (fixture / "manifest.json").write_text(json.dumps([{"testIdentifier": "WatchScreenCaptureTests", "attachments": attachments}]))
PYCODE
for case in complete missing duplicate blank corrupt wrong-width wrong-viewport clipped-option; do
  mkdir -p "$tmp_dir/export-$case"
  result=0
  bash -c '
    set -Eeuo pipefail
    optin_leg_names=(); optin_leg_fns=(); optin_leg_reports=()
    source "$1"
    tmp_root="$2"; repo_root="$2"; fixture="$3"
    git() { printf "meta-sha\n"; }
    run_bounded_native_command() { "$@"; }
    xcrun() { cp -R "$fixture/." "${@: -1}"; }
    export_watch_captures "$tmp_root/fixture.xcresult"
  ' _ "$watch_lib" "$tmp_dir/export-$case" "$tmp_dir/attachments-$case" >"$tmp_dir/export-$case.log" 2>&1 || result=$?
  if [[ "$case" == complete ]]; then
    [[ "$result" == 0 ]] || { cat "$tmp_dir/export-$case.log" >&2; exit 1; }
    [[ "$(find "$tmp_dir/export-$case/.logs" -name '*.png' | wc -l | tr -d ' ')" == 4 ]] || exit 1
    assert_contains 'uncommitted working-tree bytes' "$(find "$tmp_dir/export-$case/.logs" -name capture-evidence.json)"
    python3 - "$(find "$tmp_dir/export-$case/.logs" -name capture-evidence.json)" <<'PYCODE'
import json, sys
value=json.load(open(sys.argv[1]))
assert value['viewport_pixels'] == [4, 4]
assert value['capture_pixels']['watch-speed.png'] == [4, 8]
assert value['capture_pixels']['watch-sleep.png'] == [4, 12]
PYCODE
  else
    [[ "$result" != 0 && ! -d "$tmp_dir/export-$case/.logs" ]] || { cat "$tmp_dir/export-$case.log" >&2; exit 1; }
  fi
done

printf '%s\n' 'native gate watchos-build test passed'
