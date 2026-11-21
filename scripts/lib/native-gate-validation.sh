source "$(dirname "${BASH_SOURCE[0]}")/native-gate-snapshots.sh"

parse_result_bundle_test_count() {
  local summary_file="$1"
  jq -er '.totalTestCount | numbers | select(. > 0)' "$summary_file"
}

result_bundle_summary_passed() {
  jq -e '
    type == "object" and .result == "Passed" and
    (.totalTestCount | type == "number") and
    (.passedTests | type == "number") and (.passedTests >= 0) and
    (.failedTests | type == "number") and (.failedTests == 0) and
    (.skippedTests | type == "number") and (.skippedTests >= 0) and
    (.passedTests + .failedTests + .skippedTests == .totalTestCount)
  ' "$summary_file" >/dev/null
}

validate_mac_ui_selector() {
  local selector="$1"
  if [[ ! "$selector" =~ ^WiltedMacUITests/WiltedMacJourneyUITests/test[A-Za-z0-9_]+$ ]]; then
    fail 'WILTED_MAC_UI_SELECTOR must name one WiltedMacJourneyUITests test method'
    return 1
  fi
}

validate_unit_selectors() {
  local variable="$1"
  local value="${!variable-}"
  [[ -n "${!variable+x}" ]] || return 0
  if [[ -z "$value" ]]; then
    fail "$variable is set but empty; name a test or unset it"
    return 1
  fi
  # One anchored expression accepts the whole comma list, so empty entries,
  # whitespace, extra separators and shell metacharacters cannot reach xcodebuild.
  if [[ ! "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*(/test[A-Za-z0-9_]*)?(,[A-Za-z_][A-Za-z0-9_]*(/test[A-Za-z0-9_]*)?)*$ ]]; then
    fail "$variable must be a comma list of Class or Class/testMethod"
    return 1
  fi
}

validate_unit_iterations() {
  local variable="$1"
  local value="${!variable-}"
  [[ -n "${!variable+x}" ]] || return 0
  if [[ -z "$value" ]]; then
    fail "$variable is set but empty; name an iteration count or unset it"
    return 1
  fi
  if [[ ! "$value" =~ ^([1-9][0-9]?|100)$ ]]; then
    fail "$variable must be an integer from 1 to 100"
    return 1
  fi
}

validate_unit_test_environment() {
  local variable
  for variable in WILTED_MAC_UNIT_SELECTORS WILTED_IOS_UNIT_SELECTORS; do
    [[ -z "${!variable+x}" ]] || validate_unit_selectors "$variable" || return 1
  done
  for variable in WILTED_MAC_UNIT_ITERATIONS WILTED_IOS_UNIT_ITERATIONS; do
    [[ -z "${!variable+x}" ]] || validate_unit_iterations "$variable" || return 1
  done
  return 0
}

# The default Mac UI floor is read from the suite rather than pinned, so it
# follows journeys as they are added, merged, or retired (INVARIANTS.md
# W-INV-012) while a run that executes fewer tests than the suite declares
# still fails. Every journey is a `WiltedMacJourneyUITests` method; these are
# the files that hold them.
mac_ui_declared_test_count() {
  local count source source_count
  count=0
  for source in WiltedMacSmokeUITests WiltedMacSidebarChromeUITests WiltedMacQuitUITests WiltedMacEpisodeInfoUITests WiltedMacPlaylistUITests; do
    [[ -f "$repo_root/WiltedMacUITests/$source.swift" ]] || fail "missing Mac UI journey source: $source"
    source_count="$(grep -cE '^[[:space:]]*func[[:space:]]+test' "$repo_root/WiltedMacUITests/$source.swift" || true)"
    [[ "$source_count" =~ ^[1-9][0-9]*$ ]] || fail "$source declares no test methods"
    count=$((count + source_count))
  done
  printf '%s\n' "$count"
}

expected_test_count_floor() {
  if [[ "$1" == "macos-ui-tests" && -n "${WILTED_MAC_UI_SELECTOR:-}" ]]; then
    validate_mac_ui_selector "$WILTED_MAC_UI_SELECTOR" || return 1
    printf '1\n'
    return
  fi
  if [[ "$1" == "macos-unit-tests" && -n "${WILTED_MAC_UNIT_SELECTORS+x}" ]]; then
    validate_unit_selectors WILTED_MAC_UNIT_SELECTORS || return 1
    printf '1\n'
    return
  fi
  case "$1" in
    macos-unit-tests) printf '30\n' ;;
    macos-ui-tests) mac_ui_declared_test_count ;;
    ios-pixel-snapshot-tests) printf '27\n' ;;
    watchos-build) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}

