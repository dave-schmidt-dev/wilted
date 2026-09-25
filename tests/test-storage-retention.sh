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

# Apply-mode deletion is exercised only in isolated fixture roots with fake
# lsof/pgrep commands. The live TMPDIR is never passed to this test.
probe_bin="$test_root/probe-bin"
mkdir -p "$probe_bin"
cat >"$probe_bin/lsof" <<'SH'
#!/bin/sh
case "${FAKE_LSOF_MODE:-none}" in
    none) exit 1 ;;
    open) printf '4242\n'; exit 0 ;;
    error) exit 2 ;;
    warning) printf 'lsof warning\n' >&2; exit 1 ;;
    timeout) exec /bin/sleep 3 ;;
    *) exit 2 ;;
esac
SH
cat >"$probe_bin/pgrep" <<'SH'
#!/bin/sh
case "${FAKE_PGREP_MODE:-none}" in
    none) exit 1 ;;
    used) printf '5252\n'; exit 0 ;;
    error) exit 2 ;;
    mutate)
        count=0
        [ -f "$FAKE_PGREP_COUNT" ] && count="$(cat "$FAKE_PGREP_COUNT")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$FAKE_PGREP_COUNT"
        if [ "$count" -eq 2 ]; then
            mv "$FAKE_MUTATE_PATH" "$FAKE_MUTATE_PATH.moved"
            mkdir "$FAKE_MUTATE_PATH"
            printf 'replacement\n' >"$FAKE_MUTATE_PATH/replacement"
        fi
        exit 1
        ;;
    *) exit 2 ;;
esac
SH
chmod +x "$probe_bin/lsof" "$probe_bin/pgrep"
case_root=""
case_repo=""
case_tmp=""
candidate=""
new_case() {
    case_root="$test_root/apply-$1"
    case_repo="$case_root/repo"
    case_tmp="$case_root/tmp"
    mkdir -p "$case_repo" "$case_tmp"
}
make_old_candidate() {
    candidate="$case_tmp/wilted-spec.$1"
    mkdir -p "$candidate"
    printf 'diagnostic log\n' >"$candidate/run.log"
    printf '{"result":"ok"}\n' >"$candidate/gate-result.json"
    mkdir -p "$candidate/Run.xcresult/Data"
    printf 'xcresult evidence\n' >"$candidate/Run.xcresult/Data/summary.log"
    python3 - "$candidate" <<'PY'
import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
old = time.time() - 48 * 60 * 60
for path in [root, *root.rglob("*")]:
    os.utime(path, (old, old), follow_symlinks=False)
PY
}
run_apply() {
    local lsof_mode="$1" pgrep_mode="$2" timeout="${3:-1}"
    env PATH="$probe_bin:$PATH" FAKE_LSOF_MODE="$lsof_mode" FAKE_PGREP_MODE="$pgrep_mode" \
        python3 "$collector" --repo "$case_repo" --tmp-root "$case_tmp" --apply \
        --probe-timeout-seconds "$timeout" --json >"$test_root/apply.json" 2>"$test_root/apply.err"
}
expect_apply() {
    local expected_status="$1" expected_reason="$2"
    python3 - "$test_root/apply.json" "$expected_status" "$expected_reason" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["mode"] == "apply", data
assert len(data["cleanup"]) == 1, data["cleanup"]
row = data["cleanup"][0]
assert row["status"] == sys.argv[2], row
assert row["reason"] == sys.argv[3], row
assert row["allocated_bytes"] >= 0, row
summary = data["cleanup_summary"]
assert summary["removed_count"] == int(sys.argv[2] == "removed"), summary
assert summary["skipped_count"] == int(sys.argv[2] == "skipped"), summary
PY
}

new_case recent
make_old_candidate fdgyGX
printf 'new activity\n' >"$candidate/nested-recent"
touch "$candidate/nested-recent"
if run_apply none none; then
    expect_apply skipped newest-entry-younger-than-cutoff && [[ -d "$candidate" ]] && pass 'newest recursive mtime protects recent activity' || fail 'recent activity was not protected'
else fail 'recent-age apply invocation failed'; fi

new_case lsof-open
make_old_candidate ABCD0002
if run_apply open none; then
    expect_apply skipped open-files && [[ -d "$candidate" ]] && pass 'lsof open-file result prevents deletion' || fail 'lsof open-file safeguard failed'
else fail 'lsof-open apply invocation failed'; fi

new_case lsof-error
make_old_candidate ABCD0003
if run_apply error none; then
    expect_apply skipped lsof-probe-error-exit-2 && [[ -d "$candidate" ]] && pass 'lsof error fails closed' || fail 'lsof error safeguard failed'
else fail 'lsof-error apply invocation failed'; fi

