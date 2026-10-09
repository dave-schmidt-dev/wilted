# shellcheck shell=bash
# Each build-and-test transaction holds its product lock; work starts after destination readiness.
xcode_test_leg() {
  local label="$1" source_dir="$2" scheme="$3" destination="$4" target="$5"
  shift 5
  local cache_key="native-$label" project udid="" xcode_status=0
  local only_testing_args=(-only-testing:"$target")
  for target in "$@"; do only_testing_args+=(-only-testing:"$target"); done
  require_tool xcodebuild; require_tool jq; require_tool xmllint
  assert_test_sources "$label" "$source_dir" || return 1
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
  local test_command=(env WILTED_TEST_TIMEOUT_SECONDS="$xcode_test_timeout_seconds" WILTED_WORK_PHASE=build-and-test \
    python3 "$build_with_cache" run xcode "$cache_key" -- xcodebuild test \
    "${common[@]}" -collect-test-diagnostics never -resultBundlePath "$tmp_root/$label.xcresult")
  if [[ "$destination" == *'id='* ]]; then
    udid="${destination##*id=}"
    wilted_gate_simulator_session "$udid" "${test_command[@]}" &
    WILTED_ACTIVE_SUPERVISOR_PID=$!
  else
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
