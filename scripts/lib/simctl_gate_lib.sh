#!/usr/bin/env bash
# simctl_gate_lib.sh — shared simulator hygiene helpers for app test-gate.sh scripts.
#
# Source this file; it only defines functions and never executes anything on
# load, so it is safe to source under any caller shell-option combination
# (`set -e`, `set -u`, `set -o pipefail`, or none of those). It also never
# changes the caller's shell options itself, for the same reason: a sourced
# file runs in the caller's shell, and flipping options here would silently
# change behavior downstream of the `source` line.
#
# Functions:
#   gate_sim_create <app> <purpose> <device-type> <runtime>
#       Creates a disposable simulator named "<app>-gate-<pid>-<purpose>" via
#       `xcrun simctl create`, prints its UDID on stdout, and registers it for
#       shutdown+delete on the caller's EXIT. <device-type> and <runtime> are
#       forwarded verbatim to `simctl create` (device type / runtime
#       identifiers or names, as `simctl create` itself accepts).
#
#       Creating also sweeps: before making the first device for <app> in a
#       run, it calls `gate_sweep <app>` once. The EXIT trap below never runs
#       under SIGKILL, so a consumer that created without sweeping would leak
#       every simulator a killed run made; folding the sweep into create means
#       a consumer cannot get that pairing wrong by forgetting it.
#
#       Callers capture the UDID via `udid="$(gate_sim_create ...)"`, which
#       runs the whole function in a forked command-substitution subshell. A
#       `trap ... EXIT` set from inside that subshell would fire the instant
#       the subshell exits — immediately after this function returns, not at
#       the caller's real exit — so gate_sim_create does NOT set a trap
#       itself. Instead it records the UDID into a registry file (a
#       filesystem write, which — unlike shell state such as traps or
#       variables — survives the subshell boundary); a single EXIT trap,
#       installed once when this library is *sourced* (never inside a
#       subshell), reads that file at the caller's actual exit and deletes
#       everything in it. That source-time installation is itself composed
#       with whatever EXIT trap the caller already has, so sourcing this
#       library after a script's own `trap ... EXIT` accumulates cleanup
#       instead of clobbering it. INT/TERM get `exit`-routing traps at source
#       time only if the caller has none, so the EXIT cleanup also fires on
#       Ctrl-C/kill. Composition only works in this direction: source
#       this library AFTER the caller sets any EXIT trap of its own, not
#       before. A bare `trap ... EXIT` (not going through this library) that a
#       caller sets AFTER sourcing will silently overwrite ours — bash traps
#       have no chaining, only last-writer-wins — and this library's cleanup
#       would then never run. (Corollary: `source` this file directly in the
#       caller's shell, never as `x="$(source simctl_gate_lib.sh)"` or similar
#       — that would put the registration inside a subshell too and silently
#       disable cleanup.)
#
#   gate_derived_data
#       Prints a fresh `mktemp -d` DerivedData directory for this run. Callers
#       are responsible for passing it to `xcodebuild -derivedDataPath`; nothing
#       here registers cleanup for it (unlike simulators, a per-run DerivedData
#       directory does not leak host state that matters across runs, and
#       callers that want it removed on exit can register their own trap).
#
#   gate_ui_test_lock [--label <label>] [--simulator-udid <UDID>] <cmd...>
#       Runs <cmd...> through `~/.agent/bin/apple-ui-test-lock`, which
#       keeps host UI and legacy calls globally exclusive. With an explicit
#       disposable simulator UDID, only tests for the same simulator serialize;
#       separate devices may run together. <label> defaults to "Apple UI test".
#       Do NOT put a literal `--`
#       before <cmd...> — gate_ui_test_lock adds the separator
#       apple-ui-test-lock's own contract (`apple-ui-test-lock --label
#       <label> -- <cmd...>`) requires; a caller-supplied `--` would double up
#       and apple-ui-test-lock only strips one, leaving a stray `--` it tries
#       to execute as the command. Only wrap the XCUITest legs of a gate in
#       this — plain `xcodebuild build`/`swift test` legs do not need the lock
#       and would serialize for no reason.
#
#       It also cleans up after the leg: it snapshots the XCTestDevices clone
#       set before <cmd...> and deletes new Shutdown clones only after acquiring
#       the global exclusive lock, when no simulator lane can still own a clone.
#       This happens whether the leg passed or failed. That is the
#       actual fix for the clone leak — gate_sweep_xctest_clones' 24h sweep is
#       the backstop for the case this cannot cover, a run killed hard enough
#       that nothing after the lock helper ever executes.
#
#       Which means calling apple-ui-test-lock directly is no longer
#       equivalent: it still serializes, but it leaks a clone per run. Every
#       simulator UI leg across the consumers goes through this wrapper
#       (quizzler's three, wwpis' test plan, gradus' two iOS legs), and each
#       repo's selfcheck pins that in both directions. gradus' GradusMacUI leg
#       is the one deliberate exception — a macOS UI test runs on the host and
#       creates no simulator clone for this to reap.
#
#   gate_sweep <app>
#       Deletes this app's leftover "<app>-gate-*" simulators whose creator
#       PID is no longer live, regardless of age. Lists
#       devices via `xcrun simctl list devices -j`, parsed with python3.
#       Matches names strictly against the "<app>-gate-" prefix before
#       touching anything, so it never deletes another app's gate devices or
#       any simulator outside the gate naming convention. Prints the number of
#       devices it deleted on stdout; per-device detail goes to stderr.
#
#       gate_sim_create calls this automatically, so an explicit call is
#       optional -- it is still worth making when a gate wants to report the
#       swept count at start. Both paths record the same per-run marker, so
#       whichever runs first suppresses the other and no run sweeps twice.
#
#   gate_sweep_xctest_clones
#       Deletes xcodebuild's own leftover UI-test simulator clones older than
#       24h from ~/Library/Developer/XCTestDevices (override with
#       GATE_XCTEST_DEVICE_SET). Prints the number deleted on stdout;
#       per-device detail goes to stderr.
#
#       This is a *separate device set*, which is why gate_sweep cannot reach
#       these: `xcrun simctl list devices` enumerates only the default set, so
#       every clone xcodebuild fails to reclaim is invisible to it. Quizzler
#       accumulated 26 of them (4.1 GB each, 105 GB) over one night in August
#       2026 before anyone looked at the disk.
#
#       Unlike gate_sweep there is no name filter, and that is deliberate.
#       Clones are named by xcodebuild ("Clone 2 of iPhone 17"), not by the
#       gate, so a name pattern would be a guess about a private naming
#       convention that a future Xcode can change -- and the failure mode of a
#       stale guess is exactly the silent re-leak this function exists to stop.
#       Containment comes from the two properties that are actually stable:
#       the device must live inside the XCTestDevices set (a scratch set owned
#       by xcodebuild, which no one populates by hand), and it must be older
#       than the 24h cutoff. The set is shared by every app on the machine, so
#       this sweep is machine-wide rather than per-app; the cutoff is what
#       keeps a concurrently running gate's minutes-old clone out of range.
#
#       gate_sweep calls this automatically, once per run, so no consumer has
#       to add a call site. An explicit call is still useful for a gate that
#       wants to report the reclaimed count itself.
#
# All xcodebuild/xcodebuild-test destinations built against a UDID this
# library returns MUST use the `id=<UDID>` destination form, e.g.:
#   -destination "platform=iOS Simulator,id=$udid"
# never a name/OS-version destination — those can resolve to a stale or
# shared device instead of the disposable one `gate_sim_create` just made.

