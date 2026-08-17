#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/test-gate.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wilted-native-gate-meta.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

run_case() {
  local label="$1"
  local output="$2"
  shift 2
  set +e
  env NATIVE_SELF_TEST=1 "$@" >"$output" 2>&1
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

assert_gatekeeper_contract() {
  if rg -q 'CODE_SIGNING_(ALLOWED|REQUIRED)=NO' "$gate"; then
    printf '%s\n' 'assertion failed: native gate still disables code signing' >&2
    exit 1
  fi
  assert_contains 'build-for-testing' "$gate"
  assert_contains 'test-without-building' "$gate"
  assert_contains 'codesign --verify --deep --strict' "$gate"
  assert_contains 'WiltedMacUITests-Runner.app' "$gate"
}

assert_gatekeeper_contract

assert_snapshot_contract() {
  assert_contains 'validate_pixel_snapshot_baselines' "$gate"
  assert_contains 'expected_count=156' "$gate"
  assert_contains 'expected_state_ids=' "$gate"
  assert_contains 'expected_variants=' "$gate"
  assert_contains 'expected_selectors' "$gate"
  assert_contains 'duplicate_selectors' "$gate"
  assert_contains 'empty_pngs' "$gate"
  assert_contains 'cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests"' "$gate"
  assert_contains 'cp "$repo_root/Producer/Package.swift" "$integration_root/Producer/Package.swift"' "$gate"
  assert_contains 'cp -R "$repo_root/Producer/Sources" "$repo_root/Producer/Tests" "$integration_root/Producer/"' "$gate"
  assert_contains 'validate_pixel_snapshot_baselines "$integration_root"' "$gate"
  assert_contains 'NATIVE_FORCE_SNAPSHOT_BASELINE' "$gate"

  # The Mac result-bundle floor proves the four snapshot methods are included
  # in the executed target count, rather than merely present in source.
  assert_contains 'expected_test_count_floor' "$gate"
  assert_contains 'macos-unit-tests) printf' "$gate"
  for method in \
    testEveryPreviewStateHasLightAndDarkPixelBaselines \
    testPixelSnapshotSelectorsAreUniqueAndComplete \
    testMacLibraryShellPixelBaselines \
    testMacPlayerShellPixelBaselines; do
    assert_contains "$method" "$gate"
  done
}

assert_snapshot_contract

assert_simulator_readiness_contract() {
  local simulator_block
  local first_booted_line
  local first_shutdown_line

  assert_contains 'native.simulator.reuse' "$gate"
  assert_contains 'native.simulator.boot' "$gate"
  assert_contains 'xcrun simctl boot "$udid"' "$gate"
  assert_contains 'xcrun simctl bootstatus "$udid" -b' "$gate"
  assert_contains 'native.simulator.ready' "$gate"

  simulator_block="$(sed -n '/^find_simulator_udid()/,/^}/p' "$gate")"
  first_booted_line="$(printf '%s\n' "$simulator_block" | rg -n 'Booted' | head -1 | cut -d: -f1)"
  first_shutdown_line="$(printf '%s\n' "$simulator_block" | rg -n 'Shutdown' | head -1 | cut -d: -f1)"
  [[ -n "$first_booted_line" && -n "$first_shutdown_line" && "$first_booted_line" -lt "$first_shutdown_line" ]] || {
    printf '%s\n' 'assertion failed: booted simulator preference must precede shutdown fallback' >&2
    exit 1
  }
}

assert_simulator_readiness_contract

assert_ios_ui_clean_simulator_contract() {
  local ios_ui_block
  local selection_line
  local boot_line
  local bootstatus_line
  local test_line
  local shutdown_line
  local trap_line

  assert_contains 'find_shutdown_iphone_udid' "$gate"
  assert_contains '/iPhone/ && /Shutdown/' "$gate"
  assert_contains 'xcrun simctl shutdown "$udid"' "$gate"
  assert_contains 'trap cleanup_ios_ui_simulator EXIT' "$gate"

  ios_ui_block="$(sed -n '/^leg_ios_ui_tests()/,/^)$/p' "$gate")"
  if printf '%s\n' "$ios_ui_block" | rg -q 'find_simulator_udid|iPad|Booted'; then
    printf '%s\n' 'assertion failed: iOS UI leg may not reuse booted or iPad simulators' >&2
    exit 1
  fi
  selection_line="$(printf '%s\n' "$ios_ui_block" | rg -n 'find_shutdown_iphone_udid' | head -1 | cut -d: -f1)"
  boot_line="$(printf '%s\n' "$ios_ui_block" | rg -n 'simctl boot ' | head -1 | cut -d: -f1)"
  bootstatus_line="$(printf '%s\n' "$ios_ui_block" | rg -n 'simctl bootstatus ' | head -1 | cut -d: -f1)"
  test_line="$(printf '%s\n' "$ios_ui_block" | rg -n 'xcode_test_leg ' | head -1 | cut -d: -f1)"
  shutdown_line="$(printf '%s\n' "$ios_ui_block" | rg -n 'simctl shutdown ' | head -1 | cut -d: -f1)"
  trap_line="$(printf '%s\n' "$ios_ui_block" | rg -n 'trap cleanup_ios_ui_simulator EXIT' | head -1 | cut -d: -f1)"
  [[ -n "$selection_line" && -n "$boot_line" && -n "$bootstatus_line" && -n "$test_line" && -n "$shutdown_line" && -n "$trap_line" ]] || {
    printf '%s\n' 'assertion failed: iOS UI clean simulator lifecycle is incomplete' >&2
    exit 1
  }
  [[ "$selection_line" -lt "$boot_line" && "$boot_line" -lt "$bootstatus_line" && "$bootstatus_line" -lt "$test_line" ]] || {
    printf '%s\n' 'assertion failed: iOS UI simulator must boot and become ready before tests' >&2
    exit 1
  }
  # Cleanup is registered before the simulator is booted, so it runs for both
  # successful and failed xcodebuild invocations.
  [[ "$trap_line" -lt "$boot_line" ]] || {
    printf '%s\n' 'assertion failed: iOS UI simulator shutdown cleanup is misplaced' >&2
    exit 1
  }
}

assert_ios_ui_clean_simulator_contract

assert_result_bundle_contract() {
  if rg -q 'xcodebuild.*(Executed [0-9]+ tests|Test run with [0-9]+ tests)' "$gate"; then
    printf '%s\n' 'assertion failed: native gate still infers counts from xcodebuild stdout' >&2
    exit 1
  fi
  assert_contains 'xcrun xcresulttool get test-results summary' "$gate"
  assert_contains 'totalTestCount' "$gate"
  assert_contains 'parse_result_bundle_test_count' "$gate"
  assert_contains '-resultBundlePath' "$gate"
  assert_contains 'native.result-bundle-missing' "$gate"
  if rg -q -- '--xunit-output|assert_xunit_tests|count\(//testcase\)' "$gate"; then
    printf '%s\n' 'assertion failed: native gate still relies on SwiftPM xUnit output' >&2
    exit 1
  fi
  assert_contains '--build-tests' "$gate"
  assert_contains 'xcrun xctest' "$gate"
  assert_contains 'assert_xctest_output' "$gate"
  assert_contains 'native.xctest-missing' "$gate"
  assert_contains 'parse_xctest_output_count' "$gate"
}

assert_result_bundle_contract

success_log="$tmp_dir/success.log"
success_status="$(run_case success "$success_log" bash "$gate")"
[[ "$success_status" -eq 0 ]] || { cat "$success_log" >&2; exit 1; }
assert_contains 'native.passed count=7' "$success_log"

forced_log="$tmp_dir/forced.log"
forced_status="$(run_case forced "$forced_log" env NATIVE_FORCE_FAIL_LEG=macos-unit-tests bash "$gate")"
[[ "$forced_status" -ne 0 ]] || { cat "$forced_log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$forced_log"
assert_contains 'forced_self_test_failure' "$forced_log"

zero_log="$tmp_dir/zero.log"
zero_status="$(run_case zero "$zero_log" env NATIVE_FORCE_ZERO_TEST_LEG=ios-ui-tests bash "$gate")"
[[ "$zero_status" -ne 0 ]] || { cat "$zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=ios-ui-tests' "$zero_log"
assert_contains 'result_bundle=' "$zero_log"
assert_contains 'native.failed count=1' "$zero_log"

package_zero_log="$tmp_dir/package-zero.log"
package_zero_status="$(run_case package-zero "$package_zero_log" env NATIVE_FORCE_ZERO_TEST_LEG=wiltedproducer-tests bash "$gate")"
[[ "$package_zero_status" -ne 0 ]] || { cat "$package_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=wiltedproducer-tests' "$package_zero_log"
assert_contains 'xctest=' "$package_zero_log"

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

printf '%s\n' 'native gate aggregate meta-test passed (seven legs; forced and zero-test failures are fail-closed)'
