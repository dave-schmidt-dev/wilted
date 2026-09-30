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
  set -Eeuo pipefail
  local scratch="$1" repo_root="$2" pattern owned_host foreign_host owned_pid foreign_pid
  local owned_matches="" attempt
  pattern="$(wilted_mac_test_host_pattern "$repo_root")"
  owned_host="$(cd -P "$repo_root" && pwd)/.build/xcode/native-cleanup-selftest/WiltedMac.app/Contents/MacOS/WiltedMac"
  foreign_host="$scratch/peer-worktree/.build/xcode/native-cleanup-selftest/WiltedMac.app/Contents/MacOS/WiltedMac"
  /bin/bash -c 'exec -a "$1" /bin/sleep 60' _ "$owned_host" &
  owned_pid=$!
  /bin/bash -c 'exec -a "$1" /bin/sleep 60' _ "$foreign_host" &
  foreign_pid=$!
  trap 'kill "$owned_pid" "$foreign_pid" 2>/dev/null || true; wait "$owned_pid" 2>/dev/null || true; wait "$foreign_pid" 2>/dev/null || true' EXIT
  for attempt in {1..50}; do
    owned_matches="$(pgrep -f "$pattern" 2>/dev/null || true)"
    if printf '%s\n' "$owned_matches" | grep -Fxq -- "$owned_pid"; then break; fi
    sleep 0.1
  done
  printf '%s\n' "$owned_matches" | grep -Fxq -- "$owned_pid"
  wilted_cleanup_mac_test_hosts "$repo_root"
  ! kill -0 "$owned_pid" 2>/dev/null
  kill -0 "$foreign_pid" 2>/dev/null
  printf 'native.cleanup.fixture owned-host-matched=1 foreign-peer-preserved=1\n'
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
    if item.get("key") == "WILTED_TEST_TMPDIR":
        test_env.remove(item)
test_by_key.pop("WILTED_TEST_TMPDIR", None)

# Materialize only missing LaunchAction values before disabling inheritance.
if test_action.get("shouldUseLaunchSchemeArgsEnv") == "YES":
    launch_action = root.find("LaunchAction")
    launch_env = launch_action.find("EnvironmentVariables") if launch_action is not None else None
    if launch_env is not None:
        for item in launch_env.findall("EnvironmentVariable"):
            key = item.get("key")
            if key and key not in test_by_key:
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
