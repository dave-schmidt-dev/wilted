#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
phase0_script="$repo_root/scripts/test-phase0.sh"
# These independent fixture repos must exercise their own full-run boundary,
# even when the real outer make validate already owns its checkout lock.
unset WILTED_FULL_RUN_LOCK_HELD
python3 "$repo_root/tests/test_temp_leaks.py"
WILTED_TEMP_LEAK_CHECKER="$repo_root/scripts/check-temp-leaks.py"
source "$repo_root/scripts/lib/test-temp-state.sh"
fixture_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-full-run-test.XXXXXX")"
wilted_temp_mark_owned "$fixture_root"
trap 'rm -rf "$fixture_root"' EXIT
grep -q "^pid=$$\$" "$fixture_root/.wilted-temp-owned" || { echo "fixture root not marked with this pid" >&2; exit 1; }
grep -q '^started=.' "$fixture_root/.wilted-temp-owned" || { echo "fixture root marker has no start time" >&2; exit 1; }
mktemp_tail='XXXXXX"'; mktemp_tail+=')'  # built in pieces so this guard never matches itself
for meta_test in tests/test-native-gate.sh tests/test-native-gate-watch.sh tests/test-temp-leaks.sh; do
  grep -A1 -F "$mktemp_tail" "$repo_root/$meta_test" | grep -q wilted_temp_mark_owned \
    || { echo "$meta_test creates its temp root without wilted_temp_mark_owned" >&2; exit 1; }
done

# A sibling worktree's live, marked gate root is not this run's leak; this run's own
# marked root still is (wilted_temp_compare passes the $$ that wilted_temp_mark_owned records).
shared="$fixture_root/shared"
mkdir -p "$shared"
wilted_temp_snapshot "$shared" "$fixture_root/shared-before.json"
bash -c 'source "$1"; mkdir "$2"; wilted_temp_mark_owned "$2"; touch "$2/ready"; sleep 60' _ \
  "$repo_root/scripts/lib/test-temp-state.sh" "$shared/wilted-native-gate.neighb" &
neighbour_pid=$!
for _ in $(seq 100); do [[ -e "$shared/wilted-native-gate.neighb/ready" ]] && break; sleep .1; done
wilted_temp_snapshot "$shared" "$fixture_root/shared-after.json"
wilted_temp_compare "$fixture_root/shared-before.json" "$fixture_root/shared-after.json" neighbour-parent || {
  kill "$neighbour_pid"; echo 'live neighbour root counted as a leak' >&2; exit 1;
}
kill "$neighbour_pid"; wait "$neighbour_pid" 2>/dev/null || true
mkdir "$shared/wilted-native-gate.own"; wilted_temp_mark_owned "$shared/wilted-native-gate.own"
wilted_temp_snapshot "$shared" "$fixture_root/shared-own.json"
if wilted_temp_compare "$fixture_root/shared-before.json" "$fixture_root/shared-own.json" own-parent; then
  echo "this run's own root or a dead neighbour's was exempted" >&2; exit 1
fi

repo="$fixture_root/repo"
parent="$fixture_root/parent"
mkdir -p "$repo/scripts" "$repo/.logs" "$parent"
cp "$repo_root/scripts/run-bounded.py" "$repo/scripts/run-bounded.py"
cd "$repo"

assert_full_run_artifacts_absent() {
  local label="$1" audit_left=""
  [[ ! -e "$repo/.build/full-run.lock" ]] || { echo "$label left full-run lock" >&2; exit 1; }
  [[ ! -e "$repo/.build/full-run.lock.recovery" ]] || { echo "$label left full-run recovery" >&2; exit 1; }
  audit_left="$(find "$repo/.logs" -maxdepth 1 -type d -name 'full-run-temp-audit.*' -print -quit)"
  [[ -z "$audit_left" ]] || { echo "$label left full-run audit=$audit_left" >&2; exit 1; }
}

