#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-bounded-entry.XXXXXX")"
native_owned_pids=""
cleanup_native_fixture() {
  local pid
  for pid in $native_owned_pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in $native_owned_pids; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp_root"
}
trap cleanup_native_fixture EXIT INT TERM HUP
fixture="$tmp_root/repo"
mkdir -p "$fixture/scripts/lib"
cp "$repo_root/scripts/run-bounded.py" "$fixture/scripts/run-bounded.py"
cp "$repo_root/scripts/lib/test-runner.sh" "$fixture/scripts/lib/test-runner.sh"

cat >"$fixture/scripts/test-gate.sh" <<'GATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
printf '%s\n' "${WILTED_BOUNDED_ENTRY:-absent}" >"${WILTED_ENTRY_PROOF:?}"
GATE
chmod +x "$fixture/scripts/test-gate.sh"

proof="$tmp_root/entry-proof"
env -u WILTED_BOUNDED_ENTRY WILTED_ENTRY_PROOF="$proof" \
  WILTED_TEST_RUNNER_TIMEOUT_SECONDS=5 bash "$fixture/scripts/test-gate.sh"
[[ "$(<"$proof")" == "1" ]] || {
  printf '%s\n' 'bounded entry fixture did not run beneath the helper' >&2
  exit 1
}

python3 "$repo_root/tests/test_runtime_make_runner.py"

native_fixture="$tmp_root/native-interrupt-fixture.sh"
native_proof="$tmp_root/native-interrupt-proof"
native_bin="$tmp_root/native-bin"
native_parent="$tmp_root/native-interrupt-parent"
native_audit_parent="$tmp_root/native-interrupt-audit"
mkdir -p "$native_bin" "$native_parent" "$native_audit_parent"
cat >"$native_fixture" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
proof_dir="${WILTED_INTERRUPT_PROOF_DIR:?}"
mkdir -p "$proof_dir"
(
  trap 'exit 0' INT TERM HUP
  while :; do sleep 1; done
) &
grandchild_pid=$!
printf '%s\n' "$$" >"$proof_dir/child.pid"
printf '%s\n' "$grandchild_pid" >"$proof_dir/grandchild.pid"
trap 'kill -TERM "$grandchild_pid" 2>/dev/null || true; wait "$grandchild_pid" 2>/dev/null || true; exit 0' INT TERM HUP
wait "$grandchild_pid"
FIXTURE
chmod +x "$native_fixture"
cat >"$native_bin/swift" <<'FAKE_SWIFT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' 'Swift version fixture'
  exit 0
fi
[[ "${1:-}" == "run" ]] || exit 2
shift
if [[ "${1:-}" == "--scratch-path" ]]; then
  shift 2
fi
exec bash "$1"
FAKE_SWIFT
chmod +x "$native_bin/swift"

wait_for_native_file() {
  local file="$1" timeout_seconds="${2:-5}" attempt attempts
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
    printf 'native interruption fixture timeout must be a positive integer, got %s\n' "$timeout_seconds" >&2
    return 2
  }
  attempts=$((timeout_seconds * 10))
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    [[ -s "$file" ]] && return 0
    sleep 0.1
  done
  printf 'native interruption fixture timed out after %ss waiting for %s\n' "$timeout_seconds" "$file" >&2
  return 1
}

assert_native_stopped() {
  local pid="$1" label="$2" attempt
  for attempt in $(seq 1 30); do
    ! kill -0 "$pid" 2>/dev/null && return 0
    sleep 0.1
  done
  printf 'native interruption fixture left %s pid=%s alive\n' "$label" "$pid" >&2
  ps -p "$pid" -o pid=,ppid=,state=,command= >&2 || true
  return 1
}

