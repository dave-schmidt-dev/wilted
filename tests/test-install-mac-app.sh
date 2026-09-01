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
trap '[[ -d "$tmp_root" ]] && rm -rf "$tmp_root"' EXIT

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
