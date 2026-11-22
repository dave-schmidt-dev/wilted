# Shared collaborators for shell fixtures that source the native gate helpers.
# Set GATE_HARNESS_* values before sourcing to configure a test's fake behavior.

assert_test_sources() { :; }

require_tool() {
  if [[ "$1" == "${GATE_HARNESS_MISSING_TOOL:-}" ]]; then
    printf 'native.error missing required tool: %s\n' "$1" >&2
    return 1
  fi
  if [[ "${GATE_HARNESS_CHECK_PATH:-0}" == 1 ]]; then command -v "$1" >/dev/null; fi
}

find_project() {
  local project_path="${GATE_HARNESS_PROJECT_PATH:-${native_project:-}}"
  [[ -n "$project_path" ]] || return 1
  printf '%s\n' "$project_path"
}

build_cache_path() {
  if [[ -n "${GATE_HARNESS_CACHE_PATH:-}" ]]; then
    printf '%s\n' "$GATE_HARNESS_CACHE_PATH"
    return 0
  fi
  python3 "$build_with_cache" path "$@"
}

run_with_build_cache() {
  local kind="$1" key="$2"
  shift 2

  if [[ -n "${GATE_HARNESS_BUILD_ARGUMENTS_FILE:-}" ]]; then
    printf '%s\n' "$kind" "$key" "$@" >"$GATE_HARNESS_BUILD_ARGUMENTS_FILE"
    return 0
  fi

  if [[ -n "${GATE_HARNESS_BUILD_EVENTS_FILE:-}" ]]; then
    printf '%s\n' "${GATE_HARNESS_BUILD_EVENT:-build}" >>"$GATE_HARNESS_BUILD_EVENTS_FILE"
    return "${GATE_HARNESS_BUILD_STATUS:-0}"
  fi

  if [[ -n "${GATE_HARNESS_BUILD_TIMEOUT_SECONDS:-}" ]]; then
    WILTED_TEST_TIMEOUT_SECONDS="$GATE_HARNESS_BUILD_TIMEOUT_SECONDS" \
      WILTED_WORK_PHASE=build \
      python3 "$build_with_cache" run "$kind" "$key" -- "$@"
  else
    WILTED_WORK_PHASE=build python3 "$build_with_cache" run "$kind" "$key" -- "$@"
  fi
}

is_deferred_leg() {
  [[ "${GATE_HARNESS_DEFER_ALL_LEGS:-0}" == 1 || \
    ( -n "${GATE_HARNESS_DEFERRED_LEG:-}" && "$1" == "$GATE_HARNESS_DEFERRED_LEG" ) ]]
}
