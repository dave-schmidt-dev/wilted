#!/usr/bin/env bash
set -euo pipefail

# Proves the Mac installer refuses to leave two bundles claiming one identifier.
#
# Hermetic on purpose: it never builds, never writes to /Applications, and never
# touches LaunchServices. It exercises the identity scan against planted fake
# bundles, and asserts by inspection that the installer calls the sweep and the
# resolution check -- the two steps that cannot be tested without seizing the
# real launch database.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/scripts/install-mac-app.sh"
library="$repo_root/scripts/lib/app-identity.sh"
bundle_id='com.zerodelta.wilted.mac'
failures=0

fail() {
    printf 'install-identity.fail %s\n' "$*" >&2
    failures=$((failures + 1))
}

pass() { printf 'install-identity.ok %s\n' "$*" >&2; }

[[ -f "$library" ]] || { fail "missing $library"; exit 1; }
# shellcheck source=../scripts/lib/app-identity.sh
source "$library"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-install-identity.XXXXXX")"
owner_pid=''
cleanup() {
    if [[ -n "$owner_pid" ]]; then
        kill "$owner_pid" 2>/dev/null || true
        wait "$owner_pid" 2>/dev/null || true
    fi
    [[ -d "$tmp_root" ]] && rm -rf "$tmp_root"
}
trap cleanup EXIT

guard_bin="$tmp_root/bin"
guard_destination="$tmp_root/guard-destination"
journal="$tmp_root/library.sqlite"
mkdir -p "$guard_bin" "$guard_destination"

# By default an inactive guard invocation reaches generation, whose deliberate
# status keeps the rest of the installer outside the test. The complete-build
# mode plants a valid synthetic product and can activate the process signal
# during that build to exercise the last-safe-point recheck.
printf '%s\n' '#!/usr/bin/env bash' \
    ': >"$WILTED_TEST_GENERATE_MARKER"' \
    '[[ "${WILTED_TEST_COMPLETE_BUILD:-0}" == 1 ]] || exit 42' \
    >"$guard_bin/xcodegen"
printf '%s\n' '#!/usr/bin/env bash' \
    'app="$WILTED_TEST_DERIVED/Build/Products/Debug/WiltedMac.app"' \
    'mkdir -p "$app/Contents"' \
    '/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.zerodelta.wilted.mac" "$app/Contents/Info.plist" >/dev/null' \
    '[[ "${WILTED_TEST_ACTIVATE_DURING_BUILD:-0}" == 1 ]] && : >"$WILTED_TEST_ACTIVE_MARKER"' \
    >"$guard_bin/xcodebuild"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "${WILTED_TEST_PIPELINE_RUNNING:-0}" == 1 || -e "$WILTED_TEST_ACTIVE_MARKER" ]]' \
    >"$guard_bin/pgrep"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$guard_bin/codesign"
printf '%s\n' '#!/usr/bin/env bash' ': >"$WILTED_TEST_REPLACE_MARKER"' 'exit 1' >"$guard_bin/ditto"
printf '%s\n' '#!/usr/bin/env bash' ': >"$WILTED_TEST_QUIT_MARKER"' 'exit 0' >"$guard_bin/osascript"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "${WILTED_TEST_APP_RUNNING:-0}" == 1 ]] && printf "%s %s\\n" "$WILTED_TEST_OWNER_PID" "$WILTED_TEST_OWNER_EXECUTABLE"' \
    >"$guard_bin/ps"
chmod +x "$guard_bin/xcodegen" "$guard_bin/xcodebuild" "$guard_bin/pgrep" \
    "$guard_bin/codesign" "$guard_bin/ditto" "$guard_bin/osascript" "$guard_bin/ps"

owner_app="$tmp_root/Owner.app"
mkdir -p "$owner_app/Contents/MacOS"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" \
    "$owner_app/Contents/Info.plist" >/dev/null
