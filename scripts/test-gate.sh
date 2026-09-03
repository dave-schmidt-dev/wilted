#!/usr/bin/env bash
set -Eeuo pipefail

# Credential-free native gate for the generated Mac/iOS project.  The live
# gate uses only local XcodeGen, SwiftPM, xcodebuild, and simctl capabilities.
# NATIVE_SELF_TEST is intentionally hermetic and is used by the meta-test.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_yml="$repo_root/project.yml"
native_self_test="${NATIVE_SELF_TEST:-0}"
forced_fail_leg="${NATIVE_FORCE_FAIL_LEG:-}"
forced_zero_leg="${NATIVE_FORCE_ZERO_TEST_LEG:-}"
forced_snapshot_baseline="${NATIVE_FORCE_SNAPSHOT_BASELINE:-}"
forced_missing_ios_mvp_journey="${NATIVE_FORCE_MISSING_IOS_MVP_JOURNEY:-0}"
wilted_development_team="${WILTED_DEVELOPMENT_TEAM:-4CJ49V6QHW}"
# macOS XCUITest has no headless mode: it drives real HID events through
# WindowServer, so the macos-ui-tests leg seizes the operator's cursor,
# keyboard, and window focus for its whole run. It is therefore opt-in and
# defers by default. A deferred leg is NOT a passed leg -- it is counted and
# reported separately, and `native.passed` names it, so a green gate can never
# be read as evidence the Mac UI suite ran. Opt in with `make native-ui` or
# WILTED_MAC_UI=1.
wilted_mac_ui="${WILTED_MAC_UI:-0}"
xcode_test_timeout_seconds="${WILTED_XCODE_TEST_TIMEOUT_SECONDS:-300}"
# The iOS pixel baselines were recorded on iPhone 17 Pro. Selecting it by name
# keeps the UI leg from silently using a different first-listed iPhone model.
ios_ui_device_name='iPhone 17 Pro'
ios_ui_baseline_geometry='402x874 normalized to 390x844'
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-native-gate.XXXXXX")"
derived_data="$tmp_root/DerivedData"
# A failed real Mac UI run is the one disposable artifact worth retaining for
# diagnosis. The default lives under the repository's ignored .logs directory;
# the override keeps the meta-test hermetic.
macos_ui_failure_diagnostics_dir="${WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR:-$repo_root/.logs/native-gate-diagnostics}"
mkdir -p "$derived_data"

cleanup_mac_test_hosts() {
  local test_host_pattern test_host_pids
  test_host_pattern="$derived_data/.*/WiltedMac.app/Contents/MacOS/WiltedMac"
  test_host_pids="$(pgrep -f "$test_host_pattern" 2>/dev/null || true)"
  if [[ -n "$test_host_pids" ]]; then
    kill $test_host_pids 2>/dev/null || true
    status "native.cleanup mac-test-hosts=$(printf '%s\n' "$test_host_pids" | wc -l | tr -d ' ')"
  fi
}

