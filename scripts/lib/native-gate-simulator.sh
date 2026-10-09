#!/usr/bin/env bash
# Persistent simulator lifecycle. Only an exact runtime/type/name match is ours.
# Selection creates without booting; a session holds one runtime lane through
# readiness, tests and shutdown. The cleanup handler exists before the first boot.
create_gate_simulator() {
  local purpose="$1" runtime device_type spec
  spec="$(select_ios_simulator_spec)" || return $?
  read -r runtime device_type <<<"$spec"
  if [[ -z "$runtime" || -z "$device_type" ]]; then
    printf 'native.simulator.error selector returned empty runtime/device type purpose=%s\n' "$purpose" >&2
    return 1
  fi
  bash "$repo_root/scripts/lib/native-gate-simulator.sh" select "$repo_root" "$runtime" "$device_type"
}

select_ios_simulator_spec() {
  require_tool xcrun || return 1
  require_tool python3 || return 1
  local inventory
  inventory="$(env WILTED_WORK_PHASE=simulator-selection python3 "$repo_root/scripts/run-bounded.py" \
    --timeout-seconds "${xcode_build_timeout_seconds:-1800}" -- xcrun simctl list devices available -j)" || return $?
  printf '%s\n' "$inventory" | python3 "$repo_root/scripts/select-ios-simulator.py"
}

create_watch_gate_simulator() {
  require_tool xcrun || return 1
  require_tool python3 || return 1
  local inventory spec runtime device_type
  inventory="$(env WILTED_WORK_PHASE=watch-simulator-selection python3 "$repo_root/scripts/run-bounded.py" \
    --timeout-seconds "${xcode_build_timeout_seconds:-1800}" -- xcrun simctl list runtimes -j)" || return $?
  spec="$(printf '%s\n' "$inventory" | python3 -c '
import json, sys
kind = "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm"
choices = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable")
           and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.watchOS-")
           and any(d["identifier"] == kind for d in r.get("supportedDeviceTypes", []))]
if not choices: sys.exit("native.simulator.error no available runtime supports the 45mm Watch")
runtime = max(choices, key=lambda r: tuple(int(v) for v in r["version"].split(".")))
print(runtime["identifier"], kind)
')" || return $?
  read -r runtime device_type <<<"$spec"
  bash "$repo_root/scripts/lib/native-gate-simulator.sh" select "$repo_root" "$runtime" "$device_type"
}

wilted_gate_simulator_session() {
  local udid="$1"; shift
  exec bash "$repo_root/scripts/lib/native-gate-simulator.sh" run "$repo_root" "$udid" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  exec python3 - "$@" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import tempfile

mode, root, *args = sys.argv[1:]
root = Path(root)
runner = root / 'scripts/run-bounded.py'
child = None
boot_owned = False
udid = None
owned_name = None

def emit(message):
    print('native.simulator.' + message, file=sys.stderr, flush=True)

def inventory():
    return json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j'], 'simulator-inventory', 1800, capture=True))['devices']

def lock(runtime):
    key = hashlib.sha256(runtime.encode()).hexdigest()[:16]
    path = root / '.build/simulator-locks' / (key + '.lock')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    started = time.monotonic()
    heartbeat = -15
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            elapsed = time.monotonic() - started
            if elapsed - heartbeat >= 15:
                emit(f'wait runtime={runtime} waited={elapsed:.0f}s phase=lane')
                heartbeat = elapsed
            time.sleep(.1)

def interrupted(sig, frame):
    raise SystemExit(128 + sig)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, interrupted)

def run(argv, phase, budget=None, capture=False):
    global child
    env = dict(os.environ, WILTED_WORK_PHASE=phase)
    budget_args = ['--timeout-seconds', str(budget)] if budget else ['--no-timeout']
    output = tempfile.TemporaryFile() if capture else None
    child = subprocess.Popen([sys.executable, str(runner), *budget_args, '--', *argv], env=env, stdout=output)
    try:
        result = child.wait()
    finally:
        # Repeated cancellation must not interrupt descendant reaping or the
        # semantic shutdown that follows it. Restore handlers only on success.
        unwinding = sys.exc_info()[0] is not None
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        for sig in handlers: signal.signal(sig, signal.SIG_IGN)
        if child.poll() is None:
            child.terminate()
            # Do not release a simulator lane until descendant cleanup is complete.
            while child.poll() is None:
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    emit(f'cleanup.wait phase={phase}')
        child = None
        if not unwinding:
            for sig, handler in handlers.items(): signal.signal(sig, handler)
    if result:
        if output: output.close()
        raise SystemExit(result if result > 0 else 128 - result)
    if output:
        output.seek(0)
        value = output.read().decode()
        output.close()
        return value