# The cleanup subprocesses source this file again after callers may have
# changed directories. Capture the source location now, while its relative
# path still resolves against the original working directory.
_GATE_LIB_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

# _gate_lib_append_exit_trap <command>
# Internal. Installs <command> so it runs on EXIT without discarding whatever
# EXIT trap is already registered. Only ever called at source time below (see
# the top-of-file note on why gate_sim_create itself must not call this).
# `trap -p EXIT` prints the existing handler already shell-quoted (e.g.
# `trap -- 'existing cmd' EXIT`); stripping the fixed `trap -- ` prefix and
# trailing ` EXIT` leaves a single already-quoted token that `eval`
# reconstitutes correctly, including when it is itself the product of a
# previous composition.
_gate_lib_append_exit_trap() {
    local new_cmd="$1"
    local previous
    previous="$(trap -p EXIT)"
    if [[ -n "$previous" ]]; then
        previous="${previous#trap -- }"
        previous="${previous% EXIT}"
        # Expanding now (not deferring to signal time) is deliberate: $previous
        # and $new_cmd are local variables that go out of scope when this
        # function returns, so the literal text must be captured into the trap
        # string at registration time or it would be gone by the time EXIT fires.
        # shellcheck disable=SC2064
        trap "eval ${previous}; ${new_cmd}" EXIT
    else
        # shellcheck disable=SC2064
        trap "${new_cmd}" EXIT
    fi
}

