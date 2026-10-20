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
  assert_contains "$1" "$native_gate_validation"
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
    printf '%s\n' 'assertion failed: native gate disables code signing' >&2; exit 1
  fi
  assert_contains 'Strip owned test-product metadata before signing' "$gate"
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

# The self-test never runs the Mac UI leg, so pin that its testmanagerd preflight precedes the build.
assert_mac_ui_testmanagerd_preflight_contract() {
  local mac_ui_block preflight_line build_line
  mac_ui_block="$(sed -n '/^leg_macos_ui_tests()/,/^}$/p' "$gate")"
  preflight_line="$(printf '%s\n' "$mac_ui_block" | rg -nF 'if ! wilted_testmanagerd_preflight; then return 1; fi' | head -1 | cut -d: -f1)"
  build_line="$(printf '%s\n' "$mac_ui_block" | rg -n 'xcodebuild build-for-testing' | head -1 | cut -d: -f1)"
  [[ -n "$preflight_line" && -n "$build_line" && "$preflight_line" -lt "$build_line" ]] || {
    printf '%s\n' 'assertion failed: Mac UI testmanagerd preflight must precede build-for-testing' >&2
    exit 1
  }
}
assert_mac_ui_testmanagerd_preflight_contract

assert_mac_test_parent_static_contract() {
  assert_contains 'wilted_mac_test_scheme_configure "$project/xcshareddata/xcschemes/$scheme.xcscheme" "$WILTED_TEMP_LEG_WORK"' "$native_gate_xcode"
  assert_contains 'mac_test_env=("WILTED_TEST_TMPDIR=$WILTED_TEMP_LEG_WORK")' "$native_gate_xcode"
  assert_contains 'wilted_mac_test_scheme_configure "$project/xcshareddata/xcschemes/WiltedMac.xcscheme" "$WILTED_TEMP_LEG_WORK"' "$gate"
  assert_contains 'TMPDIR="$WILTED_TEMP_LEG_WORK" "$@"' "$gate"
  assert_contains 'without exporting a host-owned' "$repo_root/scripts/lib/mac-test-parent.sh"
  assert_contains 'source "$repo_root/scripts/lib/mac-test-parent.sh"' "$gate"
  assert_contains 'source "$repo_root/scripts/lib/mac-test-parent.sh"' \
    "$repo_root/scripts/record-mac-snapshots.sh"
  assert_contains 'source "$repo_root/scripts/lib/mac-test-parent.sh"' \
    "$repo_root/scripts/record-walkthrough-frames.sh"
}
assert_mac_test_parent_static_contract
wilted_mac_test_parent_selftest "$tmp_dir" "$gate"
cleanup_proof="$(wilted_mac_test_host_cleanup_selftest "$tmp_dir" "$repo_root")"
assert_block_contains 'owned-host-matched=1' "$cleanup_proof"
assert_block_contains 'foreign-peer-preserved=1' "$cleanup_proof"

assert_wiltedkit_sync_contract() {
  assert_contains 'assert_test_sources wiltedkit-tests' "$gate"
  assert_contains 'testFixtureManifestPinsAllAuthoritativeCopies' "$gate"
  assert_contains 'testPublishDecodeFixture' "$gate"
  assert_contains 'leg_cloudsync_tests' "$gate"
  assert_validation_contains "local cache_key='native-cloudsync-tests'"
  assert_validation_contains 'run_with_build_cache swiftpm "$cache_key" swift test --package-path "$package"'
  assert_validation_contains 'CloudSync named zone bootstrap generation case was not observed'
  assert_validation_contains 'CloudSync named account ownership case was not observed'
  staging="$repo_root/scripts/lib/native-gate-staging.sh"; assert_contains 'source "$repo_root/scripts/lib/native-gate-staging.sh"' "$gate"
  assert_contains 'cp "$repo_root/CloudSync/Package.swift" "$integration_root/CloudSync/Package.swift"' "$staging"
  assert_contains 'cp -R "$repo_root/CloudSync/Sources" "$repo_root/CloudSync/Tests" "$integration_root/CloudSync/"' "$staging"
  assert_contains 'leg_playback_tests' "$gate"
  assert_validation_contains "local cache_key='native-playback-tests'"
  assert_validation_contains 'Playback Now Playing payload case was not observed'
  assert_contains 'cp "$repo_root/Playback/Package.swift" "$integration_root/Playback/Package.swift"' "$staging"
  assert_contains 'cp -R "$repo_root/Playback/Sources" "$repo_root/Playback/Tests" "$integration_root/Playback/"' "$staging"
  assert_absent 'leg_listener_tests' "$gate"
}

