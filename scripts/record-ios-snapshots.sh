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
build_cache="$repo_root/scripts/build-with-cache.py"
tmp_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-record-ios-snapshots.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
# shellcheck source=lib/simctl_gate_lib.sh
source "$repo_root/scripts/lib/simctl_gate_lib.sh"

status() { printf '%s\n' "$*" >&2; }

snapshots="WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests"
# Bind requested methods to their filenames from the test source, before any
# simulator work. Unknown methods cannot silently reuse copied old baselines.
python3 - "$repo_root/WiltediOSUITests/WiltediOSPixelSnapshotTests.swift" "$tmp_root/expected.json" "$@" <<'PYCASES'
import json, re, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
cases = dict(re.findall(r'func (test\w+)\(\)\s*\{\s*assertSnapshot\([^\n]+named: "([^"]+)"', source))
methods = re.findall(r'func (test\w+)\(\)', source)
if set(methods) != set(cases) or len(set(cases.values())) != len(cases):
    sys.exit("record.failed snapshot method-to-filename mapping is incomplete or duplicated")
requested = list(dict.fromkeys(sys.argv[3:] or cases))
unknown = [method for method in requested if method not in cases]
if not requested or unknown:
    sys.exit("record.failed cases=" + ",".join(unknown or ["no snapshot methods"]))
Path(sys.argv[2]).write_text(json.dumps({method: cases[method] + ".png" for method in requested}))
PYCASES

stale_simulators_swept="$(gate_sweep wilted)"
status "record.simulator.sweep wilted_deleted=${stale_simulators_swept:-0}"

root="$tmp_root/record-root"
mkdir -p "$root/WiltedKit" "$root/Producer" "$root/CloudSync" "$root/Playback"
cp "$repo_root/project.yml" "$root/project.yml"
cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests" \
  "$repo_root/WiltedMacUITests" "$repo_root/WiltediOS" "$repo_root/WiltediOSTests" \
  "$repo_root/WiltediOSIntents" "$repo_root/WiltediOSUITests" \
  "$repo_root/WiltedWatch" "$repo_root/WiltedWatchTests" "$root/"
for package in WiltedKit Producer CloudSync Playback; do
  cp "$repo_root/$package/Package.swift" "$root/$package/Package.swift"
  cp -R "$repo_root/$package/Sources" "$repo_root/$package/Tests" "$root/$package/"
done

# Remove copied PNGs so each requested output must be created in this run.
rm -f "$root/$snapshots"/*.png

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

status "record.start device=iPhone 17 Pro runtime=$runtime methods=${*:-all}"
gate_ui_test_lock --label 'Wilted iOS snapshot recording' --simulator-udid "$udid" \
  env TEST_RUNNER_WILTED_RECORD_SNAPSHOTS=1 python3 "$build_cache" run xcode ios-snapshot-recording -- xcodebuild test \
  -project "$root/Wilted.xcodeproj" \
  -scheme WiltediOS \
  -destination "platform=iOS Simulator,id=$udid" \
  -parallel-testing-enabled NO \
  "${only[@]}" 2>&1 | tee "$tmp_root/record.log" >&2 || {
    python3 - "$tmp_root/expected.json" "$root/$snapshots" "$tmp_root/record.log" <<'PYFAILED'
import json, re, sys
from pathlib import Path
cases = json.loads(Path(sys.argv[1]).read_text())
fresh = Path(sys.argv[2])
lines = Path(sys.argv[3]).read_text(errors="replace").splitlines()
failed = [method for method in cases if any(
    re.search(r"\b" + re.escape(method) + r"\b", line)
    and re.search(r"\b(?:failed|failure)\b|error:", line, re.IGNORECASE)
    for line in lines)]
if not failed:
    failed = [method for method, name in cases.items()
              if (fresh / name).is_symlink() or not (fresh / name).is_file()
              or (fresh / name).stat().st_size == 0]
# A command can fail after all captures exist without a test-specific log entry.
# Report that uncertainty without labelling successful requested cases as failed.
print("record.failed cases=" + ",".join(failed or ["unknown-run-failure"]), file=sys.stderr)
PYFAILED
    status 'record.failure-log last 40 lines follow'
    tail -40 "$tmp_root/record.log" >&2
    exit 1
  }

# Prepare a complete replacement beside the destination (same filesystem),
# preserving unrequested baselines, then exchange the directories atomically.
# A failed capture or preparation never publishes any subset of the PNGs.
python3 - "$root/$snapshots" "$repo_root/$snapshots" "$tmp_root/expected.json" <<'PYPUBLISH'
import ctypes, json, os, shutil, signal, sys, tempfile
from pathlib import Path
fresh, destination = map(Path, sys.argv[1:3])
cases = json.loads(Path(sys.argv[3]).read_text())
failed = [method for method, name in cases.items() if (fresh / name).is_symlink() or not (fresh / name).is_file() or (fresh / name).stat().st_size == 0]
if failed:
    sys.exit("record.failed cases=" + ",".join(failed))
if destination.is_symlink() or not destination.is_dir():
    sys.exit("record.failed baseline directory is missing or symlinked")
def interrupted(signum, _frame):
    raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, interrupted)
replacement = Path(tempfile.mkdtemp(prefix=".wilted-record-ios-", dir=destination.parent))
try:
    shutil.copytree(destination, replacement, dirs_exist_ok=True, symlinks=True)
    for name in cases.values():
        if (replacement / name).is_symlink():
            sys.exit("record.failed baseline is symlinked: " + name)
        shutil.copy2(fresh / name, replacement / name)
    # Darwin RENAME_SWAP replaces the complete directory without a missing-path
    # window. Failure leaves destination untouched; finally removes our staging.
    libc = ctypes.CDLL(None, use_errno=True)
    swap = libc.renamex_np
    swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(os.fsencode(replacement), os.fsencode(destination), 2) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
finally:
    shutil.rmtree(replacement)
print("record.complete baselines=" + str(len(cases)), file=sys.stderr)
PYPUBLISH
status "record.changed=$(cd "$repo_root" && git status --porcelain "$snapshots" | wc -l | tr -d ' ')"