owner_executable="$owner_app/Contents/MacOS/WiltedMac"
/bin/sleep 60 &
owner_pid=$!

run_guard() {
    local output_file="$1" pipeline_running="${2:-0}" app_running="${3:-0}"
    local complete_build="${4:-0}" activate_during_build="${5:-0}"
    PATH="$guard_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        WILTED_INSTALL_LIBRARY_URL="$journal" \
        WILTED_INSTALL_DERIVED_DATA_PATH="$tmp_root/derived" \
        WILTED_TEST_PIPELINE_RUNNING="$pipeline_running" \
        WILTED_TEST_APP_RUNNING="$app_running" \
        WILTED_TEST_OWNER_PID="$owner_pid" \
        WILTED_TEST_OWNER_EXECUTABLE="$owner_executable" \
        WILTED_TEST_COMPLETE_BUILD="$complete_build" \
        WILTED_TEST_ACTIVATE_DURING_BUILD="$activate_during_build" \
        WILTED_TEST_GENERATE_MARKER="$tmp_root/generated" \
        WILTED_TEST_ACTIVE_MARKER="$tmp_root/active" \
        WILTED_TEST_DERIVED="$tmp_root/derived" \
        WILTED_TEST_QUIT_MARKER="$tmp_root/quit" \
        WILTED_TEST_REPLACE_MARKER="$tmp_root/replaced" \
        bash "$installer" "$guard_destination" >"$output_file" 2>&1
}

assert_guard_refuses() {
    local output_file="$1" signal="$2" pipeline_running="${3:-0}" app_running="${4:-0}"
    rm -f "$tmp_root/generated" "$tmp_root/active" "$tmp_root/replaced"
    if run_guard "$output_file" "$pipeline_running" "$app_running"; then
        fail "$signal did not stop installation"
    elif ! grep -Fqx 'install.error preparation is active; wait for it to finish or stop it in Wilted, then retry' "$output_file"; then
        fail "$signal did not produce the concise active-preparation message"
    elif [[ -e "$tmp_root/generated" ]]; then
        fail "$signal was detected only after installation work began"
    else
        pass "$signal stops installation before build or replacement"
    fi
}

# A live worker is sufficient positive evidence even with no journal store.
# The PATH-scoped pgrep stub avoids reading the host process list.
assert_guard_refuses "$tmp_root/process-guard.out" 'live wilted_pipeline process' 1

# A podcast journal with no terminalResult blocks only when a live app process
# credibly owns it. Synthetic identifiers and status JSON stay inside tmp.
sqlite3 "$journal" \
    "CREATE TABLE ZPREPARATIONRECORD (ZREQUESTID TEXT, ZSTATUSDATA BLOB); INSERT INTO ZPREPARATIONRECORD VALUES ('podcast-prepare|fixture', '{\"detail\":\"working\"}');"
assert_guard_refuses "$tmp_root/journal-owner-guard.out" 'non-terminal podcast journal with live owner' 0 1

# The same unfinished row without a live owner may be crash residue. It must
# not strand installation behind advice that cannot clear it.
rm -f "$tmp_root/generated"
if run_guard "$tmp_root/crashed-journal.out"; then
    fail 'crashed journal unexpectedly completed the stubbed installer'
elif [[ ! -e "$tmp_root/generated" ]]; then
    fail 'crashed journal without live owner blocked installation'
elif grep -Fq 'preparation is active' "$tmp_root/crashed-journal.out"; then
    fail 'crashed journal without live owner was reported as active'
else
    pass 'crashed journal without live owner preserves install flow'
fi

# Adding a terminal row makes the same request inactive. The installer must
# pass the guard and reach the deliberately stubbed project-generation step.
sqlite3 "$journal" \
    "INSERT INTO ZPREPARATIONRECORD VALUES ('podcast-prepare|fixture', '{\"terminalResult\":{\"outcome\":\"succeeded\"}}');"
rm -f "$tmp_root/generated"
if run_guard "$tmp_root/inactive-guard.out"; then
    fail 'inactive guard unexpectedly completed the stubbed installer'