assert_wiltedkit_sync_contract

assert_build_cache_routing_contract() {
  local wiltedkit_cache cloudsync_cache playback_cache producer_cache
  local unique_count wiltedkit_block producer_block xcode_test_block mac_ui_block
  wiltedkit_cache="local cache_key='native-wiltedkit-tests'"
  cloudsync_cache="local cache_key='native-cloudsync-tests'"
  playback_cache="local cache_key='native-playback-tests'"
  producer_cache="local cache_key='native-wiltedproducer-tests'"
  assert_contains "$wiltedkit_cache" "$gate"
  assert_validation_contains "$cloudsync_cache"
  assert_validation_contains "$playback_cache"
  assert_contains "$producer_cache" "$gate"
  unique_count="$(rg -o "local cache_key='native-[^']+'" "$gate" "$native_gate_validation" | sort -u | wc -l | tr -d ' ')"
  [[ "$unique_count" -eq 4 ]] || {
    printf '%s\n' 'assertion failed: SwiftPM package legs share a cache key' >&2
    exit 1
  }
  assert_contains 'cache_path="$(build_cache_path swiftpm "$cache_key")"' "$gate"
  assert_contains 'run_package_xctest_bundles WiltedKit "$cache_path"' "$gate"
  assert_contains 'run_package_xctest_bundles WiltedProducer "$cache_path"' "$gate"
  wiltedkit_block="$(sed -n '/^leg_wiltedkit_tests()/,/^}$/p' "$gate")"
  producer_block="$(sed -n '/^leg_wiltedproducer_tests()/,/^}$/p' "$gate")"
  assert_block_contains 'build_cache_path swiftpm "$cache_key"' "$wiltedkit_block"
  assert_block_contains 'run_with_build_cache swiftpm "$cache_key" swift build' "$wiltedkit_block"
  assert_block_contains 'build_cache_path swiftpm "$cache_key"' "$producer_block"
  assert_block_contains 'run_with_build_cache swiftpm "$cache_key" swift build' "$producer_block"
  xcode_test_block="$(sed -n '/^xcode_test_leg()/,/^}$/p' "$native_gate_xcode")"
  assert_block_contains 'python3 "$build_with_cache" run xcode "$cache_key" -- xcodebuild test' "$xcode_test_block"
  mac_ui_block="$(sed -n '/^leg_macos_ui_tests()/,/^}$/p' "$gate")"
  assert_block_contains 'build_cache_path xcode "$cache_key"' "$mac_ui_block"
  assert_block_contains 'run_with_build_cache xcode "$cache_key" xcodebuild build-for-testing' "$mac_ui_block"
  assert_block_contains 'run xcode "$cache_key" -- xcodebuild test-without-building' "$mac_ui_block"
  if rg -q -- '--scratch-path|\$tmp_root/swiftpm|derived_data=|DerivedData' "$gate" "$native_gate_validation"; then
    printf '%s\n' 'assertion failed: native gate retains a per-run build cache root' >&2
    exit 1
  fi
  if rg -n '(^|[[:space:]])(swift (build|test)|xcodebuild (test|build-for-testing|test-without-building))' \
      "$gate" "$native_gate_validation" | \
      rg -qv 'run_with_build_cache|build_with_cache.*run xcode'; then
    printf '%s\n' 'assertion failed: a native build bypasses the reusable build cache helper' >&2
    exit 1
  fi
  if rg -q 'find "\$package/\.build".*PackageTests\.xctest' "$gate" "$native_gate_validation"; then
    printf '%s\n' 'assertion failed: XCTest discovery still reads checkout-local .build' >&2
    exit 1
  fi
}

