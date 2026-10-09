#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-record-ios-meta.XXXXXX")"
trap 'rm -rf "$root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'record-meta.fail %s\n' "$*" >&2; exit 1; }
fixture="$root/repo"
snapshots=WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests
mkdir -p "$fixture/scripts/lib" "$fixture/$snapshots" "$root/bin" "$root/scratch"
cp "$repo_root/scripts/record-ios-snapshots.sh" "$fixture/scripts/"
cp "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift" "$fixture/WiltediOSUITests/"
printf '%s\n' fixture >"$fixture/project.yml"
for directory in Shared WiltedMac WiltedMacTests WiltedMacUITests WiltediOS WiltediOSTests WiltediOSIntents WiltedWatch WiltedWatchTests; do mkdir -p "$fixture/$directory"; done
printf watch-source-sentinel >"$fixture/WiltedWatch/source.swift"
printf watch-test-sentinel >"$fixture/WiltedWatchTests/test.swift"
for package in WiltedKit Producer CloudSync Playback; do
  mkdir -p "$fixture/$package/Sources" "$fixture/$package/Tests"
  touch "$fixture/$package/Package.swift"
done
for name in library-larder-light library-larder-dark library-settings-light; do
  printf 'old-%s\n' "$name" >"$fixture/$snapshots/$name.png"
done
cat >"$fixture/scripts/lib/simctl_gate_lib.sh" <<'LIB'
gate_sweep() { printf '%s\n' 0; }
gate_sim_create() { printf '%s\n' fixture-udid; }
gate_ui_test_lock() { shift 4; "$@"; }
LIB
printf '%s\n' 'print("runtime device")' >"$fixture/scripts/select-ios-simulator.py"
cat >"$root/bin/xcodegen" <<'BIN'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  if [[ "$1" == --project-root ]]; then project_root="$2"; break; fi
  shift
done
[[ "$(cat "$project_root/WiltedWatch/source.swift")" == watch-source-sentinel ]] || exit 41
[[ "$(cat "$project_root/WiltedWatchTests/test.swift")" == watch-test-sentinel ]] || exit 42
printf '%s\n' recorder.watch-staging.verified >&2
[[ -z "$(find "$project_root/WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests" -maxdepth 1 -name '*.png' -print -quit)" ]] || {
  printf '%s\n' recorder.resources-present-at-generation >&2; exit 43
}
printf '%s\n' recorder.resources-empty-at-generation.verified >&2
BIN
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$root/bin/git"
cat >"$root/bin/xcrun" <<'BIN'
#!/usr/bin/env bash
printf '%s\n' '{}'
BIN
chmod +x "$root/bin/"*
cat >"$fixture/scripts/build-with-cache.py" <<'PYBUILD'
import os, sys
from pathlib import Path
args = sys.argv
project = Path(args[args.index("-project") + 1]).parent
fresh = project / "WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests"
# Copied baselines must have been cleared before starting this invocation.
assert not list(fresh.glob("*.png")), "recording reused stale PNGs"
(fresh / "library-larder-light.png").write_bytes(b"new-light")
scenario = os.environ["RECORD_META_SCENARIO"]
if scenario in ("build-failure", "build-failure-no-case", "build-failure-after-capture"):
    print("Test Case '-[WiltediOSUITests.WiltediOSPixelSnapshotTests testLibraryLarderLightPixelBaseline]' passed", file=sys.stderr)
    if scenario == "build-failure-no-case":
        print("Testing failed: fixture transport failed", file=sys.stderr)
    else:
        print("Test Case '-[WiltediOSUITests.WiltediOSPixelSnapshotTests testLibraryLarderDarkPixelBaseline]' failed", file=sys.stderr)
    if scenario == "build-failure-after-capture":
        (fresh / "library-larder-dark.png").write_bytes(b"new-dark")
    sys.exit(1)
if scenario == "symlink":
    (fresh / "library-larder-dark.png").symlink_to(fresh / "library-larder-light.png")
elif scenario != "missing":
    (fresh / "library-larder-dark.png").write_bytes(b"" if scenario == "empty" else b"new-dark")
