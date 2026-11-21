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
  assert_validation_contains '^WiltedMacUITests/WiltedMacJourneyUITests/test[A-Za-z0-9_]+$'
  assert_validation_contains 'WiltedMacUITests/WiltedMacJourneyUITests/test06EpisodeInfoJourneyAcrossFeedsHistoryAndPlayer'
  assert_validation_contains 'focused EpisodeInfo selector must require exactly one test'
  assert_validation_contains 'saved episode info native journey must stay registered'
  assert_contains 'func test06EpisodeInfoJourneyAcrossFeedsHistoryAndPlayer' "$repo_root/WiltedMacUITests/WiltedMacEpisodeInfoUITests.swift"
  assert_validation_contains 'test07ManualPlaylistDiscoveryRenameDeleteAndShare'
  assert_validation_contains 'test08AutomaticPlaylistFormulaPreviewAndSave'
  assert_validation_contains 'playlist owner-feedback native journey must stay registered'
  assert_contains 'func test07ManualPlaylistDiscoveryRenameDeleteAndShare' "$repo_root/WiltedMacUITests/WiltedMacPlaylistUITests.swift"
  assert_contains 'func test08AutomaticPlaylistFormulaPreviewAndSave' "$repo_root/WiltedMacUITests/WiltedMacPlaylistUITests.swift"
  assert_validation_contains 'test09CommandQuitDrainsRepliesOnceAndExits'
  assert_validation_contains 'the Quit journey must sort after every other journey'
  assert_contains 'func test09CommandQuitDrainsRepliesOnceAndExits' "$repo_root/WiltedMacUITests/WiltedMacQuitUITests.swift"
  assert_validation_contains 'test03CollapsedSidebarKeepsContentBelowWindowControls'
  assert_contains 'func test03CollapsedSidebarKeepsContentBelowWindowControls' "$repo_root/WiltedMacUITests/WiltedMacSidebarChromeUITests.swift"
  # One launch per run: every journey shares the app, and the gate counts launches.
  assert_contains 'final class WiltedMacJourneyUITests: XCTestCase' "$repo_root/WiltedMacUITests/WiltedMacJourneyUITests.swift"
  assert_contains 'WILTED_UI_LAUNCH_LEDGER=$ui_launch_ledger' "$gate"
  assert_contains 'wilted_mac_ui_report_launches "$ui_launch_ledger"' "$gate"
  local ledger="$tmp_dir/ui-launches.jsonl" report="$tmp_dir/ui-launches.out"
  printf '%s\n' '{"event":"launch"}' '{"event":"switch"}' '{"event":"switch"}' >"$ledger"
  wilted_mac_ui_report_launches "$ledger" >"$report" 2>&1 || { printf 'assertion failed: %s\n' 'one launch must pass the launch count' >&2; exit 1; }
  assert_contains 'native.macos-ui.app-launches count=1 switches=2' "$report"
  [[ ! -e "$ledger" ]] || { printf 'assertion failed: %s\n' 'the launch count must remove its ledger' >&2; exit 1; }
  printf '%s\n' '{"event":"launch"}' '{"event":"launch"}' >"$ledger"
  ! wilted_mac_ui_report_launches "$ledger" >"$report" 2>&1 || { printf 'assertion failed: %s\n' 'a second launch must fail the launch count' >&2; exit 1; }
  assert_contains 'launched the app 2 times' "$report"
  ! wilted_mac_ui_report_launches "$ledger" >"$report" 2>&1 || { printf 'assertion failed: %s\n' 'an absent ledger must fail the launch count' >&2; exit 1; }
  assert_contains 'count=unknown ledger=absent' "$report"
  printf '%s\n' '{"event":"switch"}' >"$ledger"
  ! wilted_mac_ui_report_launches "$ledger" >"$report" 2>&1 || { printf 'assertion failed: %s\n' 'zero launches must fail the launch count' >&2; exit 1; }
  assert_contains 'count=0 switches=1' "$report"

  # A floor is a minimum, so a named journey can vanish while an unrelated new
  # test holds the count up. The gate asserts this one by identifier too.
  assert_validation_contains 'testLarderOverridesAnOffPeakDeferralWithPrepareNow'
  assert_contains '-only-testing:WiltedMacUITests' "$gate"
  for method in test01IntakeJourneyAcrossLarderFeedsAndSettings test02ShowSettingsUsesTheSameFeedIDFromFeedsLarderAndAllShows test02EpisodeDecisionJourneyFromFeedsToLarder; do
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
  assert_validation_contains 'expected_count=223'
  assert_validation_contains 'shells=71'
  assert_validation_contains 'window_shells=16'
  assert_validation_contains 'mac-shell-show-settings-light'
  assert_validation_contains 'mac-shell-show-settings-changed-light'
  assert_validation_contains 'mac-shell-show-settings-article-light'
  assert_validation_contains 'mac-shell-show-settings-article-dark'
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
  assert_contains 'local xcode_test_timeout_seconds="${WILTED_XCODE_TEST_TIMEOUT_SECONDS:-900}"' "$gate"
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
    testGeneralSettingsPixels \
    testNewEpisodesSettingsPixels \
    testPreparingSettingsPixels \
    testAdsSettingsPixels \
    testReportsSettingsPixels \
    testDevicesSettingsPixels \
    testAboutSettingsPixels \
    testMacNavigationSelectionPixelBaselines \
    testShippingMacProducerPixelBaselines \
    testShippingMacURLFocusPixelBaselines \
    testMacSidebarFullPixelBaselines \
    testMacSidebarRailPixelBaselines \
    testMacSidebarCountsPixelBaselines \
    testMacToolbarPixelBaselines \
    testMacAddSheetPixelBaselines \
    testShowSettingsPagePixelBaselines \
    testArticleShowSettingsPixelBaselines \
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
