#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
collector="$root/scripts/collect-storage-backlog.py"
retainer="$root/scripts/retain-delivery-evidence.py"
wrapper="$root/scripts/with-spec-scratch.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-storage-test.XXXXXXXX")"
trap '[[ -d "$test_root" ]] && rm -rf "$test_root"' EXIT
failures=0
fail() { printf 'storage-retention.fail %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'storage-retention.ok %s\n' "$*" >&2; }
repo="$test_root/repo"
tmp_root="$test_root/tmp"
mkdir -p "$repo/.logs/delivery" "$repo/.build/Products" "$repo/Logs/Test/Run.xcresult/Data" "$tmp_root"
printf 'log\n' >"$repo/.logs/delivery/gate.log"
printf '{"status":"ok"}\n' >"$repo/.logs/delivery/gate-result.json"
printf 'source\n' >"$repo/source.swift"
printf 'build\n' >"$repo/.build/Products/build.log"
printf 'summary\n' >"$repo/Logs/Test/Run.xcresult/Data/summary.log"
printf 'nonreceipt\n' >"$repo/Logs/Test/Run.xcresult/Data/ordinary.json"
printf 'outside\n' >"$test_root/outside.log"
ln -s "$test_root/outside.log" "$repo/.logs/delivery/link.log"
archive="$test_root/archive/storage-retained-fixture"
if python3 "$retainer" "$repo" "$archive" >"$test_root/retain.out" 2>&1; then pass 'retainer completed'; else fail 'retainer failed'; cat "$test_root/retain.out" >&2; fi
[[ -f "$archive/.logs/delivery/gate.log" ]] && pass 'log retained' || fail 'log missing'
[[ -f "$archive/.logs/delivery/gate-result.json" ]] && pass 'named receipt retained' || fail 'receipt missing'
[[ -f "$archive/Logs/Test/Run.xcresult/Data/summary.log" ]] && pass 'xcresult retained' || fail 'xcresult missing'
[[ ! -e "$archive/source.swift" && ! -e "$archive/.build" ]] && pass 'source and .build excluded' || fail 'source or .build copied'
[[ ! -e "$archive/.logs/delivery/link.log" ]] && pass 'symlink skipped' || fail 'symlink copied'
[[ -f "$archive/retained-evidence-manifest.json" ]] && pass 'retention manifest written' || fail 'manifest missing'
[[ -f "$repo/source.swift" && -f "$repo/.build/Products/build.log" ]] && pass 'backlog source untouched' || fail 'source backlog changed'
if python3 "$retainer" "$repo" "$repo/nested-archive" >/dev/null 2>&1; then fail 'nested destination accepted'; else pass 'nested destination rejected'; fi
mkdir "$test_root/existing"
printf 'keep\n' >"$test_root/existing/sentinel"
if python3 "$retainer" "$repo" "$test_root/existing" >/dev/null 2>&1; then fail 'existing destination accepted'; else [[ -f "$test_root/existing/sentinel" ]] && pass 'existing destination preserved' || fail 'existing destination changed'; fi
ln -s "$test_root/missing-target" "$test_root/dangling-archive"
if python3 "$retainer" "$repo" "$test_root/dangling-archive" >/dev/null 2>&1; then fail 'dangling destination symlink accepted'; else [[ -L "$test_root/dangling-archive" && ! -e "$test_root/missing-target" ]] && pass 'dangling destination symlink preserved' || fail 'dangling destination changed'; fi
mkdir -p "$tmp_root/pass" "$tmp_root/fail" "$tmp_root/signal"
pass_marker="$test_root/pass-path"
env TMPDIR="$tmp_root/pass" SPEC_MARKER="$pass_marker" bash "$wrapper" bash -c 'printf "%s\n" "$TMPDIR" >"$SPEC_MARKER"; test -d "$WILTED_SPEC_SCRATCH"'
pass_path="$(cat "$pass_marker")"
[[ ! -e "$pass_path" ]] && pass 'success exit cleaned scratch' || fail 'success scratch survived'
fail_marker="$test_root/fail-path"
set +e
env TMPDIR="$tmp_root/fail" SPEC_MARKER="$fail_marker" bash "$wrapper" bash -c 'printf "%s\n" "$TMPDIR" >"$SPEC_MARKER"; exit 23'
fail_status=$?
set -e
fail_path="$(cat "$fail_marker")"
[[ "$fail_status" -eq 23 ]] && pass 'failure exit status preserved' || fail "failure status $fail_status, expected 23"
[[ ! -e "$fail_path" ]] && pass 'failure exit cleaned scratch' || fail 'failure scratch survived'
signal_marker="$test_root/signal-path"
env TMPDIR="$tmp_root/signal" SPEC_MARKER="$signal_marker" bash "$wrapper" bash -c 'printf "%s\n" "$TMPDIR" >"$SPEC_MARKER"; trap "exit 0" TERM; while :; do sleep 1; done' >"$test_root/signal.log" 2>&1 &
wrapper_pid=$!
(
    sleep 6
    kill -KILL "$wrapper_pid" 2>/dev/null || true
) &
watchdog_pid=$!
for _ in {1..100}; do [[ -s "$signal_marker" ]] && break; sleep 0.05; done
if [[ ! -s "$signal_marker" ]]; then fail 'signal child did not start'; kill -TERM "$wrapper_pid" 2>/dev/null || true; else
    signal_path="$(cat "$signal_marker")"
    kill -TERM "$wrapper_pid"
    set +e
    wait "$wrapper_pid"
    signal_status=$?
    set -e
    [[ "$signal_status" -eq 143 ]] && pass 'TERM status reported' || fail "TERM status $signal_status, expected 143"
    [[ ! -e "$signal_path" ]] && pass 'TERM exit cleaned scratch' || fail 'TERM scratch survived'
fi
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
mkdir -p "$repo/.logs/delivery/storage-retained-old" "$tmp_root/wilted-spec-old"
printf 'archive\n' >"$repo/.logs/delivery/storage-retained-old/archive.log"
printf 'temp\n' >"$tmp_root/wilted-spec-old/output"
python3 "$collector" --repo "$repo" --tmp-root "$tmp_root" --json >"$test_root/backlog.json"
python3 - "$test_root/backlog.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
totals = data["totals"]
assert data["mode"] == "dry-run"
assert totals["retained_archive_count"] == 1
assert totals["repo_build_allocated_bytes"] > 0
assert totals["wilted_spec_count"] == 1 and totals["wilted_spec_allocated_bytes"] > 0
assert totals["all_allocated_bytes"] == totals["retained_allocated_bytes"] + totals["repo_build_allocated_bytes"] + totals["wilted_spec_allocated_bytes"]
PY
[[ -f "$repo/.logs/delivery/storage-retained-old/archive.log" && -f "$repo/.build/Products/build.log" && -f "$tmp_root/wilted-spec-old/output" ]] && pass 'collector did not alter backlog' || fail 'collector altered backlog'
if (( failures )); then printf 'storage-retention.failed count=%s\n' "$failures" >&2; exit 1; fi
printf 'storage-retention.passed\n' >&2
