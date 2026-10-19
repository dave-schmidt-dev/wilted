# shellcheck shell=bash
# A host testmanagerd blocked on an unanswered Automation Mode authentication prompt hangs every
# Mac-hosted run until its budget ends (HISTORY 2026-10-12). Sample the user's daemon once and fail
# at once on that stack. Absent (launchd starts it on demand), healthy or unsampleable daemons pass.
# Simulator legs use the runtime's own testmanagerd, so only Mac destinations call this.
wilted_testmanagerd_preflight() {
  local pgrep_bin="${WILTED_TESTMANAGERD_PGREP:-pgrep}" sample_bin="${WILTED_TESTMANAGERD_SAMPLE:-/usr/bin/sample}"
  local pids="" pid scratch="" lookup_status=0 sample_status
  pids="$("$pgrep_bin" -U "$(id -u)" -fx /usr/libexec/testmanagerd)" || lookup_status=$?
  [[ "$lookup_status" -ne 1 ]] || return 0
  if [[ "$lookup_status" -ne 0 ]]; then
    printf 'native.testmanagerd.warning lookup-status=%s; continuing without preflight\n' "$lookup_status" >&2
    return 0
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    printf 'native.testmanagerd.sample pid=%s seconds=1\n' "$pid" >&2
    sample_status=0
    scratch="$(mktemp -d "$tmp_root/testmanagerd-sample.XXXXXX")" || sample_status=$?
    if [[ "$sample_status" -eq 0 ]]; then
      env WILTED_WORK_PHASE=testmanagerd-preflight python3 "${repo_root:?}/scripts/run-bounded.py" \
        --timeout-seconds "${WILTED_TESTMANAGERD_SAMPLE_TIMEOUT_SECONDS:-30}" -- \
        "$sample_bin" "$pid" 1 -file "$scratch/sample.txt" </dev/null >"$scratch/sample.log" 2>&1 || sample_status=$?
      [[ "$sample_status" -ne 0 || -s "$scratch/sample.txt" ]] || sample_status=1
    fi
    if [[ "$sample_status" -ne 0 ]]; then
      printf 'native.testmanagerd.warning pid=%s sample-status=%s; continuing without preflight\n' "$pid" "$sample_status" >&2
    elif grep -q 'XAMLocalAuthenticationProvider' "$scratch/sample.txt" && grep -q 'LAContext evaluatePolicy' "$scratch/sample.txt"; then
      rm -rf "$scratch"
      printf 'native.testmanagerd.error pid=%s is blocked on an unanswered authentication prompt (%s); hosted tests would hang.\n' \
        "$pid" 'XAMLocalAuthenticationProvider -> LAContext evaluatePolicy' >&2
      printf 'native.testmanagerd.remedy Answer or cancel the prompt, or run: kill -9 %s (plain SIGTERM is not enough).\n' "$pid" >&2
      return 1
    fi
    [[ -z "$scratch" ]] || rm -rf "$scratch"
    scratch=""
  done <<<"$pids"
}