# _gate_lib_sweep_marker <app>
# Internal. Path of the per-run, per-app "already swept" marker. Derived from
# the registry path so it is unique to this run without a second mktemp, and
# kept on the filesystem rather than in a shell variable for exactly the reason
# the registry is: gate_sim_create runs inside a command-substitution subshell,
# so shell state it sets would not survive back to the caller. The app name is
# sanitized because it becomes a filename component.
_gate_lib_sweep_marker() {
    local app_key="${1//[^A-Za-z0-9._-]/_}"
    printf '%s\n' "${_GATE_LIB_SIM_REGISTRY}.swept.${app_key}"
}

# The marker key the machine-wide XCTestDevices sweep books itself under.
# Not an app name: that set is shared by every app on the host, so one sweep
# per run covers all of them. It goes through the same marker helpers so
# _gate_lib_cleanup_registered_sims' `.swept.*` glob removes it too.
_GATE_LIB_CLONE_SWEEP_KEY="__xctest_clones__"

# _gate_lib_already_swept <app>
# Internal. True once this app has been swept during this run.
_gate_lib_already_swept() {
    [[ -f "$(_gate_lib_sweep_marker "$1")" ]]
}

# _gate_lib_mark_swept <app>
# Internal. Records that this app has been swept during this run.
_gate_lib_mark_swept() {
    : > "$(_gate_lib_sweep_marker "$1")" 2>/dev/null || true
}

# _gate_lib_cleanup_registered_sims
# Internal. The EXIT-trap body: shuts down and deletes every UDID
# gate_sim_create recorded into the registry file, then removes the registry
# file itself. Safe to call more than once (e.g. if this library is sourced
# twice, composing two copies onto the trap) — a missing/empty registry is a
# silent no-op.
_gate_lib_cleanup_registered_sims() {
    # Markers are keyed off the registry path but are removed first: a run that
    # swept and then created nothing has no registry file, and the early return
    # below would otherwise leave its markers behind in TMPDIR.
    rm -f "${_GATE_LIB_SIM_REGISTRY}".swept.* 2>/dev/null || true
    [[ -f "$_GATE_LIB_SIM_REGISTRY" ]] || return 0
    local udid
    while IFS= read -r udid; do
        [[ -z "$udid" ]] && continue
        xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    done < "$_GATE_LIB_SIM_REGISTRY"
    rm -f "$_GATE_LIB_SIM_REGISTRY"
}

# Registry of simulator UDIDs gate_sim_create has created but not yet cleaned
# up, one UDID per line. Created once, at source time (in the real caller
# shell, not a subshell), so both this top-level registration and any later
# gate_sim_create call — even from inside a command-substitution subshell —
# agree on the same path.
_GATE_LIB_SIM_REGISTRY="$(mktemp "${TMPDIR:-/tmp}/gate-sim-registry.XXXXXX" 2>/dev/null)" || {
    echo "simctl_gate_lib.sh: failed to create simulator registry file" >&2
    # `return` covers the normal case (this file is sourced); `exit` is a
    # fallback for the unsupported case of running it directly, where
    # `return` fails and shellcheck (correctly, for the sourced case) can't
    # see that this line is reachable.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
}
_gate_lib_append_exit_trap "_gate_lib_cleanup_registered_sims"

# A caught INT/TERM does not run the EXIT trap unless the signal handler
# exits, so an untrapped Ctrl-C would leak every registered simulator until a
# later gate_sweep. Route both signals through exit (130/143, the conventional
# 128+signum codes) — but only where the caller hasn't installed their own
# handler, which must keep winning.
if [[ -z "$(trap -p INT)" ]]; then
    trap 'exit 130' INT
fi
if [[ -z "$(trap -p TERM)" ]]; then
    trap 'exit 143' TERM
fi