elif [[ ! -e "$tmp_root/generated" ]]; then
    fail 'inactive process and terminal journal did not pass the guard'
elif grep -Fq 'preparation is active' "$tmp_root/inactive-guard.out"; then
    fail 'terminal journal was reported as active'
else
    pass 'inactive process and terminal journal preserve install flow'
fi

# A preparation can start after the first check while xcodebuild runs. The
# second check must observe it before any app quit or bundle replacement.
rm -rf "$tmp_root/derived"
rm -f "$tmp_root/generated" "$tmp_root/active" "$tmp_root/quit" "$tmp_root/replaced"
if run_guard "$tmp_root/late-activation.out" 0 1 1 1; then
    fail 'preparation activated during build did not stop installation'
elif [[ ! -e "$tmp_root/active" ]]; then
    fail 'late-activation fixture did not reach the synthetic build'
elif ! grep -Fq 'preparation is active' "$tmp_root/late-activation.out"; then
    fail 'late activation did not produce the active-preparation message'
elif [[ -e "$tmp_root/quit" || -e "$tmp_root/replaced" ]]; then
    fail 'late activation was detected only after app quit or bundle replacement began'
else
    pass 'preparation activated during build stops before quit or replacement'
fi

plant_bundle() {
    local path="$1" identifier="$2"
    mkdir -p "$path/Contents/MacOS"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string '"$identifier" \
        "$path/Contents/Info.plist" >/dev/null
}

destination="$tmp_root/Applications"
mkdir -p "$destination"
target="$destination/WiltedMac.app"

# 1. A clean destination holding only the target reports no conflict.
plant_bundle "$target" "$bundle_id"
conflicts="$(wilted_conflicting_bundles "$destination" "$bundle_id" "$target")"
if [[ -n "$conflicts" ]]; then
    fail "clean destination reported conflicts: $conflicts"
else
    pass 'clean destination has no conflict'
fi

# 2. A second bundle claiming the same identifier is reported by path. This is
#    the 2026-09-01 failure: /Applications/Wilted.app and
#    /Applications/WiltedMac.app both claimed com.zerodelta.wilted.mac, and the
#    installer's one-path check saw nothing wrong.
plant_bundle "$destination/Wilted.app" "$bundle_id"
conflicts="$(wilted_conflicting_bundles "$destination" "$bundle_id" "$target")"
if [[ "$conflicts" != "$destination/Wilted.app" ]]; then
    fail "planted duplicate not reported; got: ${conflicts:-<none>}"
else
    pass 'planted duplicate is reported by path'
fi

# 3. An unrelated app in the destination is not a conflict.
plant_bundle "$destination/Unrelated.app" 'com.example.unrelated'
conflicts="$(wilted_conflicting_bundles "$destination" "$bundle_id" "$target")"
if [[ "$conflicts" != "$destination/Wilted.app" ]]; then
    fail "unrelated bundle changed the conflict set: ${conflicts:-<none>}"
else
    pass 'unrelated identifiers are ignored'
fi

# 4. A duplicate one folder down is still a duplicate; LaunchServices does not
#    care that macOS groups some apps into subfolders.
mkdir -p "$destination/Utilities"
plant_bundle "$destination/Utilities/WiltedMac.app" "$bundle_id"
conflicts="$(wilted_conflicting_bundles "$destination" "$bundle_id" "$target")"
if ! grep -Fq "$destination/Utilities/WiltedMac.app" <<<"$conflicts"; then
    fail "nested duplicate not reported; got: ${conflicts:-<none>}"
else
    pass 'nested duplicate is reported'
fi

# 5. Nested helper apps inside a bundle are not scanned; they carry their own
#    identifiers and are not separately launchable candidates.
rm -rf "$destination/Utilities" "$destination/Wilted.app"
plant_bundle "$target/Contents/Library/LoginItems/Helper.app" "$bundle_id"
conflicts="$(wilted_conflicting_bundles "$destination" "$bundle_id" "$target")"
if [[ -n "$conflicts" ]]; then
    fail "descended into the target bundle: $conflicts"