assert_phase0_initialization_cleanup() {
  local label="$1" expected_status="$2" parent audit_parent output status leftover
  shift 2
  parent="$fixture_root/phase0-init-$label-parent"
  audit_parent="$fixture_root/phase0-init-$label-audit"
  output="$fixture_root/phase0-init-$label.log"
  mkdir -p "$parent" "$audit_parent"
  set +e
  env WILTED_BOUNDED_ENTRY=1 PHASE0_SELF_TEST=1 TMPDIR="$parent" \
    WILTED_PHASE0_TEMP_AUDIT_PARENT="$audit_parent" "$@" \
    bash "$phase0_script" >"$output" 2>&1
  status=$?
  set -e
  [[ "$status" -eq "$expected_status" ]] || {
    echo "phase0 $label status=$status expected=$expected_status" >&2
    cat "$output" >&2
    exit 1
  }
  leftover="$(find "$parent" -maxdepth 1 -name 'wilted-*' -print -quit)"
  [[ -z "$leftover" ]] || { echo "phase0 $label left temp root=$leftover" >&2; exit 1; }
  leftover="$(find "$audit_parent" -maxdepth 1 -name 'phase0-temp-audit.*' -print -quit)"
  [[ -z "$leftover" ]] || { echo "phase0 $label left audit root=$leftover" >&2; exit 1; }
}

# The real Phase 0 wrapper exits before any production test when setup fails.
failing_snapshot_checker="$fixture_root/failing-phase0-snapshot.py"
printf 'import sys\nsys.exit(73)\n' >"$failing_snapshot_checker"
assert_phase0_initialization_cleanup snapshot-failure 73 "WILTED_TEMP_LEAK_CHECKER=$failing_snapshot_checker"
marker_failure_bin="$fixture_root/phase0-marker-failure-bin"
mkdir -p "$marker_failure_bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$marker_failure_bin/ps"
chmod +x "$marker_failure_bin/ps"
assert_phase0_initialization_cleanup marker-failure 1 "PATH=$marker_failure_bin:$PATH"
assert_phase0_initialization_cleanup invalid-timeout 2 'PHASE0_LEG_TIMEOUT_SECONDS=0'
assert_phase0_initialization_cleanup missing-runner 127 "WILTED_BOUNDED_RUNNER=$fixture_root/no-runner"

caller_parent="$fixture_root/caller-parent"
caller_fixture="$caller_parent/wilted-caller-trap"
caller_script="$fixture_root/caller-trap.sh"
mkdir -p "$caller_parent"
wilted_temp_snapshot "$caller_parent" "$fixture_root/caller-before.json"
cat >"$caller_script" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/lib/test-temp-state.sh"
WILTED_TEMP_LEAK_CHECKER="$1/scripts/check-temp-leaks.py"
trap 'printf "EXIT:%s\n" "$?" >>"$CALLER_EVENTS"; rm -rf "$CALLER_FIXTURE"' EXIT
trap ':' INT
trap ':' TERM
trap ':' RETURN
mkdir -p "$CALLER_FIXTURE"
before="$(trap -p EXIT INT TERM RETURN)"
set +e
WILTED_FULL_RUN_TIMEOUT_SECONDS="${CALLER_TIMEOUT:-20}" TMPDIR="$2" wilted_full_run "$4" bash -c "${CALLER_COMMAND:-true}"
status=$?
set -e
[[ "$(trap -p EXIT INT TERM RETURN)" == "$before" ]] || { echo 'caller traps changed' >&2; exit 91; }
[[ -d "$CALLER_FIXTURE" ]] || { echo 'caller EXIT ran before shell exit' >&2; exit 92; }
exit "$status"
CALLER
chmod +x "$caller_script"
caller_events="$fixture_root/caller-events"
for expected in 0 23 124; do
  command=true
  timeout=20
  [[ "$expected" != 23 ]] || command='exit 23'
  if [[ "$expected" == 124 ]]; then command='sleep 20'; timeout=.2; fi
  set +e
  CALLER_FIXTURE="$caller_fixture" CALLER_EVENTS="$caller_events" CALLER_COMMAND="$command" CALLER_TIMEOUT="$timeout" \
    bash "$caller_script" "$repo_root" "$caller_parent" "$caller_fixture" "$repo"
  actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || { echo "caller status=$actual expected=$expected" >&2; exit 1; }
  assert_full_run_artifacts_absent "caller-$expected"
done
set +e
CALLER_FIXTURE="$caller_fixture" CALLER_EVENTS="$caller_events" \
  bash "$caller_script" "$repo_root" "$caller_parent" "$caller_fixture" "$fixture_root/missing-repo"
