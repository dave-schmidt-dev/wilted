#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# These independent fixture repos must exercise their own full-run boundary,
# even when the real outer make validate already owns its checkout lock.
unset WILTED_FULL_RUN_LOCK_HELD
WILTED_TEMP_LEAK_CHECKER="$repo_root/scripts/check-temp-leaks.py"
source "$repo_root/scripts/lib/test-temp-state.sh"
fixture_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-full-run-lock.XXXXXX")"; wilted_temp_mark_owned "$fixture_root"

helper_pids=""
track_helper() { helper_pids="$helper_pids $1"; }
cleanup_fixture() {
  local helper
  for helper in $helper_pids; do
    kill "$helper" 2>/dev/null || true
    wait "$helper" 2>/dev/null || true
  done
  rm -rf "$fixture_root"
}
trap cleanup_fixture EXIT

repo="$fixture_root/repo"
parent="$fixture_root/parent"
mkdir -p "$repo/scripts" "$repo/.logs" "$parent"
cp "$repo_root/scripts/run-bounded.py" "$repo/scripts/run-bounded.py"
cd "$repo"

run_full() {
  TMPDIR="$parent" wilted_full_run "$repo" "$@"
}

assert_full_run_artifacts_absent() {
  local label="$1" audit_left=""
  [[ ! -e "$repo/.build/full-run.lock" ]] || { echo "$label left full-run lock" >&2; exit 1; }
  [[ ! -e "$repo/.build/full-run.lock.recovery" ]] || { echo "$label left full-run recovery" >&2; exit 1; }
  audit_left="$(find "$repo/.logs" -maxdepth 1 -type d -name 'full-run-temp-audit.*' -print -quit)"
  [[ -z "$audit_left" ]] || { echo "$label left full-run audit=$audit_left" >&2; exit 1; }
}

