#!/usr/bin/env bash
# Attended Development CloudKit qualification build for Task 6.
#
# Produces Development-configuration, Apple Development-signed Mac producer and
# iOS listener builds that carry the real `iCloud.com.zerodelta.wilted`
# entitlement, then installs the listener on the attended physical device.
#
# This script performs NO portal mutation on its own beyond what automatic
# signing requires; `-allowProvisioningUpdates` is passed only when the caller
# opts in with WILTED_ALLOW_PROVISIONING_UPDATES=1, which is an attended,
# owner-approved gate (see docs/task5-cloudkit-capability-preflight.md).
#
# The team identifier is never pinned in `project.yml`; it is supplied here the
# same way `scripts/test-gate.sh` supplies it, so committed source stays
# credential-free and free of a pinned Apple team.
#
# `--library-sync` extends the same flow for the attended iPhone library-sync
# run: it builds both Development apps, installs the iOS app on
# WILTED_DEVICE_ID, quits any running Mac app, and relaunches the Development
# Mac app with no launch flag: a live Development build selects the library
# publisher by default (WILTED_LIBRARY_SYNC=0 is the explicit off override). Run
# `scripts/attended-cloudkit-run.sh --help` for details.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

usage() {
  cat <<'USAGE'
Usage: scripts/attended-cloudkit-run.sh [STEP | --library-sync | --help]

Steps (default: all):
  generate       regenerate the Xcode project from project.yml
  mac            build the signed Development Mac producer
  ios            build the signed Development iOS listener
  install        install the built iOS listener on WILTED_DEVICE_ID
  all            generate, mac, ios

Modes:
  --library-sync  attended iPhone library-sync run:
                  1. build the Development Mac and iOS apps
                  2. install the iOS app on the device in WILTED_DEVICE_ID
                  3. quit any running com.zerodelta.wilted.mac (fails if it
                     does not exit)
                  4. launch the Development Mac app with open -n <app>; a live
                     Development build selects the library publisher by
                     default, so no launch flag is needed
                     (WILTED_LIBRARY_SYNC=0 forces it off, =1 forces it on)
                  5. verify by bundle id and process path that the running
                     instance is the Development build
                  The installed app in /Applications is not modified.
                  Restore the daily-driver app afterwards with: make install
  -h, --help      print this help and exit

Environment:
  WILTED_DEVICE_ID                      paired device identifier (required for
                                        install and --library-sync)
  WILTED_DEVELOPMENT_TEAM               Apple team id (default 4CJ49V6QHW)
  WILTED_ALLOW_PROVISIONING_UPDATES=1   pass -allowProvisioningUpdates
USAGE
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

wilted_development_team="${WILTED_DEVELOPMENT_TEAM:-4CJ49V6QHW}"
allow_updates="${WILTED_ALLOW_PROVISIONING_UPDATES:-0}"
project="$repo_root/Wilted.xcodeproj"
build_cache="$repo_root/scripts/build-with-cache.py"
derived="$(python3 "$build_cache" path xcode attended-cloudkit)"
log_dir="$repo_root/.logs/attended-cloudkit"
container='iCloud.com.zerodelta.wilted'
mac_bundle_id='com.zerodelta.wilted.mac'
mac_app_path="$derived/Build/Products/Development/WiltedMac.app"
ios_app_path="$derived/Build/Products/Development-iphoneos/WiltediOS.app"

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
fail() { printf 'attended.error %s\n' "$*" >&2; exit 1; }

require_tool() { command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"; }

# Streams a long build so it never blocks silently (W-INV-001).
run_build() {
  local label="$1"; shift
  local log="$log_dir/$label.log"
  mkdir -p "$log_dir"
  info "building $label (streaming to $log)"
  set -o pipefail
  "$@" >"$log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10
    waited=$((waited + 10))
    printf '   [%3ds] %s\n' "$waited" "$(tail -n 1 "$log" 2>/dev/null | cut -c1-100)"
  done
  wait "$pid" || {
    printf '\n--- last 40 log lines (%s) ---\n' "$label" >&2
    tail -n 40 "$log" >&2
    fail "$label build failed"
  }
  info "$label build succeeded"
}

# Proves the built artifact carries the real CloudKit entitlement, an embedded
# Development profile, and an Apple Development signature for the expected team.
verify_artifact() {
  local label="$1" app="$2" profile_name="$3"
  [[ -d "$app" ]] || fail "$label product not found at $app"

  local ents
  ents="$(codesign --display --entitlements :- --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null)" \
    || fail "$label effective entitlements unavailable"
  printf '%s' "$ents" | grep -q "$container" \
    || fail "$label effective entitlements do not carry $container"
  info "$label effective entitlements carry $container"

  local aps
  aps="$(printf '%s' "$ents" | grep -A1 'aps-environment' | tail -n1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')"
  [[ "$aps" == 'development' ]] || fail "$label aps-environment is '$aps', expected development"
  info "$label aps-environment=development"

  [[ -f "$app/$profile_name" ]] || fail "$label has no embedded provisioning profile ($profile_name)"
  local pname
  pname="$(security cms -D -i "$app/$profile_name" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)"
  info "$label embedded profile: $pname"

  local sig
  sig="$(codesign --display --verbose=4 "$app" 2>&1)" || fail "$label signature metadata unavailable"
  [[ "$sig" == *'Authority=Apple Development:'* ]] \
    || fail "$label is not signed by an Apple Development identity"
  [[ "$sig" == *"TeamIdentifier=$wilted_development_team"* ]] \
    || fail "$label is not signed for team $wilted_development_team"
  info "$label signed by Apple Development, team=$wilted_development_team"
  codesign --verify --strict "$app" || fail "$label signature does not verify"
}

# Automatic signing must override the credential-free `-` identity and the
# disabled-signing defaults that `project.yml` pins for local gates. The flag
# precedes build settings because xcodebuild expects settings last.
signing_args() {
  if [[ "$allow_updates" == '1' ]]; then
    printf '%s\n' -allowProvisioningUpdates
  fi
  printf '%s\n' \
    CODE_SIGN_STYLE=Automatic \
    "CODE_SIGN_IDENTITY=Apple Development" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    "DEVELOPMENT_TEAM=$wilted_development_team"
}

cmd_generate() {
  require_tool xcodegen
  step 'Regenerating Xcode project from project.yml'
  xcodegen generate --spec project.yml >/dev/null || fail 'xcodegen generate failed'
  info 'project regenerated; project.yml remains authoritative'
}

cmd_mac() {
  require_tool xcodebuild; require_tool codesign
  step 'Building Mac producer (Development, live CloudKit)'
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(signing_args)
  run_build mac python3 "$build_cache" run xcode attended-cloudkit -- xcodebuild build \
    -project "$project" -scheme WiltedMac -configuration Development \
    -destination 'platform=macOS,arch=arm64' \
    "${args[@]}"
  verify_artifact 'mac' "$mac_app_path" 'Contents/embedded.provisionprofile'
  printf '\nMAC_APP=%s\n' "$mac_app_path"
}

# The iOS Development build signs manually with the "Wilted iOS Development" profile (the only one that
# carries the CarPlay audio entitlement), so the automatic-signing overrides are dropped for it.
ios_signing_args() {
  signing_args | grep -Fvx -e -allowProvisioningUpdates -e CODE_SIGN_STYLE=Automatic -e 'CODE_SIGN_IDENTITY=Apple Development'
}

cmd_ios() {
  require_tool xcodebuild; require_tool codesign
  step 'Building iOS listener (Development, live CloudKit, device slice, manual CarPlay profile)'
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(ios_signing_args)
  run_build ios python3 "$build_cache" run xcode attended-cloudkit -- xcodebuild build \
    -project "$project" -scheme WiltediOS -configuration Development \
    -destination 'generic/platform=iOS' \
    "${args[@]}"
  verify_artifact 'ios' "$ios_app_path" 'embedded.mobileprovision'
  printf '\nIOS_APP=%s\n' "$ios_app_path"
}

cmd_install() {
  require_tool xcrun
  local device="${WILTED_DEVICE_ID:-}"
  [[ -n "$device" ]] || fail 'set WILTED_DEVICE_ID to the paired device identifier'
  [[ -d "$ios_app_path" ]] || fail 'no iOS product to install; run the ios step first'
  step "Installing listener on device $device"
  xcrun devicectl device install app --device "$device" "$ios_app_path" || fail 'device install failed'
  info 'listener installed'
}

# Attended library-sync run. The device is checked first so a missing
# WILTED_DEVICE_ID fails before any build starts. The installed app is
# only quit, never modified; `make install` restores it.
cmd_library_sync() {
  [[ -n "${WILTED_DEVICE_ID:-}" ]] || fail 'set WILTED_DEVICE_ID to the paired device identifier'
  require_tool open; require_tool osascript
  # shellcheck source=lib/app-identity.sh
  source "$repo_root/scripts/lib/app-identity.sh"

  step 'Library-sync run: building Development apps'
  cmd_mac
  cmd_ios
  cmd_install

  step "Quitting running $mac_bundle_id"
  info 'the installed app is left untouched; restore it afterwards with: make install'
  if [[ -n "$(wilted_running_bundle_pids "$mac_bundle_id")" ]]; then
    osascript -e "tell application id \"$mac_bundle_id\" to quit" >/dev/null 2>&1 || true
    wilted_wait_for_bundle_exit "$mac_bundle_id" 10 \
      || fail "a running $mac_bundle_id did not exit; quit it manually and rerun"
  fi
  info "no $mac_bundle_id instance running"

  step 'Launching Development Mac app (library publisher is the live default)'
  # No --env: the live build selects the publisher itself, and LaunchServices
  # does not inherit the shell, so a stray WILTED_LIBRARY_SYNC cannot leak in.
  open -n "$mac_app_path" || fail 'open failed'

  local expected_dir pid path bad='' found=0 tries=20
  expected_dir="$(cd -P "$mac_app_path" && pwd -P)/Contents/MacOS/"
  [[ "$(wilted_bundle_identifier "$mac_app_path")" == "$mac_bundle_id" ]] \
    || fail "built app bundle id is not $mac_bundle_id"
  while (( tries > 0 )); do
    found=0; bad=''
    while read -r pid path; do
      [[ -n "$pid" && "$path" == *.app/Contents/MacOS/* ]] || continue
      [[ "$(wilted_bundle_identifier "${path%%.app/Contents/MacOS/*}.app")" == "$mac_bundle_id" ]] || continue
      if [[ "$path" == "$expected_dir"* ]]; then found=1; else bad="$bad $pid:$path"; fi
    done < <(ps -axo pid=,comm= 2>/dev/null || true)
    [[ -z "$bad" && "$found" == 1 ]] && break
    [[ -n "$bad" ]] && break
    sleep 0.5; tries=$((tries - 1))
  done
  [[ -z "$bad" ]] || fail "a non-Development $mac_bundle_id is running:$bad"
  [[ "$found" == 1 ]] || fail "Development Mac app did not start from $mac_app_path"
  info "running Development instance verified: $mac_bundle_id from $expected_dir"

  step 'Library-sync run ready'
  info 'Mac app is publishing (live default); iOS app is installed on the device'
  info 'restore the daily-driver app with: make install'
}

case "${1:-all}" in
  generate) cmd_generate ;;
  mac) cmd_mac ;;
  ios) cmd_ios ;;
  install) cmd_install ;;
  all) cmd_generate; cmd_mac; cmd_ios ;;
  --library-sync)
    (( $# == 1 )) || fail "--library-sync takes no further arguments (got: ${*:2})"
    cmd_library_sync ;;
  *) fail "unknown step: $1 (expected generate|mac|ios|install|all|--library-sync|--help)" ;;
esac
