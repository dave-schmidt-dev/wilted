#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

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
WILTED_TEMP_LEAK_CHECKER="$repo_root/scripts/check-temp-leaks.py"
# shellcheck source=../scripts/lib/test-temp-state.sh
source "$repo_root/scripts/lib/test-temp-state.sh"

mark_dead_owned() {
    local canonical
    canonical="$(cd -P "$1" 2>/dev/null && pwd)" || return 1
    printf 'pid=99999\nstarted=dead-owner\npath=%s\n' "$canonical" >"$canonical/.wilted-temp-owned"
}

hermetic_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-temp-sweep-test.XXXXXX")"
# The undeletable-directory case below sets the macOS user-immutable flag to
# force a real removal failure; strip it recursively before teardown or this
# test's own cleanup would fail the same way it is testing for.
trap 'chflags -R nouchg "$hermetic_root" 2>/dev/null || true; [[ -d "$hermetic_root" ]] && rm -rf "$hermetic_root"' EXIT

backdate() {
    # Same tool the sweep itself uses for its reference file, so this
    # exercises real mtime comparison rather than a mocked clock.
    touch -t "$(date -v-"$2"H '+%Y%m%d%H%M.%S')" "$1"
}

assert_gate_initialization_cleanup() {
    local label="$1" expected_status="$2" parent audit_parent output status leftover
    shift 2
    parent="$hermetic_root/gate-init-$label-parent"
    audit_parent="$hermetic_root/gate-init-$label-audit"
    output="$hermetic_root/gate-init-$label.log"
    mkdir -p "$parent" "$audit_parent"
    set +e
    env WILTED_BOUNDED_ENTRY=1 NATIVE_SELF_TEST=1 WILTED_MAC_UI=1 \
        TMPDIR="$parent" WILTED_NATIVE_TEMP_AUDIT_PARENT="$audit_parent" \
        "$@" bash "$gate" >"$output" 2>&1
    status=$?
    set -e
    [[ "$status" -eq "$expected_status" ]] || {
        fail "gate $label exited $status, expected $expected_status"
        cat "$output" >&2
        return
    }
    leftover="$(find "$parent" -maxdepth 1 -name 'wilted-*' -print -quit)"
    [[ -z "$leftover" ]] || fail "gate $label left owned temp root: $leftover"
    leftover="$(find "$audit_parent" -maxdepth 1 -name 'native-temp-audit.*' -print -quit)"
    [[ -z "$leftover" ]] || fail "gate $label left initialization audit root: $leftover"
    pass "gate $label cleans initialization roots"
}

# --- (b) the sweep function itself: stale goes, fresh and non-wilted survive,
#     and a stale entry the sweep cannot actually remove is still counted once ---
sweep_root="$hermetic_root/sweep-target"
mkdir -p "$sweep_root"
stale_dir="$sweep_root/wilted-old-fixture.abc123"
fresh_dir="$sweep_root/wilted-new-fixture.def456"
untouched_dir="$sweep_root/not-wilted-anything"
spec_dir="$sweep_root/wilted-spec.owner-review"
# `chflags uchg` makes rm -rf fail on this one even though it is stale: the
# only way to exercise the removed-count-double-counted-as-kept regression is
# a stale entry the sweep actually tries and fails to remove, not merely one
# it never targets.
undeletable_dir="$sweep_root/wilted-undeletable.ghi789"
mkdir -p "$stale_dir" "$fresh_dir" "$untouched_dir" "$undeletable_dir" "$spec_dir"
mark_dead_owned "$stale_dir"
mark_dead_owned "$undeletable_dir"
backdate "$stale_dir" 48
backdate "$spec_dir" 48
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
if [[ ! -d "$spec_dir" ]]; then
    fail 'sweep removed a historical spec workspace'
else
    pass 'historical spec workspace is left for the dry-run collector'
fi
if [[ ! -d "$fresh_dir" ]]; then
    fail "fresh directory younger than the cutoff was removed: $fresh_dir"
