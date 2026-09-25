validate_pixel_snapshot_baselines() {
  local root="$1"
  local snapshot_dir="$root/WiltedMacTests/__Snapshots__/WiltedPixelSnapshotTests"
  local expected_count expected_state_ids actual_state_ids state_id state_count
  local expected_variants actual_variants variant_count shell_name bad_pngs
  local expected_selectors actual_selectors duplicate_selectors empty_pngs
  local window_baselines window_name png_path png_name
  local snapshot_test_source method

  require_tool file
  [[ -d "$snapshot_dir" ]] || fail "missing Mac pixel snapshot directory: $snapshot_dir"
  snapshot_test_source="$root/WiltedMacTests/WiltedPixelSnapshotTests.swift"
  [[ -f "$snapshot_test_source" ]] || fail "missing Mac pixel snapshot test source: $snapshot_test_source"
  grep -Fq 'assertSnapshot' "$snapshot_test_source" ||
    fail 'Mac pixel snapshot test has no image assertions'
  grep -Fq 'NSHostingView' "$snapshot_test_source" ||
    fail 'Mac pixel snapshot test does not render real AppKit views'
  grep -Fq 'WILTED_RECORD_SNAPSHOTS' "$snapshot_test_source" ||
    fail 'Mac pixel snapshots have no explicit recording mode'
  grep -Fq 'expectedPixelBaselineCount' "$snapshot_test_source" ||
    fail 'Mac pixel test does not declare its expected baseline count'
  for method in \
    testEveryPreviewStateHasLightAndDarkPixelBaselines \
    testPixelSnapshotSelectorsAreUniqueAndComplete \
    testLibraryAndPreparingBaselinesContainRenderedControls \
    testMacLibraryShellPixelBaselines \
    testMacPlayerShellPixelBaselines; do
    grep -Eq "^[[:space:]]*func[[:space:]]+$method\\(" "$snapshot_test_source" ||
      fail "Mac pixel snapshot test method is missing: $method"
  done
  grep -Fq 'WiltedMacCompactPlayer(model: model)' "$snapshot_test_source" ||
    fail 'Mac player baselines do not render the shipping compact player'
  for identifier in \
    wilted-compact-player wilted-player-speed wilted-player-rewind \
    wilted-player-play-pause wilted-player-forward \
    wilted-player-transcript wilted-player-notes wilted-player-menu wilted-player-route-recovery \
    wilted-player-volume wilted-player-scrubber wilted-player-previous \
    wilted-player-next wilted-player-restart wilted-player-keyboard-transports \
    wilted-player-status wilted-player-transcript-expanded \
    wilted-mac-menu-detail wilted-menu-clear-ready wilted-menu-clear-downloaded \
    wilted-menu-clear-available wilted-menu-mark-completed- wilted-menu-remove- wilted-menu-row-; do
    grep -Fq "$identifier" \
      "$root"/WiltedMac/Views/*.swift "$root/Shared/WiltedRootView.swift" ||
      fail "Mac compact player identifier is missing: $identifier"
  done
  grep -Fq '@FocusState private var keyboardFocus' "$root"/WiltedMac/Views/*.swift ||
    fail 'Mac compact player does not own keyboard focus restoration'
  grep -Fq '@AccessibilityFocusState private var accessibilityFocus' "$root"/WiltedMac/Views/*.swift ||
    fail 'Mac compact player does not own accessibility focus restoration'
  # The sidebar draws its own selected row. A List that also tracks selection
  # stacks AppKit's blue capsule under the leaf-tinted background, and no pixel
  # baseline can catch it: the offscreen renderer does not draw List selection,
  # which is why re-recording every baseline after the fix changed nothing.
  if grep -Eq 'List\(selection:' "$root"/WiltedMac/Views/*.swift; then
    fail 'Mac sidebar List tracks selection, which double-draws the selected row'
  fi
  grep -Fq '.accessibilityAddTraits(isSelected ? [.isSelected] : [])' \
    "$root"/WiltedMac/Views/*.swift ||
    fail 'Mac sidebar does not announce its selected destination to accessibility'
  grep -Fq 'testPodcastPlaybackStaysOutOfArticleSyncWhileArticleQueuesOneCheckpoint' \
    "$root/WiltedMacTests/WiltedVisualSystemTests.swift" ||
    fail 'Mac podcast/article sync-isolation model selector is missing'
  grep -Fq 'testPodcastPlaybackJourneyAcrossDestinations' \
    "$repo_root/WiltedMacUITests/WiltedMacSmokeUITests.swift" ||
    fail 'Mac persistent compact-player real-window selector is missing'

  expected_count=162
  [[ "$(find "$snapshot_dir" -type f -name '*.png' | wc -l | tr -d ' ')" -eq "$expected_count" ]] ||
    fail "Mac pixel baseline count is not $expected_count"
  empty_pngs="$(find "$snapshot_dir" -type f -name '*.png' -size 0c -print)"
  [[ -z "$empty_pngs" ]] || fail "Mac pixel baselines contain empty PNG files: $empty_pngs"

  expected_state_ids=$'cancelling\ncompleted\ndeletedRemotely\ndownloadFailure\nemptyLibrary\nextractionFailure\niCloudUnavailable\nincompatibleRevision\nofflineCached\npaused\nplaying\npreparing-assembling\npreparing-extracting\npreparing-fetching\npreparing-saving\npreparing-synthesizing\nready\nspeechUnavailable\nsyncPending'
  actual_state_ids="$(find "$snapshot_dir" -type f -name '*.png' -print |
    sed -E -n 's/.*\.state-(.*)-(light|dark)-(standard|xxxLarge)-motion-(full|reduced)\.png/\1/p' | sort -u)"
  [[ "$actual_state_ids" == "$(printf '%s\n' "$expected_state_ids" | sort)" ]] ||
    fail 'Mac pixel baselines do not cover exactly the required preview states'
  while IFS= read -r state_id; do
    [[ -n "$state_id" ]] || continue
    state_count="$(printf '%s\n' "$actual_state_ids" | grep -Fxc "$state_id")"
    [[ "$state_count" -eq 1 ]] || fail "duplicate preview state selector: $state_id"
    [[ "$(find "$snapshot_dir" -type f -name "*.state-$state_id-*.png" | wc -l | tr -d ' ')" -eq 8 ]] ||
      fail "preview state does not have the full visual variant matrix: $state_id"
  done <<<"$actual_state_ids"

  expected_variants=$'dark-standard-motion-full\ndark-standard-motion-reduced\ndark-xxxLarge-motion-full\ndark-xxxLarge-motion-reduced\nlight-standard-motion-full\nlight-standard-motion-reduced\nlight-xxxLarge-motion-full\nlight-xxxLarge-motion-reduced'
  actual_variants="$(find "$snapshot_dir" -type f -name '*.png' -print |
    sed -E -n 's/.*\.state-.*-(light|dark)-(standard|xxxLarge)-motion-(full|reduced)\.png/\1-\2-motion-\3/p' | sort -u)"
  [[ "$actual_variants" == "$(printf '%s\n' "$expected_variants" | sort)" ]] ||
    fail 'Mac pixel baselines do not cover exactly the required visual variants'
  while IFS= read -r variant; do
    [[ -n "$variant" ]] || continue
    variant_count="$(find "$snapshot_dir" -type f -name "*.state-*$variant.png" | wc -l | tr -d ' ')"
    [[ "$variant_count" -eq 19 ]] || fail "visual variant is missing preview states: $variant"
  done <<<"$actual_variants"

  expected_selectors=""
  while IFS= read -r state_id; do
    [[ -n "$state_id" ]] || continue
    while IFS= read -r variant; do
      [[ -n "$variant" ]] || continue
      expected_selectors+="state-$state_id-$variant\n"
    done <<<"$expected_variants"
  done <<<"$expected_state_ids"
  expected_selectors+=$'mac-shell-library-light\nmac-shell-library-dark\nmac-shell-player-light\nmac-shell-player-dark\nmac-shell-navigation-selection-light\nmac-shell-navigation-selection-dark\nmac-shell-producer-library-light\nmac-shell-producer-library-dark\nmac-shell-producer-url-focus-light\nmac-shell-producer-url-focus-dark\n'
  expected_selectors="$(printf '%b' "$expected_selectors" | sort)"
  actual_selectors="$(find "$snapshot_dir" -type f -name '*.png' -exec basename {} \; |
    sed -E 's/^.*\.(state-[^.]+|mac-shell-[^.]+)\.png$/\1/' | sort)"
  [[ "$actual_selectors" == "$expected_selectors" ]] ||
    fail 'Mac pixel baseline selectors have missing or unexpected names'
  duplicate_selectors="$(printf '%s\n' "$actual_selectors" | uniq -d)"
  [[ -z "$duplicate_selectors" ]] || fail "Mac pixel baseline selectors are not unique: $duplicate_selectors"

  for shell_name in \
    testMacLibraryShellPixelBaselines.mac-shell-library-light.png \
    testMacLibraryShellPixelBaselines.mac-shell-library-dark.png \
    testMacPlayerShellPixelBaselines.mac-shell-player-light.png \
    testMacPlayerShellPixelBaselines.mac-shell-player-dark.png \
    testMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-light.png \
    testMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-dark.png \
    testShippingMacProducerPixelBaselines.mac-shell-producer-library-light.png \
    testShippingMacProducerPixelBaselines.mac-shell-producer-library-dark.png \
    testShippingMacURLFocusPixelBaselines.mac-shell-producer-url-focus-light.png \
    testShippingMacURLFocusPixelBaselines.mac-shell-producer-url-focus-dark.png; do
    [[ -s "$snapshot_dir/$shell_name" ]] || fail "missing Mac shell baseline: $shell_name"
  done
  # Component baselines render at card scale. The two window shells render at
  # window scale so the detail region is not cropped out of the capture, and
  # both sizes are pinned here so a silent shrink back to the card canvas
  # cannot pass the gate.
  window_baselines=$'testShippingMacProducerPixelBaselines.mac-shell-producer-library-light.png\ntestShippingMacProducerPixelBaselines.mac-shell-producer-library-dark.png\ntestMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-light.png\ntestMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-dark.png'
  while IFS= read -r window_name; do
    [[ -n "$window_name" ]] || continue
    file "$snapshot_dir/$window_name" | grep -Fq 'PNG image data, 1100 x 700' ||
      fail "Mac window-scale baseline is not 1100 x 700: $window_name"
  done <<<"$window_baselines"
  bad_pngs=0
  while IFS= read -r png_path; do
    [[ -n "$png_path" ]] || continue
    png_name="$(basename "$png_path")"
    printf '%s\n' "$window_baselines" | grep -Fxq "$png_name" && continue
    file "$png_path" | grep -Fq 'PNG image data, 520 x 260' || {
      bad_pngs=$((bad_pngs + 1))
      printf 'native.snapshots.unexpected-size name=%s\n' "$png_name" >&2
    }
  done < <(find "$snapshot_dir" -type f -name '*.png' -print)
  [[ "$bad_pngs" -eq 0 ]] || fail "pixel baselines contain invalid or zero-size images: $bad_pngs"
  printf 'native.snapshots.baselines count=%s states=19 variants=8 shells=10 window_shells=4\n' "$expected_count"
}

validate_ios_pixel_snapshot_baselines() {
  local root="$1"
  local snapshot_dir="$root/WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests"
  local source="$root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift"
  local expected actual bad_pngs

  require_tool file
  [[ -f "$source" ]] || fail "missing iOS pixel snapshot test source: $source"
  [[ -d "$snapshot_dir" ]] || fail "missing iOS pixel snapshot directory: $snapshot_dir"
  grep -Fq 'wilted-listener-pixel-fixture' "$source" ||
    fail 'iOS pixel test does not exercise the shipping listener fixture'
  grep -Fq 'WiltedWordmark' "$root/WiltediOS/ListenerAppView.swift" ||
    fail 'shipping listener Library has no wordmark for iOS pixel coverage'
  for method in \
    testListenerLibraryDarkPixelBaseline \
    testListenerLibraryLightPixelBaseline \
    testListenerSettingsDarkPixelBaseline \
    testListenerSettingsLightPixelBaseline \
    testListenerNowPlayingDarkPixelBaseline \
    testListenerNowPlayingLightPixelBaseline \
    testListenerEmptyNowPlayingDarkPixelBaseline \
    testListenerEmptyNowPlayingLightPixelBaseline \
    testListenerTerminalFailureDarkPixelBaseline \
    testListenerTerminalFailureLightPixelBaseline; do
    grep -Eq "^[[:space:]]*func[[:space:]]+$method\\(" "$source" ||
      fail "iOS pixel snapshot test method is missing: $method"
  done

  expected=$'listener-library-dark.png\nlistener-library-light.png\nlistener-now-playing-dark.png\nlistener-now-playing-empty-dark.png\nlistener-now-playing-empty-light.png\nlistener-now-playing-light.png\nlistener-settings-dark.png\nlistener-settings-light.png\nlistener-terminal-failure-dark.png\nlistener-terminal-failure-light.png'
  actual="$(find "$snapshot_dir" -type f -name '*.png' -exec basename {} \; | sort)"
  [[ "$actual" == "$expected" ]] || fail 'iOS listener pixel baseline selectors are missing or unexpected'
  bad_pngs="$(find "$snapshot_dir" -type f -name '*.png' -exec file {} \; | grep -vc 'PNG image data, 390 x 844' || true)"
  [[ "$bad_pngs" -eq 0 ]] || fail "iOS listener pixel baselines are invalid or wrong-sized: $bad_pngs"
  printf 'native.ios-snapshots.baselines count=10 listener-library-downloads-settings-now-playing-terminal-failure-light-dark\n'
}

parse_result_bundle_test_count() {
  local summary_file="$1"
  jq -er '.totalTestCount | numbers | select(. > 0)' "$summary_file"
}

validate_mac_ui_selector() {
  local selector="$1"
  if [[ ! "$selector" =~ ^WiltedMacUITests/WiltedMacSmokeUITests/test[A-Za-z0-9_]+$ ]]; then
    fail 'WILTED_MAC_UI_SELECTOR must name one WiltedMacSmokeUITests test method'
    return 1
  fi
}

# The default Mac UI floor is read from the suite rather than pinned, so it
# follows journeys as they are added, merged, or retired (INVARIANTS.md
# W-INV-012) while a run that executes fewer tests than the suite declares
# still fails.
mac_ui_declared_test_count() {
  local count
  count="$(grep -cE '^[[:space:]]*func[[:space:]]+test' \
    "$repo_root/WiltedMacUITests/WiltedMacSmokeUITests.swift" || true)"
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || fail 'WiltedMacSmokeUITests declares no test methods'
  printf '%s\n' "$count"
}

expected_test_count_floor() {
  if [[ "$1" == "macos-ui-tests" && -n "${WILTED_MAC_UI_SELECTOR:-}" ]]; then
    validate_mac_ui_selector "$WILTED_MAC_UI_SELECTOR" || return 1
    printf '1\n'
    return
  fi
  case "$1" in
    macos-unit-tests) printf '30\n' ;;
    macos-ui-tests) mac_ui_declared_test_count ;;
    ios-pixel-snapshot-tests) printf '11\n' ;;
    *) printf '1\n' ;;
  esac
}

assert_mac_ui_selector_floor_contract() {
  local focused='WiltedMacUITests/WiltedMacSmokeUITests/testFocusedSelector'
  [[ "$(WILTED_MAC_UI_SELECTOR="$focused" expected_test_count_floor macos-ui-tests)" == "1" ]] ||
    fail 'validated focused Mac UI selector must require exactly one test'
  [[ "$(unset WILTED_MAC_UI_SELECTOR; expected_test_count_floor macos-ui-tests)" == \
    "$(mac_ui_declared_test_count)" ]] ||
    fail 'default Mac UI floor must equal the number of tests the suite declares'
  # A floor is a minimum, not a named set: an unrelated new test keeps the
  # suite above it while a named one quietly disappears. Tests whose absence
  # would not be caught by the count alone are asserted by identifier.
  grep -q 'testMenuOverridesAnOffPeakDeferralWithPrepareNow' \
    "$repo_root/WiltedMacUITests/WiltedMacSmokeUITests.swift" ||
    fail 'the off-peak Prepare now journey must stay in the Mac UI suite'
  # `fail` exits, so the rejecting probe runs in a subshell: the contract is
  # that an invalid selector must not SUCCEED here, not that it must return.
  if ( WILTED_MAC_UI_SELECTOR='WiltedMacUITests/OtherTests/testNope' \
    expected_test_count_floor macos-ui-tests ) >/dev/null 2>&1; then
    fail 'invalid Mac UI selector lowered the test-count floor'
  fi
}

if [[ "$native_self_test" == "1" ]]; then
  assert_mac_ui_selector_floor_contract
fi

assert_result_bundle_tests() {
  local label="$1"
  local result_bundle="$2"
  local summary_file="$tmp_root/$label-summary.json"
  local reported expected_minimum

  if [[ "$native_self_test" == "1" ]]; then
    if is_forced_zero "$label"; then
      printf '%s\n' '{"totalTestCount":0}' >"$summary_file"
    elif [[ "$label" == "ios-pixel-snapshot-tests" && "$forced_missing_ios_mvp_journey" == "1" ]]; then
      printf '%s\n' '{"totalTestCount":10}' >"$summary_file"
    elif [[ "$label" == "macos-unit-tests" ]]; then
      printf '%s\n' '{"totalTestCount":30}' >"$summary_file"
    elif [[ "$label" == "macos-ui-tests" ]]; then
      printf '{"totalTestCount":%s}\n' "$(mac_ui_declared_test_count)" >"$summary_file"
    elif [[ "$label" == "ios-pixel-snapshot-tests" ]]; then
      printf '%s\n' '{"totalTestCount":11}' >"$summary_file"
    else
      printf '%s\n' '{"totalTestCount":2}' >"$summary_file"
    fi
  else
    require_tool xcrun
    [[ -d "$result_bundle" ]] || {
      printf 'native.result-bundle-missing label=%s path=%s\n' "$label" "$result_bundle" >&2
      return 1
    }
    xcrun xcresulttool get test-results summary --path "$result_bundle" --compact >"$summary_file"
  fi

  reported="$(parse_result_bundle_test_count "$summary_file" 2>/dev/null || true)"

  if [[ -z "$reported" || "$reported" -eq 0 ]]; then
    printf 'native.zero-tests label=%s reported=%s result_bundle=%s\n' \
      "$label" "${reported:-0}" "$result_bundle" >&2
    return 1
  fi
  expected_minimum="$(expected_test_count_floor "$label")"
  if [[ "$reported" -lt "$expected_minimum" ]]; then
    printf 'native.insufficient-tests label=%s reported=%s expected_minimum=%s result_bundle=%s\n' \
      "$label" "$reported" "$expected_minimum" "$result_bundle" >&2
    return 1
  fi
  printf 'native.tests label=%s reported=%s\n' "$label" "$reported"
}

parse_xctest_output_count() {
  local output_file="$1"
  local reported

  # xcrun xctest emits an XCTest summary after the bundle has actually run.
  # Prefer the final aggregate; fall back to terminal case records so a
  # truncated or otherwise malformed runner log cannot pass as a test run.
  reported="$(awk '
    /Executed [0-9]+ tests,/ {
      line = $0
      sub(/^.*Executed /, "", line)
      sub(/ tests,.*$/, "", line)
      if (line ~ /^[0-9]+$/) last = line
    }
    /Test run with [0-9]+ tests / {
      line = $0
      sub(/^.*Test run with /, "", line)
      sub(/ tests.*$/, "", line)
      if (line ~ /^[0-9]+$/) last = line
    }
    END { if (last != "") print last }
  ' "$output_file")"
  if [[ -z "$reported" ]]; then
    reported="$(grep -Ec "^Test Case '.*' (passed|failed|skipped)" "$output_file" || true)"
  fi
  [[ "$reported" =~ ^[0-9]+$ ]] || reported=0
  printf '%s\n' "$reported"
}

leg_cloudsync_tests() {
  local package="$repo_root/CloudSync"
  local scratch_path="$tmp_root/swiftpm/cloudsync-tests"
  [[ -d "$package" ]] || fail "missing CloudSync package: $package"
  assert_test_sources cloudsync-tests "$package/Tests"
  require_tool swift

  # Keep the complete SwiftPM runner log as the leg's XCTest evidence.  The
  # named-case checks below prevent a package that merely builds or reports an
  # empty test plan from satisfying this leg.
  set +e
  swift test --package-path "$package" --scratch-path "$scratch_path" 2>&1 | tee "$tmp_root/cloudsync-tests.xctest.log" >&2
  local test_status="${PIPESTATUS[0]}"
  set -e
  if [[ "$test_status" -eq 0 ]]; then
    if ! grep -Fq 'all CloudKit field types map round trip through a valid article' "$tmp_root/cloudsync-tests.xctest.log"; then
      printf '%s\n' 'native.error CloudSync named adapter case was not observed in the test log' >&2
      return 1
    fi
    if ! grep -Fq 'transport send returns partial acknowledgement and server conflict envelope' "$tmp_root/cloudsync-tests.xctest.log"; then
      printf '%s\n' 'native.error CloudSync named send case was not observed in the test log' >&2
      return 1
    fi
  fi
  return "$test_status"
}

leg_listener_tests() {
  local package="$repo_root/Listener"
  local scratch_path="$tmp_root/swiftpm/listener-tests"
  [[ -d "$package" ]] || fail "missing Listener package: $package"
  assert_test_sources listener-tests "$package/Tests"
  require_tool swift

  # These cases exercise the durable repository and offline playback paths;
  # keep their names in the runner evidence so an empty or unrelated suite
  # cannot satisfy the leg.
  set +e
  swift test --package-path "$package" --scratch-path "$scratch_path" 2>&1 | tee "$tmp_root/listener-tests.xctest.log" >&2
  local test_status="${PIPESTATUS[0]}"
  set -e
  if [[ "$test_status" -eq 0 ]]; then
    if ! grep -Fq 'repository applies remote deletion and quarantines pending playback' "$tmp_root/listener-tests.xctest.log"; then
      printf '%s\n' 'native.error Listener repository case was not observed in the test log' >&2
      return 1
    fi
    if ! grep -Fq 'offline playback supports resume, rewind, restart, interruption, and route changes' "$tmp_root/listener-tests.xctest.log"; then
      printf '%s\n' 'native.error Listener playback case was not observed in the test log' >&2
      return 1
    fi
  fi
  return "$test_status"
}

assert_xctest_output() {
  local label="$1"
  local output_file="$2"
  local reported

  if [[ "$native_self_test" == "1" ]]; then
    if is_forced_zero "$label"; then
      printf '%s\n' "Test Suite 'All tests' started." "Test Suite 'All tests' passed." >"$output_file"
    fi
  fi
  [[ -s "$output_file" ]] || {
    printf 'native.xctest-missing label=%s path=%s\n' "$label" "$output_file" >&2
    return 1
  }
  reported="$(parse_xctest_output_count "$output_file")"
  if [[ "$reported" -eq 0 ]]; then
    printf 'native.zero-tests label=%s reported=%s xctest=%s\n' "$label" "$reported" "$output_file" >&2
    return 1
  fi
  printf 'native.tests label=%s reported=%s evidence=xctest\n' "$label" "$reported"
}

retain_ui_failure_bundle() {
  local leg_name="$1"
  local result_bundle="$2"
  local retained_bundle="$macos_ui_failure_diagnostics_dir/$leg_name.xcresult"
  local staging_bundle="$macos_ui_failure_diagnostics_dir/.$leg_name.xcresult.$$"

  [[ -d "$result_bundle" ]] || return 0
  mkdir -p "$macos_ui_failure_diagnostics_dir"
  rm -rf "$staging_bundle"
  cp -R "$result_bundle" "$staging_bundle"
  rm -rf "$retained_bundle"
  mv "$staging_bundle" "$retained_bundle"
  status "native.ui-leg.failure-bundle leg=$leg_name path=$retained_bundle"
}

clear_ui_failure_bundle() {
  local leg_name="$1"
  local retained_bundle="$macos_ui_failure_diagnostics_dir/$leg_name.xcresult"

  [[ -e "$retained_bundle" || -L "$retained_bundle" ]] || return 0
  rm -rf "$retained_bundle"
  status "native.ui-leg.failure-bundle-cleared leg=$leg_name path=$retained_bundle"
}
