#!/usr/bin/env bash
set -Eeuo pipefail

# Re-records the iPhone listener pixel baselines and copies them back into the
# repo. The iOS half of scripts/record-mac-snapshots.sh.
#
# The baselines live next to WiltediOSPixelSnapshotTests.swift and the path
# comes from `#filePath`, so this builds from a copy under $TMPDIR (as the gate
# does) and copies the PNGs back afterwards. Unlike the macOS test host, the
# simulator's UI-test runner does receive `TEST_RUNNER_`-prefixed variables
# from xcodebuild's environment, so no scheme edit is needed. The device is
# pinned to the model the baselines were recorded on; a different iPhone
# renders a different geometry and every comparison fails.
#
# Usage: scripts/record-ios-snapshots.sh [test-method ...]
#        (default: every method in WiltediOSPixelSnapshotTests)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-record-ios-snapshots.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
# shellcheck source=lib/simctl_gate_lib.sh
source "$repo_root/scripts/lib/simctl_gate_lib.sh"

status() { printf '%s\n' "$*" >&2; }

stale_simulators_swept="$(gate_sweep wilted)"
status "record.simulator.sweep wilted_deleted=${stale_simulators_swept:-0}"

root="$tmp_root/record-root"
mkdir -p "$root/WiltedKit" "$root/Producer" "$root/CloudSync" "$root/Listener"
cp "$repo_root/project.yml" "$root/project.yml"
cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests" \
  "$repo_root/WiltedMacUITests" "$repo_root/WiltediOS" "$repo_root/WiltediOSTests" \
  "$repo_root/WiltediOSUITests" "$root/"
for package in WiltedKit Producer CloudSync Listener; do
  cp "$repo_root/$package/Package.swift" "$root/$package/Package.swift"
  cp -R "$repo_root/$package/Sources" "$repo_root/$package/Tests" "$root/$package/"
done

xcodegen generate --spec "$root/project.yml" --project "$root" --project-root "$root" >/dev/null

read -r runtime device_type <<<"$(xcrun simctl list devices available -j | python3 "$repo_root/scripts/select-ios-simulator.py")"
[[ -n "${runtime:-}" && -n "${device_type:-}" ]] || { status 'iOS 26.x simulator selector returned no device'; exit 1; }
udid="$(gate_sim_create wilted snapshots "$device_type" "$runtime")"
status "simulator.create name=wilted-gate-snapshots runtime=$runtime device_type=$device_type udid=$udid"
xcrun simctl boot "$udid" >&2
xcrun simctl bootstatus "$udid" -b >&2

declare -a only=()
if [[ $# -gt 0 ]]; then
  for method in "$@"; do
    only+=("-only-testing:WiltediOSUITests/WiltediOSPixelSnapshotTests/$method")
  done
else
  only+=("-only-testing:WiltediOSUITests/WiltediOSPixelSnapshotTests")
fi

snapshots="WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests"

status "record.start device=iPhone 17 Pro runtime=$runtime methods=${*:-all}"
gate_ui_test_lock --label 'Wilted iOS snapshot recording' --simulator-udid "$udid" \
  env TEST_RUNNER_WILTED_RECORD_SNAPSHOTS=1 xcodebuild test \
  -project "$root/Wilted.xcodeproj" \
  -scheme WiltediOS \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$tmp_root/DerivedData" \
  -parallel-testing-enabled NO \
  "${only[@]}" >"$tmp_root/record.log" 2>&1 || {
    status 'record.failed; last 40 lines follow'
    tail -40 "$tmp_root/record.log" >&2
    exit 1
  }

recorded=0
for file in "$root/$snapshots"/*.png; do
  [[ -s "$file" ]] || { status "record.empty $(basename "$file")"; exit 1; }
  cp "$file" "$repo_root/$snapshots/$(basename "$file")"
  recorded=$((recorded + 1))
done

status "record.complete baselines=$recorded"
status "record.changed=$(cd "$repo_root" && git status --porcelain "$snapshots" | wc -l | tr -d ' ')"
