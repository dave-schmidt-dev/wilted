#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test-runner.sh
source "$repo_root/scripts/lib/test-runner.sh"
WILTED_TEMP_LEAK_CHECKER="${WILTED_TEMP_LEAK_CHECKER:-$repo_root/scripts/check-temp-leaks.py}"
# shellcheck source=lib/test-temp-state.sh
source "$repo_root/scripts/lib/test-temp-state.sh"
# shellcheck source=lib/mac-test-parent.sh
source "$repo_root/scripts/lib/mac-test-parent.sh"
project_yml="$repo_root/project.yml"
native_self_test="${NATIVE_SELF_TEST:-0}"
native_interrupt_test_command="${NATIVE_INTERRUPT_TEST_COMMAND:-}"
forced_fail_leg="${NATIVE_FORCE_FAIL_LEG:-}"
forced_zero_leg="${NATIVE_FORCE_ZERO_TEST_LEG:-}"
forced_snapshot_baseline="${NATIVE_FORCE_SNAPSHOT_BASELINE:-}"
forced_missing_ios_mvp_journey="${NATIVE_FORCE_MISSING_IOS_MVP_JOURNEY:-0}"
forced_screen_locked="${NATIVE_FORCE_SCREEN_LOCKED:-0}"
wilted_development_team="${WILTED_DEVELOPMENT_TEAM:-4CJ49V6QHW}"
wilted_mac_ui="${WILTED_MAC_UI:-0}"
# Build and test work have separate budgets; queue waits consume neither.
xcode_test_timeout_seconds="${WILTED_XCODE_TEST_TIMEOUT_SECONDS:-600}"
native_leg_timeout_seconds="${WILTED_NATIVE_LEG_TIMEOUT_SECONDS:-600}"
xcode_build_timeout_seconds="${WILTED_XCODE_BUILD_TIMEOUT_SECONDS:-1800}"
# The iOS pixel baselines were recorded on iPhone 17 Pro. Selecting it by name
# keeps the UI leg from silently using a different first-listed iPhone model.
ios_ui_device_name='iPhone 17 Pro'
ios_ui_baseline_geometry='402x874 normalized to 390x844'
# shellcheck source=lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
inherited_tmp="$(cd -P "${TMPDIR:?TMPDIR must be set}" 2>/dev/null && pwd)" || exit 1
native_audit_parent="$(wilted_temp_prepare_parent "${WILTED_NATIVE_TEMP_AUDIT_PARENT:-$repo_root/.logs}")" || exit 1
native_audit_root="$(mktemp -d "$native_audit_parent/native-temp-audit.XXXXXX")" || exit 1
tmp_root=""
cleanup_initialization() { trap - EXIT INT TERM HUP; wilted_temp_remove_owned_pair "$tmp_root" "$inherited_tmp" wilted-native-gate. "$native_audit_root" "$native_audit_parent" native-temp-audit.; }
trap 'status=$?; cleanup_initialization; exit "$status"' EXIT
trap 'cleanup_initialization; exit 130' INT
trap 'cleanup_initialization; exit 143' TERM
trap 'cleanup_initialization; exit 129' HUP
wilted_temp_snapshot "$inherited_tmp" "$native_audit_root/parent-before.json"
wilted_sweep_stale_temp_dirs
tmp_root="$(mktemp -d "$inherited_tmp/wilted-native-gate.XXXXXX")"
wilted_temp_mark_owned "$tmp_root"
wilted_temp_save_output_streams
build_with_cache="$repo_root/scripts/build-with-cache.py"
bounded_runner="${WILTED_BOUNDED_RUNNER:-$repo_root/scripts/run-bounded.py}"
# A failed real Mac UI run is the one disposable artifact worth retaining for
# diagnosis. The default lives under the repository's ignored .logs directory;
# the override keeps the meta-test hermetic.
macos_ui_failure_diagnostics_dir="${WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR:-$repo_root/.logs/native-gate-diagnostics}"
cleanup_mac_test_hosts() {
  # Never sweep a peer's active test host. Hold all Mac product locks while
  # probing stale hosts; admission is nonblocking so cleanup cannot add a queue.
  python3 - "$repo_root" <<'PYMAC'
import fcntl
import os
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
locks = [root / '.build/xcode.lock'] + [root / '.build/xcode-locks' / (key + '.lock')
         for key in ('native-macos-unit-tests', 'native-macos-ui-tests')]
fds = []
try:
    for lock in locks:
        lock.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        fds.append(fd)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('native.cleanup mac-test-hosts-deferred=product-live', file=sys.stderr)
            sys.exit(0)
    result = subprocess.run(['bash', '-c', 'source "$1/scripts/lib/mac-test-parent.sh"; wilted_cleanup_mac_test_hosts "$1"', '_', str(root)])
    sys.exit(result.returncode)
finally:
    for fd in fds: os.close(fd)
PYMAC
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  wilted_temp_cleanup_native_gate "$tmp_root" "$inherited_tmp" "$native_audit_root" "$native_audit_parent" || true
  tmp_root=""; native_audit_root=""
  return "$status"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
# shellcheck source=lib/simctl_gate_lib.sh
GATE_PROJECT_OWNED_CLONES_ONLY=1
source "$repo_root/scripts/lib/simctl_gate_lib.sh"
[[ -f "$bounded_runner" ]] || {
  printf 'native.error bounded runner is missing: %s\n' "$bounded_runner" >&2
  exit 127
}
[[ "$native_leg_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  printf '%s\n' 'native.error WILTED_NATIVE_LEG_TIMEOUT_SECONDS must be a positive integer' >&2
  exit 2
}
leg_names=(
  xcodegen-reproducible
  wiltedkit-tests
  cloudsync-tests
  playback-tests
  wiltedproducer-tests
  macos-unit-tests
  ios-unit-tests
  macos-ui-tests
  ios-pixel-snapshot-tests
)
leg_reports=(none xctest xctest xctest xctest count count count count)
# shellcheck source=lib/native-gate-staging.sh
source "$repo_root/scripts/lib/native-gate-staging.sh"
# shellcheck source=lib/native-gate-legs.sh
source "$repo_root/scripts/lib/native-gate-legs.sh"
source "$repo_root/scripts/lib/native-gate-parallel.sh"
# shellcheck source=lib/native-gate-watch.sh
source "$repo_root/scripts/lib/native-gate-watch.sh"
wilted_gate_legs_validate "${leg_names[@]}" || exit 2
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

if [[ "$native_self_test" != "1" ]]; then
  if ! stale_simulators_swept="$(gate_sweep wilted)"; then
    fail 'could not complete Wilted simulator ownership sweep'
  fi
  status "native.simulator.sweep complete wilted_deleted=${stale_simulators_swept:-0}"
fi

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
    local cache_key="$(basename "$scratch_path")"
    wilted_start_supervisor env WILTED_EOF_BOUNDED_RUNNER="$repo_root/scripts/run-bounded.py" \
      WILTED_TEST_TIMEOUT_SECONDS="$native_leg_timeout_seconds" WILTED_WORK_PHASE=test \
      python3 "$build_with_cache" run-tests swiftpm "$cache_key" -- xcrun xctest "$bundle" > >(tee -a "$log_path" >&2) 2>&1
    wilted_wait_active_supervisor
    bundle_status=$?
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

# A declared evidence root is private to this gate and never reuses prior output.
prepare_native_results_dir() {
  [[ -n "${native_results_dir:-}" ]] || return 0
  printf 'native.results.prepare path=%s\n' "$native_results_dir" >&2
  python3 - "$repo_root" "$native_results_dir" <<'PYRESULTDIR'
import os
from pathlib import Path
import sys
root, requested = Path(sys.argv[1]).resolve() / '.logs', Path(sys.argv[2])
try:
    relative = requested.relative_to(root)
    if not relative.parts or any(p in ('.', '..') for p in relative.parts):
        raise ValueError('destination must be a unique child of repository .logs')
    current = root
    for part in ('', *relative.parts):
        if part: current /= part
        if current.is_symlink(): raise ValueError('symlink destination ancestor')
    if requested.exists(): raise ValueError('destination already exists')
    requested.parent.mkdir(parents=True, exist_ok=True)
    requested.mkdir(mode=0o700)
except (OSError, ValueError) as error:
    print(f'native.results.destination-refused reason={error}', file=sys.stderr)
    sys.exit(1)
PYRESULTDIR
}

retain_native_success_bundle() {
  [[ -n "${native_results_dir:-}" ]] || return 0
  case "$1" in macos-unit-tests|ios-unit-tests|ios-pixel-snapshot-tests) ;; *) return 0 ;; esac
  local retained="$native_results_dir/$1.xcresult" staging="$native_results_dir/.$1.staging.$$"
  status "native.results.start leg=$1 path=$retained"
  copy_terminal_result_bundle "$2" "$staging" "$retained" 1 || return $?
  status "native.results.complete leg=$1 path=$retained"
}

