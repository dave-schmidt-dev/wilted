# shellcheck shell=bash
# Opt-in hosted Watch fixtures; the ordinary nine-leg gate is unchanged.
optin_leg_names+=(watchos-build)
optin_leg_fns+=(leg_watchos_build)
optin_leg_reports+=(count)

leg_watchos_build() {
  local udid result_bundle="$tmp_root/watchos-build.xcresult"
  [[ -f "$integration_root/WiltedWatch/Info.plist" ]] || fail 'missing WiltedWatch sources in the integration root'
  udid="$(create_watch_gate_simulator)" || return $?
  xcode_test_leg watchos-build "$integration_root/WiltedWatchTests" WiltedWatch \
    "platform=watchOS Simulator,id=$udid" WiltedWatchTests || return $?
  assert_result_bundle_tests watchos-build "$result_bundle" || return $?
  export_watch_captures "$result_bundle" || return $?
  printf 'native.watchos.tests scheme=WiltedWatch captures=4 destination=45mm-watch-simulator\n'
}

export_watch_captures() {
  local result_bundle="$1" exported="$tmp_root/watch-attachments" candidate
  candidate="$(git -C "$repo_root" rev-parse HEAD)" || return 1
  run_bounded_native_command xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$exported" || return $?
  python3 - "$exported" "$repo_root/.logs/watch-captures/$candidate" "$candidate" <<'PYCODE'
import json
from pathlib import Path
import shutil
import re
import struct
import sys
import zlib

source, target = map(Path, sys.argv[1:3])
expected = {"watch-now-playing.png", "watch-up-next.png", "watch-speed.png", "watch-sleep.png"}
found = {}
for test in json.loads((source / "manifest.json").read_text()):
    for attachment in test["attachments"]:
        raw_name = attachment["suggestedHumanReadableName"]
        match = re.fullmatch(r"(watch-(?:now-playing|up-next|speed|sleep))(?:_[0-9]+_[0-9A-Fa-f-]{36})?\.png", raw_name)
        if not match: continue
        name = match[1] + ".png"
        if name in found: raise SystemExit("native.watch-captures.error duplicate " + name)
        path = source / attachment["exportedFileName"]
        if path.parent != source or not path.is_file(): raise SystemExit("native.watch-captures.error invalid attachment path")
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n": raise SystemExit("native.watch-captures.error invalid PNG " + name)
        offset, compressed, dimensions, ended = 8, bytearray(), None, False
        while offset < len(data):
            size = struct.unpack(">I", data[offset:offset + 4])[0]
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + size]
            crc = struct.unpack(">I", data[offset + 8 + size:offset + 12 + size])[0]
            if zlib.crc32(kind + payload) & 0xffffffff != crc: raise SystemExit("native.watch-captures.error corrupt PNG " + name)
            if kind == b"IHDR": dimensions = struct.unpack(">II", payload[:8])
            if kind == b"IDAT": compressed.extend(payload)
            offset += size + 12
            if kind == b"IEND":
                ended = size == 0 and offset == len(data)
                break
        if not ended or not dimensions or min(dimensions) <= 0 or len(set(zlib.decompress(compressed))) < 8:
            raise SystemExit("native.watch-captures.error empty PNG " + name)
        found[name] = (path, dimensions)
if set(found) != expected: raise SystemExit("native.watch-captures.error incomplete named set " + str(sorted(found)))
viewport = found["watch-now-playing.png"][1]
if found["watch-up-next.png"][1] != viewport:
    raise SystemExit("native.watch-captures.error mismatched viewport bounds")
if any(dimensions[0] != viewport[0] for _, dimensions in found.values()):
    raise SystemExit("native.watch-captures.error mismatched device width")
for name in ["watch-speed.png", "watch-sleep.png"]:
    if found[name][1][1] <= viewport[1]:
        raise SystemExit("native.watch-captures.error option content is not full height " + name)
# Only publish after the complete set validates. A unique run directory prevents
# overwriting earlier evidence for this same HEAD's uncommitted working tree.
target.mkdir(parents=True, exist_ok=True)
import tempfile
staging = Path(tempfile.mkdtemp(prefix="working-tree-", dir=target))
try:
    for name, (path, _) in found.items(): shutil.copyfile(path, staging / name)
    (staging / "capture-evidence.json").write_text(json.dumps({
        "base_sha": sys.argv[3], "candidate": "uncommitted working-tree bytes",
        "renderer": "ImageRenderer; shared shipping SwiftUI content; fixture WatchSnapshot",
        "capture_scope": "Native ScrollView/List/navigation chrome excluded; no Watch runtime UI acceptance",
        "viewport_pixels": viewport,
        "capture_pixels": {name: dimensions for name, (_, dimensions) in found.items()},
        "capture_modes": {name: "full intrinsic content" if name in {"watch-speed.png", "watch-sleep.png"}
                          else "device viewport" for name in found},
        "captures": sorted(found)
    }, indent=2) + "\n")
except BaseException:
    shutil.rmtree(staging)
    raise
print("native.watch-captures.complete count=4 path=" + str(staging), flush=True)
PYCODE
}
