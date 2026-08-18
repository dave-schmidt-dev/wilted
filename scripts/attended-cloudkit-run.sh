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
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

wilted_development_team="${WILTED_DEVELOPMENT_TEAM:-4CJ49V6QHW}"
allow_updates="${WILTED_ALLOW_PROVISIONING_UPDATES:-0}"
project="$repo_root/Wilted.xcodeproj"
derived="$repo_root/.attended-build"
log_dir="$derived/logs"
container='iCloud.com.zerodelta.wilted'

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
  run_build mac xcodebuild build \
    -project "$project" -scheme WiltedMac -configuration Development \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived/mac" "${args[@]}"
  local app
  app="$(find "$derived/mac/Build/Products" -maxdepth 2 -type d -name 'WiltedMac.app' -print -quit)"
  verify_artifact 'mac' "$app" 'Contents/embedded.provisionprofile'
  printf '\nMAC_APP=%s\n' "$app"
}

cmd_ios() {
  require_tool xcodebuild; require_tool codesign
  step 'Building iOS listener (Development, live CloudKit, device slice)'
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(signing_args)
  run_build ios xcodebuild build \
    -project "$project" -scheme WiltediOS -configuration Development \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived/ios" "${args[@]}"
  local app
  app="$(find "$derived/ios/Build/Products" -maxdepth 2 -type d -name 'WiltediOS.app' -print -quit)"
  verify_artifact 'ios' "$app" 'embedded.mobileprovision'
  printf '\nIOS_APP=%s\n' "$app"
}

cmd_install() {
  require_tool xcrun
  local device="${WILTED_DEVICE_ID:-}"
  [[ -n "$device" ]] || fail 'set WILTED_DEVICE_ID to the paired device identifier'
  local app
  app="$(find "$derived/ios/Build/Products" -maxdepth 2 -type d -name 'WiltediOS.app' -print -quit)"
  [[ -d "$app" ]] || fail 'no iOS product to install; run the ios step first'
  step "Installing listener on device $device"
  xcrun devicectl device install app --device "$device" "$app" || fail 'device install failed'
  info 'listener installed'
}

case "${1:-all}" in
  generate) cmd_generate ;;
  mac) cmd_mac ;;
  ios) cmd_ios ;;
  install) cmd_install ;;
  all) cmd_generate; cmd_mac; cmd_ios ;;
  *) fail "unknown step: $1 (expected generate|mac|ios|install|all)" ;;
esac
