#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/wilted-sim-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

cat >"$bin/xcrun" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:3] == ["simctl", "list", "devices"]:
    print(open(os.environ["FAKE_STATE"], encoding="utf-8").read())
    raise SystemExit
state_path = os.environ["FAKE_STATE"]
events_path = os.environ["FAKE_EVENTS"]
state = json.load(open(state_path, encoding="utf-8"))
devices = state["devices"]
op = args[1]
if op == "create":
    name, device_type, runtime = args[2:5]
    udid = os.environ["FAKE_UDID"]
    devices.setdefault(runtime, []).append({"udid":udid,"name":name,"state":"Shutdown","isAvailable":True,"deviceTypeIdentifier":device_type,"dataPath":f"/fake/{udid}/data"})
    print(udid)
else:
    udid = args[2]
    if op in ("boot", "shutdown", "delete"):
        for runtime, items in list(devices.items()):
            for device in list(items):
                if device["udid"] == udid:
                    if op == "delete": items.remove(device)
                    else: device["state"] = "Booted" if op == "boot" else "Shutdown"
            if not items: del devices[runtime]
with open(state_path, "w", encoding="utf-8") as output: json.dump(state, output)
with open(events_path, "a", encoding="utf-8") as output: output.write(f"{op} {locals().get('udid','')}\n")
PY
cat >"$bin/apple-ui-test-lock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  case "$1" in
    --if-available) shift ;;
    --label|--simulator-udid) shift 2 ;;
    --) shift; break ;;
    *) exit 2 ;;
  esac