invalid_repo_status=$?
set -e
[[ "$invalid_repo_status" -eq 1 ]] || { echo "invalid repo status=$invalid_repo_status" >&2; exit 1; }
assert_full_run_artifacts_absent invalid-repo
[[ "$(wc -l <"$caller_events" | tr -d ' ')" == 4 ]] || { echo 'caller EXIT did not run exactly once per shell' >&2; exit 1; }
[[ ! -e "$caller_fixture" ]] || { echo 'full-run replaced caller EXIT trap' >&2; exit 1; }
wilted_temp_snapshot "$caller_parent" "$fixture_root/caller-after.json"
wilted_temp_compare "$fixture_root/caller-before.json" "$fixture_root/caller-after.json" caller-tmpdir || {
  echo 'caller TMPDIR gained an entry' >&2; exit 1;
}

run_full() {
  TMPDIR="$parent" wilted_full_run "$repo" "$@"
}

recovery_sentinel="$repo/.recovery/sentinel"
mkdir -p "${recovery_sentinel%/*}"
: >"$recovery_sentinel"

run_full true
assert_full_run_artifacts_absent success
[[ -f "$recovery_sentinel" ]] || { echo 'success removed unowned fixture .recovery sentinel' >&2; exit 1; }

set +e
run_full bash -c 'mkdir -p "$TMPDIR/wilted-child-leak"'
leak_status=$?
set -e
[[ "$leak_status" -ne 0 && -d "$parent/wilted-child-leak" ]] || { echo 'full-run leak was not propagated' >&2; exit 1; }
assert_full_run_artifacts_absent leak
[[ -f "$recovery_sentinel" ]] || { echo 'leak cleanup removed unowned fixture .recovery sentinel' >&2; exit 1; }
rm -rf "$parent/wilted-child-leak"

set +e
run_full bash -c 'exit 23'
failure_status=$?
set -e
[[ "$failure_status" -eq 23 ]] || { echo "full-run failure status=$failure_status" >&2; exit 1; }
assert_full_run_artifacts_absent failure
[[ -f "$recovery_sentinel" ]] || { echo 'failure removed unowned fixture .recovery sentinel' >&2; exit 1; }

pid_file="$fixture_root/child.pid"
set +e
WILTED_FULL_RUN_TIMEOUT_SECONDS=.2 TMPDIR="$parent" wilted_full_run "$repo" bash -c \
  'sleep 20 & echo $! >"$1"; wait' _ "$pid_file"
timeout_status=$?
set -e
[[ "$timeout_status" -eq 124 ]] || { echo "full-run timeout status=$timeout_status" >&2; exit 1; }
child_pid="$(cat "$pid_file")"
! kill -0 "$child_pid" 2>/dev/null || { echo 'full-run descendant survived timeout' >&2; exit 1; }
assert_full_run_artifacts_absent timeout
[[ -f "$recovery_sentinel" ]] || { echo 'timeout removed unowned fixture .recovery sentinel' >&2; exit 1; }

unowned_build="$fixture_root/unowned-build"
mkdir -p "$unowned_build"
rm -rf "$repo/.build"
ln -s "$unowned_build" "$repo/.build"
set +e
run_full true
symlink_build_status=$?
set -e
[[ "$symlink_build_status" -ne 0 && -L "$repo/.build" && ! -e "$unowned_build/full-run.lock" ]] || {
  echo 'noncanonical .build boundary was accepted' >&2; exit 1;
}
rm "$repo/.build"
mkdir -p "$repo/.build"

rm -rf "$repo/.build/full-run.lock"
mkdir -p "$repo/.build/full-run.lock"
printf 'bad\n' >"$repo/.build/full-run.lock/pid"
set +e
run_full true
invalid_lock_status=$?
set -e
[[ "$invalid_lock_status" -ne 0 ]] || { echo 'invalid lock was accepted' >&2; exit 1; }
rm -rf "$repo/.build/full-run.lock"

mkdir -p "$repo/.build/full-run.lock"
printf '999999\n' >"$repo/.build/full-run.lock/pid"
run_full true || { echo 'stale lock was not recovered' >&2; exit 1; }

mkdir -p "$repo/.build/full-run.lock"
printf '12345\n' >"$repo/.build/full-run.lock/pid"
fakebin="$fixture_root/fakebin"
mkdir -p "$fakebin"
printf '#!/usr/bin/env bash\nexit 2\n' >"$fakebin/ps"
chmod +x "$fakebin/ps"
set +e
PATH="$fakebin:$PATH" run_full true
unverifiable_lock_status=$?
set -e
[[ "$unverifiable_lock_status" -ne 0 && -d "$repo/.build/full-run.lock" ]] || {
  echo 'unverifiable lock was recovered' >&2; exit 1;
}
rm -rf "$repo/.build/full-run.lock"