source "$repo_root/scripts/lib/native-gate-validation.sh"
native_results_dir="${WILTED_NATIVE_RESULTS_DIR:-}"
# Phase0's synthetic gates inherit the outer environment but cannot publish evidence.
[[ "$native_self_test" != "1" ]] || native_results_dir=""
prepare_native_results_dir || exit $?

run_leg() {
  local name="$1"
  local report_mode="$2"
  shift 2
  local output_file="$tmp_root/$name.log"
  local result_bundle="$tmp_root/$name.xcresult"
  local command_status=0 logger_status=0 stream_file="$tmp_root/$name.stream"
  wilted_temp_prepare_leg "$tmp_root" "$name"

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
    elif [[ "$native_self_test" == "1" && "$name" == watchos-* ]]; then
      mkdir -p "$result_bundle"
      printf '%s\n' 'self_test_watchos_failure_evidence' >"$result_bundle/self-test-evidence"
    fi
    command_status=1
  elif is_forced_zero "$name"; then
    printf '%s\n' 'forced_self_test_zero_result_bundle' >"$output_file"
    if [[ "$native_self_test" == "1" && "$name" == "macos-ui-tests" ]]; then
      mkdir -p "$result_bundle"
      printf '%s\n' 'self_test_macos_ui_zero_test_evidence' >"$result_bundle/self-test-evidence"
    elif [[ "$native_self_test" == "1" && "$name" == watchos-* ]]; then
      mkdir -p "$result_bundle"
      printf '%s\n' 'self_test_watchos_zero_test_evidence' >"$result_bundle/self-test-evidence"
    fi
    command_status=0
  elif [[ "$native_self_test" == "1" && "$name" != "interrupt-fixture" ]]; then
    if [[ "$report_mode" == "xctest" ]]; then
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
    wilted_start_logger "$output_file" "$stream_file"
    set +e
    TMPDIR="$WILTED_TEMP_LEG_WORK" "$@" >&9 2>&1 || command_status=$?
    set +e # a leg can re-enable errexit (xcode_test_leg); `||` keeps its failure from ending the gate
    wilted_finish_logger
    logger_status=$?
    set -e
    if [[ "$command_status" -eq 0 && "$logger_status" -ne 0 ]]; then
      command_status="$logger_status"
    fi
  fi

  if ! wilted_temp_audit_leg "$tmp_root" "$name"; then command_status=1; fi

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

  # Every app leg keeps its failing result bundle; the temp root does not survive.
  if [[ "$name" == macos-* || "$name" == ios-* || "$name" == watchos-* ]]; then
    if [[ "$command_status" -ne 0 ]]; then
      retain_ui_failure_bundle "$name" "$result_bundle" || status "native.results.failure-diagnostics-error leg=$name"
    else
      if ! clear_ui_failure_bundle "$name"; then command_status=1; fi
    fi
  fi
  if [[ "$command_status" -eq 0 ]]; then
    retain_native_success_bundle "$name" "$result_bundle" || command_status=$?
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

build_cache_path() {
  local kind="$1" key="$2"
  python3 "$build_with_cache" path "$kind" "$key"
}

run_with_build_cache() {
  local kind="$1" key="$2"
  shift 2
  local timeout_seconds="$xcode_build_timeout_seconds"
  wilted_start_supervisor env WILTED_TEST_TIMEOUT_SECONDS="$timeout_seconds" \
    WILTED_WORK_PHASE=build python3 "$build_with_cache" run "$kind" "$key" -- "$@"
  wilted_wait_active_supervisor
}

run_bounded_native_command() {
  wilted_start_supervisor python3 "$bounded_runner" --timeout-seconds "$native_leg_timeout_seconds" -- "$@"
  wilted_wait_active_supervisor
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
  run_bounded_native_command xcodegen generate --spec "$integration_root/project.yml" --project "$first" --project-root "$integration_root"
  run_bounded_native_command xcodegen generate --spec "$integration_root/project.yml" --project "$second" --project-root "$integration_root"

  # XcodeGen resolves plist and entitlement paths relative to the generated
  # project, while the disposable project lives under tmp_root. Keep every
  # referenced signing input in both generated projects so xcodebuild never
  # reads or writes the checkout.
  local project_file
  for project_file in "${wilted_gate_xcodegen_inputs[@]}"; do
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
  local cache_key='native-wiltedkit-tests'
  local cache_path
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
  cache_path="$(build_cache_path swiftpm "$cache_key")"
  run_with_build_cache swiftpm "$cache_key" swift build --package-path "$package" --build-tests || return $?
  # The installed Swift toolchain accepts the SwiftPM xUnit flag but does not
  # emit the requested file for this package. Invoke the built XCTest bundles
  # directly; their runner log is authoritative and remains visible while running.
  set +e
  run_package_xctest_bundles WiltedKit "$cache_path" "$tmp_root/wiltedkit-tests.xctest.log"
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
  local cache_key='native-wiltedproducer-tests'
  local cache_path
  [[ -d "$package" ]] || fail "missing WiltedProducer package: $package"
  assert_test_sources wiltedproducer-tests "$package/Tests"
  require_tool swift
  require_tool xcrun
  cache_path="$(build_cache_path swiftpm "$cache_key")"
  run_with_build_cache swiftpm "$cache_key" swift build --package-path "$package" --build-tests || return $?
  set +e
  run_package_xctest_bundles WiltedProducer "$cache_path" "$tmp_root/wiltedproducer-tests.xctest.log"
  local xctest_status="$?"
  set -e
  return "$xctest_status"
}

find_project() {
  [[ -n "$native_project" && -d "$native_project" ]] || fail 'no temporary XcodeGen project is available'
  printf '%s\n' "$native_project"
}

source "$repo_root/scripts/lib/native-gate-simulator.sh"
source "$repo_root/scripts/lib/native-gate-xcode.sh"

leg_macos_unit_tests() {
  xcode_test_leg macos-unit-tests "$integration_root/WiltedMacTests" WiltedMac 'platform=macOS' WiltedMacTests
}

leg_ios_unit_tests() {
  local udid result=0
  udid="$(create_gate_simulator ios-units)" || return 1
  xcode_test_leg ios-unit-tests "$integration_root/WiltediOSTests" WiltediOS \
    "platform=iOS Simulator,id=$udid" WiltediOSTests || result=$?
  return "$result"
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

wait_macos_ui_supervisor() {
  local supervisor_status=0
  wilted_wait_active_supervisor || supervisor_status=$?
  WILTED_UI_LOCK_PID_FILE=""
  return "$supervisor_status"
}

leg_macos_ui_tests() {
  local label=macos-ui-tests
  local source_dir="$integration_root/WiltedMacUITests"
  local destination='platform=macOS'
  local project="$tmp_root/$label-project/$(basename "$native_project")"
  mkdir -p "$(dirname "$project")"
  cp -R "$(dirname "$native_project")/." "$(dirname "$project")/"
  local cache_key="native-$label"
  local label_data
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
  wilted_mac_test_scheme_configure "$project/xcshareddata/xcschemes/WiltedMac.xcscheme" "$WILTED_TEMP_LEG_WORK" || fail "could not bind $label XCTest to its owned temp parent"
  label_data="$(build_cache_path xcode "$cache_key")"
  # Build pre-actions execute under the cache helper's lock, before Xcode
  # copies/signs products. Clear only our staged inputs and owned product tree;
  # the post-build audit still refuses any forbidden metadata that reappears.
  if ! require_tool xattr; then return 1; fi
  local products="$label_data/Build/Products" metadata_ready="$tmp_root/$label.metadata-ready"
  python3 - "$project/xcshareddata/xcschemes/WiltedMac.xcscheme" "$integration_root" "$products" "$metadata_ready" <<'PYMETADATA' || return 1
import shlex, sys, xml.etree.ElementTree as ET
scheme, staged, products, ready = sys.argv[1:]
tree = ET.parse(scheme)
build = tree.getroot().find("BuildAction")
if build is None:
    sys.exit("native.error Mac UI scheme has no BuildAction")
actions = build.find("PreActions")
if actions is None:
    actions = ET.SubElement(build, "PreActions")
action = ET.SubElement(actions, "ExecutionAction", ActionType="Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction")
# -s prevents recursive stripping from dereferencing a staged symlink into
# canonical sources, installed bundles or another cache.
script = "set -eu\ntest ! -L " + shlex.quote(products) + "\nmkdir -p " + shlex.quote(products) + "\nxattr -crs " + shlex.quote(staged) + " " + shlex.quote(products) + "\ntouch " + shlex.quote(ready) + "\n"
ET.SubElement(action, "ActionContent", title="Strip owned test-product metadata before signing", scriptText=script)
tree.write(scheme, encoding="UTF-8", xml_declaration=True)
PYMETADATA
  if ! run_with_build_cache xcode "$cache_key" xcodebuild build-for-testing \
    -project "$project" \
    -scheme WiltedMac \
    "$only_testing_arg" \
    -destination "$destination" \
    -parallel-testing-enabled NO \
    -quiet \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY='Apple Development' \
    DEVELOPMENT_TEAM="$wilted_development_team"; then
    return 1
  fi

  # Xcode may continue after a scheme action failure; require its success marker.
  [[ -f "$metadata_ready" ]] || { fail 'Mac UI pre-sign metadata strip failed'; return 1; }

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
    "$metadata_info" == *'com.apple.FinderInfo'* ||
    "$metadata_info" == *'com.apple.fileprovider.fpfs#P'* ]]; then
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

  local lock_pid_file="$tmp_root/$label.ui-lock.pid"
  WILTED_UI_LOCK_PID_FILE="$lock_pid_file"
  GATE_UI_TEST_LOCK_PID_FILE="$lock_pid_file" gate_ui_test_lock --label "$label" \
    env WILTED_TEST_TIMEOUT_SECONDS="$xcode_test_timeout_seconds" WILTED_WORK_PHASE=test \
    python3 "$build_with_cache" run xcode "$cache_key" -- xcodebuild test-without-building \
    -project "$project" \
    -scheme WiltedMac \
    "$only_testing_arg" \
    -destination "$destination" \
    -resultBundlePath "$tmp_root/$label.xcresult" \
    -parallel-testing-enabled NO \
    -quiet &
  WILTED_ACTIVE_SUPERVISOR_PID=$!
  wait_macos_ui_supervisor
}

