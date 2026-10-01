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
# This seizes the screen: the runner launches the app nine times and drives it.
# Do not run it alongside other work on this machine.
#
# Usage: scripts/record-walkthrough-frames.sh [output-dir]
#        (default: .logs/walkthrough-captures)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test-runner.sh
source "$repo_root/scripts/lib/test-runner.sh"
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

status() { printf '%s\n' "$*" >&2; }

out_dir="${1:-$repo_root/.logs/walkthrough-captures}"
development_team="${WILTED_DEVELOPMENT_TEAM:-4CJ49V6QHW}"
build_cache="$repo_root/scripts/build-with-cache.py"
# shellcheck source=lib/mac-test-parent.sh
source "$repo_root/scripts/lib/mac-test-parent.sh"
# shellcheck source=lib/test-temp-state.sh
source "$repo_root/scripts/lib/test-temp-state.sh"
temp_parent="$(cd -P "${TMPDIR:?TMPDIR must be set}" 2>/dev/null && pwd)" || exit 1
tmp_root="$(mktemp -d "$temp_parent/wilted-walkthrough.XXXXXX")"
# A failed capture is diagnosed from the runner log, and the tail this script
# prints is not enough -- the interesting part is which sections wrote frames
# before the failure, which is thousands of lines earlier. Opt-in diagnostics
# copy only that log and written frame artifacts; the scratch tree is removed.
keep_tmp_root="${WILTED_CAPTURE_KEEP:-0}"
capture_diagnostics_root="$repo_root/.logs/walkthrough-capture-diagnostics"

save_capture_diagnostics() {
  local destination file copied=0
  local -a artifacts=()
  [[ "$keep_tmp_root" == "1" && -d "$tmp_root" ]] || return 0
  shopt -s nullglob
  artifacts=("$tmp_root"/frames/*.png "$tmp_root"/frames/*.json)
  [[ -f "$tmp_root/capture.log" || ${#artifacts[@]} -gt 0 ]] || return 0
  mkdir -p "$capture_diagnostics_root" || return 1
  destination="$(mktemp -d "$capture_diagnostics_root/run.XXXXXX")" || return 1
  if [[ -f "$tmp_root/capture.log" ]]; then
    cp "$tmp_root/capture.log" "$destination/capture.log" || return 1
    copied=1
  fi
  if [[ ${#artifacts[@]} -gt 0 ]]; then
    mkdir -p "$destination/frames" || return 1
    for file in "${artifacts[@]}"; do
      cp "$file" "$destination/frames/" || return 1
      copied=1
    done
  fi
  (( copied == 1 )) || return 1
  status "capture.diagnostics=$destination"
}

cleanup_tmp_root() {
  local result=$?
  trap - EXIT INT TERM HUP
  if [[ "$keep_tmp_root" == "1" ]]; then
    save_capture_diagnostics || {
      status 'capture.diagnostics.failed'
      [[ "$result" -ne 0 ]] || result=1
    }
  fi
  if ! wilted_temp_remove_owned_child "$tmp_root" "$temp_parent" wilted-walkthrough.; then
    status "capture.cleanup.failed root=$tmp_root"
    [[ "$result" -ne 0 ]] || result=1
  fi
  exit "$result"
}
trap cleanup_tmp_root EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
wilted_temp_mark_owned "$tmp_root"

# The same preflight the native gate's UI leg runs, for the same reason:
# XCUITest cannot bring an application forward while the login session is
# locked, so a capture started against a lock burns a full build and then fails
# on an assertion that says nothing about the cause. The gate refuses rather
# than run; this refuses too, so the two agree about when a capture is possible.
# It refused a real lock on 2026-09-07. It is not the explanation for that
# night's failed captures -- those ran against a live session, driving the app
# through six sections before failing on an unhittable control in a window
# placed at a negative origin across a display boundary.
screen_is_locked() {
  ioreg -n Root -d1 -a 2>/dev/null | grep -A 1 'CGSSessionScreenIsLocked' | grep -q '<true/>'
}

if screen_is_locked; then
  status 'capture.failed: the screen is locked; unlock the Mac and rerun'
  exit 1
fi

[[ "$development_team" =~ ^[A-Z0-9]{10}$ ]] ||
  { status 'WILTED_DEVELOPMENT_TEAM must be a ten-character Apple team identifier'; exit 1; }

root="$tmp_root/capture-root"
capture_dir="$tmp_root/frames"
mkdir -p "$root/WiltedKit" "$root/Producer" "$root/CloudSync" "$root/Listener" "$capture_dir"
cp "$repo_root/project.yml" "$root/project.yml"
cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests" \
  "$repo_root/WiltedMacUITests" "$repo_root/WiltediOS" "$repo_root/WiltediOSTests" \
  "$repo_root/WiltediOSIntents" "$repo_root/WiltediOSUITests" "$root/"
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
wilted_mac_test_scheme_configure "$scheme" "$test_tmp_parent" \
  WILTED_WALKTHROUGH_CAPTURE=1 WILTED_WALKTHROUGH_CAPTURE_DIR="$capture_dir"

start_marker="$tmp_root/start"
: >"$start_marker"

status 'capture.start suite=WiltedMacUITests/WiltedMacWalkthroughCapture'
command_status=0
WILTED_TEST_TMPDIR="$test_tmp_parent" caffeinate -disu python3 "$build_cache" run xcode walkthrough-frame-recording -- xcodebuild test \
  -project "$root/Wilted.xcodeproj" \
  -scheme WiltedMac \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:WiltedMacUITests/WiltedMacWalkthroughCapture \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Development' \
  DEVELOPMENT_TEAM="$development_team" >"$tmp_root/capture.log" 2>&1 || {
    command_status=$?
    status 'capture.failed; last 40 lines follow'
    tail -40 "$tmp_root/capture.log" >&2
    exit "$command_status"
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