gate_sim_create() {
    if [[ "$#" -ne 4 ]]; then
        echo "gate_sim_create: usage: gate_sim_create <app> <purpose> <device-type> <runtime>" >&2
        return 1
    fi
    local app="$1" purpose="$2" device_type="$3" runtime="$4"
    if [[ -z "$app" || -z "$purpose" || -z "$device_type" || -z "$runtime" ]]; then
        echo "gate_sim_create: app, purpose, device-type, and runtime must all be non-empty" >&2
        return 1
    fi
    # Creating implies sweeping. The EXIT trap that deletes these devices never
    # runs under SIGKILL, so a gate script that does not sweep leaks every
    # simulator a killed run created; making the sweep a side effect of create
    # removes that failure mode instead of relying on each consumer to
    # remember. Runs at most once per app per run. stdout is discarded because
    # callers capture this function's stdout as the UDID and gate_sweep prints
    # its deleted-device count there; per-device detail on stderr still shows.
    if ! _gate_lib_already_swept "$app"; then
        gate_sweep "$app" >/dev/null || true
    fi
    local device_name="${app}-gate-$$-${purpose}"
    local udid
    if ! udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime" 2>&1)"; then
        echo "gate_sim_create: xcrun simctl create failed for '$device_name': $udid" >&2
        return 1
    fi
    if [[ ! "$udid" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]]; then
        echo "gate_sim_create: simctl create did not return a UDID for '$device_name': $udid" >&2
        return 1
    fi
    printf '%s\n' "$udid" >> "$_GATE_LIB_SIM_REGISTRY"
    printf '%s\n' "$udid"
}

gate_sim_cleanup() {
    if [[ "$#" -ne 1 || -z "$1" ]]; then
        echo "gate_sim_cleanup: usage: gate_sim_cleanup <UDID>" >&2
        return 1
    fi
    local udid="$1" registry_tmp
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    if ! xcrun simctl delete "$udid" >/dev/null 2>&1; then
        echo "gate_sim_cleanup: failed to delete $udid; EXIT cleanup will retry" >&2
        return 1
    fi
    registry_tmp="$(mktemp "${TMPDIR:-/tmp}/gate-sim-registry-update.XXXXXX")" || return 1
    if [[ -f "$_GATE_LIB_SIM_REGISTRY" ]]; then
        grep -vxF -- "$udid" "$_GATE_LIB_SIM_REGISTRY" >"$registry_tmp" || true
        cat "$registry_tmp" >"$_GATE_LIB_SIM_REGISTRY"
    fi
    rm -f "$registry_tmp"
}

gate_derived_data() {
    mktemp -d "${TMPDIR:-/tmp}/gate-derived-data.XXXXXX"
}

