#!/usr/bin/env bash
# Run a command with a fresh Wilted spec TMPDIR and clean it on exit/signals.
set -u
if (( $# == 0 )); then
    printf 'usage: %s command [args...]\n' "${0##*/}" >&2
    exit 2
fi
scratch_parent="${TMPDIR:-/tmp}"
[[ -d "$scratch_parent" ]] || { printf 'spec-scratch.error temp root is missing\n' >&2; exit 2; }
scratch_parent="$(cd -P "$scratch_parent" && pwd)" || exit 2
scratch="$(mktemp -d "$scratch_parent/wilted-spec.XXXXXXXX")" || exit 2
child_pid=""
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$child_pid" ]]; then kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi
    if [[ "$scratch" == "$scratch_parent"/wilted-spec.* && -d "$scratch" && ! -L "$scratch" ]]; then rm -rf "$scratch"; fi
    exit "$status"
}
on_signal() {
    local signal="$1" code="$2"
    trap - INT TERM
    if [[ -n "$child_pid" ]]; then kill -s "$signal" "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi
    child_pid=""
    exit "$code"
}
trap cleanup EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
export WILTED_SPEC_SCRATCH="$scratch"
export TMPDIR="$scratch/"
"$@" &
child_pid=$!
set +e
wait "$child_pid"
status=$?
set -e
child_pid=""
exit "$status"
