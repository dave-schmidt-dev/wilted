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
# So the durable fix is a sweep at startup rather than more trap coverage. The
# age cutoff is the whole safety argument: a directory nothing has touched for
# a day belongs to a run that is not coming back, and a concurrent run's
# directory is minutes old.

# Default age past which an untouched wilted-* temp directory is abandoned.
WILTED_TEMP_SWEEP_MAX_AGE_HOURS="${WILTED_TEMP_SWEEP_MAX_AGE_HOURS:-24}"

# Removes abandoned wilted-* entries from a temp root.
#
#   $1  temp root to sweep       (default: ${TMPDIR:-/tmp})
#   $2  age cutoff in hours      (default: WILTED_TEMP_SWEEP_MAX_AGE_HOURS)
#
# Prints one `temp.sweep` line to stderr and never fails the caller: this is
# housekeeping in front of real work, and a temp directory that cannot be
# removed (another user's, or one being written right now) is not a reason to
# refuse to run the gate.
wilted_sweep_stale_temp_dirs() {
    local root="${1:-${TMPDIR:-/tmp}}"
    local max_age_hours="${2:-$WILTED_TEMP_SWEEP_MAX_AGE_HOURS}"
    local removed=0 kept=0 entry

    [[ -d "$root" ]] || return 0

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
        # Never follow a symlink out of the temp root.
        [[ -L "$entry" ]] && { rm -f "$entry" 2>/dev/null && removed=$((removed + 1)); continue; }
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