cleanup() {
  cleanup_mac_test_hosts
  rm -rf "$tmp_root"
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

leg_names=(
  xcodegen-reproducible
  wiltedkit-tests
  cloudsync-tests
  listener-tests
  wiltedproducer-tests
  macos-unit-tests
  ios-unit-tests
  macos-ui-tests
  ios-pixel-snapshot-tests
)
leg_reports=(none xctest xctest xctest xctest count count count count)
declare -i failed_legs=0
declare -i completed_legs=0
declare -i deferred_legs=0
deferred_leg_names=()
native_project=""
integration_root=""

status() {
  printf '%s\n' "$1" >&2
}

fail() {
  printf 'native.error %s\n' "$1" >&2
  return 1
}

is_forced_failure() {
  [[ "$forced_fail_leg" == "$1" ]]
}

is_deferred_leg() {
  [[ "$1" == "macos-ui-tests" && "$wilted_mac_ui" != "1" ]]
}

is_forced_zero() {
  [[ "$forced_zero_leg" == "$1" ]]
}

count_source_files() {
  local directory="$1"
  if [[ ! -d "$directory" ]]; then
    printf '0\n'
    return 0
  fi
  find "$directory" -type f -name '*.swift' -print | wc -l | tr -d ' '
}

assert_test_sources() {
  local label="$1"
  local directory="$2"
  local file_count

  file_count="$(count_source_files "$directory")"
  if [[ "$file_count" -eq 0 ]]; then
    printf 'native.zero-sources label=%s source_files=0 path=%s\n' "$label" "$directory" >&2
    return 1
  fi
  printf 'native.discovery label=%s source_files=%s\n' "$label" "$file_count"
}

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
    wilted-player-play-pause wilted-player-forward wilted-player-overflow \
    wilted-player-transcript wilted-player-up-next wilted-player-route-recovery \
    wilted-player-volume wilted-player-scrubber wilted-player-previous \
    wilted-player-next wilted-player-restart wilted-player-keyboard-transports \
    wilted-player-status wilted-player-transcript-expanded \
    wilted-player-up-next-expanded wilted-player-up-next-remove- \
    wilted-player-up-next-move-earlier- wilted-player-up-next-move-later-; do
    grep -Fq "$identifier" \
      "$root/WiltedMac/WiltedMacRootView.swift" "$root/Shared/WiltedRootView.swift" ||
      fail "Mac compact player identifier is missing: $identifier"
  done
  grep -Fq '@FocusState private var keyboardFocus' "$root/WiltedMac/WiltedMacRootView.swift" ||
    fail 'Mac compact player does not own keyboard focus restoration'
  grep -Fq '@AccessibilityFocusState private var accessibilityFocus' "$root/WiltedMac/WiltedMacRootView.swift" ||
    fail 'Mac compact player does not own accessibility focus restoration'
  # The sidebar draws its own selected row. A List that also tracks selection
  # stacks AppKit's blue capsule under the leaf-tinted background, and no pixel
  # baseline can catch it: the offscreen renderer does not draw List selection,
  # which is why re-recording every baseline after the fix changed nothing.
  if grep -Eq 'List\(selection:' "$root/WiltedMac/WiltedMacRootView.swift"; then
    fail 'Mac sidebar List tracks selection, which double-draws the selected row'
  fi
  grep -Fq '.accessibilityAddTraits(isSelected ? [.isSelected] : [])' \
    "$root/WiltedMac/WiltedMacRootView.swift" ||
    fail 'Mac sidebar does not announce its selected destination to accessibility'
  grep -Fq 'testPodcastPlaybackStaysOutOfArticleSyncWhileArticleQueuesOneCheckpoint' \
    "$root/WiltedMacTests/WiltedVisualSystemTests.swift" ||
    fail 'Mac podcast/article sync-isolation model selector is missing'
  grep -Fq 'testPodcastCompactPlayerPersistsAcrossLarderScrollAndExposesCompleteControls' \
    "$root/WiltedMacUITests/WiltedMacSmokeUITests.swift" ||
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

expected_test_count_floor() {
  if [[ "$1" == "macos-ui-tests" && -n "${WILTED_MAC_UI_SELECTOR:-}" ]]; then
    validate_mac_ui_selector "$WILTED_MAC_UI_SELECTOR" || return 1
    printf '1\n'
    return
  fi
  case "$1" in
    macos-unit-tests) printf '30\n' ;;
    macos-ui-tests) printf '16\n' ;;
    ios-pixel-snapshot-tests) printf '11\n' ;;
    *) printf '1\n' ;;
  esac
}

