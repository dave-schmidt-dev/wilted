#!/usr/bin/env bash
# Run one command in an owned spec TMPDIR, bounded and cleaned on every exit.
set -u
if (( $# == 0 )); then
    printf 'usage: %s command [args...]\n' "${0##*/}" >&2
    exit 2
fi
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-temp-state.sh
source "$script_root/lib/test-temp-state.sh"
scratch_parent="${TMPDIR:?TMPDIR must be set}"
[[ -d "$scratch_parent" ]] || { printf 'spec-scratch.error temp root is missing\n' >&2; exit 2; }
scratch_parent="$(cd -P "$scratch_parent" && pwd)" || exit 2
scratch=""
child_pid=""
launching=0
signal_status=0
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    trap '' INT TERM
    if [[ -n "$child_pid" ]]; then
        kill -TERM "$child_pid" 2>/dev/null || true
        # run-bounded owns descendant termination and reaping. Killing its
        # supervisor early would let the watchdog outlive this parent root.
        wait "$child_pid" 2>/dev/null || true
    fi
    [[ -n "$scratch" && "$scratch" == "$scratch_parent"/wilted-spec.* && -d "$scratch" && ! -L "$scratch" ]] && rm -rf "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'signal_status=130; [[ "$launching" == 1 ]] || exit 130' INT
trap 'signal_status=143; [[ "$launching" == 1 ]] || exit 143' TERM
scratch="$(mktemp -d "$scratch_parent/wilted-spec.XXXXXXXX")" || exit 2
wilted_temp_mark_owned "$scratch" || exit 2
runner="$script_root/run-bounded.py"
timeout_seconds="${WILTED_SPEC_SCRATCH_TIMEOUT_SECONDS:-1800}"
[[ -f "$runner" && "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || exit 2
export WILTED_SPEC_SCRATCH="$scratch"
export TMPDIR="$scratch/"
launching=1
python3 "$runner" --timeout-seconds "$timeout_seconds" -- "$@" &
child_pid=$!
launching=0
(( signal_status == 0 )) || exit "$signal_status"
if wait "$child_pid"; then status=0; else status=$?; fi
child_pid=""
exit "$status"