assert_mac_ui_selector_floor_contract() {
  local focused='WiltedMacUITests/WiltedMacJourneyUITests/testFocusedSelector'
  # Quit ends the one shared launch, so it must stay the last journey by name.
  grep -Eq '^[[:space:]]*func[[:space:]]+test09CommandQuitDrainsRepliesOnceAndExits\(' \
    "$repo_root/WiltedMacUITests/WiltedMacQuitUITests.swift" ||
    fail 'command quit drain journey must stay registered as the last journey'
  local source last_journey
  last_journey="$(for source in WiltedMacSmokeUITests WiltedMacSidebarChromeUITests WiltedMacQuitUITests WiltedMacEpisodeInfoUITests WiltedMacPlaylistUITests; do
    grep -hoE '^[[:space:]]*func[[:space:]]+test[A-Za-z0-9_]+' "$repo_root/WiltedMacUITests/$source.swift"
  done | awk '{print $2}' | LC_ALL=C sort | tail -n 1)"
  [[ "$last_journey" == 'test09CommandQuitDrainsRepliesOnceAndExits' ]] ||
    fail "the Quit journey must sort after every other journey; $last_journey sorts last"

  local chrome='WiltedMacUITests/WiltedMacJourneyUITests/test03CollapsedSidebarKeepsContentBelowWindowControls'
  [[ "$(WILTED_MAC_UI_SELECTOR="$chrome" expected_test_count_floor macos-ui-tests)" == "1" ]] ||
    fail 'focused SidebarChrome selector must require exactly one test'
  grep -q 'test03CollapsedSidebarKeepsContentBelowWindowControls' \
    "$repo_root/WiltedMacUITests/WiltedMacSidebarChromeUITests.swift" ||
    fail 'collapsed sidebar native window chrome journey must stay registered'
  local episode_info='WiltedMacUITests/WiltedMacJourneyUITests/test06EpisodeInfoJourneyAcrossFeedsHistoryAndPlayer'
  [[ "$(WILTED_MAC_UI_SELECTOR="$episode_info" expected_test_count_floor macos-ui-tests)" == "1" ]] ||
    fail 'focused EpisodeInfo selector must require exactly one test'
  grep -Eq '^[[:space:]]*func[[:space:]]+test06EpisodeInfoJourneyAcrossFeedsHistoryAndPlayer\(' \
    "$repo_root/WiltedMacUITests/WiltedMacEpisodeInfoUITests.swift" ||
    fail 'saved episode info native journey must stay registered'
  # The playlist owner-feedback journeys raise the declared Mac UI floor from
  # seven to nine; the two retry journeys stay unpinned.
  for method in \
    test07ManualPlaylistDiscoveryRenameDeleteAndShare \
    test08AutomaticPlaylistFormulaPreviewAndSave; do
    grep -Eq "^[[:space:]]*func[[:space:]]+$method\\(" \
      "$repo_root/WiltedMacUITests/WiltedMacPlaylistUITests.swift" ||
      fail "playlist owner-feedback native journey must stay registered: $method"
  done
  [[ "$(WILTED_MAC_UI_SELECTOR="$focused" expected_test_count_floor macos-ui-tests)" == "1" ]] ||
    fail 'validated focused Mac UI selector must require exactly one test'
  [[ "$(unset WILTED_MAC_UI_SELECTOR; expected_test_count_floor macos-ui-tests)" == \
    "$(mac_ui_declared_test_count)" ]] ||
    fail 'default Mac UI floor must equal the number of tests the suite declares'
  # A floor is a minimum, not a named set: an unrelated new test keeps the
  # suite above it while a named one quietly disappears. Tests whose absence
  # would not be caught by the count alone are asserted by identifier.
  grep -q 'testLarderOverridesAnOffPeakDeferralWithPrepareNow' \
    "$repo_root/WiltedMacTests/WiltedMacSettingsJourneyTests.swift" ||
    fail 'the off-peak Prepare now journey must stay in the Mac journey tests'
  # `fail` exits, so the rejecting probe runs in a subshell: the contract is
  # that an invalid selector must not SUCCEED here, not that it must return.
  if ( WILTED_MAC_UI_SELECTOR='WiltedMacUITests/WiltedMacSmokeUITests/testNope' \
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
    if [[ "${NATIVE_FORCE_FAILED_RESULT_SUMMARY_LEG:-}" == "$label" ]]; then
      mkdir -p "$result_bundle"
      printf '%s\n' 'self_test_macos_ui_failed_summary' >"$result_bundle/self-test-evidence"
      printf '%s\n' '{"totalTestCount":11,"passedTests":1,"failedTests":9,"skippedTests":1,"result":"Failed"}' >"$summary_file"
    elif is_forced_zero "$label"; then
      printf '%s\n' '{"totalTestCount":0,"passedTests":0,"failedTests":0,"skippedTests":0,"result":"Passed"}' >"$summary_file"
    elif [[ "$label" == "ios-pixel-snapshot-tests" && "$forced_missing_ios_mvp_journey" == "1" ]]; then
      printf '%s\n' '{"totalTestCount":26,"passedTests":26,"failedTests":0,"skippedTests":0,"result":"Passed"}' >"$summary_file"
    elif [[ "$label" == "watchos-build" ]]; then
      local watch_count="${NATIVE_SELF_TEST_WATCH_COUNT:-4}"
      printf '{"totalTestCount":%s,"passedTests":%s,"failedTests":0,"skippedTests":0,"result":"Passed"}\n' "$watch_count" "$watch_count" >"$summary_file"
    elif [[ "$label" == "macos-unit-tests" ]]; then
      printf '%s\n' '{"totalTestCount":30,"passedTests":30,"failedTests":0,"skippedTests":0,"result":"Passed"}' >"$summary_file"
    elif [[ "$label" == "macos-ui-tests" ]]; then
      local ui_count
      ui_count="$(mac_ui_declared_test_count)"
      printf '{"totalTestCount":%s,"passedTests":%s,"failedTests":0,"skippedTests":0,"result":"Passed"}\n' "$ui_count" "$ui_count" >"$summary_file"
    elif [[ "$label" == "ios-pixel-snapshot-tests" ]]; then
      printf '%s\n' '{"totalTestCount":27,"passedTests":27,"failedTests":0,"skippedTests":0,"result":"Passed"}' >"$summary_file"
    else
      printf '%s\n' '{"totalTestCount":2,"passedTests":2,"failedTests":0,"skippedTests":0,"result":"Passed"}' >"$summary_file"
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
  if ! result_bundle_summary_passed "$summary_file"; then
    printf 'native.result-summary-failed label=%s result_bundle=%s\n' \
      "$label" "$result_bundle" >&2
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
      if (line ~ /^[0-9]+$/) { xctest = line; seen = 1 }
    }
    # Each Swift Testing product prints its own run summary (a package with an
    # XCTest-only product also prints an empty one), so they add up rather
    # than the last one winning.
    /Test run with [0-9]+ tests / {
      line = $0
      sub(/^.*Test run with /, "", line)
      sub(/ tests.*$/, "", line)
      if (line ~ /^[0-9]+$/) { swift_testing += line; seen = 1 }
    }
    END { if (seen) print xctest + swift_testing }
  ' "$output_file")"
  if [[ -z "$reported" ]]; then
    reported="$(grep -Ec "^Test Case '.*' (passed|failed|skipped)" "$output_file" || true)"
  fi
  [[ "$reported" =~ ^[0-9]+$ ]] || reported=0
  printf '%s\n' "$reported"
}