original_status = 0
cleanup_failed = False
try:
    devices = inventory()
    if mode == 'select':
        runtime, device_type = args
        fd = lock(runtime)
        name = 'wilted-persistent-' + runtime.rsplit('.', 1)[-1]
        matches = [d for d in inventory().get(runtime, []) if d.get('name') == name
                   and d.get('deviceTypeIdentifier') == device_type and d.get('isAvailable', True)]
        if len(matches) > 1:
            raise SystemExit('native.simulator.error ambiguous persistent ownership')
        if matches:
            udid = matches[0]['udid']
            emit(f'reuse runtime={runtime} udid={udid}')
        else:
            udid = run(['xcrun', 'simctl', 'create', name, device_type, runtime], 'simulator-create', 1800, capture=True).strip()
            if not re.fullmatch(r'[0-9A-Fa-f-]{36}', udid):
                raise SystemExit('native.simulator.error invalid create identity')
            emit(f'create runtime={runtime} udid={udid}')
        print(udid, flush=True)
    elif mode == 'run':
        udid, *command = args
        matches = [(runtime, d) for runtime, ds in devices.items() for d in ds if d.get('udid') == udid
                   and d.get('name') == 'wilted-persistent-' + runtime.rsplit('.', 1)[-1]
                   and ((runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
                         and d.get('deviceTypeIdentifier') == 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
                        or (runtime.startswith('com.apple.CoreSimulator.SimRuntime.watchOS-')
                            and d.get('deviceTypeIdentifier') == 'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm'))
                   and d.get('isAvailable', True)]
        if len(matches) != 1:
            raise SystemExit('native.simulator.error unowned destination')
        runtime, device = matches[0]
        fd = lock(runtime)
        owned_name = device['name']
        device = next(d for d in inventory()[runtime] if d['udid'] == udid)
        if device['state'] != 'Booted':
            # Register ownership before simctl can boot or wait, including interrupts.
            boot_owned = True
            run(['xcrun', 'simctl', 'boot', udid], 'simulator-boot', 1800)
        run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], 'simulator-readiness', 1800)
        emit(f'ready runtime={runtime} udid={udid} boot_owned={int(boot_owned)}')
        # The shared Apple lane is acquired after readiness, before the cache
        # lock and the actual test timer. Its wrapper owns XCTest clone cleanup.
        os.environ['GATE_PROJECT_OWNED_CLONES_ONLY'] = '1'
        os.environ['GATE_OWNED_SIMULATOR_NAME'] = device['name']
        run(['bash', '-c', 'source "$1"; shift; gate_ui_test_lock --label persistent-tests --simulator-udid "$1" "${@:2}"',
             '_', str(root / 'scripts/lib/simctl_gate_lib.sh'), udid, *command], 'test-queue')
    else:
        raise SystemExit('native.simulator.error unknown mode')
except SystemExit as error:
    original_status = error.code if isinstance(error.code, int) else 1
    if isinstance(error.code, str): emit('error detail=' + error.code)
except Exception as error:
    original_status = 1
    emit('error detail=' + type(error).__name__)
finally:
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP): signal.signal(sig, signal.SIG_IGN)
    try:
        if owned_name:
            # Descendants have finished before this point, and the runtime lock is
            # still held. Reap only clones of our exact persistent device, including
            # ones stranded by an earlier interrupted session of the same lane.
            clone_set = Path(os.environ.get('GATE_XCTEST_DEVICE_SET', str(Path.home() / 'Library/Developer/XCTestDevices')))
            if clone_set.is_dir():
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                signal.signal(signal.SIGINT, signal.SIG_IGN)
                clones = json.loads(run(['xcrun', 'simctl', '--set', str(clone_set), 'list', 'devices', '-j'],
                                        'simulator-clone-inventory', 60, capture=True))
                for clone in clones['devices'].get(runtime, []):
                    if not re.fullmatch(r'Clone [0-9]+ of ' + re.escape(owned_name), clone.get('name', '')):
                        continue
                    data_path = Path(clone.get('dataPath', ''))
                    if not data_path.is_relative_to(clone_set):
                        continue
                    clone_id = clone['udid']
                    if clone.get('state') == 'Booted':
                        run(['xcrun', 'simctl', '--set', str(clone_set), 'shutdown', clone_id], 'simulator-clone-cleanup', 60)
                    elif clone.get('state') != 'Shutdown':
                        raise SystemExit('native.simulator.error owned clone not quiescent')
                    run(['xcrun', 'simctl', '--set', str(clone_set), 'delete', clone_id], 'simulator-clone-cleanup', 60)
    except BaseException as error:
        cleanup_failed = True
        code = error.code if isinstance(error, SystemExit) else type(error).__name__
        emit(f'cleanup.failure phase=clones status={code}')
    try:
        if boot_owned and udid:
            # Never delete the persistent device and never shut down an already booted one.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            emit(f'cleanup udid={udid} action=shutdown')
            run(['xcrun', 'simctl', 'shutdown', udid], 'simulator-cleanup', 60)
    except BaseException as error:
        cleanup_failed = True
        code = error.code if isinstance(error, SystemExit) else type(error).__name__
        emit(f'cleanup.failure phase=persistent status={code}')

# A failed test keeps its cause; cleanup failure is independently visible.
sys.exit(original_status if original_status else (125 if cleanup_failed else 0))
PY
fi
