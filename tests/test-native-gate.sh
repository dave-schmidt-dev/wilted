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

assert_block_contains() {
  local needle="$1"
  local block="$2"
  [[ "$block" == *"$needle"* ]] || {
    printf 'assertion failed: missing %s\n' "$needle" >&2
    printf '%s\n' "$block" >&2
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
  assert_contains 'WiltedMac.app' "$gate"
  assert_contains 'WILTED_DEVELOPMENT_TEAM' "$gate"
  assert_contains "wilted_development_team=\"\${WILTED_DEVELOPMENT_TEAM:-4CJ49V6QHW}\"" "$gate"
  assert_contains "CODE_SIGN_IDENTITY='Apple Development'" "$gate"
  assert_contains 'DEVELOPMENT_TEAM="$wilted_development_team"' "$gate"
  assert_contains 'Authority=Apple Development:' "$gate"
  assert_contains 'TeamIdentifier=$wilted_development_team' "$gate"
  assert_contains 'com.apple.quarantine' "$gate"
  assert_contains 'com.apple.FinderInfo' "$gate"
  assert_contains 'if ! codesign --verify --deep --strict "$runner"; then return 1; fi' "$gate"
  assert_contains 'if ! codesign --verify --strict "$host"; then return 1; fi' "$gate"
  assert_contains 'if ! runner_metadata=' "$gate"
  assert_contains 'if ! host_metadata=' "$gate"
  local mac_ui_block build_line runner_probe_line host_probe_line verify_runner_line verify_host_line signature_runner_line signature_host_line launch_line
  mac_ui_block="$(sed -n '/^leg_macos_ui_tests()/,/^}$/p' "$gate")"
  build_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'xcodebuild build-for-testing' | head -1 | cut -d: -f1)"
  runner_probe_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'if ! runner_metadata=' | head -1 | cut -d: -f1)"
  host_probe_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'if ! host_metadata=' | head -1 | cut -d: -f1)"
  verify_runner_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'codesign --verify --deep --strict "\$runner"' | head -1 | cut -d: -f1)"
  verify_host_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'codesign --verify --strict "\$host"' | head -1 | cut -d: -f1)"
  signature_runner_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'assert_apple_development_signature runner' | head -1 | cut -d: -f1)"
  signature_host_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'assert_apple_development_signature host' | head -1 | cut -d: -f1)"
  launch_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'xcodebuild test-without-building' | head -1 | cut -d: -f1)"
  [[ -n "$build_line" && -n "$runner_probe_line" && -n "$host_probe_line" && -n "$verify_runner_line" &&
    -n "$verify_host_line" && -n "$signature_runner_line" && -n "$signature_host_line" &&
    -n "$launch_line" && "$build_line" -lt "$runner_probe_line" &&
    "$runner_probe_line" -lt "$host_probe_line" &&
    "$host_probe_line" -lt "$verify_runner_line" && "$host_probe_line" -lt "$verify_host_line" &&
    "$verify_runner_line" -lt "$signature_runner_line" &&
    "$verify_host_line" -lt "$signature_host_line" &&
    "$signature_runner_line" -lt "$launch_line" && "$signature_host_line" -lt "$launch_line" ]] || {
    printf '%s\n' 'assertion failed: Mac UI signing/metadata verification must precede launch' >&2
    exit 1
  }
}

assert_gatekeeper_contract

