#!/usr/bin/env bash
# Parent temp audit attribution under concurrent sessions (found pushing LG-2, 2026-10-19).
# A sibling session's live test must never count as this run's leak; this run's own leak
# still must. Sibling tests now keep their files in a root they mark, so the audit
# attributes them to their live owner. The shape that failed LG-2, an unmarked top-level
# file escaped by `mktemp -t`, stays a leak, and scripts/check-no-global-tmp.py keeps any
# shell source from creating it.
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_lib="$repo_root/scripts/lib/test-temp-state.sh"
WILTED_TEMP_LEAK_CHECKER="$repo_root/scripts/check-temp-leaks.py"
source "$temp_lib"
fixture="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-temp-attribution.XXXXXX")"; wilted_temp_mark_owned "$fixture"
sibling_pid=""
cleanup() {
  if [[ -n "$sibling_pid" ]]; then kill "$sibling_pid" 2>/dev/null || true; wait "$sibling_pid" 2>/dev/null || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT
fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }

shared="$fixture/shared"
mkdir "$shared"
wilted_temp_snapshot "$shared" "$fixture/before.json" >/dev/null

# Audits the shared root against the baseline; prints the audit and returns its status.
audit_shared() {
  local label="$1"
  wilted_temp_snapshot "$shared" "$fixture/$label.json" >/dev/null
  wilted_temp_compare "$fixture/before.json" "$fixture/$label.json" "$label" 2>&1
}

printf '%s\n' 'test.stage=live-sibling-test-root' >&2
# A sibling session's file-producing test, made the way the converted tests make it, still
# running when this run audits the root it shares.
TMPDIR="$shared" bash -c '
  source "$1"
  work_dir="$(mktemp -d "${TMPDIR:?}/wilted-persistence-probe-tests.XXXXXX")"; wilted_temp_mark_owned "$work_dir"
  : >"$(mktemp "$work_dir/output.XXXXXX")"
  touch "$work_dir/ready"
  exec sleep 60' _ "$temp_lib" &
sibling_pid=$!
for _ in $(seq 100); do compgen -G "$shared/wilted-persistence-probe-tests.*/ready" >/dev/null && break; sleep .1; done
compgen -G "$shared/wilted-persistence-probe-tests.*/ready" >/dev/null || fail 'sibling test root never became ready'
output="$(audit_shared sibling-parent)" || fail "a live sibling's marked test root counted as a leak: $output"
grep -q 'temp.foreign label=sibling-parent entry=wilted-persistence-probe-tests\.' <<<"$output" \
  || fail "sibling test root was not attributed to its owner: $output"

printf '%s\n' 'test.stage=own-escaped-file' >&2
# This run's own unmarked top-level file, the LG-2 shape, is a leak even beside a live sibling.
: >"$shared/wilted-persistence-probe.XXXXXX.escaped"
if output="$(audit_shared own-escape)"; then fail "an unmarked top-level file passed the audit: $output"; fi
grep -q 'temp.leak label=own-escape entry=wilted-persistence-probe.XXXXXX.escaped ' <<<"$output" \
  || fail "the escaped file was not reported: $output"
grep -q 'temp.foreign label=own-escape entry=wilted-persistence-probe-tests\.' <<<"$output" \
  || fail "the live sibling stopped being attributed: $output"
rm "$shared/wilted-persistence-probe.XXXXXX.escaped"

printf '%s\n' 'test.stage=own-finished-test-root' >&2
# A test this run launched that exited without removing its marked root: its owner is gone.
TMPDIR="$shared" bash -c '
  source "$1"
  work_dir="$(mktemp -d "${TMPDIR:?}/wilted-pipeline-worker.XXXXXX")"; wilted_temp_mark_owned "$work_dir"' _ "$temp_lib"
if output="$(audit_shared own-finished)"; then fail "a finished test's leftover root passed the audit: $output"; fi
grep -q 'temp.leak label=own-finished entry=wilted-pipeline-worker\.' <<<"$output" \
  || fail "the finished test's root was not reported: $output"

printf '%s\n' 'temp attribution tests: OK'