gate_ui_test_lock() {
    local label="Apple UI test"
    local simulator_udid=""
    while [[ "${1:-}" == "--label" || "${1:-}" == "--simulator-udid" ]]; do
        if [[ "$#" -lt 2 || -z "$2" ]]; then
            echo "gate_ui_test_lock: $1 requires a value" >&2
            return 1
        fi
        case "$1" in
            --label) label="$2" ;;
            --simulator-udid) simulator_udid="$2" ;;
        esac
        shift 2
    done
    # Defensive: this function owns the single "--" separator passed to the
    # lock helper. The direct command form callers port from invokes
    # apple-ui-test-lock as `--label "..." -- xcodebuild test ...`; if that
    # same "--" is carried over here verbatim it would double up (we add our
    # own below) and apple-ui-test-lock only strips one, leaving a literal
    # "--" it tries to exec. Strip a single leading "--" so a port that
    # changes only the command name still works.
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    if [[ "$#" -eq 0 ]]; then
        echo "gate_ui_test_lock: a command is required" >&2
        return 1
    fi
    local lock_bin="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"
    if [[ ! -x "$lock_bin" ]]; then
        echo "gate_ui_test_lock: lock helper not found or not executable: $lock_bin" >&2
        return 1
    fi
    # Clones are cleaned up here, per leg, rather than left to the 24h sweep.
    # This is the only place in the library that knows a UI-test run is about
    # to happen, and UI-test legs are the only thing that produces clones, so
    # it is also the only place that can bound the leak instead of mopping it
    # up a day later.
    local set_root before rc end_ts
    set_root="${GATE_XCTEST_DEVICE_SET:-$HOME/Library/Developer/XCTestDevices}"
    before="$(mktemp "${TMPDIR:-/tmp}/gate-clone-snapshot.XXXXXX")"
    _gate_lib_snapshot_clones "$set_root" >"$before" 2>/dev/null || true
    # `|| rc=$?` rather than a bare call followed by `rc=$?`: consumers source
    # this under `set -e`, which would abort the function on a failing leg
    # before the reap ever ran, and the reap has to happen whether the leg
    # passed or failed -- a crashed run is exactly when clones are left behind.
    local lock_args=(--label "$label")
    [[ -z "$simulator_udid" ]] || lock_args+=(--simulator-udid "$simulator_udid")
    rc=0
    local lock_pid lock_pid_file="${GATE_UI_TEST_LOCK_PID_FILE:-}"
    if [[ -n "$lock_pid_file" ]]; then
        "$lock_bin" "${lock_args[@]}" -- "$@" &
        lock_pid=$!
        printf '%s\n' "$lock_pid" >"$lock_pid_file"
        wait "$lock_pid" || rc=$?
        rm -f "$lock_pid_file"
    else
        "$lock_bin" "${lock_args[@]}" -- "$@" || rc=$?
    fi
    end_ts="$(date +%s)"
    # The child exited and released its lane lock. Wait for every other lane
    # to drain before enumerating the shared XCTestDevices set: a peer's clone
    # may be Shutdown briefly before xcodebuild boots it. The helper is sourced
    # in the child only to reuse the same contained clone parser and reaper.
    if [[ -d "$set_root" ]]; then
        "$lock_bin" --label "XCTest clone cleanup" -- bash -c \
            'source "$1"; _gate_lib_reap_new_clones "$2" "$3" "$4"' \
            _ "$_GATE_LIB_SELF" "$set_root" "$before" "$end_ts" || true
    fi
    rm -f "$before"
    return "$rc"
}

# _gate_lib_snapshot_clones <set-root>
# Internal. Emits the UDID of every device in the clone set, one per line;
# silent and successful when the set does not exist yet (a machine that has
# never run an XCUITest has no such directory).
_gate_lib_snapshot_clones() {
    local set_root="$1"
    [[ -z "$set_root" || ! -d "$set_root" ]] && return 0
    _gate_lib_list_devices --set "$set_root" | cut -f1
}

# _gate_lib_reap_new_clones <set-root> <snapshot-file> <end-ts>
# Internal. Deletes the clones this leg just created: present now, absent from
# <snapshot-file>, Shutdown, and born before <end-ts>. Reports what it deleted
# on stderr and returns 0 regardless -- a failed reap must never turn a passing
# leg red, because gate_sweep_xctest_clones will collect the remains anyway.
#
# All three conditions are load-bearing, and the third is the subtle one. The
# reap necessarily runs *after* the lock helper returns, so the lock is already
# released and the next holder can be creating its own clone while this loop
# runs. A brand-new clone is Shutdown until xcodebuild boots it, so the state
# check alone would delete it out from under a concurrent run. Its birth time
# cannot precede the moment our helper returned; ours were born minutes
# earlier. Hence the strict `birth < end_ts`.
#
# Requiring Shutdown rather than excluding Booted is likewise deliberate: it
# also spares Creating/Booting, and a device whose state simctl did not report
# fails safe by being left alone.
_gate_lib_reap_new_clones() {
    local set_root="$1" before="$2" end_ts="$3"
    [[ -z "$set_root" || ! -d "$set_root" ]] && return 0
    [[ -f "$before" ]] || return 0
    local udid name data_path state device_dir birth reaped=0
    while IFS=$'\t' read -r udid name data_path state; do
        [[ -z "$udid" ]] && continue
        case "$data_path" in
            "${set_root}/"*) ;;
            *) continue ;;
        esac
        grep -qxF -- "$udid" "$before" && continue
        [[ "$state" == "Shutdown" ]] || continue
        device_dir="$(dirname -- "$data_path")"
        birth="$(stat -f "%B" "$device_dir" 2>/dev/null || true)"
        [[ -z "$birth" ]] && continue
        (( birth < end_ts )) || continue
        if xcrun simctl --set "$set_root" delete "$udid" >/dev/null 2>&1; then
            reaped=$(( reaped + 1 ))
            echo "gate_ui_test_lock: reaped clone $name ($udid)" >&2
        else
            echo "gate_ui_test_lock: failed to reap clone $name ($udid)" >&2
        fi
    done < <(_gate_lib_list_devices --set "$set_root")
    (( reaped > 0 )) && echo "gate_ui_test_lock: reaped $reaped clone(s) left by this leg" >&2
    return 0
}