assert_wiltedkit_sync_contract() {
  assert_contains 'WiltedSyncTests' "$gate"
  assert_contains 'assert_test_sources wiltedsync-tests' "$gate"
  assert_contains 'WiltedSync authoritative fixture drift' "$gate"
  assert_contains 'native.sync-fixture.parity' "$gate"
  assert_contains 'authoritative publish fixture decodes all records and round trips exactly' "$gate"
  assert_contains 'fake delay emits visible status before completion' "$gate"
  assert_contains 'remote deletions apply incrementally, cascade items, and preserve protected work' "$gate"
  assert_contains 'leg_cloudsync_tests' "$gate"
  assert_contains 'swift test --package-path "$package"' "$gate"
  assert_contains 'CloudSync named adapter case was not observed' "$gate"
  assert_contains 'CloudSync named send case was not observed' "$gate"
  assert_contains 'cp "$repo_root/CloudSync/Package.swift" "$integration_root/CloudSync/Package.swift"' "$gate"
  assert_contains 'cp -R "$repo_root/CloudSync/Sources" "$repo_root/CloudSync/Tests" "$integration_root/CloudSync/"' "$gate"
  assert_contains 'leg_listener_tests' "$gate"
  assert_contains 'swift test --package-path "$package"' "$gate"
  assert_contains 'Listener repository case was not observed' "$gate"
  assert_contains 'Listener playback case was not observed' "$gate"
  assert_contains 'cp "$repo_root/Listener/Package.swift" "$integration_root/Listener/Package.swift"' "$gate"
  assert_contains 'cp -R "$repo_root/Listener/Sources" "$repo_root/Listener/Tests" "$integration_root/Listener/"' "$gate"
}

assert_wiltedkit_sync_contract