leg_ios_ui_tests() {
  local udid result=0
  udid="$(create_gate_simulator ios-pixel-ui)" || return 1
  WILTED_UI_TEST_SIMULATOR_UDID="$udid" xcode_test_leg \
    ios-pixel-snapshot-tests "$integration_root/WiltediOSUITests" WiltediOS \
    "platform=iOS Simulator,id=$udid" \
    WiltediOSUITests/WiltediOSPixelSnapshotTests \
    WiltediOSUITests/WiltediOSMVPFlowUITests || result=$?
  return "$result"
}

if [[ "$native_self_test" != "1" ]]; then
  [[ -f "$project_yml" ]] || fail "missing XcodeGen source: $project_yml"
  require_tool xcodegen
  require_tool jq
  require_tool xmllint
  # The deterministic first output path is known before XcodeGen starts.
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

if ! is_deferred_leg macos-ui-tests && wilted_gate_leg_selected macos-ui-tests && screen_is_locked; then
  status 'native.macos-ui.screen-locked remedy="unlock the Mac and rerun make native-ui"'
  fail 'the macOS UI leg cannot activate an application while the screen is locked'
  exit 1
fi

if [[ -n "$native_interrupt_test_command" ]]; then
  if [[ "${NATIVE_INTERRUPT_UI_TEST:-0}" == "1" ]]; then WILTED_UI_LOCK_PID_FILE="${NATIVE_INTERRUPT_UI_LOCK_PID_FILE:-$tmp_root/interrupt.ui-lock.pid}"; run_leg "interrupt-fixture" "none" wilted_run_ui_lock_fixture "$native_interrupt_test_command"; else run_leg "interrupt-fixture" "none" run_with_build_cache swiftpm native-wiltedproducer-tests swift run "$native_interrupt_test_command"; fi
  (( failed_legs == 0 )) || exit 1
  exit 0