assert_mac_ui_selector_floor_contract() {
  local focused='WiltedMacUITests/WiltedMacSmokeUITests/testFocusedSelector'
  [[ "$(WILTED_MAC_UI_SELECTOR="$focused" expected_test_count_floor macos-ui-tests)" == "1" ]] ||
    fail 'validated focused Mac UI selector must require exactly one test'
  [[ "$(unset WILTED_MAC_UI_SELECTOR; expected_test_count_floor macos-ui-tests)" == "16" ]] ||
    fail 'default Mac UI suite must retain its sixteen-test floor'
  if WILTED_MAC_UI_SELECTOR='WiltedMacUITests/OtherTests/testNope' \
    expected_test_count_floor macos-ui-tests >/dev/null 2>&1; then
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
      printf '%s\n' '{"totalTestCount":16}' >"$summary_file"
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
    else
      printf '%s\n' "Test Case '-[SelfTest testOne]' passed (0.000 seconds)." \
        "Test Case '-[SelfTest testTwo]' passed (0.000 seconds)." \
        "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.000 seconds" >"$output_file"
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

retain_macos_ui_failure_bundle() {
  local result_bundle="$1"
  local retained_bundle="$macos_ui_failure_diagnostics_dir/macos-ui-tests.xcresult"
  local staging_bundle="$macos_ui_failure_diagnostics_dir/.macos-ui-tests.xcresult.$$"

  [[ -d "$result_bundle" ]] || return 0
  mkdir -p "$macos_ui_failure_diagnostics_dir"
  rm -rf "$staging_bundle"
  cp -R "$result_bundle" "$staging_bundle"
  rm -rf "$retained_bundle"
  mv "$staging_bundle" "$retained_bundle"
  status "native.macos-ui.failure-bundle path=$retained_bundle"
}

clear_macos_ui_failure_bundle() {
  local retained_bundle="$macos_ui_failure_diagnostics_dir/macos-ui-tests.xcresult"

  [[ -e "$retained_bundle" || -L "$retained_bundle" ]] || return 0
  rm -rf "$retained_bundle"
  status "native.macos-ui.failure-bundle-cleared path=$retained_bundle"
}

run_leg() {
  local name="$1"
  local report_mode="$2"
  shift 2
  local output_file="$tmp_root/$name.log"
  local result_bundle="$tmp_root/$name.xcresult"
  local command_status=0

  if is_deferred_leg "$name"; then
    deferred_legs+=1
    deferred_leg_names+=("$name")
    status "native.leg.deferred name=$name reason=takes-over-the-screen rerun=\"make native-ui\""
    return 0
  fi

  status "native.leg.start name=$name"
  if is_forced_failure "$name"; then
    printf '%s\n' 'forced_self_test_failure' >"$output_file"
    if [[ "$native_self_test" == "1" && "$name" == "macos-ui-tests" ]]; then
      mkdir -p "$result_bundle"
      printf '%s\n' 'self_test_macos_ui_failure_evidence' >"$result_bundle/self-test-evidence"
    fi
    command_status=1
  elif is_forced_zero "$name"; then
    printf '%s\n' 'forced_self_test_zero_result_bundle' >"$output_file"
    if [[ "$native_self_test" == "1" && "$name" == "macos-ui-tests" ]]; then
      mkdir -p "$result_bundle"
      printf '%s\n' 'self_test_macos_ui_zero_test_evidence' >"$result_bundle/self-test-evidence"
    fi
    command_status=0
  elif [[ "$native_self_test" == "1" ]]; then
    printf '%s\n' 'self_test_command_success' >"$output_file"
    command_status=0
  else
    set +e
    "$@" 2>&1 | tee "$output_file" >&2
    command_status="${PIPESTATUS[0]}"
    set -e
  fi

  if [[ "$command_status" -eq 0 && "$report_mode" == "count" ]]; then
    set +e
    assert_result_bundle_tests "$name" "$result_bundle"
    local count_status=$?
    set -e
    if [[ "$count_status" -ne 0 ]]; then
      command_status="$count_status"
    fi
  elif [[ "$command_status" -eq 0 && "$report_mode" == "xctest" ]]; then
    set +e
    assert_xctest_output "$name" "$tmp_root/$name.xctest.log"
    local xctest_status=$?
    set -e
    if [[ "$xctest_status" -ne 0 ]]; then
      command_status="$xctest_status"
    fi
  fi

  if [[ "$name" == "macos-ui-tests" ]]; then
    if [[ "$command_status" -ne 0 ]]; then
      retain_macos_ui_failure_bundle "$result_bundle"
    else
      clear_macos_ui_failure_bundle
    fi
  fi

  completed_legs+=1
  if [[ "$command_status" -ne 0 ]]; then
    failed_legs+=1
    status "native.leg.complete name=$name status=$command_status"
    if [[ -s "$output_file" ]]; then
      printf '%s\n' "--- $name output ---" >&2
      cat "$output_file" >&2 || true
    fi
    return 0
  fi
  status "native.leg.complete name=$name status=0"
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
}

generated_project_path() {
  find "$1" -maxdepth 1 -type d -name '*.xcodeproj' -print -quit
}

leg_xcodegen_reproducible() {
  [[ -f "$integration_root/project.yml" ]] || fail "missing integration XcodeGen source"
  require_tool xcodegen

  local first="$tmp_root/generated-first"
  local second="$tmp_root/generated-second"
  mkdir -p "$first" "$second"
  xcodegen generate --spec "$integration_root/project.yml" --project "$first" --project-root "$integration_root"
  xcodegen generate --spec "$integration_root/project.yml" --project "$second" --project-root "$integration_root"

  # XcodeGen resolves plist and entitlement paths relative to the generated
  # project, while the disposable project lives under tmp_root. Keep every
  # referenced signing input in both generated projects so xcodebuild never
  # reads or writes the checkout.
  local project_file
  for project_file in \
    WiltedMac/Info.plist WiltedMac/WiltedMac.entitlements \
    WiltedMac/WiltedMacProduction.entitlements WiltediOS/Info.plist \
    WiltediOS/WiltediOS.entitlements WiltediOS/WiltediOSProduction.entitlements; do
    mkdir -p "$first/$(dirname "$project_file")" "$second/$(dirname "$project_file")"
    cp "$integration_root/$project_file" "$first/$project_file"
    cp "$integration_root/$project_file" "$second/$project_file"
  done

  local first_project second_project
  first_project="$(generated_project_path "$first")"
  second_project="$(generated_project_path "$second")"
  [[ -n "$first_project" && -n "$second_project" ]] || fail 'XcodeGen produced no .xcodeproj'
  diff -ru "$first_project" "$second_project"
  native_project="$first_project"
  printf 'native.xcodegen.reproducible project=%s\n' "$(basename "$first_project")"
}

leg_wiltedkit_tests() {
  local package="$repo_root/WiltedKit"
  local scratch_path="$tmp_root/swiftpm/wiltedkit-tests"
  local authoritative="$repo_root/contracts/fixtures"
  local copied="$package/Tests/WiltedDomainTests/Fixtures"
  local sync_authoritative="$repo_root/contracts/cloudkit/fixtures/01-valid-publish-decode.json"
  local sync_copied="$package/Tests/WiltedSyncTests/Fixtures/01-valid-publish-decode.json"
  [[ -d "$package" ]] || fail "missing WiltedKit package: $package"
  [[ -d "$authoritative" && -d "$copied" ]] || fail 'missing authoritative or WiltedKit fixture directory'
  if ! diff -u <(find "$authoritative" -maxdepth 1 -type f -name '*.json' -exec basename {} \; | sort) \
      <(find "$copied" -maxdepth 1 -type f -name '*.json' ! -name 'FixtureManifest.json' -exec basename {} \; | sort); then
    fail 'WiltedKit fixture names differ from authoritative contracts/fixtures'
  fi
  local fixture
  while IFS= read -r fixture; do
    cmp -s "$authoritative/$fixture" "$copied/$fixture" ||
      fail "WiltedKit fixture drift: $fixture"
  done < <(find "$authoritative" -maxdepth 1 -type f -name '*.json' -exec basename {} \; | sort)
  [[ -f "$sync_authoritative" && -f "$sync_copied" ]] || fail 'missing authoritative or copied sync fixture'
  cmp -s "$sync_authoritative" "$sync_copied" || fail 'WiltedSync authoritative fixture drift'
  printf 'native.sync-fixture.parity file=%s\n' "$(basename "$sync_authoritative")"
  printf 'native.fixtures.parity count=%s\n' "$(find "$authoritative" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  assert_test_sources wiltedkit-tests "$package/Tests"
  # Keep the sync-core suite in the package leg's executed test bundle; a
  # generic domain source count must not allow this target to disappear.
  assert_test_sources wiltedsync-tests "$package/Tests/WiltedSyncTests"
  require_tool swift
  require_tool xcrun
  swift build --package-path "$package" --scratch-path "$scratch_path" --build-tests
  local test_bundle
  test_bundle="$(find "$scratch_path" -type d -name 'WiltedKitPackageTests.xctest' -print -quit)"
  [[ -n "$test_bundle" && -d "$test_bundle" ]] || fail 'WiltedKit XCTest bundle was not produced'

  # The installed Swift toolchain accepts the SwiftPM xUnit flag but does not
  # emit the requested file for this package. Invoke the built XCTest bundle
  # directly; its runner log is authoritative and remains visible while running.
  set +e
  xcrun xctest "$test_bundle" 2>&1 | tee "$tmp_root/wiltedkit-tests.xctest.log" >&2
  local xctest_status="${PIPESTATUS[0]}"
  set -e
  if [[ "$xctest_status" -eq 0 ]]; then
    [[ -s "$tmp_root/wiltedkit-tests.xctest.log" ]] || fail 'WiltedKit XCTest log is empty'
    grep -Fq 'authoritative publish fixture decodes all records and round trips exactly' "$tmp_root/wiltedkit-tests.xctest.log" ||
      fail 'WiltedSyncTests fixture case was not observed in the XCTest log'
    grep -Fq 'fake delay emits visible status before completion' "$tmp_root/wiltedkit-tests.xctest.log" ||
      fail 'WiltedSyncTests liveness case was not observed in the XCTest log'
    grep -Fq 'remote deletions apply incrementally, cascade items, and preserve protected work' "$tmp_root/wiltedkit-tests.xctest.log" ||
      fail 'WiltedSyncTests deletion case was not observed in the XCTest log'
  fi
  return "$xctest_status"
}

leg_wiltedproducer_tests() {
  local package="$repo_root/Producer"
  local scratch_path="$tmp_root/swiftpm/wiltedproducer-tests"
  [[ -d "$package" ]] || fail "missing WiltedProducer package: $package"
  assert_test_sources wiltedproducer-tests "$package/Tests"
  require_tool swift
  require_tool xcrun
  swift build --package-path "$package" --scratch-path "$scratch_path" --build-tests
  local test_bundle
  test_bundle="$(find "$scratch_path" -type d -name 'WiltedProducerPackageTests.xctest' -print -quit)"
  [[ -n "$test_bundle" && -d "$test_bundle" ]] || fail 'WiltedProducer XCTest bundle was not produced'

  set +e
  xcrun xctest "$test_bundle" 2>&1 | tee "$tmp_root/wiltedproducer-tests.xctest.log" >&2
  local xctest_status="${PIPESTATUS[0]}"
  set -e
  return "$xctest_status"
}

find_project() {
  [[ -n "$native_project" && -d "$native_project" ]] || fail 'no temporary XcodeGen project is available'
  printf '%s\n' "$native_project"
}

find_simulator_udid() {
  require_tool xcrun
  local udid
  local state

  # Reuse a booted device first to avoid racing CoreSimulatorService or
  # disturbing a simulator the owner is already using.
  udid="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Booted/ { print $2; exit }')"
  [[ -n "$udid" ]] || udid="$(xcrun simctl list devices available | awk -F '[()]' '/iPad/ && /Booted/ { print $2; exit }')"
  state=Booted
  if [[ -z "$udid" ]]; then
    udid="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Shutdown/ { print $2; exit }')"
    [[ -n "$udid" ]] || udid="$(xcrun simctl list devices available | awk -F '[()]' '/iPad/ && /Shutdown/ { print $2; exit }')"
    state=Shutdown
  fi
  [[ -n "$udid" ]] || fail 'no available iOS simulator device'

  if [[ "$state" == Booted ]]; then
    printf 'native.simulator.reuse udid=%s state=Booted\n' "$udid" >&2
  else
    printf 'native.simulator.boot udid=%s\n' "$udid" >&2
    xcrun simctl boot "$udid" >&2
  fi
  printf 'native.simulator.bootstatus.start udid=%s\n' "$udid" >&2
  xcrun simctl bootstatus "$udid" -b >&2
  printf 'native.simulator.ready udid=%s\n' "$udid" >&2
  printf '%s\n' "$udid"
}

find_shutdown_iphone_udid() {
  require_tool xcrun
  local udid state device_list
  device_list="$(xcrun simctl list devices available)"
  read -r udid state <<<"$(printf '%s\n' "$device_list" | awk -F '[()]' -v device_name="$ios_ui_device_name" '
    {
      name=$1
      state=$4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", state)
      if (name == device_name) { print $2, state; exit }
    }')"
  [[ -n "$udid" ]] || fail "no available $ios_ui_device_name simulator for $ios_ui_baseline_geometry geometry"
  if [[ "$state" == "Booted" ]]; then
    printf 'native.simulator.clean-shutdown name=%s udid=%s state=Booted\n' \
      "$ios_ui_device_name" "$udid" >&2
    xcrun simctl shutdown "$udid" >&2
    state=Shutdown
  fi
  [[ "$state" == "Shutdown" ]] ||
    fail "$ios_ui_device_name simulator is not available in a clean state: $state"
  printf 'native.simulator.clean-selection name=%s geometry=%s udid=%s state=Shutdown\n' \
    "$ios_ui_device_name" "$ios_ui_baseline_geometry" "$udid" >&2
  printf '%s\n' "$udid"
}

xcode_test_leg() {
  local label="$1"
  local source_dir="$2"
  local scheme="$3"
  local destination="$4"
  local target="$5"
  local project
  shift 5
  local only_testing_args=(-only-testing:"$target")
  for target in "$@"; do
    only_testing_args+=(-only-testing:"$target")
  done

  [[ -f "$integration_root/project.yml" ]] || fail "missing integration XcodeGen source"
  require_tool xcodebuild
  require_tool jq
  require_tool xmllint
  assert_test_sources "$label" "$source_dir"
  project="$(find_project)"
  [[ "$xcode_test_timeout_seconds" =~ ^[1-9][0-9]*$ ]] ||
    fail 'WILTED_XCODE_TEST_TIMEOUT_SECONDS must be a positive integer'
  xcodebuild test \
    -project "$project" \
    -scheme "$scheme" \
    "${only_testing_args[@]}" \
    -destination "$destination" \
    -derivedDataPath "$derived_data/$label" \
    -resultBundlePath "$tmp_root/$label.xcresult" \
    -parallel-testing-enabled NO \
    -quiet &
  local xcode_pid=$!
  local elapsed_seconds=0
  local xcode_status
  while kill -0 "$xcode_pid" 2>/dev/null; do
    if (( elapsed_seconds >= xcode_test_timeout_seconds )); then
      status "native.timeout label=$label seconds=$xcode_test_timeout_seconds"
      kill -TERM "$xcode_pid" 2>/dev/null || true
      cleanup_mac_test_hosts
      set +e
      wait "$xcode_pid"
      set -e
      return 124
    fi
    if (( elapsed_seconds > 0 && elapsed_seconds % 30 == 0 )); then
      status "native.heartbeat label=$label elapsed_seconds=$elapsed_seconds"
    fi
    sleep 1
    ((elapsed_seconds += 1))
  done
  set +e
  wait "$xcode_pid"
  xcode_status=$?
  set -e
  return "$xcode_status"
}

leg_macos_unit_tests() {
  xcode_test_leg macos-unit-tests "$integration_root/WiltedMacTests" WiltedMac 'platform=macOS' WiltedMacTests
}

leg_ios_unit_tests() {
  local udid
  udid="$(find_simulator_udid)"
  xcode_test_leg ios-unit-tests "$integration_root/WiltediOSTests" WiltediOS "platform=iOS Simulator,id=$udid" WiltediOSTests
}

leg_macos_ui_tests() {
  local label=macos-ui-tests
  local source_dir="$integration_root/WiltedMacUITests"
  local destination='platform=macOS'
  local project="$native_project"
  local label_data="$derived_data/$label"
  local runner host runner_metadata host_metadata metadata_info runner_signature_info host_signature_info
  local only_testing_arg='-only-testing:WiltedMacUITests'
  local requested_selector="${WILTED_MAC_UI_SELECTOR:-}"

  if [[ -n "$requested_selector" ]]; then
    validate_mac_ui_selector "$requested_selector" || return 1
    only_testing_arg="-only-testing:$requested_selector"
  fi

  if [[ ! -f "$integration_root/project.yml" ]]; then
    fail 'missing integration XcodeGen source'
    return 1
  fi
  if ! require_tool xcodebuild; then return 1; fi
  if ! require_tool codesign; then return 1; fi
  if ! assert_test_sources "$label" "$source_dir"; then return 1; fi
  if [[ -z "$project" || ! -d "$project" ]]; then
    fail 'no temporary XcodeGen project is available'
    return 1
  fi
  if [[ ! "$wilted_development_team" =~ ^[A-Z0-9]{10}$ ]]; then
    fail 'WILTED_DEVELOPMENT_TEAM must be a ten-character Apple team identifier'
    return 1
  fi

  if ! xcodebuild build-for-testing \
    -project "$project" \
    -scheme WiltedMac \
    "$only_testing_arg" \
    -destination "$destination" \
    -derivedDataPath "$label_data" \
    -parallel-testing-enabled NO \
    -quiet \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY='Apple Development' \
    DEVELOPMENT_TEAM="$wilted_development_team"; then
    return 1
  fi

  runner="$label_data/Build/Products/Debug/WiltedMacUITests-Runner.app"
  if [[ ! -d "$runner" ]]; then
    runner="$(find "$label_data/Build/Products" -type d -name 'WiltedMacUITests-Runner.app' -print -quit)"
  fi
  if [[ -z "$runner" || ! -d "$runner" ]]; then
    fail 'macOS UI test runner was not produced'
    return 1
  fi
  host="$label_data/Build/Products/Debug/WiltedMac.app"
  if [[ ! -d "$host" ]]; then
    host="$(find "$label_data/Build/Products" -type d -name 'WiltedMac.app' -print -quit)"
  fi
  if [[ -z "$host" || ! -d "$host" ]]; then
    fail 'macOS UI host app was not produced'
    return 1
  fi
  if ! require_tool xattr; then return 1; fi

  if ! runner_metadata="$(xattr -lr "$runner" 2>/dev/null)"; then return 1; fi
  if ! host_metadata="$(xattr -lr "$host" 2>/dev/null)"; then return 1; fi
  metadata_info="${runner_metadata}"$'\n'"${host_metadata}"
  if [[ "$metadata_info" == *'com.apple.quarantine'* ||
    "$metadata_info" == *'com.apple.FinderInfo'* ]]; then
    printf '%s\n' 'native.error forbidden Mac UI quarantine/FinderInfo metadata remains' >&2
    return 1
  fi
  if ! codesign --verify --deep --strict "$runner"; then return 1; fi
  # The host app is verified strictly without traversing XCTest bundles that
  # Xcode may reference from the test product but does not ship in the host.
  if ! codesign --verify --strict "$host"; then return 1; fi
  if ! runner_signature_info="$(codesign --display --verbose=4 "$runner" 2>&1)"; then
    fail 'macOS UI runner signature metadata unavailable'
    return 1
  fi
  if ! host_signature_info="$(codesign --display --verbose=4 "$host" 2>&1)"; then
    fail 'macOS UI host signature metadata unavailable'
    return 1
  fi
  assert_apple_development_signature() {
    local label="$1"
    local signature="$2"
    if [[ "$signature" != *'Authority=Apple Development:'* ||
      "$signature" != *"TeamIdentifier=$wilted_development_team"* ]]; then
      printf 'native.error %s is not signed by Apple Development team=%s\n' "$label" "$wilted_development_team" >&2
      return 1
    fi
  }
  if ! assert_apple_development_signature runner "$runner_signature_info"; then return 1; fi
  if ! assert_apple_development_signature host "$host_signature_info"; then return 1; fi
  if [[ "$runner_signature_info" != *CodeDirectory* || "$host_signature_info" != *CodeDirectory* ]]; then
    fail 'macOS UI test runner is unsigned'
    return 1
  fi
  printf '%s\n' "$runner_signature_info"
  printf '%s\n' "$host_signature_info"

  xcodebuild test-without-building \
    -project "$project" \
    -scheme WiltedMac \
    "$only_testing_arg" \
    -destination "$destination" \
    -derivedDataPath "$label_data" \
    -resultBundlePath "$tmp_root/$label.xcresult" \
    -parallel-testing-enabled NO \
    -quiet
}

leg_ios_ui_tests() (
  local udid=""
  local simulator_started=0

  cleanup_ios_ui_simulator() {
    local test_status=$?
    local cleanup_status=0
    if [[ "$simulator_started" -eq 1 ]]; then
      printf 'native.simulator.shutdown.start udid=%s\n' "$udid" >&2
      xcrun simctl shutdown "$udid" >&2 || cleanup_status=$?
      if [[ "$cleanup_status" -eq 0 ]]; then
        printf 'native.simulator.shutdown.complete udid=%s\n' "$udid" >&2
      else
        printf 'native.simulator.shutdown.failed udid=%s status=%s\n' "$udid" "$cleanup_status" >&2
      fi
    fi
    if [[ "$test_status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
      exit "$cleanup_status"
    fi
    exit "$test_status"
  }
  trap cleanup_ios_ui_simulator EXIT

  udid="$(find_shutdown_iphone_udid)"
  printf 'native.simulator.boot udid=%s purpose=ios-ui-tests\n' "$udid" >&2
  xcrun simctl boot "$udid" >&2
  simulator_started=1
  printf 'native.simulator.bootstatus.start udid=%s purpose=ios-ui-tests\n' "$udid" >&2
  xcrun simctl bootstatus "$udid" -b >&2
  printf 'native.simulator.ready udid=%s purpose=ios-ui-tests\n' "$udid" >&2
  xcode_test_leg ios-pixel-snapshot-tests "$integration_root/WiltediOSUITests" WiltediOS \
    "platform=iOS Simulator,id=$udid" \
    WiltediOSUITests/WiltediOSPixelSnapshotTests \
    WiltediOSUITests/WiltediOSMVPFlowUITests
)

prepare_integration_root() {
  integration_root="$tmp_root/integration-root"
  mkdir -p "$integration_root/WiltedKit" "$integration_root/Producer" "$integration_root/CloudSync" "$integration_root/Listener"
  cp "$project_yml" "$integration_root/project.yml"
  cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests" \
    "$repo_root/WiltedMacUITests" "$repo_root/WiltediOS" "$repo_root/WiltediOSTests" \
    "$repo_root/WiltediOSUITests" "$integration_root/"
  cp "$repo_root/WiltedKit/Package.swift" "$integration_root/WiltedKit/Package.swift"
  cp -R "$repo_root/WiltedKit/Sources" "$repo_root/WiltedKit/Tests" "$integration_root/WiltedKit/"
  cp "$repo_root/Producer/Package.swift" "$integration_root/Producer/Package.swift"
  cp -R "$repo_root/Producer/Sources" "$repo_root/Producer/Tests" "$integration_root/Producer/"
  cp "$repo_root/CloudSync/Package.swift" "$integration_root/CloudSync/Package.swift"
  cp -R "$repo_root/CloudSync/Sources" "$repo_root/CloudSync/Tests" "$integration_root/CloudSync/"
  cp "$repo_root/Listener/Package.swift" "$integration_root/Listener/Package.swift"
  cp -R "$repo_root/Listener/Sources" "$repo_root/Listener/Tests" "$integration_root/Listener/"
}

if [[ "$native_self_test" != "1" ]]; then
  [[ -f "$project_yml" ]] || fail "missing XcodeGen source: $project_yml"
  require_tool xcodegen
  require_tool jq
  require_tool xmllint
  # run_leg streams each function through tee, so state assigned inside the
  # xcodegen function is not propagated from its pipeline subshell.  The
  # deterministic first output path is known before that leg starts.
  prepare_integration_root
  native_project="$tmp_root/generated-first/Wilted.xcodeproj"
  validate_pixel_snapshot_baselines "$integration_root"
  validate_ios_pixel_snapshot_baselines "$integration_root"
else
  snapshot_validation_root="$repo_root"
  if [[ -n "$forced_snapshot_baseline" ]]; then
    snapshot_validation_root="$tmp_root/snapshot-fixture"
    mkdir -p "$snapshot_validation_root"
    cp -R "$repo_root/WiltedMacTests" "$snapshot_validation_root/"
    forced_snapshot_file="$(find "$snapshot_validation_root/WiltedMacTests/__Snapshots__/WiltedPixelSnapshotTests" \
      -type f -name '*.png' -print -quit)"
    [[ -n "$forced_snapshot_file" ]] || fail 'snapshot self-test fixture has no PNG baseline'
    case "$forced_snapshot_baseline" in
      missing) rm -f "$forced_snapshot_file" ;;
      zero) : >"$forced_snapshot_file" ;;
      malformed) printf '%s\n' 'not a PNG baseline' >"$forced_snapshot_file" ;;
      *) fail "unknown NATIVE_FORCE_SNAPSHOT_BASELINE: $forced_snapshot_baseline" ;;
    esac
  fi
  validate_pixel_snapshot_baselines "$snapshot_validation_root"
  validate_ios_pixel_snapshot_baselines "$repo_root"