# Model a proof file published after the old 50-poll window without adding
# wall-clock delay to this regression suite. The production fixture below uses
# a separate bounded 20-second readiness allowance for aggregate contention.
native_fixture_readiness_timeout_seconds=20
readiness_delay_bin="$tmp_root/readiness-delay-bin"
readiness_delay_count="$tmp_root/readiness-delay.count"
readiness_delay_proof="$tmp_root/readiness-delayed.pid"
mkdir -p "$readiness_delay_bin"
cat >"$readiness_delay_bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -s "$READINESS_DELAY_COUNT" ]] || count="$(<"$READINESS_DELAY_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$READINESS_DELAY_COUNT"
if [[ "$count" -eq 52 ]]; then
  printf '%s\n' 4242 >"$READINESS_DELAY_PROOF"
fi
SLEEP
chmod +x "$readiness_delay_bin/sleep"
PATH="$readiness_delay_bin:$PATH" READINESS_DELAY_COUNT="$readiness_delay_count" \
  READINESS_DELAY_PROOF="$readiness_delay_proof" \
  wait_for_native_file "$readiness_delay_proof" "$native_fixture_readiness_timeout_seconds"
[[ "$(<"$readiness_delay_count")" -eq 52 ]] || {
  printf '%s\n' 'native fixture readiness allowance did not tolerate delayed publication beyond 50 polls' >&2
  exit 1
}

sleep 60 &
native_peer_pid=$!
native_owned_pids="$native_peer_pid"
env WILTED_BOUNDED_ENTRY=1 NATIVE_SELF_TEST=1 \
  PATH="$native_bin:$PATH" NATIVE_INTERRUPT_TEST_COMMAND="$native_fixture" WILTED_INTERRUPT_PROOF_DIR="$native_proof" \
  TMPDIR="$native_parent" WILTED_NATIVE_TEMP_AUDIT_PARENT="$native_audit_parent" \
  bash "$repo_root/scripts/test-gate.sh" >"$tmp_root/native-interrupt.log" 2>&1 &
native_gate_pid=$!
native_owned_pids="$native_owned_pids $native_gate_pid"
wait_for_native_file "$native_proof/grandchild.pid" "$native_fixture_readiness_timeout_seconds" || {
  cat "$tmp_root/native-interrupt.log" >&2
  exit 1
}
native_child_pid="$(<"$native_proof/child.pid")"
native_grandchild_pid="$(<"$native_proof/grandchild.pid")"
kill -TERM "$native_gate_pid"
set +e
wait "$native_gate_pid"
native_result=$?
set -e
[[ "$native_result" -eq 143 ]] || {
  printf 'native interruption fixture expected inner gate exit 143, got %s\n' "$native_result" >&2
  cat "$tmp_root/native-interrupt.log" >&2
  exit 1
}
assert_native_stopped "$native_child_pid" child
assert_native_stopped "$native_grandchild_pid" descendant
native_leftover="$(find "$native_parent" -maxdepth 1 -name 'wilted-native-gate.*' -print -quit)"
[[ -z "$native_leftover" ]] || {
  printf 'native interruption fixture left owned root %s\n' "$native_leftover" >&2
  exit 1
}
kill -0 "$native_peer_pid" 2>/dev/null || {
  printf '%s\n' 'native interruption fixture killed unrelated peer' >&2
  exit 1
}
kill -TERM "$native_peer_pid" 2>/dev/null || true
wait "$native_peer_pid" 2>/dev/null || true
native_owned_pids=""
printf 'native inner interrupt fixture passed child=%s descendant=%s\n' \
  "$native_child_pid" "$native_grandchild_pid"

ui_bin="$tmp_root/ui-bin"
ui_set_root="$tmp_root/ui-set"
ui_state="$tmp_root/ui-state.json"
ui_events="$tmp_root/ui-events.log"
ui_lock_pid_file="$tmp_root/ui-lock.pid"
ui_lock_helper_pid_proof="$tmp_root/ui-lock-helper.pid"
ui_lock_publication_proof="$tmp_root/ui-lock-published.pid"
ui_bash_env="$tmp_root/ui-bash-env"
ui_proof="$tmp_root/native-proof-ui"
mkdir -p "$ui_bin" "$ui_set_root/clone/data"
printf '%s\n' '{"devices":{}}' >"$ui_state"
: >"$ui_events"
cat >"$ui_bash_env" <<'BASH_ENV'
printf() {
  if [[ "$BASH_SUBSHELL" -gt 0 && "$#" -eq 2 && "$1" == '%s\n' && "$2" =~ ^[1-9][0-9]*$ && -n "${GATE_UI_TEST_LOCK_PID_FILE:-}" ]]; then
    sleep 2
    builtin printf '%s\n' "$2" >"${UI_LOCK_PUBLICATION_PROOF:?}"
  fi
  builtin printf "$@"
}
BASH_ENV
cat >"$ui_bin/apple-ui-test-lock" <<'LOCK'
#!/usr/bin/env bash
set -euo pipefail
label=""
while (($#)); do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --simulator-udid) shift 2 ;;
    --if-available) shift ;;
    --) shift; break ;;
    *) exit 2 ;;
  esac
done
printf '%s\n' "$label" >>"$UI_EVENTS"
printf '%s\n' "$$" >"${UI_LOCK_HELPER_PID_PROOF:?}"
if [[ "$label" == "interrupt-fixture" ]]; then
  python3 - "$UI_STATE" "$UI_SET_ROOT" <<'PY'
import json, sys
state, root = sys.argv[1:]
json.dump({"devices":{"fixture":[{"udid":"fixture-clone","name":"fixture-clone","dataPath":root+"/clone/data","state":"Shutdown"}]}}, open(state, "w"))
PY
fi
[[ "$label" == "XCTest clone cleanup" ]] && sleep 6
"$@" &
command_pid=$!
trap 'kill -TERM "$command_pid" 2>/dev/null || true; wait "$command_pid" 2>/dev/null || true; exit 143' INT TERM HUP
wait "$command_pid"
LOCK
cat >"$ui_bin/xcrun" <<'XCRUN'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
state = os.environ["UI_STATE"]
events = os.environ["UI_EVENTS"]
if args and args[0] == "simctl" and "list" in args:
    print(open(state, encoding="utf-8").read())
    raise SystemExit(0)
