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
forced_screen_locked="${NATIVE_FORCE_SCREEN_LOCKED:-0}"
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
# shellcheck source=lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
# A prior run that died to SIGKILL or a harness timeout never ran its own EXIT
# trap, so its wilted-native-gate.XXXXXX directory is still sitting in
# $TMPDIR. Sweep before minting this run's own directory, not after: the 24h
# cutoff is what keeps this safe next to a gate that is genuinely still
# running, whose directory is at most minutes old.
wilted_sweep_stale_temp_dirs
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-native-gate.XXXXXX")"
derived_data="$tmp_root/DerivedData"
# A failed real Mac UI run is the one disposable artifact worth retaining for
# diagnosis. The default lives under the repository's ignored .logs directory;
# the override keeps the meta-test hermetic.
macos_ui_failure_diagnostics_dir="${WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR:-$repo_root/.logs/native-gate-diagnostics}"
mkdir -p "$derived_data"

cleanup_mac_test_hosts() {
  local test_host_pattern test_host_pid test_host_pids alive_pids="" killed=0
  test_host_pattern='wilted-native-gate\.[A-Za-z0-9]+/DerivedData/.*/WiltedMac\.app/Contents/MacOS/WiltedMac'
  test_host_pids="$(pgrep -f "$test_host_pattern" 2>/dev/null || true)"
  for test_host_pid in $test_host_pids; do
    if kill -0 "$test_host_pid" 2>/dev/null; then
      alive_pids="$alive_pids $test_host_pid"
    fi
  done
  [[ -n "$alive_pids" ]] || return 0
  kill $alive_pids 2>/dev/null || true
  sleep 1
  for test_host_pid in $alive_pids; do
    if kill -0 "$test_host_pid" 2>/dev/null; then
      kill -KILL "$test_host_pid" 2>/dev/null || true
    fi
  done
  sleep 1
  for test_host_pid in $alive_pids; do
    if ! kill -0 "$test_host_pid" 2>/dev/null; then
      killed=$((killed + 1))
    fi
  done
  status "native.cleanup mac-test-hosts-killed=$killed"
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
  exit 1
}