missing_parent="$fixture_root/missing-parent"
set +e
TMPDIR="$missing_parent" wilted_full_run "$repo" true
snapshot_failure_status=$?
set -e
[[ "$snapshot_failure_status" -ne 0 && ! -e "$repo/.build/full-run.lock" ]] || {
  echo 'snapshot failure was not propagated' >&2; exit 1;
}

TMPDIR="$parent" wilted_full_run "$repo" bash -c 'sleep .4' &
holder_pid=$!
for _ in {1..40}; do [[ -d "$repo/.build/full-run.lock" ]] && break; sleep .02; done
started="$(date +%s)"
run_full true
wait "$holder_pid"
elapsed=$(( $(date +%s) - started ))
[[ "$elapsed" -ge 1 ]] || { echo 'lock contention did not serialize' >&2; exit 1; }

# Delay a second stale observer until the first replacement lock is live.
# Recovery must re-read the current owner under its own serialized guard.
race_bin="$fixture_root/race-bin"
mkdir -p "$race_bin" "$repo/.build/full-run.lock"
printf '999999\n' >"$repo/.build/full-run.lock/pid"
cat >"$race_bin/ps" <<'PS'
#!/usr/bin/env bash
if [[ "$*" == *999999* ]]; then
  if mkdir "$RACE_FIRST" 2>/dev/null; then sleep .2; else
    for _ in {1..100}; do [[ -f "$RACE_OWNER" ]] && break; sleep .02; done
  fi
  exit 1
fi
exec /bin/ps "$@"
PS
chmod +x "$race_bin/ps"
race_first="$fixture_root/race-first"
race_owner="$fixture_root/race-owner"
race_critical="$fixture_root/race-critical"
race_command='mkdir "$1" || exit 29; : >"$2"; sleep 1.2; rmdir "$1"'
PATH="$race_bin:$PATH" RACE_FIRST="$race_first" RACE_OWNER="$race_owner" \
  run_full bash -c "$race_command" _ "$race_critical" "$race_owner" &
race_a=$!
for _ in {1..100}; do [[ -d "$race_first" ]] && break; sleep .02; done
PATH="$race_bin:$PATH" RACE_FIRST="$race_first" RACE_OWNER="$race_owner" \
  run_full bash -c "$race_command" _ "$race_critical" "$race_owner" &
race_b=$!
wait "$race_a" || { echo 'first stale-lock owner failed' >&2; exit 1; }
wait "$race_b" || { echo 'stale recovery deleted a newly acquired live lock' >&2; exit 1; }

# A live owner releasing while an observer is mid-probe must not break the observer. The owner
# holds the lock until the observer's (slow) ps has started, then exits while the observer is
# still inside its stale check; release goes through the same guard, so the observer sees a live
# owner instead of a vanished lock (cat/mv ENOENT).
slow_bin="$fixture_root/slow-ps-bin"
slowps_mark="$fixture_root/slow-ps-started"
mkdir -p "$slow_bin"
printf '#!/usr/bin/env bash\n: >"$SLOWPS_MARK"\nsleep 1.2\nexec /bin/ps "$@"\n' >"$slow_bin/ps"
chmod +x "$slow_bin/ps"
run_full bash -c 'for _ in {1..500}; do [[ -f "$1" ]] && break; sleep .02; done' _ "$slowps_mark" &
release_owner=$!
for _ in {1..100}; do [[ -s "$repo/.build/full-run.lock/pid" ]] && break; sleep .02; done
SLOWPS_MARK="$slowps_mark" PATH="$slow_bin:$PATH" run_full true || { echo 'observer failed when the owner released mid-probe' >&2; exit 1; }
wait "$release_owner" || { echo 'owner failed while an observer probed it' >&2; exit 1; }
[[ -f "$slowps_mark" ]] || { echo 'release-race observer never probed the owner' >&2; exit 1; }
assert_full_run_artifacts_absent release-race