new_case lsof-warning
make_old_candidate ABCD0010
if run_apply warning none; then
    expect_apply skipped lsof-probe-error-exit-1 && [[ -d "$candidate" ]] && pass 'lsof warning fails closed' || fail 'lsof warning safeguard failed'
else fail 'lsof-warning apply invocation failed'; fi

new_case lsof-timeout
make_old_candidate ABCD0004
if run_apply timeout none 0.1; then
    expect_apply skipped lsof-probe-timeout && [[ -d "$candidate" ]] && pass 'lsof timeout fails closed' || fail 'lsof timeout safeguard failed'
else fail 'lsof-timeout apply invocation failed'; fi

new_case pgrep-used
make_old_candidate ABCD0005
if run_apply none used; then
    expect_apply skipped process-reference && [[ -d "$candidate" ]] && pass 'pgrep process reference prevents deletion' || fail 'pgrep in-use safeguard failed'
else fail 'pgrep-used apply invocation failed'; fi

new_case pgrep-error
make_old_candidate ABCD0006
if run_apply none error; then
    expect_apply skipped pgrep-probe-error-exit-2 && [[ -d "$candidate" ]] && pass 'pgrep error fails closed' || fail 'pgrep error safeguard failed'
else fail 'pgrep-error apply invocation failed'; fi

new_case unsafe-names
candidate="$case_tmp/wilted-spec.ABCD0007"
mkdir -p "$test_root/outside-target"
printf 'do not follow\n' >"$test_root/outside-target/sentinel"
ln -s "$test_root/outside-target" "$candidate"
mkdir -p "$case_tmp/wilted-spec-not-random"
if run_apply none none; then
    python3 - "$test_root/apply.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = {row["path"]: row for row in data["cleanup"]}
assert rows[next(path for path in rows if path.endswith("ABCD0007"))]["reason"] == "symlink", rows
assert rows[next(path for path in rows if path.endswith("wilted-spec-not-random"))]["reason"] == "noncanonical-name-or-path", rows
PY
    [[ -L "$case_tmp/wilted-spec.ABCD0007" && -d "$case_tmp/wilted-spec-not-random" && -f "$test_root/outside-target/sentinel" ]] && pass 'symlink roots and noncanonical dirs are preserved' || fail 'unsafe-name fixture changed'
else fail 'unsafe-name apply invocation failed'; fi

new_case revalidate
make_old_candidate ABCD0008
pgrep_count="$case_root/pgrep-count"
if env PATH="$probe_bin:$PATH" FAKE_LSOF_MODE=none FAKE_PGREP_MODE=mutate \
    FAKE_PGREP_COUNT="$pgrep_count" FAKE_MUTATE_PATH="$candidate" \
    python3 "$collector" --repo "$case_repo" --tmp-root "$case_tmp" --apply --json >"$test_root/apply.json" 2>"$test_root/apply.err"; then
    expect_apply skipped delete-error-directory-changed-before-delete \
        && [[ -f "$candidate/replacement" && -f "$candidate.moved/run.log" ]] \
        && pass 'directory identity is revalidated before deletion' || fail 'directory identity revalidation failed'
else fail 'revalidation apply invocation failed'; fi

new_case successful-removal
make_old_candidate ABCD0009
printf 'external data\n' >"$test_root/external-data"
ln -s "$test_root/external-data" "$candidate/external-link"
python3 - "$candidate" <<'PY'
import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
old = time.time() - 48 * 60 * 60
os.utime(root / "external-link", (old, old), follow_symlinks=False)
os.utime(root, (old, old))
PY
if run_apply none none; then
    if expect_apply removed stale-and-unused && [[ ! -e "$candidate" && -f "$test_root/external-data" ]]; then
        if python3 - "$test_root/apply.json" "$case_repo" <<'PY'
import json, pathlib, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
row = data["cleanup"][0]
archive = pathlib.Path(row["evidence_archive"])
assert archive.is_dir(), archive
assert (archive / "run.log").is_file()
assert (archive / "gate-result.json").is_file()
assert (archive / "Run.xcresult/Data/summary.log").is_file()
manifest = json.loads((archive / "retained-evidence-manifest.json").read_text())
assert manifest["retained_file_count"] >= 3, manifest
assert data["cleanup_summary"]["freed_bytes"] == row["allocated_bytes"], data["cleanup_summary"]
PY
        then pass 'stale scratch removed after evidence was retained'
        else fail 'evidence retention validation failed'; fi
    else fail 'stale scratch was not removed'; fi
else fail 'successful-removal apply invocation failed'; fi

if python3 "$collector" --repo "$repo" --tmp-root "$tmp_root" --apply --min-age-hours 0 >/dev/null 2>&1; then
    fail 'apply accepted an age cutoff below 24 hours'
else pass 'apply enforces the 24-hour minimum age'; fi
if (( failures )); then printf 'storage-retention.failed count=%s\n' "$failures" >&2; exit 1; fi
printf 'storage-retention.passed\n' >&2