# _gate_lib_list_devices [simctl-global-args...]
# Internal. Emits "<udid>\t<name>\t<dataPath>\t<state>" per simulator, one line
# each. Read it with four fields: bash assigns the unconsumed remainder to the
# last variable, so a three-field read silently folds the state into dataPath
# and every later dirname/stat on it comes back empty.
# Any arguments are passed to simctl ahead of `list devices` so a caller can
# target a non-default device set (`--set <path>`). udid/name/dataPath come
# straight from simctl rather than being reconstructed from a hardcoded
# ~/Library/Developer/CoreSimulator/Devices path, so callers still find the
# right on-disk directory under a device-set override -- a hardcoded root
# would silently yield an empty birth time and sweep nothing.
_gate_lib_list_devices() {
    xcrun simctl "$@" list devices -j 2>/dev/null | python3 -c '
import json
import sys

try:
    inventory = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError):
    sys.exit(0)

for devices in inventory.get("devices", {}).values():
    for device in devices:
        udid = device.get("udid", "")
        name = device.get("name", "")
        data_path = device.get("dataPath", "")
        state = device.get("state", "")
        if udid and name:
            print(f"{udid}\t{name}\t{data_path}\t{state}")
'
}

gate_sweep() {
    if [[ "$#" -ne 1 ]]; then
        echo "gate_sweep: usage: gate_sweep <app>" >&2
        return 1
    fi
    local app="$1"
    if [[ -z "$app" ]]; then
        echo "gate_sweep: app must be non-empty" >&2
        return 1
    fi
    # Mark before doing the work, not after: gate_sim_create consults this to
    # decide whether it still owes a lazy sweep, and a sweep that fails hard
    # should not make every subsequent create retry it.
    _gate_lib_mark_swept "$app"
    local lock_bin="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"
    local swept=0 output rc
    if [[ ! -x "$lock_bin" ]]; then
        echo "gate_sweep: lock helper not found or not executable: $lock_bin" >&2
        rc=1
    elif output="$("$lock_bin" --if-available --label "simulator sweep $app" -- bash -c \
        'source "$1"; _gate_lib_sweep_app_unlocked "$2"' \
        _ "$_GATE_LIB_SELF" "$app")"; then
        swept="$output"
        rc=0
    else
        rc=$?
    fi
    if [[ "$rc" -eq 75 ]]; then
        echo "gate_sweep: deferred $app while a UI lane is active" >&2
        rc=0
    elif [[ "$rc" -ne 0 ]]; then
        echo "gate_sweep: lock or sweep failed for $app (status $rc)" >&2
    fi
    # The clone set is distinct. Never nest two global exclusive locks.
    if ! _gate_lib_already_swept "$_GATE_LIB_CLONE_SWEEP_KEY"; then
        # shellcheck disable=SC2119 # takes no arguments; the guard below rejects any
        gate_sweep_xctest_clones >/dev/null || true
    fi
    printf '%s\n' "$swept"
    return "$rc"
}

_gate_lib_sweep_app_unlocked() {
    local app="$1"
    local swept udid name data_path state creator_pid
    local name_tail creator_pid
    swept=0
    while IFS=$'\t' read -r udid name data_path state; do
        [[ -z "$udid" ]] && continue
        case "$name" in
            "${app}-gate-"*) ;;
            *) continue ;; # never touch a device outside this app's gate naming convention
        esac
        # $$ in gate_sim_create names the original gate shell even when the
        # function runs inside command substitution. A live creator still owns
        # its device when the simulator is Shutdown between test legs.
        name_tail="${name#"${app}-gate-"}"
        creator_pid="${name_tail%%-*}"
        if [[ ! "$creator_pid" =~ ^[1-9][0-9]*$ ]]; then
            echo "gate_sweep: ownership hold $name ($udid) reason=invalid-creator-pid state=$state" >&2
            continue
        fi
        if kill -0 "$creator_pid" 2>/dev/null; then
            echo "gate_sweep: ownership hold $name ($udid) reason=creator-live pid=$creator_pid state=$state" >&2
            continue
        fi
        if [[ "$state" != "Shutdown" ]]; then
            echo "gate_sweep: ownership hold $name ($udid) reason=state-not-shutdown state=$state creator_pid=$creator_pid" >&2
            continue
        fi
        if xcrun simctl delete "$udid" >/dev/null 2>&1; then
            swept=$(( swept + 1 ))
            echo "gate_sweep: deleted stale $name ($udid) creator_pid=$creator_pid" >&2
        else
            echo "gate_sweep: failed to delete stale $name ($udid) creator_pid=$creator_pid" >&2
        fi
    done < <(_gate_lib_list_devices)
    printf '%s\n' "$swept"
}