assert_capability_source_contract() {
  local project="$repo_root/project.yml"
  local mac_development="$repo_root/WiltedMac/WiltedMac.entitlements"
  local mac_release="$repo_root/WiltedMac/WiltedMacProduction.entitlements"
  local ios_development="$repo_root/WiltediOS/WiltediOS.entitlements"
  local ios_release="$repo_root/WiltediOS/WiltediOSProduction.entitlements"

  for required in \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.mac.tests' \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.ios.tests' \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.mac.uitests' \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.ios.uitests'; do
    assert_contains "$required" "$project"
  done
  assert_contains 'Development: debug' "$project"
  target_block() {
    local target="$1"
    awk -v target="$target" '
      index($0, "  " target ":") == 1 { found = 1 }
      found && index($0, "  " target ":") != 1 && $0 ~ /^  [A-Za-z0-9_]+:/ { exit }
      found { print }
    ' "$project"
  }
  mac_block="$(target_block WiltedMac)"
  ios_block="$(target_block WiltediOS)"
  config_block() {
    local block="$1"; local config="$2"
    printf '%s\n' "$block" | awk -v config="$config" '
      index($0, "        " config ":") == 1 { found = 1 }
      found && $0 ~ /^        [A-Za-z0-9_]+:/ && index($0, "        " config ":") != 1 { exit }
      found { print }
    '
  }
  assert_target_config() {
    local target="$1"; local block="$2"; local config="$3"; local expected="$4"
    printf '%s\n' "$block" | grep -Fq -- "PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.$([ "$target" = WiltedMac ] && printf mac || printf ios)" || {
      printf 'assertion failed: %s bundle ID missing\n' "$target" >&2
      exit 1
    }
    printf '%s\n' "$(config_block "$block" "$config")" | grep -Fq -- "$expected" || {
      printf 'assertion failed: %s %s mapping missing %s\n' "$target" "$config" "$expected" >&2
      exit 1
    }
  }
  assert_target_config WiltedMac "$mac_block" Debug 'CODE_SIGN_ENTITLEMENTS: ""'
  assert_target_config WiltedMac "$mac_block" Debug 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"'
  assert_target_config WiltedMac "$mac_block" Development 'CODE_SIGN_ENTITLEMENTS: WiltedMac/WiltedMac.entitlements'
  assert_target_config WiltedMac "$mac_block" Development 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE"'
  assert_target_config WiltedMac "$mac_block" Release 'CODE_SIGN_ENTITLEMENTS: WiltedMac/WiltedMacProduction.entitlements'
  assert_target_config WiltedMac "$mac_block" Release 'CODE_SIGN_IDENTITY: "Developer ID Application"'
  assert_target_config WiltedMac "$mac_block" Release 'CODE_SIGN_STYLE: Manual'
  assert_target_config WiltedMac "$mac_block" Release 'DEVELOPMENT_TEAM: 4CJ49V6QHW'
  assert_target_config WiltedMac "$mac_block" Release 'ENABLE_HARDENED_RUNTIME: YES'
  assert_target_config WiltedMac "$mac_block" Release 'PROVISIONING_PROFILE_SPECIFIER: Wilted Developer ID'
  assert_target_config WiltedMac "$mac_block" Release 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE"'
  assert_target_config WiltediOS "$ios_block" Debug 'CODE_SIGN_ENTITLEMENTS: ""'
  assert_target_config WiltediOS "$ios_block" Debug 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"'
  assert_target_config WiltediOS "$ios_block" Development 'CODE_SIGN_ENTITLEMENTS: WiltediOS/WiltediOS.entitlements'
  assert_target_config WiltediOS "$ios_block" Development 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE"'
  assert_target_config WiltediOS "$ios_block" Release 'CODE_SIGN_ENTITLEMENTS: WiltediOS/WiltediOSProduction.entitlements'
  assert_target_config WiltediOS "$ios_block" Release 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE"'
  for debug_block in "$(config_block "$mac_block" Debug)" "$(config_block "$ios_block" Debug)"; do
    if printf '%s\n' "$debug_block" | grep -Fq 'WILTED_CLOUDKIT_LIVE'; then
      printf '%s\n' 'assertion failed: Debug defines the CloudKit-live compilation condition' >&2
      exit 1
    fi
  done
  for wiring in \
    '  WiltedCloudKit:' \
    '    path: CloudSync' \
    '  WiltedListener:' \
    '    path: Listener' \
    '        product: WiltedSync' \
    '        product: WiltedCloudKit'; do
    assert_contains "$wiring" "$project"
  done
  assert_contains '        product: WiltedListener' "$project"
  if rg -n 'com\.example\.wilted' \
    "$project" "$mac_development" "$mac_release" "$ios_development" "$ios_release"; then
    printf '%s\n' 'assertion failed: placeholder binding remains' >&2
    exit 1
  fi
  assert_contains 'CODE_SIGN_IDENTITY: Apple Distribution' "$project"
  assert_contains 'DEVELOPMENT_TEAM: 4CJ49V6QHW' "$project"
  assert_contains 'PROVISIONING_PROFILE_SPECIFIER: Wilted App Store' "$project"

  assert_entitlement() {
    local file="$1"; local key="$2"; local value="$3"
    plutil -p "$file" | grep -Fq "\"$key\" => \"$value\"" || {
      printf 'assertion failed: %s missing %s=%s\n' "$file" "$key" "$value" >&2
      exit 1
    }
  }
  assert_entitlement "$mac_development" 'com.apple.developer.aps-environment' development
  assert_entitlement "$ios_development" 'aps-environment' development
  assert_entitlement "$mac_release" 'com.apple.developer.aps-environment' production
  assert_entitlement "$ios_release" 'aps-environment' production
  assert_entitlement "$mac_release" 'com.apple.developer.icloud-container-environment' Production
  assert_entitlement "$ios_release" 'com.apple.developer.icloud-container-environment' Production
  for file in "$mac_development" "$mac_release" "$ios_development" "$ios_release"; do
    plutil -p "$file" | grep -Fq 'CloudKit' || {
      printf 'assertion failed: %s missing CloudKit service\n' "$file" >&2
      exit 1
    }
    plutil -p "$file" | grep -Fq 'iCloud.com.zerodelta.wilted' || {
      printf 'assertion failed: %s missing approved CloudKit container\n' "$file" >&2
      exit 1
    }
  done
  for file in "$mac_development" "$ios_development"; do
    if plutil -p "$file" | grep -Fq 'icloud-container-environment'; then
      printf '%s\n' 'assertion failed: Development entitlements contain Production environment key' >&2
      exit 1
    fi
  done
  plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq 'UIBackgroundModes' || {
    printf '%s\n' 'assertion failed: iOS Info.plist lacks UIBackgroundModes' >&2
    exit 1
  }
  plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq 'audio' || {
    printf '%s\n' 'assertion failed: iOS Info.plist lacks audio background mode' >&2
    exit 1
  }
  plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq '"ITSAppUsesNonExemptEncryption" => false' || {
    printf '%s\n' 'assertion failed: iOS Info.plist lacks the exempt-encryption declaration' >&2
    exit 1
  }
  for orientation in \
    UIInterfaceOrientationPortrait \
    UIInterfaceOrientationPortraitUpsideDown \
    UIInterfaceOrientationLandscapeLeft \
    UIInterfaceOrientationLandscapeRight; do
    plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq "$orientation" || {
      printf 'assertion failed: iOS Info.plist lacks %s\n' "$orientation" >&2
      exit 1
    }
  done
}

