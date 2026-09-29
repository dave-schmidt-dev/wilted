#!/usr/bin/env bash
# Sweeps Wilted's own abandoned temp directories before making another one.
#
# Every gate leg, probe, and fixture launch mints a directory under $TMPDIR and
# removes it on the way out. The removal is a trap, and traps do not run under
# SIGKILL, a harness timeout that kills the process group, or a crash -- and
# XCUITest terminates the app it is driving by design, so the fixture launches
# have no exit path at all. macOS only purges $TMPDIR at boot, and only entries
# untouched for three days, so on a machine that runs for weeks nothing
# collects them in between. Measured 2026-09-04: 1,019 wilted-* entries, of
# which 587 were older than three days and 4.9 GB came back when they went.
#
# The sweep is only a crash backstop. Age is never ownership: it may remove a
# stale root only when its creator marked it as Wilted-owned and no process
# currently has it open. Borrowed, unmarked, symlinked, or unverifiable roots
# remain evidence for an explicit owner review.

# Default age past which an untouched wilted-* temp directory is abandoned.
WILTED_TEMP_SWEEP_MAX_AGE_HOURS="${WILTED_TEMP_SWEEP_MAX_AGE_HOURS:-24}"

# Removes abandoned wilted-* entries from a temp root.
#
#   $1  temp root to sweep       (default: ${TMPDIR:?TMPDIR must be set})
#   $2  age cutoff in hours      (default: WILTED_TEMP_SWEEP_MAX_AGE_HOURS)
#
# Prints one `temp.sweep` line to stderr and never fails the caller: this is
# housekeeping in front of real work, and a temp directory that cannot be
# removed (another user's, or one being written right now) is not a reason to
# refuse to run the gate.
wilted_sweep_stale_temp_dirs() {
    local root="${1:-${TMPDIR:?TMPDIR must be set}}"
    local max_age_hours="${2:-$WILTED_TEMP_SWEEP_MAX_AGE_HOURS}"
    local removed=0 kept=0 entry owner_marker live_status live_output owner_pid owner_started owner_status owner_output owner_path

    [[ -d "$root" && ! -L "$root" ]] || return 0
    root="$(cd -P "$root" 2>/dev/null && pwd)" || return 0
    [[ -n "$root" && -d "$root" && ! -L "$root" ]] || return 0

    # `-mtime +N` counts whole days and rounds the wrong way for an hourly
    # cutoff, so the cutoff is a reference file `find` compares against.
    local reference
    reference="$(mktemp "${root%/}/.wilted-temp-sweep.XXXXXX")" || return 0
    touch -t "$(date -v-"${max_age_hours}"H '+%Y%m%d%H%M.%S')" "$reference" 2>/dev/null || {
        rm -f "$reference"
        return 0
    }

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        # Re-validate the prefix here, not just in the find that built this
        # list: this loop is the thing that actually deletes, and it must
        # refuse on its own even if a future edit changes how entries reach it.
        [[ "$(basename -- "$entry")" == wilted-* ]] || continue
        # Never follow a symlink, remove unknown roots, or infer ownership from
        # a prefix. The marker is created by the owning wrapper immediately
        # after mktemp succeeds.
        [[ -d "$entry" && ! -L "$entry" ]] || continue
        owner_marker="$entry/.wilted-temp-owned"
        [[ -f "$owner_marker" && ! -L "$owner_marker" ]] || continue
        owner_pid="$(sed -n 's/^pid=//p' "$owner_marker")"
        owner_started="$(sed -n 's/^started=//p' "$owner_marker")"
        owner_path="$(sed -n 's/^path=//p' "$owner_marker")"
        [[ "$owner_pid" =~ ^[1-9][0-9]*$ && -n "$owner_started" && "$owner_path" == "$entry" ]] || continue
        set +e
        owner_output="$(ps -o lstart= -p "$owner_pid" 2>&1)"
        owner_status=$?
        set -e
        # Only ps(1)'s documented missing-process result establishes absence.
        # Permission and inspection errors are indistinguishable from a live
        # owner to this safety backstop, so they remain untouched.
        if (( owner_status == 0 )); then
            [[ -n "$owner_output" ]] && continue
            continue
        fi
        [[ "$owner_status" -eq 1 && -z "$owner_output" ]] || continue
        # A live descriptor proves this root is still in use even if the mtime
        # is old. If lsof cannot answer, preserve it rather than guessing.
        set +e
        live_output="$(lsof -t +D "$entry" 2>&1)"
        live_status=$?
        set -e
        [[ "$live_status" -eq 1 && -z "$live_output" ]] || continue
        if rm -rf "$entry" 2>/dev/null; then
            removed=$((removed + 1))
        fi
    done < <(find "$root" -maxdepth 1 -name 'wilted-*' ! -newer "$reference" -print 2>/dev/null)

    # `kept` is a fresh post-sweep count, not a running tally: a survivor is a
    # survivor whether it was too young to target or targeted and failed to
    # remove, and counting it in both places double-counted every removal
    # failure against the entries still sitting there afterward.
    kept="$(find "$root" -maxdepth 1 -name 'wilted-*' -print 2>/dev/null | wc -l | tr -d ' ')"
    rm -f "$reference"
    printf 'temp.sweep root=%s max_age_hours=%s removed=%s kept=%s\n' \
        "$root" "$max_age_hours" "$removed" "$kept" >&2
}