PYBUILD
export PATH="$root/bin:$PATH"
before="$(shasum -a 256 "$fixture/$snapshots/"*.png)"
if ! TMPDIR="$root/scratch" RECORD_META_SCENARIO=success bash "$fixture/scripts/record-ios-snapshots.sh" \
  testLibraryLarderLightPixelBaseline testLibraryLarderDarkPixelBaseline >"$root/staging.log" 2>&1; then
  cat "$root/staging.log" >&2; fail 'Watch sources were not staged before XcodeGen'
fi
grep -q recorder.watch-staging.verified "$root/staging.log" || fail 'Watch staging sentinel proof absent'
grep -q recorder.resources-empty-at-generation.verified "$root/staging.log" || fail 'generation saw stale PNG resources'
[[ -z "$(find "$root/scratch" -mindepth 1 -print)" ]] || fail 'Watch staging leaked scratch'
for name in library-larder-light library-larder-dark library-settings-light; do
  printf 'old-%s\n' "$name" >"$fixture/$snapshots/$name.png"
done
printf '%s\n' 'recorder Watch directory and sentinel staging regression passed'

for scenario in build-failure build-failure-no-case build-failure-after-capture missing empty symlink; do
  if TMPDIR="$root/scratch" RECORD_META_SCENARIO="$scenario" bash "$fixture/scripts/record-ios-snapshots.sh" \
    testLibraryLarderLightPixelBaseline testLibraryLarderDarkPixelBaseline >"$root/$scenario.log" 2>&1; then fail "$scenario was accepted"; fi
  diagnostic="$(sed -n '/^record.failed cases=/p' "$root/$scenario.log")"
  [[ "$diagnostic" == 'record.failed cases=testLibraryLarderDarkPixelBaseline' ]] || { cat "$root/$scenario.log" >&2; fail "$scenario misidentified failed cases: $diagnostic"; }
  [[ "$diagnostic" != *testLibraryLarderLightPixelBaseline* ]] || fail "$scenario labelled passing light case as failed"
  [[ "$(shasum -a 256 "$fixture/$snapshots/"*.png)" == "$before" ]] || fail "$scenario changed existing baselines"
  [[ -z "$(find "$root/scratch" -mindepth 1 -print)" ]] || fail "$scenario leaked scratch"
done
if TMPDIR="$root/scratch" RECORD_META_SCENARIO=success bash "$fixture/scripts/record-ios-snapshots.sh" unknownCase >"$root/unknown.log" 2>&1; then fail 'unknown method accepted'; fi
grep -q 'record.failed cases=unknownCase' "$root/unknown.log" || fail 'unknown method diagnostic absent'
[[ "$(shasum -a 256 "$fixture/$snapshots/"*.png)" == "$before" ]] || fail 'unknown case changed baselines'
TMPDIR="$root/scratch" RECORD_META_SCENARIO=success bash "$fixture/scripts/record-ios-snapshots.sh" \
  testLibraryLarderLightPixelBaseline testLibraryLarderDarkPixelBaseline >"$root/success.log" 2>&1 || { cat "$root/success.log" >&2; fail 'successful set not published'; }
[[ "$(cat "$fixture/$snapshots/library-larder-light.png")" == new-light ]] || fail 'light baseline not replaced'
[[ "$(cat "$fixture/$snapshots/library-larder-dark.png")" == new-dark ]] || fail 'dark baseline not replaced'
[[ "$(cat "$fixture/$snapshots/library-settings-light.png")" == old-library-settings-light ]] || fail 'unrequested baseline changed'
[[ -z "$(find "$root/scratch" -mindepth 1 -print)" ]] || fail 'success leaked scratch'
[[ -z "$(find "$fixture/$(dirname "$snapshots")" -name '.wilted-record-ios-*' -print)" ]] || fail 'transaction directory leaked'
printf '%s\n' 'snapshot recording meta-test passed (build failure/missing/empty/symlink/unknown preserve bytes; successful complete set swaps and preserves unrequested cases; scratch clean)'