assert_capability_source_contract

assert_snapshot_contract() {
  assert_contains 'validate_pixel_snapshot_baselines' "$gate"
  assert_contains 'validate_ios_pixel_snapshot_baselines' "$gate"
  assert_contains 'expected_count=162' "$gate"
  assert_contains 'expected_state_ids=' "$gate"
  assert_contains 'expected_variants=' "$gate"
  assert_contains 'expected_selectors' "$gate"
  assert_contains 'duplicate_selectors' "$gate"
  assert_contains 'empty_pngs' "$gate"
  assert_contains 'cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests"' "$gate"
  assert_contains 'cp "$repo_root/Producer/Package.swift" "$integration_root/Producer/Package.swift"' "$gate"
  assert_contains 'cp -R "$repo_root/Producer/Sources" "$repo_root/Producer/Tests" "$integration_root/Producer/"' "$gate"
  for entitlement in \
    WiltedMac/WiltedMac.entitlements \
    WiltedMac/WiltedMacProduction.entitlements \
    WiltediOS/WiltediOS.entitlements \
    WiltediOS/WiltediOSProduction.entitlements; do
    assert_contains "$entitlement" "$gate"
  done
  assert_contains 'validate_pixel_snapshot_baselines "$integration_root"' "$gate"
  assert_contains 'validate_ios_pixel_snapshot_baselines "$integration_root"' "$gate"
  assert_contains 'NATIVE_FORCE_SNAPSHOT_BASELINE' "$gate"
  assert_contains 'test_host_pattern' "$gate"
  assert_contains 'native.cleanup mac-test-hosts=' "$gate"
  assert_contains 'trap cleanup EXIT' "$gate"
  assert_contains 'WILTED_XCODE_TEST_TIMEOUT_SECONDS' "$gate"
  assert_contains 'native.timeout label=$label seconds=$xcode_test_timeout_seconds' "$gate"
  assert_contains 'native.heartbeat label=$label elapsed_seconds=$elapsed_seconds' "$gate"
  assert_contains 'cleanup_mac_test_hosts' "$gate"

  # The Mac result-bundle floor proves the four snapshot methods are included
  # in the executed target count, rather than merely present in source.
  assert_contains 'expected_test_count_floor' "$gate"
  assert_contains 'macos-unit-tests) printf' "$gate"
  assert_contains 'ios-pixel-snapshot-tests) printf' "$gate"
  assert_contains "printf '%s\\n' '{\"totalTestCount\":11}'" "$gate"
  for method in \
    testEveryPreviewStateHasLightAndDarkPixelBaselines \
    testPixelSnapshotSelectorsAreUniqueAndComplete \
    testLibraryAndPreparingBaselinesContainRenderedControls \
    testMacLibraryShellPixelBaselines \
    testMacPlayerShellPixelBaselines \
    testMacNavigationSelectionPixelBaselines \
    testShippingMacProducerPixelBaselines \
    testShippingMacURLFocusPixelBaselines; do
    assert_contains "$method" "$gate"
  done
  for method in \
    testListenerLibraryDarkPixelBaseline \
    testListenerLibraryLightPixelBaseline \
    testListenerDownloadsDarkPixelBaseline \
    testListenerDownloadsLightPixelBaseline \
    testListenerSettingsDarkPixelBaseline \
    testListenerSettingsLightPixelBaseline \
    testListenerNowPlayingDarkPixelBaseline \
    testListenerNowPlayingLightPixelBaseline \
    testListenerTerminalFailureDarkPixelBaseline \
    testListenerTerminalFailureLightPixelBaseline; do
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

  assert_contains 'run_leg "${leg_names[7]}" "${leg_reports[7]}" leg_ios_ui_tests' "$gate"
  assert_contains 'find_shutdown_iphone_udid' "$gate"
  assert_contains "ios_ui_device_name='iPhone 17 Pro'" "$gate"
  assert_contains 'ios_ui_baseline_geometry' "$gate"
  assert_contains 'name == device_name' "$gate"
  assert_contains 'native.simulator.clean-shutdown' "$gate"
  assert_contains 'geometry=%s' "$gate"
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
  assert_block_contains 'WiltediOSUITests/WiltediOSPixelSnapshotTests' "$ios_ui_block"
  assert_block_contains 'WiltediOSUITests/WiltediOSMVPFlowUITests' "$ios_ui_block"
  if printf '%s\n' "$ios_ui_block" | rg -q 'WiltediOSSmokeUITests|WiltediOSAttendedCloudKitUITests|[[:space:]]WiltediOSUITests$'; then
    printf '%s\n' 'assertion failed: iOS pixel leg must exclude smoke and attended UI tests' >&2
    exit 1
  fi
}