assert_build_cache_routing_contract

# shellcheck source=../scripts/lib/native-gate-capability-contract.sh
source "$repo_root/scripts/lib/native-gate-capability-contract.sh"

assert_capability_source_contract

# A leg function that is defined but never invoked is invisible: the macOS UI
# leg was dropped from the run list in 040e7b8 while `leg_macos_ui_tests` stayed
# in the file, so for two days nothing drove the real Mac window and a window
# composition the owner rejected on sight cleared a green gate. Assert the leg
# is executed, not merely present, and pin its floor so an empty suite cannot
# pass either.
assert_macos_ui_leg_is_executed() {
  assert_contains 'leg_macos_ui_tests()' "$gate"
  assert_contains 'leg_macos_ui_tests' "$gate"
  assert_contains 'wilted_gate_parallel_launch "$name" "${leg_reports[$i]}" "${leg_fns[$i]}"' "$repo_root/scripts/lib/native-gate-legs.sh"
  assert_contains '  macos-ui-tests' "$gate"
  assert_validation_contains 'macos-ui-tests) mac_ui_declared_test_count ;;'
  assert_validation_contains 'WiltedMacSmokeUITests WiltedMacSidebarChromeUITests WiltedMacQuitUITests WiltedMacEpisodeInfoUITests WiltedMacPlaylistUITests'
  assert_validation_contains 'WiltedMacSmokeUITests|WiltedMacSidebarChromeUITests|WiltedMacEpisodeInfoUITests'
  assert_validation_contains 'WiltedMacUITests/WiltedMacEpisodeInfoUITests/testEpisodeInfoJourneyAcrossFeedsHistoryAndPlayer'
  assert_validation_contains 'focused EpisodeInfo selector must require exactly one test'
  assert_validation_contains 'saved episode info native journey must stay registered'
  assert_contains 'func testEpisodeInfoJourneyAcrossFeedsHistoryAndPlayer' "$repo_root/WiltedMacUITests/WiltedMacEpisodeInfoUITests.swift"
  assert_validation_contains 'testManualPlaylistDiscoveryRenameDeleteAndShare'
  assert_validation_contains 'testAutomaticPlaylistFormulaPreviewAndSave'
  assert_validation_contains 'playlist owner-feedback native journey must stay registered'
  assert_contains 'func testManualPlaylistDiscoveryRenameDeleteAndShare' "$repo_root/WiltedMacUITests/WiltedMacPlaylistUITests.swift"
  assert_contains 'func testAutomaticPlaylistFormulaPreviewAndSave' "$repo_root/WiltedMacUITests/WiltedMacPlaylistUITests.swift"
  assert_validation_contains 'testCommandQuitDrainsRepliesOnceAndExits'
  assert_contains 'func testCommandQuitDrainsRepliesOnceAndExits' "$repo_root/WiltedMacUITests/WiltedMacQuitUITests.swift"
  assert_validation_contains 'testCollapsedSidebarKeepsContentBelowWindowControls'
  assert_contains 'func testCollapsedSidebarKeepsContentBelowWindowControls' "$repo_root/WiltedMacUITests/WiltedMacSidebarChromeUITests.swift"

  # A floor is a minimum, so a named journey can vanish while an unrelated new
  # test holds the count up. The gate asserts this one by identifier too.
  assert_validation_contains 'testLarderOverridesAnOffPeakDeferralWithPrepareNow'
  assert_contains '-only-testing:WiltedMacUITests' "$gate"
  for method in testIntakeJourneyAcrossLarderFeedsAndSettings testEpisodeDecisionJourneyFromFeedsToLarder; do
    assert_contains "$method" "$repo_root/WiltedMacUITests/WiltedMacSmokeUITests.swift"
  done
  # The other journeys run headless in the Mac unit leg.
  assert_contains testPodcastPlaybackJourneyAcrossDestinations "$repo_root/WiltedMacTests/WiltedMacPlaybackJourneyTests.swift"
  assert_contains testSettingsAutomationAndSyncRecoveryJourney "$repo_root/WiltedMacTests/WiltedMacSettingsJourneyTests.swift"
}