term_script="$fixture_root/term.sh"
cat >"$term_script" <<'TERM'
#!/usr/bin/env bash
set -euo pipefail
source "$1/scripts/lib/test-temp-state.sh"
WILTED_TEMP_LEAK_CHECKER="$1/scripts/check-temp-leaks.py"
caller_cleanup() {
  local status=$?
  if kill -0 "$(cat "$4")" 2>/dev/null; then printf 'alive\n' >>"$TERM_EVENTS"; fi
  printf 'EXIT:%s\n' "$status" >>"$TERM_EVENTS"
  rm -rf "$TERM_FIXTURE"
  : >"$TERM_CLEANED"
}
child_file="$4"
trap 'caller_cleanup "$1" "$2" "$3" "$child_file"' EXIT
trap 'printf "INT\n" >>"$TERM_EVENTS"; exit 130' INT
trap 'printf "TERM\n" >>"$TERM_EVENTS"; exit 143' TERM
trap ':' RETURN
mkdir -p "$TERM_FIXTURE"
TMPDIR="$2" wilted_full_run "$3" bash -c 'sleep 20 & echo $! >"$1"; wait' _ "$4"
TERM
chmod +x "$term_script"
term_child="$fixture_root/term-child.pid"
term_fixture="$fixture_root/term-caller-owned"
term_cleaned="$fixture_root/term-caller-cleaned"
term_events="$fixture_root/term-events"
TERM_FIXTURE="$term_fixture" TERM_CLEANED="$term_cleaned" TERM_EVENTS="$term_events" bash "$term_script" "$repo_root" "$parent" "$repo" "$term_child" &
term_pid=$!
for _ in {1..40}; do [[ -s "$term_child" ]] && break; sleep .05; done
kill -TERM "$term_pid"
set +e
wait "$term_pid"
term_status=$?
set -e
[[ "$term_status" -eq 143 ]] || { echo "full-run TERM status=$term_status" >&2; exit 1; }
! kill -0 "$(cat "$term_child")" 2>/dev/null || { echo 'full-run descendant survived TERM' >&2; exit 1; }
[[ ! -e "$term_fixture" && -f "$term_cleaned" ]] || { echo 'full-run TERM lost caller EXIT cleanup' >&2; exit 1; }
[[ "$(cat "$term_events")" == $'TERM\nEXIT:143' ]] || { echo 'TERM caller cleanup was early, duplicated, or lost its handler' >&2; exit 1; }
assert_full_run_artifacts_absent term
[[ -f "$recovery_sentinel" ]] || { echo 'TERM removed unowned fixture .recovery sentinel' >&2; exit 1; }

# Enable INT explicitly for this positive fixture, even from a Bash async leg.
python3 - "$term_script" "$repo_root" "$parent" "$repo" "$fixture_root" <<'PY'
import os, pathlib, signal, subprocess, sys, time
script, root, parent, repo, fixture = sys.argv[1:]
fixture = pathlib.Path(fixture)
child_file = fixture / 'int-child.pid'
events = fixture / 'int-events'
env = dict(os.environ, TERM_FIXTURE=str(fixture / 'int-owned'),
           TERM_CLEANED=str(fixture / 'int-cleaned'), TERM_EVENTS=str(events))
def enable_interrupt():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
process = subprocess.Popen(['bash', script, root, parent, repo, str(child_file)],
                           env=env, preexec_fn=enable_interrupt)
try:
    deadline = time.monotonic() + 5
    while not child_file.exists() and time.monotonic() < deadline:
        time.sleep(.02)
    assert child_file.exists(), 'INT child did not start'
    process.send_signal(signal.SIGINT)
    assert process.wait(timeout=10) == 130, 'INT status changed'
    assert events.read_text() == 'INT\nEXIT:130\n', 'INT cleanup was early or duplicated'
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
PY

assert_full_run_artifacts_absent int
[[ -f "$recovery_sentinel" ]] || { echo 'INT removed unowned fixture .recovery sentinel' >&2; exit 1; }

capture_repo="$fixture_root/capture-repo"
capture_bin="$fixture_root/capture-bin"
mkdir -p "$capture_repo/scripts/lib" "$capture_repo/.logs" "$capture_bin"
mkdir -p "$capture_repo/WiltedMacTests/__Snapshots__/WiltedPixelSnapshotTests"
git init -q "$capture_repo"
cp "$repo_root/scripts/record-mac-snapshots.sh" "$repo_root/scripts/record-walkthrough-frames.sh" \
  "$repo_root/scripts/build-with-cache.py" "$capture_repo/scripts/"
