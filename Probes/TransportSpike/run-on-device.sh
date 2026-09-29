#!/usr/bin/env bash
# Builds SpikeiOS signed for a device, installs it and launches it with devicectl.
#   run-on-device.sh <udid>            build, install, launch
#   run-on-device.sh <udid> pull [dir] copy the app's Documents (JSON reports) to dir (default ./spike-reports)
# Find the UDID with: xcrun devicectl list devices
set -euo pipefail

UDID="${1:-}"
ACTION="${2:-run}"
BUNDLE_ID="com.zerodelta.wilted.spike.ios"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$UDID" ]]; then
  echo "usage: $0 <device-udid> [run|pull [dest-dir]]" >&2
  exit 2
fi

if [[ "$ACTION" == "pull" ]]; then
  DEST="${3:-./spike-reports}"
  mkdir -p "$DEST"
  xcrun devicectl device copy from --device "$UDID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents --destination "$DEST"
  echo "reports copied to $DEST"
  exit 0
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:?set TMPDIR}/spike-device.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcodegen generate --spec "$ROOT/project.yml"
echo "building SpikeiOS (signing with team 4CJ49V6QHW)..."
xcodebuild build \
  -project "$ROOT/TransportSpike.xcodeproj" \
  -scheme SpikeiOS \
  -configuration Development \
  -destination "id=$UDID" \
  -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates \
  -quiet

APP="$BUILD_DIR/Build/Products/Development-iphoneos/SpikeiOS.app"
[[ -d "$APP" ]] || { echo "build product not found: $APP" >&2; exit 1; }

echo "installing on $UDID..."
xcrun devicectl device install app --device "$UDID" "$APP"
echo "launching $BUNDLE_ID..."
xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID"
echo "done; run '$0 $UDID pull' later to fetch the JSON report"