stage() { printf 'test.stage=%s\n' "$1" >&2; }
fail() { echo "$*" >&2; exit 1; }
reference_start() {
  LC_ALL=C TZ=UTC0 /bin/ps -o lstart= -p "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

lock="$repo/.build/full-run.lock"

stage recycled-pid
sleep 60 &
live=$!
track_helper "$live"
mkdir -p "$lock"
printf 'pid=%s\nstarted=Thu Jan  1 00:00:00 1970\n' "$live" >"$lock/pid"
err="$fixture_root/recycled-pid.err"
run_full true 2>"$err"
assert_full_run_artifacts_absent recycled-pid
grep -Fq 'reason=recycled-pid' "$err" || fail 'recycled pid was not recovered'
grep -Fq "owner_pid=$live" "$err" || fail 'recycled owner pid was not reported'
kill -0 "$live" 2>/dev/null || fail 'recycled-pid helper was not left running'

stage live-owner-times-out
started="$(reference_start "$live")"
record="$(printf 'pid=%s\nstarted=%s\n' "$live" "$started")"
mkdir -p "$lock"
printf '%s\n' "$record" >"$lock/pid"
err="$fixture_root/live-owner-times-out.err"
set +e
WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS=2 run_full true 2>"$err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "live-owner timeout status=$status"
wait_line="$(grep 'temp.full-run.wait' "$err" | head -n 1)"
[[ -n "$wait_line" ]] || fail 'live owner never produced a wait line'
[[ "$wait_line" == *"owner_pid=$live"* ]] || fail "wait line lacks owner pid: $wait_line"
[[ "$wait_line" == *'lock_age='* ]] || fail "wait line lacks lock age: $wait_line"
[[ "$wait_line" == *'limit=2s'* ]] || fail "wait line lacks limit: $wait_line"
timeout_line="$(grep 'temp.full-run.timeout' "$err" | head -n 1)"
[[ "$timeout_line" == *"owner_pid=$live"* ]] || fail "timeout line lacks owner pid: $timeout_line"
[[ "$timeout_line" == *'WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS'* ]] || fail "timeout line lacks remedy: $timeout_line"
[[ -d "$lock" && "$(cat "$lock/pid")" == "$record" ]] || fail 'timed-out lock changed'

stage legacy-live-pid
printf '%s\n' "$live" >"$lock/pid"
err="$fixture_root/legacy-live-pid.err"
set +e
WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS=1 run_full true 2>"$err"
status=$?
set -e
[[ "$status" -eq 1 && -d "$lock" ]] || fail 'legacy live pid lock did not time out in place'
record="$(printf 'pid=%s\nstarted=%s\n' "$live" "$started")"
printf '%s\n' "$record" >"$lock/pid"

stage owner-exited
kill "$live" 2>/dev/null || true
wait "$live" 2>/dev/null || true
err="$fixture_root/owner-exited.err"
run_full true 2>"$err"
assert_full_run_artifacts_absent owner-exited
grep -Fq 'reason=owner-exited' "$err" || fail 'exited owner was not recovered'

stage owner-record-written
holder_err="$fixture_root/owner-record-holder.err"
run_full bash -c 'sleep 2' 2>"$holder_err" &
holder_job=$!
for _ in {1..100}; do [[ -s "$lock/pid" ]] && break; sleep .05; done
[[ -s "$lock/pid" ]] || fail 'owner never wrote a pid record'
owner_pid="$(sed -n 's/^pid=//p' "$lock/pid" | head -n 1)"
owner_started="$(sed -n 's/^started=//p' "$lock/pid" | head -n 1)"
[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || fail "owner record pid=$owner_pid"
kill -0 "$owner_pid" 2>/dev/null || fail "owner record pid $owner_pid is not alive"
[[ "$owner_started" == "$(reference_start "$owner_pid")" ]] || fail 'owner record start time does not match ps'
err="$fixture_root/owner-record-written.err"
run_full true 2>"$err"
grep 'temp.full-run.wait' "$err" | grep -Fq "owner_pid=$owner_pid" || fail 'waiter did not name the recorded owner'
wait "$holder_job"
assert_full_run_artifacts_absent owner-record-written

stage pidless-fresh
rm -rf "$lock"
mkdir -p "$lock"
err="$fixture_root/pidless-fresh.err"
set +e
WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS=2 run_full true 2>"$err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "pid-less fresh lock status=$status"
grep 'temp.full-run.wait' "$err" | grep -Fq 'owner_pid=none' || fail 'pid-less fresh lock did not report owner_pid=none'
[[ -d "$lock" ]] || fail 'pid-less fresh lock was removed'
rm -rf "$lock"

stage pidless-stale
mkdir -p "$lock"
touch -t 202001010000 "$lock"
err="$fixture_root/pidless-stale.err"
run_full true 2>"$err"
assert_full_run_artifacts_absent pidless-stale
grep -Fq 'reason=no-owner-record' "$err" || fail 'pid-less stale lock was not recovered'

stage default-limit
sleep 60 &
default_live=$!
track_helper "$default_live"
started="$(reference_start "$default_live")"
mkdir -p "$lock"
printf 'pid=%s\nstarted=%s\n' "$default_live" "$started" >"$lock/pid"
err="$fixture_root/default-limit.err"
( unset WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS; run_full true ) >/dev/null 2>"$err" &
waiter=$!
for _ in {1..200}; do grep -q 'temp.full-run.wait' "$err" 2>/dev/null && break; sleep .05; done
wait_line="$(grep 'temp.full-run.wait' "$err" 2>/dev/null | head -n 1)"
[[ "$wait_line" == *'limit=5400s'* ]] || fail "default wait line limit missing: $wait_line"
kill -TERM "$waiter" 2>/dev/null || true
set +e
wait "$waiter"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail 'default-limit waiter survived TERM'
[[ -d "$lock" ]] || fail 'default-limit waiter removed the owner lock'
rm -rf "$lock"
kill "$default_live" 2>/dev/null || true
wait "$default_live" 2>/dev/null || true

stage invalid-limit
sleep 60 &
invalid_live=$!
track_helper "$invalid_live"
started="$(reference_start "$invalid_live")"
mkdir -p "$lock"
printf 'pid=%s\nstarted=%s\n' "$invalid_live" "$started" >"$lock/pid"
err="$fixture_root/invalid-limit.err"
set +e
WILTED_FULL_RUN_LOCK_TIMEOUT_SECONDS=0 run_full true 2>"$err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "invalid limit status=$status"
rm -rf "$lock"
kill "$invalid_live" 2>/dev/null || true
wait "$invalid_live" 2>/dev/null || true

echo 'full-run-lock.passed'