else
    pass 'nested helper apps are not scanned'
fi

# 6. A missing destination is not a crash.
if ! wilted_conflicting_bundles "$tmp_root/absent" "$bundle_id" "$target" >/dev/null; then
    fail 'scanning a missing directory returned non-zero'
else
    pass 'missing destination is handled'
fi

# 7. Identifier read back from a planted bundle.
if [[ "$(wilted_bundle_identifier "$target")" != "$bundle_id" ]]; then
    fail 'wilted_bundle_identifier did not read the planted identifier'
else
    pass 'identifier is read from Info.plist'
fi

# 8. The registration dump parser survives being handed nothing.
if ! wilted_registered_bundle_paths 'com.example.nothing.registered' >/dev/null 2>&1; then
    fail 'wilted_registered_bundle_paths returned non-zero for an unregistered id'
else
    pass 'unregistered identifier is handled'
fi

# 9. Stale products under the repo's build roots are deleted, the kept product
#    and other identifiers are not, and nothing outside those roots is touched.
#    This is the 2026-09-01 relaunch failure: an old build/quickcheck app
#    outlived the registration sweep and won the next click.
fake_repo="$tmp_root/repo"
kept="$fake_repo/.build/mac-install/Build/Products/Debug/WiltedMac.app"
stale="$fake_repo/build/quickcheck/Build/Products/Debug/WiltedMac.app"
runner="$fake_repo/build/quickcheck/Build/Products/Debug/WiltedMacUITests-Runner.app"
outside="$tmp_root/elsewhere/WiltedMac.app"
plant_bundle "$kept" "$bundle_id"
plant_bundle "$stale" "$bundle_id"
plant_bundle "$runner" 'com.zerodelta.wilted.mac.uitests.xctrunner'
plant_bundle "$outside" "$bundle_id"
pruned="$(wilted_prune_build_products "$fake_repo" "$bundle_id" "$kept")"
if [[ "$pruned" != "$stale" ]]; then
    fail "prune reported the wrong set; got: ${pruned:-<none>}"
elif [[ -d "$stale" ]]; then
    fail 'prune reported the stale product but left it in place'
elif [[ ! -d "$kept" || ! -d "$runner" || ! -d "$outside" ]]; then
    fail 'prune removed the kept product, another identifier, or a bundle outside the repo'
else
    pass 'stale build products are pruned; kept, foreign, and outside bundles survive'
fi
if ! wilted_prune_build_products "$tmp_root/absent" "$bundle_id" "$kept" >/dev/null; then
    fail 'pruning a repo without build roots returned non-zero'
else
    pass 'missing build roots are handled'
fi

# 10. A running copy is found by the identifier of the bundle it runs from,
#     wherever that bundle is. A symlink to a system binary stands in for the
#     app: a copied one is killed by the platform-binary check and raises a
#     crash dialog, and a script's `comm` is its interpreter.
running_app="$tmp_root/Running.app"
mkdir -p "$running_app/Contents/MacOS"
ln -s /bin/sleep "$running_app/Contents/MacOS/Running"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.example.wilted-install-test' \
    "$running_app/Contents/Info.plist" >/dev/null
"$running_app/Contents/MacOS/Running" 30 &
running_pid=$!
sleep 0.3
found="$(wilted_running_bundle_pids 'com.example.wilted-install-test')"
unrelated="$(wilted_running_bundle_pids 'com.example.wilted-install-test.nobody')"
kill "$running_pid" 2>/dev/null || true
wait "$running_pid" 2>/dev/null || true
if [[ "$found" != "$running_pid" ]]; then
    fail "running bundle pid not found; expected $running_pid, got: ${found:-<none>}"
