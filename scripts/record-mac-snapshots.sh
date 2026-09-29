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
# shellcheck source=lib/test-runner.sh
source "$repo_root/scripts/lib/test-runner.sh"
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

status() { printf '%s\n' "$*" >&2; }

build_cache="$repo_root/scripts/build-with-cache.py"
# shellcheck source=lib/mac-test-parent.sh
source "$repo_root/scripts/lib/mac-test-parent.sh"
# shellcheck source=lib/test-temp-state.sh
source "$repo_root/scripts/lib/test-temp-state.sh"
temp_parent="$(cd -P "${TMPDIR:?TMPDIR must be set}" 2>/dev/null && pwd)" || exit 1
tmp_root="$(mktemp -d "$temp_parent/wilted-record-snapshots.XXXXXX")"

cleanup_tmp_root() {
  local result=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$tmp_root" ]]; then
    if ! wilted_temp_remove_owned_child "$tmp_root" "$temp_parent" wilted-record-snapshots.; then
      status "record.cleanup.failed root=$tmp_root"
      [[ "$result" -ne 0 ]] || result=1
    fi
  fi
  exit "$result"
}
trap cleanup_tmp_root EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
wilted_temp_mark_owned "$tmp_root"

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
test_tmp_parent="$tmp_root/xctest-temp"
mkdir -p "$test_tmp_parent"
test_tmp_parent="$(cd -P "$test_tmp_parent" && pwd)"
wilted_mac_test_scheme_configure "$scheme" "$test_tmp_parent" WILTED_RECORD_SNAPSHOTS=1

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
command_status=0
WILTED_TEST_TMPDIR="$test_tmp_parent" python3 "$build_cache" run xcode mac-snapshot-recording -- xcodebuild test \
  -project "$root/Wilted.xcodeproj" \
  -scheme WiltedMac \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  "${only[@]}" >"$tmp_root/record.log" 2>&1 || command_status=$?
if [[ "$command_status" -ne 0 ]]; then
    status 'record.failed; last 40 lines follow'
    tail -40 "$tmp_root/record.log" >&2
    exit "$command_status"
fi

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