assert_macos_ui_leg_is_executed

assert_snapshot_contract() {
  assert_contains 'source "$repo_root/scripts/lib/native-gate-validation.sh"' "$gate"
  assert_contains 'validate_pixel_snapshot_baselines' "$gate"
  assert_contains 'validate_ios_pixel_snapshot_baselines' "$gate"
  assert_validation_contains 'expected_count=210'
  assert_validation_contains 'shells=58'
  assert_validation_contains 'WiltedPixelSnapshotTests+Rendering.swift'
  assert_validation_contains "expected_size='202 x 260'"
  assert_validation_contains "expected_size='56 x 260'"
  assert_validation_contains "expected_size='520 x 420'"
  assert_validation_contains "expected_size='224 x 56'"
  assert_validation_contains "expected_size='760 x 440'"
  assert_validation_contains 'testFeedsRowPixelBaselines.mac-shell-feeds-row-light.png'
  assert_validation_contains 'testFeedsRowPixelBaselines.mac-shell-feeds-row-dark.png'
  for kind in minimum full; do
    for appearance in light dark; do
      assert_validation_contains "testRealSizeLarderHeaderPixelBaselines.mac-shell-larder-real-size-$kind-$appearance.png"
    done
  done
  assert_validation_contains "expected_size='520 x 560'"
  assert_validation_contains "expected_size='1000 x 560'"
  assert_validation_contains "expected_size='640 x 740'"
  assert_contains 'func testNowPlayingPanePixelBaselines' "$repo_root/WiltedMacTests/WiltedPixelSnapshotTests+NowPlaying.swift"
  for appearance in light dark; do
    assert_validation_contains "testNowPlayingPanePixelBaselines.mac-shell-now-playing-pane-$appearance.png"
  done
  assert_contains 'func testRealSizeLarderHeaderPixelBaselines' "$repo_root/WiltedMacTests/WiltedPixelSnapshotTests+LarderRows.swift"

  assert_validation_contains 'expected_state_ids='
  assert_validation_contains 'expected_variants='
  assert_validation_contains 'expected_selectors'
  assert_validation_contains 'duplicate_selectors'
  assert_validation_contains 'empty_pngs'
  assert_contains 'cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests"' "$staging"
  assert_contains 'cp "$repo_root/Producer/Package.swift" "$integration_root/Producer/Package.swift"' "$staging"
  assert_contains 'cp -R "$repo_root/Producer/Sources" "$repo_root/Producer/Tests" "$integration_root/Producer/"' "$staging"
  for entitlement in \
    WiltedMac/WiltedMac.entitlements \
    WiltedMac/WiltedMacProduction.entitlements \
    WiltediOS/WiltediOS.entitlements \
    WiltediOS/WiltediOSProduction.entitlements; do
    assert_contains "$entitlement" "$staging"
  done
  assert_contains 'validate_pixel_snapshot_baselines "$integration_root"' "$gate"
  assert_contains 'validate_ios_pixel_snapshot_baselines "$integration_root"' "$gate"
  assert_contains 'NATIVE_FORCE_SNAPSHOT_BASELINE' "$gate"
  assert_contains 'mac-test-hosts-deferred=product-live' "$gate"
  assert_contains 'wilted_mac_test_host_pattern' "$repo_root/scripts/lib/mac-test-parent.sh"
  assert_contains 'canonical_root="$(cd -P "$repo_root"' "$repo_root/scripts/lib/mac-test-parent.sh"
  assert_contains 'cache_root="$canonical_root/.build/xcode"' "$repo_root/scripts/lib/mac-test-parent.sh"
  assert_contains 'native.cleanup mac-test-hosts-matched=' "$repo_root/scripts/lib/mac-test-parent.sh"
  assert_contains 'foreign-peer-preserved=1' "$repo_root/scripts/lib/mac-test-parent.sh"
  assert_contains 'trap cleanup EXIT' "$gate"
  assert_contains 'WILTED_XCODE_TEST_TIMEOUT_SECONDS' "$gate"
  assert_contains 'WILTED_XCODE_TEST_TIMEOUT_SECONDS:-600' "$gate"
  # The Mac unit leg's one xcodebuild test both builds and tests, so it gets both budgets (cold-cache kills at 600 s).
  assert_contains 'WILTED_XCODE_BUILD_AND_TEST_TIMEOUT_SECONDS:-1200' "$gate"
  assert_contains 'WILTED_TEST_TIMEOUT_SECONDS="${xcode_build_and_test_timeout_seconds:-$xcode_test_timeout_seconds}"' "$native_gate_xcode"
  assert_contains 'WILTED_NATIVE_LEG_TIMEOUT_SECONDS' "$gate"
  assert_contains 'scripts/run-bounded.py' "$gate"
  assert_contains 'WILTED_TEST_TIMEOUT_SECONDS="$timeout_seconds"' "$gate"
  assert_contains 'WILTED_WORK_PHASE=build-and-test' "$native_gate_xcode"
  assert_absent 'elapsed_seconds >= xcode_test_timeout_seconds' "$native_gate_xcode"
  # The Mac unit leg keeps build and test in one host-UI transaction (its hosts share a
  # bundle identifier); simulator legs build before taking the lane and host-UI locks.
  simulator_branch="$(sed -n "/destination\" == \*'id='\*/,/^  else\$/p" "$native_gate_xcode")"
  mac_unit_branch="$(sed -n '/^  else$/,/gate_ui_test_lock --label/p' "$native_gate_xcode")"
  assert_block_contains 'xcodebuild test \' "$mac_unit_branch"
  [[ "$mac_unit_branch" != *build-for-testing* && "$mac_unit_branch" != *test-without-building* ]] \
    || { printf '%s\n' 'assertion failed: Mac unit leg split build from test' >&2; exit 1; }
  assert_block_contains 'run_with_build_cache xcode "$cache_key" xcodebuild build-for-testing' "$simulator_branch"
  assert_block_contains 'WILTED_WORK_PHASE=test' "$simulator_branch"
  assert_block_contains 'xcodebuild test-without-building' "$simulator_branch"
  [[ "${simulator_branch%%build-for-testing*}" != *wilted_gate_simulator_session* ]] \
    || { printf '%s\n' 'assertion failed: iOS build runs inside the simulator session' >&2; exit 1; }

  # The Mac result-bundle floor proves the four snapshot methods are included
  # in the executed target count, rather than merely present in source.
  assert_validation_contains 'expected_test_count_floor'
  assert_validation_contains 'macos-unit-tests) printf'
  assert_validation_contains 'ios-pixel-snapshot-tests) printf'
  assert_validation_contains 'ui_count="$(mac_ui_declared_test_count)"'
  assert_validation_contains 'result":"Passed"'
  for method in \
    testEveryPreviewStateHasLightAndDarkPixelBaselines \
    testPixelSnapshotSelectorsAreUniqueAndComplete \
    testLibraryAndPreparingBaselinesContainRenderedControls \
    testMacLibraryShellPixelBaselines \
    testMacPlayerShellPixelBaselines \
    testMacNavigationSelectionPixelBaselines \
    testShippingMacProducerPixelBaselines \
    testShippingMacURLFocusPixelBaselines \
    testMacSidebarFullPixelBaselines \
    testMacSidebarRailPixelBaselines \
    testMacToolbarPixelBaselines \
    testMacAddSheetPixelBaselines \
    testArticleFeedPolicyPopoverPixelBaselines \
    testArticleFeedInboxRowPixelBaselines \
    testLarderKindFilterPixelBaselines \
    testLarderBookRowPixelBaselines \
    testPlayerChaptersPixelBaselines \
    testBulletinBannerPixelBaselines \
    testLarderReportRowPixelBaselines; do
    assert_validation_contains "$method"
  done
}