if args and args[0] == "simctl" and "delete" in args:
    udid = args[-1]
    data = json.load(open(state, encoding="utf-8"))
    for key in list(data["devices"]):
        data["devices"][key] = [item for item in data["devices"][key] if item["udid"] != udid]
    json.dump(data, open(state, "w"))
    open(events, "a", encoding="utf-8").write("delete " + udid + "\n")
    raise SystemExit(0)
raise SystemExit(2)
XCRUN
cat >"$ui_bin/stat" <<'STAT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-f" && "${2:-}" == "%B" ]]; then printf '%s\n' 1; else /usr/bin/stat "$@"; fi
STAT
chmod +x "$ui_bin/apple-ui-test-lock" "$ui_bin/xcrun" "$ui_bin/stat"

sleep 60 &
ui_peer_pid=$!
native_owned_pids="$ui_peer_pid"
env WILTED_BOUNDED_ENTRY=1 NATIVE_SELF_TEST=1 NATIVE_INTERRUPT_UI_TEST=1 \
  NATIVE_INTERRUPT_TEST_COMMAND="$native_fixture" NATIVE_INTERRUPT_UI_LOCK_PID_FILE="$ui_lock_pid_file" \
  WILTED_INTERRUPT_PROOF_DIR="$ui_proof" APPLE_UI_TEST_LOCK="$ui_bin/apple-ui-test-lock" \
  WILTED_UI_LOCK_CLEANUP_TIMEOUT_SECONDS=10 GATE_XCTEST_DEVICE_SET="$ui_set_root" UI_SET_ROOT="$ui_set_root" UI_STATE="$ui_state" UI_EVENTS="$ui_events" UI_LOCK_HELPER_PID_PROOF="$ui_lock_helper_pid_proof" UI_LOCK_PUBLICATION_PROOF="$ui_lock_publication_proof" BASH_ENV="$ui_bash_env" PATH="$ui_bin:$PATH" \
  bash "$repo_root/scripts/test-gate.sh" >"$tmp_root/native-ui-interrupt.log" 2>&1 &
ui_gate_pid=$!
native_owned_pids="$native_owned_pids $ui_gate_pid"
wait_for_native_file "$ui_proof/grandchild.pid" || { cat "$tmp_root/native-ui-interrupt.log" >&2; exit 1; }
wait_for_native_file "$ui_lock_helper_pid_proof" || { cat "$tmp_root/native-ui-interrupt.log" >&2; exit 1; }
ui_child_pid="$(<"$ui_proof/child.pid")"
ui_descendant_pid="$(<"$ui_proof/grandchild.pid")"
ui_lock_helper_pid="$(<"$ui_lock_helper_pid_proof")"
native_owned_pids="$native_owned_pids $ui_child_pid $ui_descendant_pid $ui_lock_helper_pid"
[[ ! -s "$ui_lock_pid_file" ]] || {
  printf '%s\n' 'native UI-lock fixture published the lock PID before inner interruption' >&2
  exit 1
}
kill -TERM "$ui_gate_pid"
set +e
wait "$ui_gate_pid"
ui_result=$?
set -e
[[ "$ui_result" -eq 143 ]] || { cat "$tmp_root/native-ui-interrupt.log" >&2; exit 1; }
wait_for_native_file "$ui_lock_publication_proof" || { cat "$tmp_root/native-ui-interrupt.log" >&2; exit 1; }
ui_lock_pid="$(<"$ui_lock_publication_proof")"
[[ "$ui_lock_pid" == "$ui_lock_helper_pid" ]] || {
  printf 'native UI-lock fixture published unexpected PID %s (helper %s)\n' "$ui_lock_pid" "$ui_lock_helper_pid" >&2
  exit 1
}
native_owned_pids="$native_owned_pids $ui_lock_pid"
assert_native_stopped "$ui_child_pid" ui-child
assert_native_stopped "$ui_descendant_pid" ui-descendant
assert_native_stopped "$ui_lock_pid" ui-lock
kill -0 "$ui_peer_pid" 2>/dev/null
grep -Fxq 'XCTest clone cleanup' "$ui_events"
grep -Fxq 'delete fixture-clone' "$ui_events"
python3 - "$ui_state" <<'PY'
import json, sys
assert not json.load(open(sys.argv[1]))["devices"]["fixture"]
PY
kill -TERM "$ui_peer_pid" 2>/dev/null || true
wait "$ui_peer_pid" 2>/dev/null || true
native_owned_pids=""
printf 'native UI-lock inner interrupt fixture passed lock=%s descendant=%s\n' "$ui_lock_pid" "$ui_descendant_pid"

for entrypoint in "$repo_root/scripts/test-phase0.sh" "$repo_root/scripts/test-gate.sh" "$repo_root"/tests/*.sh; do
  grep -Fq 'wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"' "$entrypoint" || {
    printf 'unbounded test entrypoint: %s\n' "$entrypoint" >&2
    exit 1
  }
done
printf '%s\n' 'bounded test entry meta-test passed'