# shellcheck disable=SC2120 # the arity guard exists to reject a mistaken argument
gate_sweep_xctest_clones() {
    if [[ "$#" -ne 0 ]]; then
        echo "gate_sweep_xctest_clones: usage: gate_sweep_xctest_clones" >&2
        return 1
    fi
    # Mark before the work, for the same reason gate_sweep does: a sweep that
    # fails hard must not make every later create retry it.
    _gate_lib_mark_swept "$_GATE_LIB_CLONE_SWEEP_KEY"
    local set_root="${GATE_XCTEST_DEVICE_SET:-$HOME/Library/Developer/XCTestDevices}"
    if [[ -z "$set_root" || ! -d "$set_root" ]]; then
        printf '%s\n' 0
        return 0
    fi
    # A stale sweep is opportunistic: waiting for an active UI lane here would
    # prevent a second project from creating its own disposable simulator and
    # running concurrently. The next gate can retry when the host is idle.
    local lock_bin="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"
    if [[ ! -x "$lock_bin" ]]; then
        echo "gate_sweep_xctest_clones: lock helper not found or not executable: $lock_bin" >&2
        return 1
    fi
    local output rc
    if output="$("$lock_bin" --if-available --label "XCTest clone sweep" -- bash -c \
        'source "$1"; _gate_lib_sweep_xctest_clones_unlocked "$2"' \
        _ "$_GATE_LIB_SELF" "$set_root")"; then
        printf '%s\n' "$output"
        return 0
    else
        rc=$?
    fi
    if [[ "$rc" -eq 75 ]]; then
        echo 'gate_sweep_xctest_clones: deferred while a UI lane is active' >&2
        printf '%s\n' 0
        return 0
    fi
    echo "gate_sweep_xctest_clones: lock or sweep failed (status $rc)" >&2
    return "$rc"
}

_gate_lib_sweep_xctest_clones_unlocked() {
    local set_root="$1"
    local now cutoff swept udid name data_path state device_dir birth
    now="$(date +%s)"
    cutoff=$(( now - 86400 ))
    swept=0
    while IFS=$'\t' read -r udid name data_path state; do
        [[ -z "$udid" ]] && continue
        # Membership in the set is the containment check (see the header note
        # on why there is no name filter). simctl was asked for this set, so
        # this only fails if simctl reported a device from somewhere else --
        # in which case deleting it is not this function's business.
        case "$data_path" in
            "${set_root}/"*) ;;
            *) continue ;;
        esac
        # dataPath is the device's .../data subdirectory; its parent is the
        # device root, created once when xcodebuild cloned it, which is the
        # birth-time anchor that survives the test run writing into data/.
        device_dir="$(dirname -- "$data_path")"
        birth="$(stat -f "%B" "$device_dir" 2>/dev/null || true)"
        [[ -z "$birth" ]] && continue
        if (( birth < cutoff )) && [[ "$state" == "Shutdown" ]]; then
            # A Booted clone may still belong to an unwrapped Xcode run. Leave
            # it for an ownership check instead of shutting it down here.
            if xcrun simctl --set "$set_root" delete "$udid" >/dev/null 2>&1; then
                swept=$(( swept + 1 ))
                echo "gate_sweep_xctest_clones: deleted stale clone $name ($udid)" >&2
            else
                echo "gate_sweep_xctest_clones: failed to delete stale clone $name ($udid)" >&2
            fi
        elif (( birth < cutoff )); then
            echo "gate_sweep_xctest_clones: stale clone $name ($udid) state=$state needs ownership check" >&2
        fi
    done < <(_gate_lib_list_devices --set "$set_root")
    printf '%s\n' "$swept"
}