elif [[ -n "$unrelated" ]]; then
    fail "an unrelated identifier matched running pids: $unrelated"
else
    pass 'running copies are found by bundle identifier, not install path'
fi

# 11. The installer waits for the process list to empty rather than trusting
#     that a quit or a signal was honoured. A copy that ignores the request
#     times the wait out; one that exits ends it early.
"$running_app/Contents/MacOS/Running" 30 &
running_pid=$!
sleep 0.3
if wilted_wait_for_bundle_exit 'com.example.wilted-install-test' 1; then
    fail 'wait reported exit while the copy was still running'
else
    pass 'wait times out while a copy is still running'
fi
disown "$running_pid" 2>/dev/null || true
( sleep 0.7; kill "$running_pid" 2>/dev/null ) &
if wilted_wait_for_bundle_exit 'com.example.wilted-install-test' 5; then
    pass 'wait returns as soon as the last copy exits'
else
    fail 'wait did not notice the copy exiting'
fi
wait "$running_pid" 2>/dev/null || true

# Wiring: the installer must call each step. A helper nothing calls is not a guard.
assert_installer_contains() {
    local needle="$1" why="$2"
    if grep -Fq "$needle" "$installer"; then
        pass "installer $why"
    else
        fail "installer does not $why (missing: $needle)"
    fi
}

assert_installer_contains 'source "$repo_root/scripts/lib/app-identity.sh"' 'sources the identity library'
assert_installer_contains 'wilted_conflicting_bundles "$destination_dir" "$bundle_id" "$target"' \
    'scans the destination for other bundles claiming the identifier'
assert_installer_contains 'wilted_sweep_registrations "$bundle_id" "$target"' \
    'sweeps stale LaunchServices registrations'
assert_installer_contains 'wilted_registered_bundle_paths "$bundle_id"' \
    'asks LaunchServices what the identifier resolves to'
assert_installer_contains 'wilted_prune_build_products "$repo_root" "$bundle_id" "$app"' \
    'prunes stale products from the repo build roots'
assert_installer_contains 'wilted_running_bundle_pids "$bundle_id"' \
    'quits every running copy by identifier'
assert_installer_contains 'wilted_wait_for_bundle_exit "$bundle_id"' \
    'waits for running copies to exit before replacing the bundle'
assert_installer_contains 'previous_app="$derived/Build/Products/Debug/WiltedMac.app"' \
    'targets only the installer-owned Debug app product for pre-build cleanup'
assert_installer_contains 'rm -rf -- "$previous_app"' \
    'removes the stale app product while preserving intermediate build data'
cleanup_line="$(awk '/rm -rf -- \"\$previous_app\"/ { print NR; exit }' "$installer")"
xcodebuild_line="$(awk '/^[[:space:]]*xcodebuild build/ { print NR; exit }' "$installer")"
if [[ -z "$cleanup_line" || -z "$xcodebuild_line" || "$cleanup_line" -ge "$xcodebuild_line" ]]; then
    fail 'stale app cleanup is not ordered before xcodebuild'
else
    pass 'stale app cleanup is ordered before xcodebuild'
fi
if grep -Fq 'pgrep -f "$target/Contents/MacOS/"' "$installer"; then
    fail 'installer still looks for a running copy at the install path only'
else
    pass 'installer no longer keys the running-copy check on the install path'
fi
assert_installer_contains 'describe --always --dirty' \
    'stamps a revision that admits a dirty tree'

if grep -Fq 'rev-parse --short HEAD' "$installer"; then
    fail 'installer still stamps rev-parse --short HEAD, which names a commit a dirty build is not from'
else
    pass 'installer no longer stamps a bare revision'
fi

bash -n "$installer" || fail 'installer failed a syntax check'
bash -n "$library" || fail 'identity library failed a syntax check'

if (( failures > 0 )); then
    printf 'install-identity.failed count=%s\n' "$failures" >&2
    exit 1
fi
printf 'install-identity.passed\n' >&2