fi
unmarked_dir="$sweep_root/wilted-unmarked"
symlink_dir="$sweep_root/wilted-symlink"
mkdir "$unmarked_dir"
ln -s "$untouched_dir" "$symlink_dir"
backdate "$unmarked_dir" 48
wilted_sweep_stale_temp_dirs "$sweep_root" 24 >/dev/null 2>&1
[[ -d "$unmarked_dir" ]] && pass 'stale unmarked directory is preserved' || fail 'unmarked directory was swept'
[[ -L "$symlink_dir" ]] && pass 'stale symlink is preserved' || fail 'symlink was swept'
active_owner="$sweep_root/wilted-active-owner"
active_child="$sweep_root/wilted-active-child"
mkdir "$active_owner" "$active_child"
active_owner_canonical="$(cd -P "$active_owner" 2>/dev/null && pwd)"
printf 'pid=%s\nstarted=%s\npath=%s\n' "$$" "$(ps -o lstart= -p "$$")" "$active_owner_canonical" >"$active_owner/.wilted-temp-owned"
mark_dead_owned "$active_child"
backdate "$active_owner" 48
backdate "$active_child" 48
sleep 20 >"$active_child/open" &
child_file_pid=$!
wilted_sweep_stale_temp_dirs "$sweep_root" 24 >/dev/null 2>&1
[[ -d "$active_owner" ]] && pass 'live marker owner without open root is preserved' || fail 'live marker owner was swept'
[[ -d "$active_child" ]] && pass 'active descendant file is preserved' || fail 'active child file root was swept'
kill "$child_file_pid" 2>/dev/null || true
wait "$child_file_pid" 2>/dev/null || true
visibility_unknown="$sweep_root/wilted-visibility-unknown"
mkdir "$visibility_unknown"
mark_dead_owned "$visibility_unknown"
backdate "$visibility_unknown" 48
visibility_bin="$hermetic_root/visibility-bin"
mkdir "$visibility_bin"
printf '#!/usr/bin/env bash\nexit 2\n' >"$visibility_bin/ps"
chmod +x "$visibility_bin/ps"
PATH="$visibility_bin:$PATH" wilted_sweep_stale_temp_dirs "$sweep_root" 24 >/dev/null 2>&1
[[ -d "$visibility_unknown" ]] && pass 'process-visibility failure preserves stale owned directory' || fail 'unverifiable owner was swept'
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
# fresh_dir, spec_dir, and undeletable_dir (three wilted-* entries still on disk
# afterward). The old code additionally re-added undeletable_dir a second
# time because it also incremented `kept` inline when its rm -rf failed.
if [[ "$sweep_output" != *'kept=3'* ]]; then
    fail "sweep did not report kept=3 (double-count regression?): $sweep_output"
else
    pass 'sweep reports the correct kept count'
fi

# A wrapper can be launched through a /var-style spelling while find reports
# the canonical path. The marker and sweep must compare that one identity, so a
# killed owner is reclaimed rather than retained forever by string mismatch.
slash_parent="$hermetic_root//slash-parent/"
slash_owned="$slash_parent/wilted-slash-spelling"
mkdir -p "$slash_owned"
wilted_temp_mark_owned "$slash_owned/"
marker_path="$(sed -n 's/^path=//p' "$slash_owned/.wilted-temp-owned")"
slash_owned_canonical="$(cd -P "$slash_owned" 2>/dev/null && pwd)"
[[ "$marker_path" == "$slash_owned_canonical" ]] || fail 'owned marker did not canonicalize its path'
printf 'pid=99999\nstarted=dead-owner\npath=%s\n' "$marker_path" >"$slash_owned/.wilted-temp-owned"
backdate "$slash_owned" 48
wilted_sweep_stale_temp_dirs "$slash_parent/" 24 >/dev/null 2>&1
[[ ! -d "$slash_owned" ]] && pass 'canonical slash spelling reclaims a crashed owned root' || fail 'slash spelling retained a crashed owned root'

# These exits occur before a native leg can start, so each uses the real wrapper
# under a dedicated parent and audit directory. No production build or TMPDIR
# sweep is involved.
failing_snapshot_checker="$hermetic_root/failing-snapshot.py"
printf 'import sys\nsys.exit(73)\n' >"$failing_snapshot_checker"
assert_gate_initialization_cleanup snapshot-failure 73 "WILTED_TEMP_LEAK_CHECKER=$failing_snapshot_checker"
marker_failure_bin="$hermetic_root/marker-failure-bin"
mkdir -p "$marker_failure_bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$marker_failure_bin/ps"
chmod +x "$marker_failure_bin/ps"
assert_gate_initialization_cleanup marker-failure 1 "PATH=$marker_failure_bin:$PATH"
assert_gate_initialization_cleanup invalid-timeout 2 'WILTED_NATIVE_LEG_TIMEOUT_SECONDS=0'
assert_gate_initialization_cleanup missing-runner 127 "WILTED_BOUNDED_RUNNER=$hermetic_root/no-runner"

# --- (a) wiring: a gate started after a killed prior run sweeps that run's
#     leftovers, never a genuinely concurrent one, and leaves nothing of its
#     own behind either ---
gate_tmpdir="$hermetic_root/gate-tmpdir"
mkdir -p "$gate_tmpdir"
killed_prior_run="$gate_tmpdir/wilted-native-gate.deadbeef"
concurrent_run="$gate_tmpdir/wilted-native-gate.stillalive"
mkdir -p "$killed_prior_run" "$concurrent_run"
mark_dead_owned "$killed_prior_run"
backdate "$killed_prior_run" 48
# concurrent_run is left at its natural (just-created) mtime, standing in for
# another gate invocation that started seconds ago and is still working.

gate_log="$hermetic_root/gate.log"
if ! env NATIVE_SELF_TEST=1 WILTED_MAC_UI=1 WILTED_TEMP_SWEEP_MAX_AGE_HOURS=24 TMPDIR="$gate_tmpdir" \
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
