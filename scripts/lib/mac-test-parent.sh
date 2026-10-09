#!/usr/bin/env bash
# Configure generated macOS XCTest schemes without exporting a host-owned
# temporary parent into the sandboxed UI-test runner.
# This file is sourced by native test and snapshot/capture runners.

wilted_mac_test_parent_is_canonical() {
  local parent="$1" canonical
  [[ "$parent" == /* && -d "$parent" && ! -L "$parent" ]] || return 1
  canonical="$(cd -P "$parent" 2>/dev/null && pwd)" || return 1
  [[ "$canonical" == "$parent" && -d "$canonical" && ! -L "$canonical" ]]
}

wilted_mac_test_host_pattern() {
  local repo_root="$1" canonical_root cache_root
  [[ -d "$repo_root" && ! -L "$repo_root" ]] || return 1
  canonical_root="$(cd -P "$repo_root" 2>/dev/null && pwd)" || return 1
  cache_root="$canonical_root/.build/xcode"
  cache_root="$(printf '%s' "$cache_root" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  printf '%s/.*/WiltedMac\\.app/Contents/MacOS/WiltedMac\n' "$cache_root"
}

## Terminates only stale Mac test hosts whose command line names this checkout's
## canonical Xcode cache. A sibling worktree has a different literal prefix.
wilted_cleanup_mac_test_hosts() {
  local repo_root="$1" test_host_pattern test_host_pid killed=0
  local -a alive_pids=()
  test_host_pattern="$(wilted_mac_test_host_pattern "$repo_root")" || {
    printf 'native.error cannot resolve current checkout for Mac test host cleanup\n' >&2
    return 1
  }
  while IFS= read -r test_host_pid; do
    [[ "$test_host_pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$test_host_pid" 2>/dev/null; then
      alive_pids+=("$test_host_pid")
    fi
  done < <(pgrep -f "$test_host_pattern" 2>/dev/null || true)
  [[ "${#alive_pids[@]}" -gt 0 ]] || {
    printf 'native.cleanup mac-test-hosts-matched=0 killed=0\n' >&2
    return 0
  }
  kill "${alive_pids[@]}" 2>/dev/null || true
  sleep 1
  for test_host_pid in "${alive_pids[@]}"; do
    if kill -0 "$test_host_pid" 2>/dev/null; then
      kill -KILL "$test_host_pid" 2>/dev/null || true
    fi
  done
  sleep 1
  for test_host_pid in "${alive_pids[@]}"; do
    if ! kill -0 "$test_host_pid" 2>/dev/null; then
      killed=$((killed + 1))
    fi
  done
  printf 'native.cleanup mac-test-hosts-matched=%s killed=%s\n' "${#alive_pids[@]}" "$killed" >&2
}

## Uses controlled argv0 values for two sleep processes: one names this
## checkout's cache and must be terminated; the other models a peer worktree
## and must remain alive. No application or Xcode process is launched.
wilted_mac_test_host_cleanup_selftest() (
  # A checkout-shaped host is live work: hold the same real product lock as XCTest.
  python3 - "$2" "$1" "${BASH_SOURCE[0]}" <<'PYFIXTURELOCK'
import importlib.util
import os
from pathlib import Path
import sys
root, scratch, helper = sys.argv[1:]
spec = importlib.util.spec_from_file_location('fixture_cache', Path(root) / 'scripts/build-with-cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
key = 'native-macos-ui-tests'
_, lock = cache.cache_paths(Path(root).resolve(), 'xcode', key)
cache.acquire_lock(lock, 'xcode', key)
print(f'native.cleanup.fixture product-lock-held={key}', file=sys.stderr, flush=True)
os.execv('/bin/bash', ['/bin/bash', '-c',
    'source "$1"; wilted_mac_test_host_cleanup_fixture "$2" "$3"', '_', helper, scratch, root])
PYFIXTURELOCK
)

wilted_mac_test_host_cleanup_fixture() (
  set -Eeuo pipefail
  local scratch="$1" repo_root="$2" pattern owned_repo owned_host foreign_host protected_host
  local owned_pid foreign_pid protected_pid owned_matches="" attempt
  mkdir -p "$scratch/mac-cleanup-owned-worktree"
  owned_repo="$(cd -P "$scratch/mac-cleanup-owned-worktree" && pwd)"
  pattern="$(wilted_mac_test_host_pattern "$owned_repo")"
  owned_host="$owned_repo/.build/xcode/native-cleanup-selftest/WiltedMac.app/Contents/MacOS/WiltedMac"
  foreign_host="$scratch/peer-worktree/.build/xcode/native-cleanup-selftest/WiltedMac.app/Contents/MacOS/WiltedMac"
  protected_host="$(cd -P "$repo_root" && pwd)/.build/xcode/native-macos-ui-tests/WiltedMac.app/Contents/MacOS/WiltedMac"
  /bin/bash -c 'exec -a "$1" /bin/sleep 60' _ "$owned_host" &
  owned_pid=$!
  /bin/bash -c 'exec -a "$1" /bin/sleep 60' _ "$foreign_host" &
  foreign_pid=$!
  /bin/bash -c 'exec -a "$1" /bin/sleep 60' _ "$protected_host" &
  protected_pid=$!
  # Bash 3.2 unwinds these locals before the subshell EXIT trap runs.
  trap "kill $owned_pid $foreign_pid $protected_pid 2>/dev/null || true; wait $owned_pid 2>/dev/null || true; wait $foreign_pid 2>/dev/null || true; wait $protected_pid 2>/dev/null || true" EXIT
  for attempt in {1..50}; do
    owned_matches="$(pgrep -f "$pattern" 2>/dev/null || true)"
    if printf '%s\n' "$owned_matches" | grep -Fxq -- "$owned_pid"; then break; fi
    sleep 0.1
  done
  printf '%s\n' "$owned_matches" | grep -Fxq -- "$owned_pid"
  wilted_cleanup_mac_test_hosts "$owned_repo"
  ! kill -0 "$owned_pid" 2>/dev/null
  kill -0 "$foreign_pid" 2>/dev/null
  kill -0 "$protected_pid" 2>/dev/null
  printf 'native.cleanup.fixture owned-host-matched=1 foreign-peer-preserved=1 live-checkout-shaped-preserved=1\n'
)

wilted_mac_test_scheme_configure() {
  local scheme="$1" parent="$2"
  shift 2
  [[ -f "$scheme" && ! -L "$scheme" ]] || {
    printf 'mac-test-parent.error scheme is missing or unsafe: %s\n' "$scheme" >&2
    return 1
  }
  wilted_mac_test_parent_is_canonical "$parent" || {
    printf 'mac-test-parent.error parent must be an existing canonical non-symlink directory: %s\n' "$parent" >&2
    return 1
  }

  python3 - "$scheme" "$parent" "$@" <<'PY'
import copy
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

scheme, parent, *assignments = sys.argv[1:]
if not os.path.isabs(parent) or os.path.realpath(parent) != parent or not os.path.isdir(parent) or os.path.islink(parent):
    raise SystemExit("mac-test-parent.error invalid canonical parent")

updates = {}
for assignment in assignments:
    key, separator, value = assignment.partition("=")
    if not separator or not key or not key.replace("_", "a").isalnum() or key[0].isdigit():
        raise SystemExit(f"mac-test-parent.error invalid TestAction environment assignment: {assignment!r}")
    updates[key] = value

proof_keys = {"WILTED_TEST_OWNER_PID", "WILTED_TEST_OWNER_STARTED", "WILTED_TEST_OWNER_PATH"}
bundle_keys = proof_keys | {"WILTED_TEST_TMPDIR"}
if proof_keys.intersection(updates):
    raise SystemExit("mac-test-parent.error owner proof is generated only by the launcher")
if "WILTED_TEST_TMPDIR" in updates:
    if updates["WILTED_TEST_TMPDIR"] != parent:
        raise SystemExit("mac-test-parent.error delivered parent differs from canonical parent")
    marker_parent = next((p for p in [Path(parent), *Path(parent).parents]
                          if os.path.lexists(p / ".wilted-temp-owned")), None)
    if marker_parent is not None:
        marker = marker_parent / ".wilted-temp-owned"
        if marker.is_symlink() or not marker.is_file():
            raise SystemExit("mac-test-parent.error unsafe controlling marker")
        fields = {}
        for line in marker.read_text().splitlines():
            key, separator, value = line.partition("=")
            if not separator or key in fields:
                raise SystemExit("mac-test-parent.error malformed controlling marker")
            fields[key] = value.strip()
        if set(fields) != {"pid", "started", "path"} or fields["path"] != str(marker_parent) or not fields["pid"].isdigit() or int(fields["pid"]) <= 0:
            raise SystemExit("mac-test-parent.error invalid controlling owner")
        def probe(pid, field):
            value = subprocess.run(["/bin/ps", "-o", field + "=", "-p", str(pid)], text=True, capture_output=True)
            if value.returncode or value.stderr or not value.stdout.strip():
                raise SystemExit("mac-test-parent.error controlling identity uninspectable")
            return value.stdout.strip()
        owner_pid = int(fields["pid"])
        if probe(owner_pid, "lstart") != fields["started"]:
            raise SystemExit("mac-test-parent.error stale controlling owner")
        current = os.getppid()
        for _ in range(128):
            if current == owner_pid: break
            if current <= 1:
                raise SystemExit("mac-test-parent.error foreign live controlling owner")
            current = int(probe(current, "ppid"))
        else:
            raise SystemExit("mac-test-parent.error controlling ancestry exceeded")
        updates.update(WILTED_TEST_OWNER_PID=fields["pid"],
                       WILTED_TEST_OWNER_STARTED=fields["started"], WILTED_TEST_OWNER_PATH=fields["path"])

tree = ET.parse(scheme)
root = tree.getroot()
test_action = root.find("TestAction")
if test_action is None:
    raise SystemExit("mac-test-parent.error generated scheme has no TestAction")

def env_section(action):
    section = action.find("EnvironmentVariables")
    if section is None:
        section = ET.SubElement(action, "EnvironmentVariables")
    return section

test_env = env_section(test_action)
test_by_key = {}
for item in list(test_env):
    key = item.get("key")
    if key:
        test_by_key.setdefault(key, item)

# Older generated schemes injected a host-owned path that the UI-test sandbox
# cannot write. Remove it even when this helper reconfigures an existing scheme.
for item in list(test_env):
    if item.get("key") in bundle_keys:
        test_env.remove(item)
for key in bundle_keys:
    test_by_key.pop(key, None)
# Reserved ownership fields never survive LaunchAction inheritance or a
# managed-to-standalone/UI reconfiguration.
launch_action = root.find("LaunchAction")
launch_env = launch_action.find("EnvironmentVariables") if launch_action is not None else None
if launch_env is not None:
    for item in list(launch_env):
        if item.get("key") in bundle_keys:
            launch_env.remove(item)

# Materialize only missing LaunchAction values before disabling inheritance.
if test_action.get("shouldUseLaunchSchemeArgsEnv") == "YES":
    launch_action = root.find("LaunchAction")
    launch_env = launch_action.find("EnvironmentVariables") if launch_action is not None else None
    if launch_env is not None:
        for item in launch_env.findall("EnvironmentVariable"):
            key = item.get("key")
            if key and key not in bundle_keys and key not in test_by_key:
                clone = copy.deepcopy(item)
                test_env.append(clone)
                test_by_key[key] = clone

test_action.set("shouldUseLaunchSchemeArgsEnv", "NO")
for key, value in updates.items():
    item = test_by_key.get(key)
    if item is None:
        item = ET.SubElement(test_env, "EnvironmentVariable")
        test_by_key[key] = item
    item.set("key", key)
    item.set("value", value)
    item.set("isEnabled", "YES")
    seen = False
    for candidate in list(test_env):
        if candidate.get("key") == key:
            if not seen:
                seen = True
            else:
                test_env.remove(candidate)

tree.write(scheme, encoding="UTF-8", xml_declaration=True)
print(f"mac-test-parent.scheme configured parent={parent}")
PY
}

# Fast regression proof used by tests/test-native-gate.sh. It uses fake scheme
# XML and the gate's self-test command path; it never starts Xcode or a UI host.
wilted_mac_test_parent_selftest() {
  local scratch="$1" gate="$2" parent
  parent="$(cd -P "$scratch" && pwd)/mac-test-owned-parent"
  local scheme="$scratch/mac-test-inherited.xcscheme"
  mkdir -p "$parent"
  cat >"$scheme" <<'XML'
<Scheme><LaunchAction shouldUseLaunchSchemeArgsEnv="YES"><EnvironmentVariables>
<EnvironmentVariable key="LAUNCH_ONLY" value="launch" isEnabled="YES" />
<EnvironmentVariable key="COLLISION" value="launch-value" isEnabled="YES" />
</EnvironmentVariables></LaunchAction><TestAction shouldUseLaunchSchemeArgsEnv="YES"><EnvironmentVariables>
<EnvironmentVariable key="TEST_ONLY" value="test" isEnabled="YES" />
<EnvironmentVariable key="COLLISION" value="test-value" isEnabled="YES" />
<EnvironmentVariable key="WILTED_TEST_TMPDIR" value="/host-owned/path" isEnabled="YES" />
</EnvironmentVariables></TestAction></Scheme>
XML
  wilted_mac_test_scheme_configure "$scheme" "$parent" WILTED_CAPTURE=1
  python3 - "$scheme" "$parent" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
action = root.find("TestAction")
assert action.get("shouldUseLaunchSchemeArgsEnv") == "NO"
values = {x.get("key"): x.get("value") for x in action.find("EnvironmentVariables")}
assert values == {"LAUNCH_ONLY": "launch", "COLLISION": "test-value", "TEST_ONLY": "test",
                  "WILTED_CAPTURE": "1"}
assert "WILTED_TEST_TMPDIR" not in values
PY
  # The unit-test leg passes its parent explicitly (Foundation on macOS 27
  # ignores TMPDIR); a stale host-owned value must be replaced, never duplicated.
  wilted_mac_test_scheme_configure "$scheme" "$parent" WILTED_TEST_TMPDIR="$parent"
  python3 - "$scheme" "$parent" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
items = root.find("TestAction").find("EnvironmentVariables").findall("EnvironmentVariable")
delivered = [x.get("value") for x in items if x.get("key") == "WILTED_TEST_TMPDIR"]
assert delivered == [sys.argv[2]], delivered
PY
  local invalid="$scratch/mac-test-invalid.xcscheme" before
  printf '%s\n' '<Scheme><LaunchAction /></Scheme>' >"$invalid"
  before="$(shasum -a 256 "$invalid" | cut -d ' ' -f 1)"
  wilted_mac_test_scheme_configure "$invalid" "$parent" >/dev/null 2>&1 && return 1
  [[ "$(shasum -a 256 "$invalid" | cut -d ' ' -f 1)" == "$before" ]] || return 1
  ln -s "$parent" "$scratch/mac-test-parent-link"
  wilted_mac_test_scheme_configure "$scheme" "$scratch/mac-test-parent-link" >/dev/null 2>&1 && return 1

  local lock="$scratch/mac-ui-lock" failed="$scratch/mac-failure.sh" interrupted="$scratch/mac-interrupt.sh"
  local failed_parent="$scratch/mac-failed-parent" interrupted_parent="$scratch/mac-interrupted-parent"
  local proof="$scratch/mac-interrupt-parent" failed_log="$scratch/mac-failure.log"
  local interrupted_log="$scratch/mac-interrupt.log" status=0
  cat >"$lock" <<'SH'
#!/usr/bin/env bash
while [[ "$#" -gt 0 && "$1" != "--" ]]; do shift; done
[[ "$#" -eq 0 ]] || shift
exec "$@"
SH
  printf '%s\n' '#!/usr/bin/env bash' 'mkdir "$TMPDIR/wilted-ui-test-failed"' 'exit 17' >"$failed"
  printf '%s\n' '#!/usr/bin/env bash' 'mkdir "$TMPDIR/wilted-ui-test-interrupted"' \
    'printf "%s\n" "$TMPDIR" >"$WILTED_PARENT_PROOF"' 'sleep 60' >"$interrupted"
  chmod +x "$lock" "$failed" "$interrupted"
  mkdir -p "$failed_parent" "$interrupted_parent"
  failed_parent="$(cd -P "$failed_parent" && pwd)"
  interrupted_parent="$(cd -P "$interrupted_parent" && pwd)"
  env TMPDIR="$failed_parent" WILTED_NATIVE_TEMP_AUDIT_PARENT="$scratch/failure-audit" \
    WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$scratch/failure-diag" WILTED_BOUNDED_ENTRY=1 \
    NATIVE_SELF_TEST=1 WILTED_MAC_UI=1 NATIVE_INTERRUPT_UI_TEST=1 NATIVE_INTERRUPT_TEST_COMMAND="$failed" \
    NATIVE_INTERRUPT_UI_LOCK_PID_FILE="$scratch/failure-lock.pid" APPLE_UI_TEST_LOCK="$lock" \
    GATE_XCTEST_DEVICE_SET="$scratch/no-devices" bash "$gate" >"$failed_log" 2>&1 || status=$?
  [[ "$status" -eq 1 && -z "$(find "$failed_parent" -mindepth 1 -maxdepth 1 -name 'wilted-native-gate.*' -print -quit)" ]] || {
    cat "$failed_log" >&2; return 1;
  }
  env TMPDIR="$interrupted_parent" WILTED_NATIVE_TEMP_AUDIT_PARENT="$scratch/interrupt-audit" \
    WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$scratch/interrupt-diag" WILTED_BOUNDED_ENTRY=1 \
    NATIVE_SELF_TEST=1 WILTED_MAC_UI=1 NATIVE_INTERRUPT_UI_TEST=1 NATIVE_INTERRUPT_TEST_COMMAND="$interrupted" \
    WILTED_PARENT_PROOF="$proof" NATIVE_INTERRUPT_UI_LOCK_PID_FILE="$scratch/interrupt-lock.pid" \
    APPLE_UI_TEST_LOCK="$lock" GATE_XCTEST_DEVICE_SET="$scratch/no-devices" \
    bash "$gate" >"$interrupted_log" 2>&1 &
  local pid=$! attempt fixture
  for attempt in {1..100}; do
    [[ -s "$proof" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if [[ ! -s "$proof" ]]; then
    kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    cat "$interrupted_log" >&2; return 1
  fi
  fixture="$(<"$proof")"
  case "$fixture" in
    "$interrupted_parent"/wilted-native-gate.*/legs/interrupt-fixture/work) ;;
    *) kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1 ;;
  esac
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  [[ "$status" -eq 143 && -z "$(find "$interrupted_parent" -mindepth 1 -maxdepth 1 -name 'wilted-native-gate.*' -print -quit)" ]] || {
    cat "$interrupted_log" >&2; return 1;
  }
}

# The bounded supervisor must be terminal first. Remove only host-created,
# identity-bound roots; unknown work remains visible to the following leak audit.
wilted_mac_test_cleanup_roots() {
  python3 - "$1" <<'PY'
import json, os, shutil, stat, subprocess, sys
from pathlib import Path

def refuse(message):
    raise RuntimeError(message)
def canonical(path):
    path=Path(path)
    if not path.is_absolute() or path.is_symlink() or path.resolve()!=path or not path.is_dir():
        refuse('noncanonical root')
    return path
def probe(pid, field):
    return subprocess.run(['/bin/ps','-o',field+'=','-p',str(pid)],text=True,capture_output=True)
def read_owner(path):
    marker=path/'.wilted-temp-owned'
    if marker.is_symlink() or not marker.is_file(): refuse('unsafe owner marker')
    fields={}
    for line in marker.read_text().splitlines():
        key,separator,value=line.partition('=')
        if not separator or key in fields: refuse('malformed owner marker')
        fields[key]=value.strip()
    if set(fields)!= {'pid','started','path'} or fields['path']!=str(path): refuse('foreign owner path')
    pid=int(fields['pid'])
    if pid<=0: refuse('invalid owner pid')
    result=probe(pid,'lstart')
    if result.returncode or result.stderr or result.stdout.strip()!=fields['started']: refuse('owner identity not live')
    # The controlling runner is this cleanup caller or an actual ancestor;
    # an unrelated live process cannot authorize removal merely by its PID.
    current=os.getppid()
    for _ in range(128):
        if current==pid: return fields
        result=probe(current,'ppid')
        if result.returncode or result.stderr or not result.stdout.strip(): break
        current=int(result.stdout.strip())
        if current<=1: break
    refuse('foreign live controlling owner')

try:
    parent=canonical(sys.argv[1]); removed=0
    owner_path=next((p for p in [parent,*parent.parents] if (p/'.wilted-temp-owned').exists() or (p/'.wilted-temp-owned').is_symlink()),None)
    if owner_path is None: refuse('managed cleanup has no runner owner')
    owner_path=canonical(owner_path); owner=read_owner(owner_path)
    candidates=[]
    for root in parent.iterdir():
        if not root.name.startswith(('wilted-mac-test-','wilted-test-host-')): continue
        canonical(root)
        marker=root/'.wilted-managed-test-root'
        if marker.is_symlink() or not marker.is_file(): refuse(f'missing or unsafe root receipt: {root}')
        receipt=json.loads(marker.read_text())
        if set(receipt)!= {'path','device','inode','host_pid','host_started','owner_path','owner_pid','owner_started'}: refuse('malformed root receipt')
        if not isinstance(receipt['host_started'],str) or not receipt['host_started'].strip(): refuse('invalid host start identity')
        for field in ['device','inode','host_pid','owner_pid']:
            if type(receipt[field]) is not int or receipt[field]<=0: refuse('invalid receipt number')
        if receipt['path']!=str(root) or receipt['owner_path']!=str(owner_path) or receipt['owner_pid']!=int(owner['pid']) or receipt['owner_started']!=owner['started']: refuse('foreign root receipt')
        identity=root.stat()
        if (identity.st_dev,identity.st_ino)!=(receipt['device'],receipt['inode']): refuse('replaced root')
        result=probe(receipt['host_pid'],'stat')
        if not (result.returncode==1 and not result.stdout and not result.stderr):
            # A reaped/zombie process has no descriptors; all other live or
            # ambiguous process states, including PID reuse, fail closed.
            if result.returncode or result.stderr or not result.stdout.strip().startswith('Z'): refuse('creating host is live or uninspectable')
        live=subprocess.run(['/usr/sbin/lsof','-t','+D',str(root)],text=True,capture_output=True)
        if live.returncode!=1 or live.stdout or live.stderr: refuse('root still open or descriptor inspection failed')
        candidates.append((root,identity.st_dev,identity.st_ino,marker.read_bytes()))
    # Validate every candidate before deleting any, then recheck identity and
    # marker immediately before each exact-root unlink.
    for root,device,inode,marker_bytes in candidates:
        identity=root.lstat()
        if not stat.S_ISDIR(identity.st_mode) or (identity.st_dev,identity.st_ino)!=(device,inode) or (root/'.wilted-managed-test-root').is_symlink() or (root/'.wilted-managed-test-root').read_bytes()!=marker_bytes: refuse('root changed during cleanup')
        shutil.rmtree(root); removed+=1
    print(f'mac-test-parent.cleanup terminal-owned-roots={removed} unknown-work-preserved=true')
except (OSError,ValueError,TypeError,RuntimeError,KeyError) as error:
    print(f'mac-test-parent.cleanup.error {error}',file=sys.stderr)
    raise SystemExit(1)
PY
}
