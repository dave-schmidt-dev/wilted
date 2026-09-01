#!/usr/bin/env bash
set -Eeuo pipefail

# Records the dated walkthrough's content-viewport frames.
#
# The capture suite skips itself unless WILTED_WALKTHROUGH_CAPTURE=1, and
# `xcodebuild` does not forward its environment to the test runner, so the
# variable has to be written into the generated scheme's TestAction with
# `shouldUseLaunchSchemeArgsEnv = "NO"` -- the same obstacle
# scripts/record-mac-snapshots.sh documents. Building from a $TMPDIR copy
# avoids the TCC hang a test host hits against the in-repo project.
#
# This seizes the screen: the runner launches the app six times and drives it.
# Do not run it alongside other work on this machine.
#
# Usage: scripts/record-walkthrough-frames.sh [output-dir]
#        (default: .logs/walkthrough-captures)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${1:-$repo_root/.logs/walkthrough-captures}"
development_team="${WILTED_DEVELOPMENT_TEAM:-4CJ49V6QHW}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-walkthrough.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

status() { printf '%s\n' "$*" >&2; }

[[ "$development_team" =~ ^[A-Z0-9]{10}$ ]] ||
  { status 'WILTED_DEVELOPMENT_TEAM must be a ten-character Apple team identifier'; exit 1; }

root="$tmp_root/capture-root"
capture_dir="$tmp_root/frames"
mkdir -p "$root/WiltedKit" "$root/Producer" "$root/CloudSync" "$root/Listener" "$capture_dir"
cp "$repo_root/project.yml" "$root/project.yml"
cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests" \
  "$repo_root/WiltedMacUITests" "$repo_root/WiltediOS" "$repo_root/WiltediOSTests" \
  "$repo_root/WiltediOSUITests" "$root/"
for package in WiltedKit Producer CloudSync Listener; do
  cp "$repo_root/$package/Package.swift" "$root/$package/Package.swift"
  cp -R "$repo_root/$package/Sources" "$repo_root/$package/Tests" "$root/$package/"
done

xcodegen generate --spec "$root/project.yml" --project "$root" --project-root "$root" >/dev/null

scheme="$root/Wilted.xcodeproj/xcshareddata/xcschemes/WiltedMac.xcscheme"
[[ -f "$scheme" ]] || { status "missing generated scheme: $scheme"; exit 1; }
python3 - "$scheme" "$capture_dir" <<'PY'
import sys, xml.etree.ElementTree as ET
path, capture_dir = sys.argv[1], sys.argv[2]
tree = ET.parse(path)
action = tree.getroot().find("TestAction")
if action is None:
    raise SystemExit("generated scheme has no TestAction")
action.set("shouldUseLaunchSchemeArgsEnv", "NO")
variables = action.find("EnvironmentVariables")
if variables is None:
    variables = ET.SubElement(action, "EnvironmentVariables")
for key, value in (("WILTED_WALKTHROUGH_CAPTURE", "1"),
                   ("WILTED_WALKTHROUGH_CAPTURE_DIR", capture_dir)):
    ET.SubElement(variables, "EnvironmentVariable", {"key": key, "value": value, "isEnabled": "YES"})
tree.write(path, encoding="UTF-8", xml_declaration=True)
PY

start_marker="$tmp_root/start"
: >"$start_marker"

status 'capture.start suite=WiltedMacUITests/WiltedMacWalkthroughCapture'
xcodebuild test \
  -project "$root/Wilted.xcodeproj" \
  -scheme WiltedMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$tmp_root/DerivedData" \
  -parallel-testing-enabled NO \
  -only-testing:WiltedMacUITests/WiltedMacWalkthroughCapture \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Development' \
  DEVELOPMENT_TEAM="$development_team" >"$tmp_root/capture.log" 2>&1 || {
    status 'capture.failed; last 40 lines follow'
    tail -40 "$tmp_root/capture.log" >&2
    exit 1
  }

# The runner reports where it could actually write. Trusting the requested
# directory would silently produce a stale report when the runner fell back.
resolved="$(sed -n 's/.*walkthrough\.capture\.root=\([^[:space:]]*\).*/\1/p' "$tmp_root/capture.log" | tail -1)"
[[ -n "$resolved" ]] || { status 'capture.failed: runner never reported its capture root'; exit 1; }
status "capture.root=$resolved"

# A skipped run still exits zero, so the frames themselves are the evidence.
shopt -s nullglob
frames=("$resolved"/*.png)
(( ${#frames[@]} > 0 )) || { status 'capture.failed: no frames were written'; exit 1; }

rm -rf "$out_dir"
mkdir -p "$out_dir"
for frame in "${frames[@]}"; do
  [[ -s "$frame" ]] || { status "capture.empty $(basename "$frame")"; exit 1; }
  sidecar="${frame%.png}.json"
  [[ -s "$sidecar" ]] || { status "capture.missing-sidecar $(basename "$frame")"; exit 1; }
  # The runner's fallback directory survives between runs. The capture suite
  # empties it before recording; this is the check that says so out loud,
  # because a frame left by an earlier run is stale evidence that looks exactly
  # like fresh evidence.
  [[ "$frame" -nt "$start_marker" && "$sidecar" -nt "$start_marker" ]] ||
    { status "capture.stale $(basename "$frame") predates this run"; exit 1; }
  cp "$frame" "$sidecar" "$out_dir/"
done

status "capture.complete frames=${#frames[@]} out=$out_dir"