leg_cloudsync_tests() {
  local package="$repo_root/CloudSync"
  local cache_key='native-cloudsync-tests'
  [[ -d "$package" ]] || fail "missing CloudSync package: $package"
  assert_test_sources cloudsync-tests "$package/Tests"
  require_tool swift

  # Keep the complete SwiftPM runner log as the leg's XCTest evidence.  The
  # named-case checks below prevent a package that merely builds or reports an
  # empty test plan from satisfying this leg.
  set +e
  run_with_build_cache swiftpm "$cache_key" swift test --package-path "$package" 2>&1 | tee "$tmp_root/cloudsync-tests.xctest.log" >&2
  local test_status="${PIPESTATUS[0]}"
  set -e
  if [[ "$test_status" -eq 0 ]]; then
    if ! grep -Fq 'zone bootstrap cancellation cannot publish a stale save generation' "$tmp_root/cloudsync-tests.xctest.log"; then
      printf '%s\n' 'native.error CloudSync named zone bootstrap generation case was not observed in the test log' >&2
      return 1
    fi
    if ! grep -Fq 'a first sign-in with no recorded owner adopts the current owner token' "$tmp_root/cloudsync-tests.xctest.log"; then
      printf '%s\n' 'native.error CloudSync named account ownership case was not observed in the test log' >&2
      return 1
    fi
  fi
  return "$test_status"
}

