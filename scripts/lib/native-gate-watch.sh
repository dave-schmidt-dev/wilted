# shellcheck shell=bash
# The `watchos-build` leg for scripts/test-gate.sh: builds the WiltedWatch scheme
# for the watchOS simulator SDK.
#
# The leg is opt-in: it runs only when WILTED_GATE_LEGS names it, so the default
# gate (and its nine-leg count) is unchanged. It builds for the generic watchOS
# Simulator destination, which needs the SDK but no device, so it creates no
# simulator and there is nothing to delete on any exit path. Relies on the gate's
# `integration_root`, `find_project`, `require_tool`, `fail` and
# `run_with_build_cache`.

optin_leg_names+=(watchos-build)
optin_leg_fns+=(leg_watchos_build)
optin_leg_reports+=(none)

leg_watchos_build() {
  [[ -f "$integration_root/WiltedWatch/Info.plist" ]] || fail 'missing WiltedWatch sources in the integration root'
  require_tool xcodebuild
  local project
  project="$(find_project)" || return 1
  # The leg runs where errexit does not reach, so the build status is checked
  # explicitly; otherwise a compile error would still report status=0.
  if ! run_with_build_cache xcode native-watchos-build xcodebuild build \
    -project "$project" \
    -scheme WiltedWatch \
    -configuration Debug \
    -destination 'generic/platform=watchOS Simulator' \
    -quiet; then
    return 1
  fi
  printf 'native.watchos.build scheme=WiltedWatch destination=watchos-simulator\n'
}
