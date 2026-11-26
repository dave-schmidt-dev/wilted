#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/test-gate.sh"
native_gate_validation="$repo_root/scripts/lib/native-gate-validation.sh"
native_gate_xcode="$repo_root/scripts/lib/native-gate-xcode.sh"
native_gate_simulator="$repo_root/scripts/lib/native-gate-simulator.sh"
# shellcheck source=../scripts/lib/mac-test-parent.sh
source "$repo_root/scripts/lib/mac-test-parent.sh"
# shellcheck source=../scripts/lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
wilted_sweep_stale_temp_dirs
# shellcheck source=../scripts/lib/test-temp-state.sh
source "$repo_root/scripts/lib/test-temp-state.sh"
tmp_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-native-gate-meta.XXXXXX")"; wilted_temp_mark_owned "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

run_case() {
  local label="$1"
  local output="$2"
  local case_tmp="$tmp_dir/$label-parent"
  shift 2
  mkdir -p "$case_tmp"
  set +e
  # Every pre-existing case asserts against a gate that RUNS the macOS UI leg.
  # The leg now defers unless opted in, so opt in here; the deferral path has
  # its own dedicated cases below, which re-override this to 0.
  #
  # A passing macOS UI leg also clears the retained
  # failure bundle. Without a per-case diagnostics directory that clear lands
  # on the repository's own `.logs/native-gate-diagnostics`, so running the
  # headless gate destroyed the evidence the previous `make native-ui` kept.
  # Cases that need their own directory pass it in "$@", which wins over this.
  env TMPDIR="$case_tmp" NATIVE_SELF_TEST=1 WILTED_MAC_UI=1 \
    WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$tmp_dir/diagnostics/$label" \
    "$@" >"$output" 2>&1
  local result=$?
  set -e
  printf 'meta-test[%s] status=%s\n' "$label" "$result" >&2
  printf '%s\n' "$result"
}
assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || {
    printf 'assertion failed: missing %s\n' "$needle" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_absent() {
  ! grep -Fq -- "$1" "$2" || { printf 'assertion failed: unexpected %s\n' "$1" >&2; exit 1; }
}

assert_validation_contains() {
  grep -Fq -- "$1" "$native_gate_validation" || assert_contains "$1" "$repo_root/scripts/lib/native-gate-mac-snapshots.sh"
}

assert_block_contains() {
  local needle="$1"
  local block="$2"
  [[ "$block" == *"$needle"* ]] || {
    printf 'assertion failed: missing %s\n' "$needle" >&2
    printf '%s\n' "$block" >&2
    exit 1
  }
}

source "$repo_root/tests/lib/native-gate-static-contracts.sh"

assert_result_bundle_contract() {
  if rg -q 'xcodebuild.*(Executed [0-9]+ tests|Test run with [0-9]+ tests)' "$gate"; then
    printf '%s\n' 'assertion failed: native gate still infers counts from xcodebuild stdout' >&2
    exit 1
  fi
  assert_validation_contains 'xcrun xcresulttool get test-results summary'
  assert_validation_contains 'totalTestCount'
  assert_validation_contains 'parse_result_bundle_test_count'
  assert_validation_contains 'result_bundle_summary_passed'
  assert_block_contains 'wait_macos_ui_supervisor' "$(sed -n '/^leg_macos_ui_tests()/,/^leg_ios_ui_tests()/p' "$gate")"
  assert_contains '-resultBundlePath' "$gate"
  assert_validation_contains 'native.result-bundle-missing'
  if rg -q -- '--xunit-output|assert_xunit_tests|count\(//testcase\)' "$gate" "$native_gate_validation"; then
    printf '%s\n' 'assertion failed: native gate still relies on SwiftPM xUnit output' >&2
    exit 1
  fi
  assert_contains '--build-tests' "$gate"
  assert_contains 'xcrun xctest' "$gate"
  assert_validation_contains 'assert_xctest_output'
  assert_validation_contains 'native.xctest-missing'
  assert_validation_contains 'parse_xctest_output_count'
  assert_contains 'build_with_cache="$repo_root/scripts/build-with-cache.py"' "$gate"
  assert_contains 'python3 "$build_with_cache" path "$kind" "$key"' "$gate"
  assert_contains 'python3 "$build_with_cache" run "$kind" "$key" -- "$@"' "$gate"
  assert_contains 'cache_path="$(build_cache_path swiftpm "$cache_key")"' "$gate"
  assert_contains 'run_with_build_cache swiftpm "$cache_key" swift build --package-path "$package" --build-tests' "$gate"
  assert_contains 'run_with_build_cache swiftpm "$cache_key" swift test --package-path "$package"' "$native_gate_validation"
  assert_contains 'local cache_key="native-$label"' "$gate"
  assert_contains 'label_data="$(build_cache_path xcode "$cache_key")"' "$gate"
  if rg -q -- '--scratch-path|derived_data=|DerivedData' "$gate" "$native_gate_validation"; then
    printf '%s\n' 'assertion failed: native gate still creates per-run SwiftPM or DerivedData caches' >&2
    exit 1
  fi
  if rg -q 'find "\$package/\.build".*WiltedProducerPackageTests\.xctest' "$gate" "$native_gate_validation"; then
    printf '%s\n' 'assertion failed: Producer XCTest discovery still reads checkout-local .build' >&2
    exit 1
  fi
}

assert_result_bundle_contract
ui_wait_helper="$(sed -n '/^wait_macos_ui_supervisor()/,/^}/p' "$gate")"
set +e; bash -c 'eval "$1"; WILTED_UI_LOCK_PID_FILE=fixture; wilted_wait_active_supervisor() { return 42; }; wait_macos_ui_supervisor; status=$?; [[ -z "$WILTED_UI_LOCK_PID_FILE" ]] || exit 99; exit "$status"' _ "$ui_wait_helper"
ui_wait_status=$?; set -e
[[ "$ui_wait_status" -eq 42 ]] || { printf 'assertion failed: UI supervisor status was masked (%s)\n' "$ui_wait_status" >&2; exit 1; }

# The retained failure bundle is the only record of why a macOS UI journey
# failed, and it is written by a run that cannot be repeated cheaply. Prove the
# meta-test leaves it alone rather than trusting the override above.
real_diagnostics="$repo_root/.logs/native-gate-diagnostics"
real_bundle="$real_diagnostics/macos-ui-tests.xcresult"
retained_bundle_before=absent
if [[ -e "$real_bundle" ]]; then
  retained_bundle_before=present
fi

# A gate copy cut off right after one of its EXIT traps and ending in a parse
# error must fail. Bash leaves $? at 0 for a parse error, so a trap that only
# returned $? let an edit made during a run turn a failed leg into a pass.
truncated_gate_status() {
  local source="$1" stop="$2" fixture="$3" helper copy
  mkdir -p "$fixture/scripts" "$fixture/scratch"
  ln -s "$repo_root/scripts/lib" "$fixture/scripts/lib"
  for helper in run-bounded.py check-temp-leaks.py build-with-cache.py; do
    ln -s "$repo_root/scripts/$helper" "$fixture/scripts/$helper"
  done
  copy="$fixture/scripts/$(basename "$source")"
  awk -v stop="$stop" '{ print } $0 == stop { exit }' "$source" >"$copy"
  grep -Fxq -- "$stop" "$copy" || { printf 'truncation line missing: %s\n' "$stop" >&2; exit 1; }
  printf '%s\n' 'echo "unterminated' >>"$copy"
  set +e
  env TMPDIR="$fixture/scratch" bash "$copy" >"$fixture/output.log" 2>&1
  local result=$?
  set -e
  printf '%s\n' "$result"
}

for truncation in "trap 'cleanup_initialization; exit 129' HUP|during initialization" "trap 'cleanup; exit 129' HUP|before its verdict"; do
  truncated_status="$(truncated_gate_status "$gate" "${truncation%%|*}" "$tmp_dir/truncated-${truncation##*|}")"
  [[ "$truncated_status" -ne 0 ]] || { cat "$tmp_dir/truncated-${truncation##*|}/output.log" >&2; printf 'a truncated gate passed\n' >&2; exit 1; }
  assert_contains "native.error stopped ${truncation##*|}" "$tmp_dir/truncated-${truncation##*|}/output.log"
done

success_log="$tmp_dir/success.log"
success_status="$(run_case success "$success_log" bash "$gate")"
[[ "$success_status" -eq 0 ]] || { cat "$success_log" >&2; exit 1; }
assert_contains 'native.passed count=10' "$success_log"
assert_contains 'native.tests label=ios27-appintents-tests reported=5' "$success_log"
for package_leg in wiltedkit-tests cloudsync-tests playback-tests wiltedproducer-tests; do
  assert_contains "native.tests label=$package_leg reported=3 evidence=xctest" "$success_log"
done

forced_log="$tmp_dir/forced.log"
forced_status="$(run_case forced "$forced_log" env NATIVE_FORCE_FAIL_LEG=macos-unit-tests bash "$gate")"
[[ "$forced_status" -ne 0 ]] || { cat "$forced_log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$forced_log"
assert_contains 'forced_self_test_failure' "$forced_log"

zero_log="$tmp_dir/zero.log"
zero_status="$(run_case zero "$zero_log" env NATIVE_FORCE_ZERO_TEST_LEG=ios-unit-tests bash "$gate")"
[[ "$zero_status" -ne 0 ]] || { cat "$zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=ios-unit-tests' "$zero_log"
assert_contains 'result_bundle=' "$zero_log"
assert_contains 'native.failed count=1' "$zero_log"

appintents_zero_log="$tmp_dir/appintents-zero.log"
appintents_zero_status="$(run_case appintents-zero "$appintents_zero_log" \
  env NATIVE_FORCE_ZERO_TEST_LEG=ios27-appintents-tests bash "$gate")"
[[ "$appintents_zero_status" -ne 0 ]] || { cat "$appintents_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=ios27-appintents-tests' "$appintents_zero_log"
assert_contains 'native.failed count=1' "$appintents_zero_log"

pixel_zero_log="$tmp_dir/pixel-zero.log"
pixel_zero_status="$(run_case pixel-zero "$pixel_zero_log" \
  env NATIVE_FORCE_ZERO_TEST_LEG=ios-pixel-snapshot-tests bash "$gate")"
[[ "$pixel_zero_status" -ne 0 ]] || { cat "$pixel_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=ios-pixel-snapshot-tests' "$pixel_zero_log"
assert_contains 'native.failed count=1' "$pixel_zero_log"

mvp_missing_log="$tmp_dir/mvp-missing.log"
mvp_missing_status="$(run_case mvp-missing "$mvp_missing_log" \
  env NATIVE_FORCE_MISSING_IOS_MVP_JOURNEY=1 bash "$gate")"
[[ "$mvp_missing_status" -ne 0 ]] || { cat "$mvp_missing_log" >&2; exit 1; }
assert_contains 'native.insufficient-tests label=ios-pixel-snapshot-tests reported=26 expected_minimum=27' "$mvp_missing_log"
assert_contains 'native.failed count=1' "$mvp_missing_log"

package_zero_log="$tmp_dir/package-zero.log"
package_zero_status="$(run_case package-zero "$package_zero_log" env NATIVE_FORCE_ZERO_TEST_LEG=wiltedproducer-tests bash "$gate")"
[[ "$package_zero_status" -ne 0 ]] || { cat "$package_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=wiltedproducer-tests' "$package_zero_log"
assert_contains 'xctest=' "$package_zero_log"

cloudsync_zero_log="$tmp_dir/cloudsync-zero.log"
cloudsync_zero_status="$(run_case cloudsync-zero "$cloudsync_zero_log" env NATIVE_FORCE_ZERO_TEST_LEG=cloudsync-tests bash "$gate")"
[[ "$cloudsync_zero_status" -ne 0 ]] || { cat "$cloudsync_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=cloudsync-tests' "$cloudsync_zero_log"
assert_contains 'xctest=' "$cloudsync_zero_log"

cloudsync_failure_log="$tmp_dir/cloudsync-failure.log"
cloudsync_failure_status="$(run_case cloudsync-failure "$cloudsync_failure_log" env NATIVE_FORCE_FAIL_LEG=cloudsync-tests bash "$gate")"
[[ "$cloudsync_failure_status" -ne 0 ]] || { cat "$cloudsync_failure_log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$cloudsync_failure_log"
assert_contains 'forced_self_test_failure' "$cloudsync_failure_log"

playback_zero_log="$tmp_dir/playback-zero.log"
playback_zero_status="$(run_case playback-zero "$playback_zero_log" env NATIVE_FORCE_ZERO_TEST_LEG=playback-tests bash "$gate")"
[[ "$playback_zero_status" -ne 0 ]] || { cat "$playback_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=playback-tests' "$playback_zero_log"
assert_contains 'xctest=' "$playback_zero_log"

playback_failure_log="$tmp_dir/playback-failure.log"
playback_failure_status="$(run_case playback-failure "$playback_failure_log" env NATIVE_FORCE_FAIL_LEG=playback-tests bash "$gate")"
[[ "$playback_failure_status" -ne 0 ]] || { cat "$playback_failure_log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$playback_failure_log"
assert_contains 'forced_self_test_failure' "$playback_failure_log"

producer_failure_log="$tmp_dir/producer-failure.log"
producer_failure_status="$(run_case producer-failure "$producer_failure_log" env NATIVE_FORCE_FAIL_LEG=wiltedproducer-tests bash "$gate")"
[[ "$producer_failure_status" -ne 0 ]] || { cat "$producer_failure_log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$producer_failure_log"
assert_contains 'forced_self_test_failure' "$producer_failure_log"

for snapshot_failure in missing zero malformed; do
  snapshot_log="$tmp_dir/snapshot-$snapshot_failure.log"
  snapshot_status="$(run_case "snapshot-$snapshot_failure" "$snapshot_log" \
    env NATIVE_FORCE_SNAPSHOT_BASELINE="$snapshot_failure" bash "$gate")"
  [[ "$snapshot_status" -ne 0 ]] || { cat "$snapshot_log" >&2; exit 1; }
  assert_contains 'native.error' "$snapshot_log"
done

# The macOS UI leg drives real HID events through WindowServer and cannot run
# headless, so it defers unless explicitly opted into. The danger of any skip
# mechanism is that a skipped leg reads as a passed leg. These cases exist to
# prove it never does.
assert_deferred_mac_ui_contract() {
  assert_contains 'wilted_mac_ui="${WILTED_MAC_UI:-0}"' "$gate"
  assert_contains 'is_deferred_leg()' "$gate"
  assert_contains '[[ "$1" == "macos-ui-tests" && "$wilted_mac_ui" != "1" ]]' "$gate"
  assert_contains 'native.leg.deferred' "$gate"
  assert_contains 'deferred_leg_names' "$gate"
  assert_contains 'WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR' "$gate"
  assert_contains '$repo_root/.logs/native-gate-diagnostics' "$gate"
  assert_contains 'source "$repo_root/scripts/lib/native-gate-validation.sh"' "$gate"
  assert_validation_contains 'retain_ui_failure_bundle'
  assert_validation_contains 'clear_ui_failure_bundle'
  # The Makefile must keep an opt-in route, or the leg becomes unreachable
  # rather than deferred.
  assert_contains 'bash scripts/verify-once-gate.sh ui-verify' "$repo_root/Makefile"
  assert_contains 'WILTED_MAC_UI=1 caffeinate -disu bash scripts/test-gate.sh' "$repo_root/scripts/verify-once-gate.sh"
}
assert_deferred_mac_ui_contract

# Default: the leg defers, says so by name, and the summary carries the debt.
mac_ui_deferred_log="$tmp_dir/mac-ui-deferred.log"
mac_ui_deferred_diagnostics="$tmp_dir/mac-ui-deferred-diagnostics"
mac_ui_deferred_status="$(run_case mac-ui-deferred "$mac_ui_deferred_log" \
  env WILTED_MAC_UI=0 WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$mac_ui_deferred_diagnostics" bash "$gate")"
[[ "$mac_ui_deferred_status" -eq 0 ]] || { cat "$mac_ui_deferred_log" >&2; exit 1; }
assert_contains 'native.leg.deferred name=macos-ui-tests' "$mac_ui_deferred_log"
assert_contains 'native.deferred count=1 legs=macos-ui-tests' "$mac_ui_deferred_log"
# A deferred run must never emit the unqualified pass line, because that is the
# line a human or a script reads as "every leg ran".
assert_contains 'native.passed count=9 deferred=1' "$mac_ui_deferred_log"
if grep -Eq 'native\.passed count=[0-9]+$' "$mac_ui_deferred_log"; then
  printf '%s\n' 'assertion failed: deferred run emitted an unqualified native.passed line' >&2
  cat "$mac_ui_deferred_log" >&2
  exit 1
fi
# A deferred leg is not a completed leg.
if grep -Fq 'native.leg.complete name=macos-ui-tests' "$mac_ui_deferred_log"; then
  printf '%s\n' 'assertion failed: deferred macOS UI leg reported completion' >&2
  cat "$mac_ui_deferred_log" >&2
  exit 1
fi
[[ ! -e "$mac_ui_deferred_diagnostics/macos-ui-tests.xcresult" ]] || {
  printf '%s\n' 'assertion failed: deferred Mac UI run retained failure evidence' >&2
  exit 1
}

# Opted in: the leg actually runs and the summary claims no deferral.
mac_ui_optin_log="$tmp_dir/mac-ui-optin.log"
mac_ui_optin_diagnostics="$tmp_dir/mac-ui-optin-diagnostics"
mkdir -p "$mac_ui_optin_diagnostics/macos-ui-tests.xcresult"
printf '%s\n' stale >"$mac_ui_optin_diagnostics/macos-ui-tests.xcresult/stale"
mac_ui_optin_status="$(run_case mac-ui-optin "$mac_ui_optin_log" \
  env WILTED_MAC_UI=1 WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$mac_ui_optin_diagnostics" bash "$gate")"
[[ "$mac_ui_optin_status" -eq 0 ]] || { cat "$mac_ui_optin_log" >&2; exit 1; }
assert_contains 'native.leg.start name=macos-ui-tests' "$mac_ui_optin_log"
assert_contains 'native.leg.complete name=macos-ui-tests status=0' "$mac_ui_optin_log"
assert_contains 'native.passed count=10' "$mac_ui_optin_log"
if grep -Fq 'native.leg.deferred' "$mac_ui_optin_log"; then
  printf '%s\n' 'assertion failed: opted-in run still deferred the macOS UI leg' >&2
  cat "$mac_ui_optin_log" >&2
  exit 1
fi
[[ ! -e "$mac_ui_optin_diagnostics/macos-ui-tests.xcresult" ]] || {
  printf '%s\n' 'assertion failed: successful Mac UI run retained failure evidence' >&2
  exit 1
}

# Deferral must not become a way to hide a real failure: an opted-in forced
# failure still fails the gate.
mac_ui_failure_log="$tmp_dir/mac-ui-failure.log"
mac_ui_failure_diagnostics="$tmp_dir/mac-ui-failure-diagnostics"
mac_ui_failure_status="$(run_case mac-ui-failure "$mac_ui_failure_log" \
  env WILTED_MAC_UI=1 NATIVE_FORCE_FAIL_LEG=macos-ui-tests \
  WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$mac_ui_failure_diagnostics" bash "$gate")"
[[ "$mac_ui_failure_status" -ne 0 ]] || { cat "$mac_ui_failure_log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$mac_ui_failure_log"
assert_contains 'native.ui-leg.failure-bundle leg=macos-ui-tests path=' "$mac_ui_failure_log"
[[ -f "$mac_ui_failure_diagnostics/macos-ui-tests.xcresult/self-test-evidence" ]] || {
  printf '%s\n' 'assertion failed: failed Mac UI run did not retain its result bundle' >&2
  exit 1
}
assert_contains 'self_test_macos_ui_failure_evidence' \
  "$mac_ui_failure_diagnostics/macos-ui-tests.xcresult/self-test-evidence"

# A zero-test result is a failed UI leg even when xcodebuild itself exited 0,
# and its result bundle is equally necessary for diagnosis.
mac_ui_zero_log="$tmp_dir/mac-ui-zero.log"
mac_ui_zero_diagnostics="$tmp_dir/mac-ui-zero-diagnostics"
mac_ui_zero_status="$(run_case mac-ui-zero "$mac_ui_zero_log" \
  env WILTED_MAC_UI=1 NATIVE_FORCE_ZERO_TEST_LEG=macos-ui-tests \
  WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$mac_ui_zero_diagnostics" bash "$gate")"
[[ "$mac_ui_zero_status" -ne 0 ]] || { cat "$mac_ui_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=macos-ui-tests' "$mac_ui_zero_log"
assert_contains 'native.ui-leg.failure-bundle leg=macos-ui-tests path=' "$mac_ui_zero_log"
assert_contains 'self_test_macos_ui_zero_test_evidence' \
  "$mac_ui_zero_diagnostics/macos-ui-tests.xcresult/self-test-evidence"
mac_ui_summary_log="$tmp_dir/mac-ui-summary.log"; mac_ui_summary_diagnostics="$tmp_dir/mac-ui-summary-diagnostics"
mac_ui_summary_status="$(run_case mac-ui-summary "$mac_ui_summary_log" env WILTED_MAC_UI=1 \
  NATIVE_FORCE_FAILED_RESULT_SUMMARY_LEG=macos-ui-tests WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$mac_ui_summary_diagnostics" bash "$gate")"
[[ "$mac_ui_summary_status" -ne 0 ]] || { cat "$mac_ui_summary_log" >&2; exit 1; }; assert_contains 'native.result-summary-failed label=macos-ui-tests' "$mac_ui_summary_log"
[[ -f "$mac_ui_summary_diagnostics/macos-ui-tests.xcresult/self-test-evidence" ]] || { cat "$mac_ui_summary_log" >&2; exit 1; }

# A locked screen makes every UI journey fail its activation timeout, which
# reads as a broken application. The leg must say so before it spends twenty
# minutes proving it.
mac_ui_locked_log="$tmp_dir/mac-ui-locked.log"
mac_ui_locked_status="$(run_case mac-ui-locked "$mac_ui_locked_log" \
  env WILTED_MAC_UI=1 NATIVE_FORCE_SCREEN_LOCKED=1 bash "$gate")"
[[ "$mac_ui_locked_status" -ne 0 ]] || { cat "$mac_ui_locked_log" >&2; exit 1; }
assert_contains 'native.macos-ui.screen-locked' "$mac_ui_locked_log"
assert_contains 'cannot activate an application while the screen is locked' "$mac_ui_locked_log"
if rg -q 'Testing started' "$mac_ui_locked_log"; then
  printf '%s\n' 'assertion failed: the locked-screen leg still started xcodebuild' >&2
  exit 1
fi

retained_bundle_after=absent
if [[ -e "$real_bundle" ]]; then
  retained_bundle_after=present
fi
if [[ "$retained_bundle_before" != "$retained_bundle_after" ]]; then
  printf '%s\n' \
    "assertion failed: the meta-test changed $real_bundle from $retained_bundle_before to $retained_bundle_after" >&2
  exit 1
fi

# Watch failure retention uses the shared configured lifecycle, including
# count/summary failures; the opt-in leg never owns a second diagnostic path.
assert_contains '|| "$name" == watchos-*' "$gate"
assert_contains 'self_test_watchos_failure_evidence' "$gate"
assert_contains 'self_test_watchos_zero_test_evidence' "$gate"

# The shipping phone lane keeps the original eight captures, adds the eight Add sheet captures, and verifies pixels, not hidden labels.
assert_validation_contains 'iOS pixel snapshot method membership must remain exactly twenty-six'
assert_validation_contains 'iOS pixel test does not verify painted date and Storage geometry'
assert_validation_contains 'expected_count=230'
assert_validation_contains 'shells=78'
assert_validation_contains 'window_shells=17'
for snapshot in \
  testShowSettingsPagePixelBaselines.mac-shell-show-settings-light.png \
  testShowSettingsPagePixelBaselines.mac-shell-show-settings-changed-light.png \
  testArticleShowSettingsPixelBaselines.mac-shell-show-settings-article-light.png \
  testArticleShowSettingsPixelBaselines.mac-shell-show-settings-article-dark.png; do
  assert_contains "$snapshot" "$repo_root/scripts/lib/native-gate-mac-snapshots.sh"
done
assert_contains 'testShowSettingsPagePixelBaselines' \
  "$repo_root/WiltedMacTests/WiltedPixelSnapshotTests+ShowSettings.swift"
assert_contains 'testArticleShowSettingsPixelBaselines' \
  "$repo_root/WiltedMacTests/WiltedPixelSnapshotTests+ShowSettings.swift"
assert_contains 'testDevicesSettingsWithSyntheticDeviceRowsPixels.mac-shell-section-devices-synthetic-rows-light.png' \
  "$repo_root/scripts/lib/native-gate-mac-snapshots.sh"
assert_contains 'testDirectDownloadsDeviceMenuPixels.mac-shell-direct-downloads-device-menu-light.png' \
  "$repo_root/scripts/lib/native-gate-mac-snapshots.sh"
assert_contains 'testDeviceRemovalConfirmationPixels.mac-shell-device-removal-confirmation-light.png' \
  "$repo_root/scripts/lib/native-gate-mac-snapshots.sh"
for settings_snapshot in \
  settings-tab-listening-top \
  settings-tab-listening-scrolled \
  settings-tab-feeds-reports-top \
  settings-tab-feeds-reports-scrolled \
  settings-tab-ads-providers-top \
  settings-tab-ads-providers-scrolled \
  settings-tab-library-sync-top \
  settings-tab-library-sync-scrolled \
  settings-providers; do
  assert_validation_contains "mac-shell-$settings_snapshot-light"
done
for method in testDevicesSettingsWithSyntheticDeviceRowsPixels testDirectDownloadsDeviceMenuPixels \
  testDeviceRemovalConfirmationPixels testAdsProvidersScrolledSettingsPixels; do
  assert_contains "func $method" "$repo_root/WiltedMacTests/WiltedPixelSnapshotTests+Reports.swift"
done
assert_contains 'func testSettingsTabScrollTargetsRenderTheirSections' \
  "$repo_root/WiltedMacTests/WiltedPixelSnapshotTests+Reports.swift"
assert_contains 'VNRecognizeTextRequest()' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"
assert_contains 'value.frame.minY, label.frame.maxY' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"
assert_contains 'assertPaintedLine("Nov 14, 2023", frame: date.frame, in: image)' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"
assert_contains 'assertPaintedLine(value.label, frame: value.frame, in: scrolledScreenshot)' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"
assert_contains 'XCTAssertGreaterThanOrEqual(date.frame.minY, metadata.frame.maxY - 1,' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"

printf '%s\n' 'native gate aggregate meta-test passed (ten gate legs; the macOS UI leg defers unless WILTED_MAC_UI=1 and its deferral is fail-loud; forced and zero-test failures are fail-closed; the retained failure bundle is untouched)'