done
exec "$@"
SH
cat >"$bin/xcodegen" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
project=""
while (($#)); do
  if [[ "$1" == "-project" ]]; then project="$2"; shift 2; else shift; fi
done
root="${project%/Wilted.xcodeproj}"
snapshot_dir="$root/WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests"
mkdir -p "$snapshot_dir"
printf '%s' fake-png >"$snapshot_dir/recorder-probe.png"
SH
chmod +x "$bin/xcrun" "$bin/apple-ui-test-lock" "$bin/xcodegen" "$bin/xcodebuild"

python3 - "$tmp/selector.json" "$$" <<'PY'
import json, sys
path, pid = sys.argv[1:]
def device(uid, name, state="Shutdown"):
    return {"udid":uid,"name":name,"state":state,"isAvailable":True,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","dataPath":"/fake/data"}
payload={"devices":{
 "com.apple.CoreSimulator.SimRuntime.iOS-26-3":[device("263","iPhone 17 Pro"),device("own","wilted-gate-"+pid+"-live"),device("stale","wilted-gate-99999999-old"),device("boot","wilted-gate-99999998-booted","Booted"),device("other","otherproject-gate-99999997-old"),device("stock","iPhone 17 Pro","Booted")],
 "com.apple.CoreSimulator.SimRuntime.iOS-26-4":[device("264","iPhone 17 Pro")],
 "com.apple.CoreSimulator.SimRuntime.iOS-26-5":[device("265","iPhone 17 Pro")],
 "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[device("270","iPhone 17 Pro")]}}
json.dump(payload,open(path,"w"))
PY
selection="$(python3 "$repo_root/scripts/select-ios-simulator.py" <"$tmp/selector.json")"
[[ "$selection" == $'com.apple.CoreSimulator.SimRuntime.iOS-26-5\tcom.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro' ]]

cat >"$tmp/runner.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo caller-exit >>"$FAKE_EVENTS"' EXIT
source "$HELPER"
gate_sweep wilted >/dev/null
udid="$(gate_sim_create wilted fake "$FAKE_DEVICE_TYPE" "$FAKE_RUNTIME")"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
set +e
gate_ui_test_lock --label fake --simulator-udid "$udid" bash -c 'exit "$1"' _ "$FAKE_STATUS"
rc=$?
set -e
exit "$rc"
SH
chmod +x "$tmp/runner.sh"

run_case() {
  local label="$1" status="$2" udid="$3" state events result
  state="$tmp/$label.json"
  events="$tmp/$label.events"
  cp "$tmp/selector.json" "$state"
  : >"$events"
  if FAKE_STATE="$state" FAKE_EVENTS="$events" FAKE_UDID="$udid" FAKE_STATUS="$status" \
    FAKE_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
    FAKE_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-5 HELPER="$repo_root/scripts/lib/simctl_gate_lib.sh" \
    APPLE_UI_TEST_LOCK="$bin/apple-ui-test-lock" GATE_XCTEST_DEVICE_SET="$tmp/no-clones" \
    PATH="$bin:$PATH" "$tmp/runner.sh"; then
    [[ "$status" == 0 ]]
  else
    result=$?
    [[ "$status" != 0 && "$result" == "$status" ]]
  fi
  python3 - "$state" "$udid" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); ids={d["udid"] for group in p["devices"].values() for d in group}
assert "stale" not in ids and sys.argv[2] not in ids
assert {"own","boot","other","stock"} <= ids
PY
  grep -Fq "boot $udid" "$events"
  grep -Fq "shutdown $udid" "$events"
  grep -Fq "delete $udid" "$events"
}
run_case pass 0 10000000-0000-0000-0000-000000000001
run_case fail 23 20000000-0000-0000-0000-000000000002

# Run the real recorder in a copied fixture project with fake Xcode and simctl.
recorder_repo="$tmp/recorder-repo"
mkdir -p "$recorder_repo/scripts/lib" "$recorder_repo/WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests"
for directory in Shared WiltedMac WiltedMacTests WiltedMacUITests WiltediOS WiltediOSTests; do
  mkdir -p "$recorder_repo/$directory"
done
for package in WiltedKit Producer CloudSync Listener; do
  mkdir -p "$recorder_repo/$package/Sources" "$recorder_repo/$package/Tests"
  : >"$recorder_repo/$package/Package.swift"
done
: >"$recorder_repo/project.yml"
git -C "$recorder_repo" init -q
cp "$repo_root/scripts/record-ios-snapshots.sh" "$recorder_repo/scripts/record-ios-snapshots.sh"
cp "$repo_root/scripts/select-ios-simulator.py" "$recorder_repo/scripts/select-ios-simulator.py"
cp "$repo_root/scripts/lib/simctl_gate_lib.sh" "$recorder_repo/scripts/lib/simctl_gate_lib.sh"
recorder_state="$tmp/recorder.json"
recorder_events="$tmp/recorder.events"
cp "$tmp/selector.json" "$recorder_state"
: >"$recorder_events"
FAKE_STATE="$recorder_state" FAKE_EVENTS="$recorder_events" \
  FAKE_UDID=30000000-0000-0000-0000-000000000003 \
  APPLE_UI_TEST_LOCK="$bin/apple-ui-test-lock" GATE_XCTEST_DEVICE_SET="$tmp/no-recorder-clones" \
  PATH="$bin:$PATH" "$recorder_repo/scripts/record-ios-snapshots.sh" >"$tmp/recorder.log" 2>&1 || {
    cat "$tmp/recorder.log" >&2
    exit 1
  }
python3 - "$recorder_state" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); ids={d["udid"] for group in p["devices"].values() for d in group}
assert "stale" not in ids and "30000000-0000-0000-0000-000000000003" not in ids
assert {"own","boot","other","stock"} <= ids
PY
[[ -s "$recorder_repo/WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests/recorder-probe.png" ]]
grep -Fq 'create 30000000-0000-0000-0000-000000000003' "$recorder_events"
grep -Fq 'boot 30000000-0000-0000-0000-000000000003' "$recorder_events"
grep -Fq 'shutdown 30000000-0000-0000-0000-000000000003' "$recorder_events"
grep -Fq 'delete 30000000-0000-0000-0000-000000000003' "$recorder_events"
printf '%s\n' 'iOS 26.x selection and simulator cleanup tests passed'