leg_playback_tests() {
  local package="$repo_root/Playback"
  local cache_key='native-playback-tests'
  [[ -d "$package" ]] || fail "missing Playback package: $package"
  assert_test_sources playback-tests "$package/Tests"
  require_tool swift

  # Keep a named case in the runner evidence so an empty or unrelated suite
  # cannot satisfy the leg.
  set +e
  run_with_build_cache swiftpm "$cache_key" swift test --package-path "$package" 2>&1 | tee "$tmp_root/playback-tests.xctest.log" >&2
  local test_status="${PIPESTATUS[0]}"
  set -e
  if [[ "$test_status" -eq 0 ]]; then
    if ! grep -Fq 'the system payload carries the rates, a podcast media type, and the artist only when present' "$tmp_root/playback-tests.xctest.log"; then
      printf '%s\n' 'native.error Playback Now Playing payload case was not observed in the test log' >&2
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

# Copy only terminal trees; the existing supervisor supplies timeout and progress.
copy_terminal_result_bundle() (
  local source="$1" staging="$2" retained="$3" exclusive="$4"
  [[ ! -e "$staging" && ! -L "$staging" ]] || return 1
  local cleanup_command
  printf -v cleanup_command 'rm -rf -- %q' "$staging"
  trap "$cleanup_command" EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
  python3 "$bounded_runner" --timeout-seconds "$native_leg_timeout_seconds" -- \
    python3 - "$source" "$staging" "$retained" "$exclusive" <<'PYRESULTCOPY'
import ctypes
import os
from pathlib import Path
import shutil
import sys
source, staging, retained = map(Path, sys.argv[1:4])
exclusive = sys.argv[4] == '1'
try:
    if exclusive and (not (source / 'Info.plist').is_file() or not (source / 'Data').is_dir()):
        raise ValueError('terminal result bundle is incomplete')
    staging.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, staging)
    if exclusive:
        # Darwin's exclusive rename atomically refuses even an empty foreign directory.
        libc = ctypes.CDLL(None, use_errno=True)
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(staging), os.fsencode(retained), 0x4):
            raise OSError(ctypes.get_errno(), 'exclusive result publication failed')
    else:
        if retained.exists(): shutil.rmtree(retained)
        staging.rename(retained)
except (OSError, ValueError, shutil.Error) as error:
    print(f'native.results.copy-failed reason={error}', file=sys.stderr)
    sys.exit(1)
finally:
    if staging.exists(): shutil.rmtree(staging)
PYRESULTCOPY
)

retain_ui_failure_bundle() {
  local leg_name="$1"
  local result_bundle="$2"
  local retained_bundle="$macos_ui_failure_diagnostics_dir/$leg_name.xcresult"
  local staging_bundle="$macos_ui_failure_diagnostics_dir/.$leg_name.xcresult.$$"

  [[ -d "$result_bundle" ]] || return 0
  copy_terminal_result_bundle "$result_bundle" "$staging_bundle" "$retained_bundle" 0 || return $?
  status "native.ui-leg.failure-bundle leg=$leg_name path=$retained_bundle"
}

clear_ui_failure_bundle() {
  local retained_bundle="$macos_ui_failure_diagnostics_dir/$1.xcresult"

  [[ -e "$retained_bundle" || -L "$retained_bundle" ]] || return 0
  rm -rf "$retained_bundle"
  status "native.ui-leg.failure-bundle-cleared leg=$1 path=$retained_bundle"
}

# Fail before any leg (or a self-test stub) starts when a selector is malformed.
validate_unit_test_environment