assert_snapshot_contract

assert_private_simulator_contract() {
  assert_contains 'scripts/select-ios-simulator.py' "$native_gate_simulator"
  assert_contains "name = 'wilted-persistent-'" "$native_gate_simulator"
  assert_contains 'boot_owned = True' "$native_gate_simulator"
  assert_contains "if boot_owned and udid:" "$native_gate_simulator"
  assert_absent "'delete', udid" "$native_gate_simulator"
  assert_contains 'gate_sweep wilted' "$gate"
  assert_contains 'gate_ui_test_lock --label persistent-tests --simulator-udid' "$native_gate_simulator"
  assert_contains 'gate_ui_test_lock --label "$label"' "$gate"
  assert_contains 'python3 "$build_with_cache" run xcode "$cache_key" -- xcodebuild test-without-building' "$gate"
}

assert_private_simulator_contract

assert_fail_stops_its_leg_contract() {
  local fail_block
  fail_block="$(sed -n '/^fail()/,/^}$/p' "$gate")"
  assert_block_contains 'exit 1' "$fail_block"
  # The FIFO logger keeps the leg function in this shell, so its direct status
  # remains available while the inner signal trap owns its supervisor.
  assert_contains 'command_status=$?' "$gate"
  assert_contains 'wilted_finish_logger' "$gate"
  assert_contains 'udid="$(create_gate_simulator ios-units)" || return 1' "$gate"
  assert_contains 'project="$(find_project)" || return 1' "$native_gate_xcode"
}