fi

leg_fns=(leg_xcodegen_reproducible leg_wiltedkit_tests leg_cloudsync_tests leg_playback_tests leg_wiltedproducer_tests
  leg_macos_unit_tests leg_ios_unit_tests leg_macos_ui_tests leg_ios_ui_tests)
if [[ "$native_self_test" != 1 ]]; then cleanup_mac_test_hosts; fi
wilted_gate_run_legs

wilted_temp_remove_owned_child "$tmp_root" "$inherited_tmp" wilted-native-gate. || fail 'native temp root ownership changed before cleanup'
tmp_root=""
wilted_temp_snapshot "$inherited_tmp" "$native_audit_root/parent-after.json"
if ! wilted_temp_compare "$native_audit_root/parent-before.json" "$native_audit_root/parent-after.json" native-parent; then
  failed_legs=$((failed_legs + 1))
fi
status "native.complete failed_legs=$failed_legs total_legs=$completed_legs deferred_legs=$deferred_legs"
wilted_gate_legs_summary
if [[ "$failed_legs" -ne 0 ]]; then
  status "native.failed count=$failed_legs"
  exit 1
fi
if [[ "$deferred_legs" -ne 0 ]]; then
  status "native.deferred count=$deferred_legs legs=${deferred_leg_names[*]} rerun=\"make native-ui\""
  status "native.passed count=$completed_legs deferred=$deferred_legs$(wilted_gate_legs_suffix)"
else
  status "native.passed count=$completed_legs$(wilted_gate_legs_suffix)"
fi