# Xcode 27's SwiftPM writes test bundles to `<scratch>/out/Products/Debug` and
# emits one per test target rather than a single `<Package>PackageTests.xctest`,
# so the bundle is discovered by shape and every bundle found is run. Passing a
# single expected name here is what broke both package legs on the upgrade.
run_package_xctest_bundles() {
  local label="$1" scratch_path="$2" log_path="$3"
  local bundles=()
  while IFS= read -r bundle; do
    bundles+=("$bundle")
  done < <(find "$scratch_path" -type d -name '*.xctest' | sort)
  if [[ "${#bundles[@]}" -eq 0 ]]; then
    fail "$label produced no XCTest bundle"
    return 1
  fi
  printf 'native.xctest.bundles label=%s count=%s\n' "$label" "${#bundles[@]}"
  : >"$log_path"
  local status=0 bundle bundle_status
  for bundle in "${bundles[@]}"; do
    printf 'native.xctest.start label=%s bundle=%s\n' "$label" "$(basename "$bundle")"
    set +e
    xcrun xctest "$bundle" 2>&1 | tee -a "$log_path" >&2
    bundle_status="${PIPESTATUS[0]}"
    set -e
    [[ "$bundle_status" -eq 0 ]] || status="$bundle_status"
  done
  return "$status"
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

source "$repo_root/scripts/lib/native-gate-validation.sh"

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
    if [[ "$report_mode" == "xctest" ]]; then
      # Distinct totals make the meta-test prove which capture is authoritative.
      # Reverting run_leg to the package leg's inner tee reports two, not three.
      printf '%s\n' \
        "Test Case '-[SelfTest testOne]' passed (0.000 seconds)." \
        "Test Case '-[SelfTest testTwo]' passed (0.000 seconds)." \
        "Test Case '-[SelfTest testThree]' passed (0.000 seconds)." \
        $'\t Executed 3 tests, with 0 failures (0 unexpected) in 0.000 seconds' \
        >"$output_file"
      printf '%s\n' \
        "Test Case '-[SelfTest testOne]' passed (0.000 seconds)." \
        "Test Case '-[SelfTest testTwo]' passed (0.000 seconds)." \
        $'\t Executed 2 tests, with 0 failures (0 unexpected) in 0.000 seconds' \
        >"$tmp_root/$name.xctest.log"
    else
      printf '%s\n' 'self_test_command_success' >"$output_file"
    fi
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
    # Parse the runner-owned capture: it contains the complete leg stream,
    # including the final aggregate that can arrive after a package leg's
    # inner XCTest tee has closed. The inner log remains useful for the named
    # case assertions inside each package leg, but is not authoritative for
    # the reported total.
    assert_xctest_output "$name" "$output_file"
    local xctest_status=$?
    set -e
    if [[ "$xctest_status" -ne 0 ]]; then
      command_status="$xctest_status"
    fi
  fi

  if [[ "$name" == "macos-ui-tests" || "$name" == "ios-pixel-snapshot-tests" ]]; then
    if [[ "$command_status" -ne 0 ]]; then
      retain_ui_failure_bundle "$name" "$result_bundle"
    else
      clear_ui_failure_bundle "$name"
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
  # The installed Swift toolchain accepts the SwiftPM xUnit flag but does not
  # emit the requested file for this package. Invoke the built XCTest bundles
  # directly; their runner log is authoritative and remains visible while running.
  set +e
  run_package_xctest_bundles WiltedKit "$scratch_path" "$tmp_root/wiltedkit-tests.xctest.log"
  local xctest_status="$?"
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
  set +e
  run_package_xctest_bundles WiltedProducer "$scratch_path" "$tmp_root/wiltedproducer-tests.xctest.log"
  local xctest_status="$?"
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
    local busy_pids busy_list
    # Match a CLIENT driving the device, not the device itself. Every booted
    # simulator runs a launchd_sim whose command line carries its own UDID, so
    # a bare `pgrep -f "$udid"` matches unconditionally here -- this branch only
    # runs when the device is Booted -- and refuses every shutdown. An
    # xcodebuild aimed at the device names it after `-destination`.
    busy_pids="$(pgrep -f -- "-destination[^ ]*$udid|id=$udid" 2>/dev/null || true)"
    busy_list="$(printf '%s' "$busy_pids" | tr '\n' ',')"
    if [[ -n "$busy_list" ]]; then
      printf 'native.simulator.clean-shutdown.busy name=%s udid=%s pids=%s\n' \
        "$ios_ui_device_name" "$udid" "$busy_list" >&2
      fail "$ios_ui_device_name simulator $udid is in use by pids $busy_list; refusing to shut it down"
    fi
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
  project="$(find_project)" || return 1
  [[ "$xcode_test_timeout_seconds" =~ ^[1-9][0-9]*$ ]] ||
    fail 'WILTED_XCODE_TEST_TIMEOUT_SECONDS must be a positive integer'
  cleanup_mac_test_hosts
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
      kill -TERM "$xcode_pid" 2>/dev/null || true
      cleanup_mac_test_hosts
      set +e
      wait "$xcode_pid"
      set -e
      local timeout_phase=build
      if grep -q 'Testing started' "$tmp_root/$label.log" 2>/dev/null; then
        timeout_phase=test
      fi
      status "native.timeout label=$label seconds=$xcode_test_timeout_seconds phase=$timeout_phase"
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
  udid="$(find_simulator_udid)" || return 1
  xcode_test_leg ios-unit-tests "$integration_root/WiltediOSTests" WiltediOS "platform=iOS Simulator,id=$udid" WiltediOSTests
}

# XCUITest cannot bring an application forward while the login session is
# locked: every test in the leg fails its activation timeout instead, so a
# locked Mac reads as every journey broken and costs a twenty-minute run to
# find out. Ask first. `caffeinate` in the Makefile keeps the display awake,
# which is a different problem and does not unlock anything.
screen_is_locked() {
  if [[ "$native_self_test" == "1" ]]; then
    [[ "$forced_screen_locked" == "1" ]]
    return
  fi
  ioreg -n Root -d1 -a 2>/dev/null | grep -A 1 'CGSSessionScreenIsLocked' | grep -q '<true/>'
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

  cleanup_mac_test_hosts
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

  udid="$(find_shutdown_iphone_udid)" || return 1
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

# Preflight, not a leg check: the UI leg runs eighth, so a locked screen
# discovered there costs twelve minutes of build and seven of activation
# timeouts before saying anything useful.
if ! is_deferred_leg macos-ui-tests && screen_is_locked; then
  status 'native.macos-ui.screen-locked remedy="unlock the Mac and rerun make native-ui"'
  fail 'the macOS UI leg cannot activate an application while the screen is locked'
  exit 1
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
