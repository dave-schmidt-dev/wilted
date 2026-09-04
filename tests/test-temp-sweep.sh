#!/usr/bin/env bash
set -euo pipefail

# Proves the startup temp sweep (scripts/lib/temp-sweep.sh) actually removes
# abandoned wilted-* temp directories, never touches one young enough that a
# concurrent run could still own it, and that wiring it into the native gate
# means a run started after a killed prior run cleans up that prior run's
# leftovers -- not just its own.
#
# Hermetic on purpose, same discipline as tests/test-install-mac-app.sh:
# everything happens under a temp root this test creates and destroys itself.
# It never sweeps or even lists the real $TMPDIR, because other projects put
# unrelated data there and this test has no business judging its age.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$repo_root/scripts/lib/temp-sweep.sh"
gate="$repo_root/scripts/test-gate.sh"
failures=0

fail() { printf 'temp-sweep.fail %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'temp-sweep.ok %s\n' "$*" >&2; }

[[ -f "$lib" ]] || { fail "missing $lib"; exit 1; }
# shellcheck source=../scripts/lib/temp-sweep.sh
source "$lib"

hermetic_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-temp-sweep-test.XXXXXX")"
# The undeletable-directory case below sets the macOS user-immutable flag to
# force a real removal failure; strip it recursively before teardown or this
# test's own cleanup would fail the same way it is testing for.
trap 'chflags -R nouchg "$hermetic_root" 2>/dev/null || true; [[ -d "$hermetic_root" ]] && rm -rf "$hermetic_root"' EXIT

backdate() {
    # Same tool the sweep itself uses for its reference file, so this
    # exercises real mtime comparison rather than a mocked clock.
    touch -t "$(date -v-"$2"H '+%Y%m%d%H%M.%S')" "$1"
}

# --- (b) the sweep function itself: stale goes, fresh and non-wilted survive,
#     and a stale entry the sweep cannot actually remove is still counted once ---
sweep_root="$hermetic_root/sweep-target"
mkdir -p "$sweep_root"
stale_dir="$sweep_root/wilted-old-fixture.abc123"
fresh_dir="$sweep_root/wilted-new-fixture.def456"
untouched_dir="$sweep_root/not-wilted-anything"
# `chflags uchg` makes rm -rf fail on this one even though it is stale: the
# only way to exercise the removed-count-double-counted-as-kept regression is
# a stale entry the sweep actually tries and fails to remove, not merely one
# it never targets.
undeletable_dir="$sweep_root/wilted-undeletable.ghi789"
mkdir -p "$stale_dir" "$fresh_dir" "$untouched_dir" "$undeletable_dir"
backdate "$stale_dir" 48
backdate "$untouched_dir" 48
backdate "$undeletable_dir" 48
chflags uchg "$undeletable_dir"

sweep_output_file="$hermetic_root/sweep-output.log"
wilted_sweep_stale_temp_dirs "$sweep_root" 24 2>"$sweep_output_file"
sweep_output="$(cat "$sweep_output_file")"

if [[ -d "$stale_dir" ]]; then
    fail "stale directory older than the cutoff survived the sweep: $stale_dir"
else
    pass 'stale directory past the cutoff was removed'
fi
if [[ ! -d "$fresh_dir" ]]; then
    fail "fresh directory younger than the cutoff was removed: $fresh_dir"
else
    pass 'fresh directory younger than the cutoff survived'
fi
if [[ ! -d "$untouched_dir" ]]; then
    fail 'sweep removed a directory outside the wilted-* prefix even though it was stale'
else
    pass 'non-wilted directory is left alone regardless of age'
fi
if [[ ! -d "$undeletable_dir" ]]; then
    fail 'the immutable stale directory should have survived (rm -rf cannot remove it)'
else
    pass 'a stale directory the sweep cannot remove is left in place, not force-deleted'
fi
if [[ "$sweep_output" != *'removed=1'* ]]; then
    fail "sweep did not report removed=1: $sweep_output"
else
    pass 'sweep reports one removal'
fi
# Regression guard for the kept-count double-count: the survivors are
# fresh_dir and undeletable_dir (two wilted-* entries still on disk
# afterward). The old code additionally re-added undeletable_dir a second
# time because it also incremented `kept` inline when its rm -rf failed.
if [[ "$sweep_output" != *'kept=2'* ]]; then
    fail "sweep did not report kept=2 (double-count regression?): $sweep_output"
else
    pass 'sweep reports the correct kept count'
fi

# --- (a) wiring: a gate started after a killed prior run sweeps that run's
#     leftovers, never a genuinely concurrent one, and leaves nothing of its
#     own behind either ---
gate_tmpdir="$hermetic_root/gate-tmpdir"
mkdir -p "$gate_tmpdir"
killed_prior_run="$gate_tmpdir/wilted-native-gate.deadbeef"
concurrent_run="$gate_tmpdir/wilted-native-gate.stillalive"
mkdir -p "$killed_prior_run" "$concurrent_run"
backdate "$killed_prior_run" 48
# concurrent_run is left at its natural (just-created) mtime, standing in for
# another gate invocation that started seconds ago and is still working.

gate_log="$hermetic_root/gate.log"
if ! env NATIVE_SELF_TEST=1 WILTED_MAC_UI=1 TMPDIR="$gate_tmpdir" \
    WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$hermetic_root/diagnostics" \
    bash "$gate" >"$gate_log" 2>&1; then
    fail 'self-test gate run did not exit 0'
    cat "$gate_log" >&2
else
    pass 'self-test gate run exited 0'
fi

if [[ -d "$killed_prior_run" ]]; then
    fail "gate startup sweep did not remove a killed prior run's directory: $killed_prior_run"
else
    pass "gate startup sweep removed a killed prior run's abandoned directory"
fi
if [[ ! -d "$concurrent_run" ]]; then
    fail "gate startup sweep removed a directory younger than its cutoff: $concurrent_run"
else
    pass 'gate startup sweep left a directory younger than the cutoff alone'
fi

leftover="$(find "$gate_tmpdir" -maxdepth 1 -name 'wilted-*' ! -path "$concurrent_run" -print 2>/dev/null)"
if [[ -n "$leftover" ]]; then
    fail "gate run left its own temp directory behind: $leftover"
else
    pass 'a completed gate run leaves no wilted-* temp directory of its own behind'
fi

if (( failures > 0 )); then
    printf 'temp-sweep.failed count=%s\n' "$failures" >&2
    exit 1
fi
printf 'temp-sweep.passed\n' >&2
