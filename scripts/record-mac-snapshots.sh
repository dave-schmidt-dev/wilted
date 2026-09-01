#!/usr/bin/env bash
set -Eeuo pipefail

# Re-records Mac pixel baselines and copies the results back into the repo.
#
# Two things make this more than `xcodebuild ... WILTED_RECORD_SNAPSHOTS=1`:
#
# 1. `xcodebuild` does not forward its environment to the macOS test host, so
#    the variable has to be written into the generated scheme's TestAction with
#    `shouldUseLaunchSchemeArgsEnv = "NO"`. A run without it silently compares
#    instead of recording and writes nothing.
# 2. The baseline path comes from `#filePath`. Run against the in-repo project,
#    the test host blocks forever in `open()` on `~/Documents` -- macOS never
#    delivers the TCC consent decision to a host launched by `xcodebuild`. So
#    this builds from a copy under $TMPDIR, exactly as scripts/test-gate.sh
#    does, and copies the recorded PNGs back afterwards.
#
# Usage: scripts/record-mac-snapshots.sh [test-method ...]
#        (default: every method in WiltedPixelSnapshotTests)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-record-snapshots.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

status() { printf '%s\n' "$*" >&2; }

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

scheme="$root/Wilted.xcodeproj/xcshareddata/xcschemes/WiltedMac.xcscheme"
[[ -f "$scheme" ]] || { status "missing generated scheme: $scheme"; exit 1; }
python3 - "$scheme" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
action = tree.getroot().find("TestAction")
if action is None:
    raise SystemExit("generated scheme has no TestAction")
action.set("shouldUseLaunchSchemeArgsEnv", "NO")
variables = action.find("EnvironmentVariables")
if variables is None:
    variables = ET.SubElement(action, "EnvironmentVariables")
ET.SubElement(variables, "EnvironmentVariable", {
    "key": "WILTED_RECORD_SNAPSHOTS", "value": "1", "isEnabled": "YES",
})
tree.write(path, encoding="UTF-8", xml_declaration=True)
PY

declare -a only=()
if [[ $# -gt 0 ]]; then
  for method in "$@"; do
    only+=("-only-testing:WiltedMacTests/WiltedPixelSnapshotTests/$method")
  done
else
  only+=("-only-testing:WiltedMacTests/WiltedPixelSnapshotTests")
fi

snapshots="WiltedMacTests/__Snapshots__/WiltedPixelSnapshotTests"

status "record.start methods=${*:-all}"
xcodebuild test \
  -project "$root/Wilted.xcodeproj" \
  -scheme WiltedMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$tmp_root/DerivedData" \
  -parallel-testing-enabled NO \
  "${only[@]}" >"$tmp_root/record.log" 2>&1 || {
    status 'record.failed; last 40 lines follow'
    tail -40 "$tmp_root/record.log" >&2
    exit 1
  }

# Copy every baseline back and let git report what actually moved. Deciding
# here which files "changed" would only duplicate what the working tree already
# knows, and would hide a baseline that was rewritten byte-identically.
recorded=0
for file in "$root/$snapshots"/*.png; do
  [[ -s "$file" ]] || { status "record.empty $(basename "$file")"; exit 1; }
  cp "$file" "$repo_root/$snapshots/$(basename "$file")"
  recorded=$((recorded + 1))
done

status "record.complete baselines=$recorded"
status "record.changed=$(cd "$repo_root" && git status --porcelain "$snapshots" | wc -l | tr -d ' ')"