cp "$repo_root/scripts/run-bounded.py" "$repo_root/scripts/check-temp-leaks.py" "$capture_repo/scripts/"
cp "$repo_root/scripts/lib/test-runner.sh" "$repo_root/scripts/lib/test-temp-state.sh" \
  "$repo_root/scripts/lib/mac-test-parent.sh" "$capture_repo/scripts/lib/"
printf 'fixture\n' >"$capture_repo/project.yml"
for directory in Shared WiltedMac WiltedMacTests WiltedMacUITests WiltediOS WiltediOSTests WiltediOSIntents WiltediOSUITests; do
  mkdir -p "$capture_repo/$directory"
done
for package in WiltedKit Producer CloudSync Listener; do
  mkdir -p "$capture_repo/$package/Sources" "$capture_repo/$package/Tests"
  printf 'fixture\n' >"$capture_repo/$package/Package.swift"
done
cat >"$capture_bin/xcodegen" <<'XCODEGEN'
#!/usr/bin/env bash
set -euo pipefail
project=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == --project ]]; then project="$2"; shift 2; else shift; fi
done
mkdir -p "$project/Wilted.xcodeproj/xcshareddata/xcschemes"
printf '%s\n' '<Scheme><LaunchAction /><TestAction /></Scheme>' >"$project/Wilted.xcodeproj/xcshareddata/xcschemes/WiltedMac.xcscheme"
XCODEGEN
cat >"$capture_bin/xcodebuild" <<'XCODEBUILD'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${WILTED_TEST_TMPDIR:-missing}" >"$FAKE_PARENT_MARKER"
case "$FAKE_XCODE_MODE" in
  fail) echo fake-xcode-failure; exit 37 ;;
  delay|timeout) sleep 60 & child=$!; echo "$child" >"$FAKE_CHILD_MARKER"; wait "$child" ;;
esac
scratch_root="$(dirname "$WILTED_TEST_TMPDIR")"
if [[ "$FAKE_CAPTURE_KIND" == walkthrough ]]; then
  capture_dir="$(python3 - "$scratch_root/capture-root/Wilted.xcodeproj/xcshareddata/xcschemes/WiltedMac.xcscheme" <<'PY'
import sys, xml.etree.ElementTree as ET
env = ET.parse(sys.argv[1]).getroot().find('TestAction/EnvironmentVariables')
print(next(x.get('value', '') for x in env if x.get('key') == 'WILTED_WALKTHROUGH_CAPTURE_DIR'))
PY
)"
  mkdir -p "$capture_dir"
  sleep 1
  printf 'png\n' >"$capture_dir/frame.png"
  printf '{}\n' >"$capture_dir/frame.json"
  printf 'walkthrough.capture.root=%s\n' "$capture_dir"
else
  capture_dir="$scratch_root/record-root/WiltedMacTests/__Snapshots__/WiltedPixelSnapshotTests"
  mkdir -p "$capture_dir"
  printf 'png\n' >"$capture_dir/fake.png"