assert_ios_ui_clean_simulator_contract

assert_ios_mvp_journey_contract() {
  local fixture="$repo_root/WiltediOS/ListenerMVPFixture.swift"
  local app="$repo_root/WiltediOS/WiltediOSApp.swift"
  local listener_view="$repo_root/WiltediOS/ListenerAppView.swift"
  local journey="$repo_root/WiltediOSUITests/WiltediOSMVPFlowUITests.swift"

  assert_contains '#if DEBUG' "$fixture"
  assert_contains '#if DEBUG' "$app"
  assert_contains 'ListenerMVPFixture.makeModel()' "$app"
  assert_contains 'testAccountFreeListenerJourneyDownloadsPlaysResumesAndRecovers' "$journey"
  assert_contains 'wilted-player-play-pause' "$journey"
  assert_contains 'Button(playbackIsPlaying ? "Pause" : "Play")' "$listener_view"
  assert_contains 'await model.play(itemID: itemID)' "$listener_view"
  assert_contains 'XCTAssertEqual(resumeControl.label, "Play")' "$journey"
  if rg -q 'app\.buttons\["Play"\]' "$journey"; then
    printf '%s\n' 'assertion failed: MVP resume must use the now-playing control identifier' >&2
    exit 1
  fi
}

assert_ios_mvp_journey_contract

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
assert_contains 'native.passed count=8' "$success_log"

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
assert_contains 'native.insufficient-tests label=ios-pixel-snapshot-tests reported=10 expected_minimum=11' "$mvp_missing_log"
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

listener_zero_log="$tmp_dir/listener-zero.log"
listener_zero_status="$(run_case listener-zero "$listener_zero_log" env NATIVE_FORCE_ZERO_TEST_LEG=listener-tests bash "$gate")"
[[ "$listener_zero_status" -ne 0 ]] || { cat "$listener_zero_log" >&2; exit 1; }
assert_contains 'native.zero-tests label=listener-tests' "$listener_zero_log"
assert_contains 'xctest=' "$listener_zero_log"

listener_failure_log="$tmp_dir/listener-failure.log"
listener_failure_status="$(run_case listener-failure "$listener_failure_log" env NATIVE_FORCE_FAIL_LEG=listener-tests bash "$gate")"
[[ "$listener_failure_status" -ne 0 ]] || { cat "$listener_failure_log" >&2; exit 1; }
assert_contains 'native.failed count=1' "$listener_failure_log"
assert_contains 'forced_self_test_failure' "$listener_failure_log"

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

printf '%s\n' 'native gate aggregate meta-test passed (eight native Xcode legs plus CloudSync and Listener SwiftPM; forced and zero-test failures are fail-closed)'