fi

run_leg "${leg_names[0]}" "${leg_reports[0]}" leg_xcodegen_reproducible
run_leg "${leg_names[1]}" "xctest" leg_wiltedkit_tests
run_leg "${leg_names[2]}" "xctest" leg_cloudsync_tests
run_leg "${leg_names[3]}" "xctest" leg_listener_tests
run_leg "${leg_names[4]}" "xctest" leg_wiltedproducer_tests
run_leg "${leg_names[5]}" "${leg_reports[5]}" leg_macos_unit_tests
run_leg "${leg_names[6]}" "${leg_reports[6]}" leg_ios_unit_tests
run_leg "${leg_names[7]}" "${leg_reports[7]}" leg_macos_ui_tests
run_leg "${leg_names[8]}" "${leg_reports[8]}" leg_ios_ui_tests

status "native.complete failed_legs=$failed_legs total_legs=$completed_legs deferred_legs=$deferred_legs"
if [[ "$failed_legs" -ne 0 ]]; then
  status "native.failed count=$failed_legs"
  exit 1
fi
if [[ "$deferred_legs" -ne 0 ]]; then
  # Named, not merely counted. This line is the only thing standing between a
  # green gate and the false claim that every leg ran.
  status "native.deferred count=$deferred_legs legs=${deferred_leg_names[*]} rerun=\"make native-ui\""
  status "native.passed count=$completed_legs deferred=$deferred_legs"
else
  status "native.passed count=$completed_legs"
fi