fi
XCODEBUILD
cat >"$capture_bin/caffeinate" <<'CAFFEINATE'
#!/usr/bin/env bash
shift
exec "$@"
CAFFEINATE
cat >"$capture_bin/ioreg" <<'IOREG'
#!/usr/bin/env bash
exit 0
IOREG
chmod +x "$capture_bin"/*

assert_capture_temp_empty() {
  local parent="$1" leftover
  leftover="$(find "$parent" -mindepth 1 -maxdepth 1 \( -name 'wilted-record-snapshots.*' -o -name 'wilted-walkthrough.*' \) -print -quit)"
  [[ -z "$leftover" ]] || { echo "capture wrapper leaked temp root=$leftover" >&2; exit 1; }
}
run_capture_case() {
  local kind="$1" mode="$2" expected="$3" keep="${4:-0}"
  local parent="$fixture_root/capture-$kind-$mode-parent" marker="$fixture_root/capture-$kind-$mode-marker"
  local child="$fixture_root/capture-$kind-$mode-child" output="$fixture_root/capture-$kind-$mode.log" entry actual
  mkdir -p "$parent"
  entry="$capture_repo/scripts/record-mac-snapshots.sh"
  [[ "$kind" != walkthrough ]] || entry="$capture_repo/scripts/record-walkthrough-frames.sh"
  set +e
  env WILTED_BOUNDED_ENTRY=0 PATH="$capture_bin:$PATH" TMPDIR="$parent" FAKE_CAPTURE_KIND="$kind" FAKE_XCODE_MODE="$mode" \
    FAKE_PARENT_MARKER="$marker" FAKE_CHILD_MARKER="$child" WILTED_CAPTURE_KEEP="$keep" \
    WILTED_TEST_RUNNER_TIMEOUT_SECONDS=5 bash "$entry" >"$output" 2>&1
  actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || { echo "capture $kind/$mode status=$actual expected=$expected" >&2; cat "$output" >&2; exit 1; }
  assert_capture_temp_empty "$parent"
  if [[ "$mode" == success || "$mode" == fail ]]; then
    [[ -s "$marker" ]] || { echo "capture $kind/$mode never reached fake xcodebuild" >&2; exit 1; }
  fi
  if [[ "$mode" == timeout ]]; then
    [[ -s "$child" ]] || { echo "capture $kind timeout did not start descendant" >&2; exit 1; }
    ! kill -0 "$(cat "$child")" 2>/dev/null || { echo "capture $kind timeout left descendant" >&2; exit 1; }
  fi
}

run_capture_case snapshot success 0
run_capture_case snapshot fail 37
run_capture_case walkthrough success 0 1
run_capture_case walkthrough fail 37
run_capture_case snapshot timeout 124
run_capture_case walkthrough timeout 124

for signal_kind in 'snapshot TERM 143' 'walkthrough INT 130'; do
  read -r kind signal_name expected <<<"$signal_kind"
  parent="$fixture_root/capture-$kind-$signal_name-parent"
  marker="$fixture_root/capture-$kind-$signal_name-marker"
  child="$fixture_root/capture-$kind-$signal_name-child"
  entry="$capture_repo/scripts/record-mac-snapshots.sh"
  [[ "$kind" != walkthrough ]] || entry="$capture_repo/scripts/record-walkthrough-frames.sh"
  mkdir -p "$parent"
  python3 - "$entry" "$capture_bin" "$parent" "$marker" "$child" "$kind" "$signal_name" "$expected" <<'PY'
import os, pathlib, signal, subprocess, sys, time
entry, fakebin, parent, marker, child, kind, signal_name, expected = sys.argv[1:]
signum = getattr(signal, 'SIG' + signal_name)
expected_shell_status = int(expected)
assert expected_shell_status == 128 + signum, 'shell signal exit expectation is inconsistent'
expected_returncode = -signum
env = dict(os.environ, PATH=fakebin + os.pathsep + os.environ['PATH'], TMPDIR=parent,
           WILTED_BOUNDED_ENTRY='0',
           FAKE_CAPTURE_KIND=kind, FAKE_XCODE_MODE='delay', FAKE_PARENT_MARKER=marker,
           FAKE_CHILD_MARKER=child, WILTED_TEST_RUNNER_TIMEOUT_SECONDS='30')
process = subprocess.Popen(['bash', entry], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           preexec_fn=(lambda: signal.signal(signal.SIGINT, signal.SIG_DFL)) if signum == signal.SIGINT else None)
try:
    deadline = time.monotonic() + 12
    while not pathlib.Path(child).exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(.05)
    assert pathlib.Path(child).exists(), 'fake descendant did not start'
    process.send_signal(signum)
    _, stderr = process.communicate(timeout=12)
    assert process.returncode == expected_returncode, f'signal returncode={process.returncode}, expected={expected_returncode}: {stderr.decode(errors="replace")}'
    try:
        os.kill(int(pathlib.Path(child).read_text()), 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError(f'descendant survived {signal_name}')
finally:
    if process.poll() is None:
        process.terminate()
        process.communicate(timeout=12)
PY
  assert_capture_temp_empty "$parent"
done

diagnostic_run="$(find "$capture_repo/.logs/walkthrough-capture-diagnostics" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -print -quit)"
[[ -n "$diagnostic_run" && -s "$diagnostic_run/capture.log" && -s "$diagnostic_run/frames/frame.png" && -s "$diagnostic_run/frames/frame.json" ]] || {
  echo 'walkthrough KEEP did not preserve log and frame diagnostics' >&2; exit 1;
}
[[ ! -e "$diagnostic_run/capture-root" && ! -e "$diagnostic_run/xctest-temp" ]] || {
  echo 'walkthrough KEEP copied generated scratch content' >&2; exit 1;
}

echo 'temp-leaks.full-run.passed'