# Simulator legs build outside the lane and host-UI locks and hold them only for
# test-without-building; the Mac unit leg keeps build and test in one host-UI transaction.
xcode_test_leg() {
  local label="$1" source_dir="$2" scheme="$3" destination="$4" target="$5"
  shift 5
  local cache_key="native-$label" project udid="" xcode_status=0
  local only_testing_args=(-only-testing:"$target")
  for target in "$@"; do only_testing_args+=(-only-testing:"$target"); done
  local unit_prefix="" unit_selectors="" entry
  if [[ "$label" == "macos-unit-tests" && -n "${WILTED_MAC_UNIT_SELECTORS+x}" ]]; then
    unit_prefix='WiltedMacTests'
    unit_selectors="$WILTED_MAC_UNIT_SELECTORS"
  elif [[ "$label" == "ios-unit-tests" && -n "${WILTED_IOS_UNIT_SELECTORS+x}" ]]; then
    unit_prefix='WiltediOSTests'
    unit_selectors="$WILTED_IOS_UNIT_SELECTORS"
  fi
  if [[ -n "$unit_prefix" ]]; then
    local unit_entries=()
    IFS=',' read -r -a unit_entries <<<"$unit_selectors"
    only_testing_args=()
    for entry in "${unit_entries[@]}"; do
      only_testing_args+=(-only-testing:"$unit_prefix/$entry")
    done
  fi
  local iteration_args=()
  if [[ "$label" == "macos-unit-tests" && -n "${WILTED_MAC_UNIT_ITERATIONS+x}" ]]; then
    iteration_args=(-test-iterations "$WILTED_MAC_UNIT_ITERATIONS")
  elif [[ "$label" == "ios-unit-tests" && -n "${WILTED_IOS_UNIT_ITERATIONS+x}" ]]; then
    iteration_args=(-test-iterations "$WILTED_IOS_UNIT_ITERATIONS")
  fi
  require_tool xcodebuild; require_tool jq; require_tool xmllint
  assert_test_sources "$label" "$source_dir" || return 1
  # Before any copy, build or trap: a wedged host daemon fails here instead of after the test budget.
  if [[ "$destination" != *'id='* ]]; then wilted_testmanagerd_preflight || return 1; fi
  # Legs with private test environments modify owned copies of the generated scheme.
  project="$(find_project)" || return 1
  # Build real runnable products in the owned leg, while retaining DerivedData.
  # Keep them outside work so fixture leak auditing remains exact.
  local products_dir
  products_dir="$(dirname "$WILTED_TEMP_LEG_WORK")/products"
  mkdir -p "$products_dir" || return 1
  if [[ "$scheme" == WiltedMac || "$label" == ios-unit-tests ]]; then
    local project_root="$tmp_root/$label-project"
    mkdir -p "$project_root"
    cp -R "$(dirname "$project")/." "$project_root/"
    project="$project_root/$(basename "$project")"
    local -a mac_test_env=()
    if [[ "$label" == macos-unit-tests ]]; then
      mac_test_env=("WILTED_TEST_TMPDIR=$WILTED_TEMP_LEG_WORK")
      mac_test_env+=("DYLD_FRAMEWORK_PATH=$products_dir/Debug/WiltedMac.app/Contents/Frameworks")
    elif [[ "$label" == ios-unit-tests ]]; then
      mac_test_env=("DYLD_FRAMEWORK_PATH=$products_dir/Debug-iphonesimulator/WiltediOS.app/Frameworks")
    fi
    wilted_mac_test_scheme_configure "$project/xcshareddata/xcschemes/$scheme.xcscheme" "$WILTED_TEMP_LEG_WORK" \
      ${mac_test_env[@]+"${mac_test_env[@]}"} || return 1
  fi
  local common=(-project "$project" -scheme "$scheme" "${only_testing_args[@]}"
    -destination "$destination" -parallel-testing-enabled NO -quiet "CONFIGURATION_BUILD_DIR=$products_dir/\$(CONFIGURATION)\$(EFFECTIVE_PLATFORM_NAME)")
  if [[ "$label" == ios-unit-tests ]]; then
    common+=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
  fi
  local saved_int="" saved_term="" saved_hup="" xcode_signal_status=0 signal_pid=""
  if [[ "$label" == macos-unit-tests ]]; then
    saved_int="$(trap -p INT)"; saved_term="$(trap -p TERM)"; saved_hup="$(trap -p HUP)"
    signal_pid="$(exec sh -c 'echo "$PPID"')"
    trap 'xcode_signal_status=130; wilted_stop_active_ui_lock; wilted_stop_active_supervisor 300' INT
    trap 'xcode_signal_status=143; wilted_stop_active_ui_lock; wilted_stop_active_supervisor 300' TERM
    trap 'xcode_signal_status=129; wilted_stop_active_ui_lock; wilted_stop_active_supervisor 300' HUP
  fi
  if [[ "$destination" == *'id='* ]]; then
    # Compile before entering the lane: a failed or timed-out build never boots a
    # simulator and never waits for another leg's host-UI lock.
    run_with_build_cache xcode "$cache_key" xcodebuild build-for-testing "${common[@]}" || return $?
    udid="${destination##*id=}"
    local test_command=(env WILTED_TEST_TIMEOUT_SECONDS="$xcode_test_timeout_seconds" \
      WILTED_WORK_PHASE=test \
      python3 "$build_with_cache" run xcode "$cache_key" -- xcodebuild test-without-building \
      "${common[@]}" ${iteration_args[@]+"${iteration_args[@]}"} -collect-test-diagnostics never -resultBundlePath "$tmp_root/$label.xcresult")
    wilted_gate_simulator_session "$udid" "${test_command[@]}" &
    WILTED_ACTIVE_SUPERVISOR_PID=$!
  else
    local test_command=(env WILTED_TEST_TIMEOUT_SECONDS="${xcode_build_and_test_timeout_seconds:-$xcode_test_timeout_seconds}" \
      WILTED_WORK_PHASE=build-and-test \
      python3 "$build_with_cache" run xcode "$cache_key" -- xcodebuild test \
      "${common[@]}" ${iteration_args[@]+"${iteration_args[@]}"} -collect-test-diagnostics never -resultBundlePath "$tmp_root/$label.xcresult")
    # Mac test hosts share a bundle identifier. Keep the current project build
    # and test under one host/product transaction so queued peers cannot replace it.
    local lock_pid_file="$tmp_root/$label.ui-lock.pid"
    WILTED_UI_LOCK_PID_FILE="$lock_pid_file"
    GATE_UI_TEST_LOCK_PID_FILE="$lock_pid_file" gate_ui_test_lock --label "$label" "${test_command[@]}" &
    WILTED_ACTIVE_SUPERVISOR_PID=$!
  fi
  if [[ "$xcode_signal_status" -ne 0 ]]; then wilted_stop_active_supervisor 300; fi
  wilted_wait_active_supervisor || xcode_status=$?
  [[ "$xcode_signal_status" -eq 0 ]] || xcode_status="$xcode_signal_status"
  WILTED_UI_LOCK_PID_FILE=""
  if [[ "$label" == macos-unit-tests ]]; then
    local cleanup_status=0
    wilted_mac_test_cleanup_roots "$WILTED_TEMP_LEG_WORK" || cleanup_status=$?
    if [[ "$xcode_signal_status" -ne 0 ]] && declare -F wilted_temp_audit_leg >/dev/null; then
      wilted_temp_audit_leg "$tmp_root" "$label" || cleanup_status=1
    fi
    trap - INT TERM HUP
    [[ -z "$saved_int" ]] || eval "$saved_int"
    [[ -z "$saved_term" ]] || eval "$saved_term"
    [[ -z "$saved_hup" ]] || eval "$saved_hup"
    [[ "$cleanup_status" -eq 0 ]] || return 125
    # Deliver the original signal after exact-host/root cleanup so the
    # caller's existing exit policy runs only after SQLite descriptors close.
    case "$xcode_signal_status" in
      130) kill -INT "$signal_pid" ;;
      143) kill -TERM "$signal_pid" ;;
      129) kill -HUP "$signal_pid" ;;
    esac
  fi
  return "$xcode_status"
}