assert_fail_stops_its_leg_contract

assert_stray_host_cleanup_contract() {
  assert_contains 'if [[ "$native_self_test" != 1 ]]; then cleanup_mac_test_hosts; fi' "$gate"
  assert_absent 'cleanup_mac_test_hosts' "$native_gate_xcode"
  # One parent sweep must finish before workers launch; no sweep may race a
  # sibling's newly built product inside the parallel leg helper.
  python3 - "$gate" "$repo_root/scripts/lib/native-gate-parallel.sh" <<'PYORDER'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
sweep = 'if [[ "$native_self_test" != 1 ]]; then cleanup_mac_test_hosts; fi'
assert source.count(sweep) == 1
assert source.index(sweep) < source.index('\nwilted_gate_run_legs\n')
assert 'cleanup_mac_test_hosts' not in Path(sys.argv[2]).read_text()
PYORDER
}

assert_stray_host_cleanup_contract

assert_ios_mvp_journey_contract() {
  local fixture="$repo_root/WiltediOS/Library/LibraryUITestFixture.swift"
  local app="$repo_root/WiltediOS/WiltediOSApp.swift"
  local journey="$repo_root/WiltediOSUITests/WiltediOSMVPFlowUITests.swift"

  assert_contains '#if DEBUG' "$fixture"
  assert_contains 'LibraryUITestFixtureHost(stack: stack)' "$app"
  assert_contains 'testLibraryRootFixtureRendersProductionRootAndPlaysWithoutLiveTransport' "$journey"
  assert_contains 'testLibraryRootDuplicatePressWhileStartingMakesOneStart' "$journey"
  assert_contains 'wilted-library-play-' "$journey"
  assert_contains 'LibraryRoot' "$repo_root/WiltediOSUITests/WiltediOSAttendedCloudKitUITests.swift"
}

assert_ios_mvp_journey_contract

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
assert_contains 'native.passed count=9' "$success_log"
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
  assert_contains 'WILTED_MAC_UI=1 caffeinate -disu python3 scripts/native-ui-receipt.py record' "$repo_root/Makefile"
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
assert_contains 'native.passed count=8 deferred=1' "$mac_ui_deferred_log"
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
assert_contains 'native.passed count=9' "$mac_ui_optin_log"
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
assert_contains 'VNRecognizeTextRequest()' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"
assert_contains 'value.frame.minY, label.frame.maxY' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"
assert_contains 'assertPaintedLine("Nov 14, 2023", frame: metadata.frame)' "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"

printf '%s\n' 'native gate aggregate meta-test passed (nine native Xcode legs; the macOS UI leg defers unless WILTED_MAC_UI=1 and its deferral is fail-loud; forced and zero-test failures are fail-closed; the retained failure bundle is untouched)'
