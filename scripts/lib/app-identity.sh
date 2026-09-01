#!/usr/bin/env bash
# Bundle-identity helpers shared by the Mac installer and its test.
#
# Why this exists: macOS resolves a click, a Dock icon, Spotlight, and
# `open -b <id>` through LaunchServices, which keys on CFBundleIdentifier
# across *every registered bundle on the machine* -- not on /Applications, and
# not on the path anyone last wrote. Two bundles claiming one identifier makes
# which binary launches a lottery.
#
# On 2026-09-01 that lottery cost a morning: `/Applications/Wilted.app`, a
# hand-copied build from a scratch tree, and dozens of gate and capture builds
# under /private/tmp and DerivedData all claimed com.zerodelta.wilted.mac.
# LaunchServices held 435 registrations for it and 56 of those bundles were
# still launchable. Their migration plans stopped at schema V6, the library had
# moved to V7, and the app the owner clicked failed to open the larder while
# the freshly installed one at a different path was fine.
#
# Registrations outlive the bundle: a gate builds into a temp root, registers,
# and deletes the root, and the record stays. So the sweep belongs at install
# time, where one known-good path exists to keep, rather than in each build.

# Prints the CFBundleIdentifier of an app bundle, or nothing.
wilted_bundle_identifier() {
    local app="$1"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true
}

# Prints every *.app under <dir> that claims <identifier>, except <keep>.
#
# Depth 3 with -prune covers /Applications/Foo.app and the one level of
# grouping folders macOS itself uses (/Applications/Utilities/Foo.app) without
# descending into bundles, whose nested helper apps carry their own identifiers.
wilted_conflicting_bundles() {
    local dir="$1" identifier="$2" keep="${3:-}" app
    [[ -d "$dir" ]] || return 0
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        [[ "$app" == "$keep" ]] && continue
        [[ "$(wilted_bundle_identifier "$app")" == "$identifier" ]] && printf '%s\n' "$app"
    done < <(find "$dir" -maxdepth 3 -type d -name '*.app' -prune -print 2>/dev/null | sort)
    return 0
}

wilted_lsregister() {
    printf '%s\n' \
        '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
}

# Prints every bundle path LaunchServices has registered for <identifier>.
#
# The dump is one record per bundle separated by a dashed rule; a record can
# repeat `identifier:` and `path:` for its document types, so only the first of
# each is the bundle's own.
wilted_registered_bundle_paths() {
    local identifier="$1" lsregister
    lsregister="$(wilted_lsregister)"
    [[ -x "$lsregister" ]] || return 0
    "$lsregister" -dump 2>/dev/null | awk '
        /^-{20,}$/ { if (id != "" && path != "") print id "\t" path; id=""; path=""; next }
        /^identifier:[[:space:]]+/ { if (id == "") { sub(/^identifier:[[:space:]]+/, ""); id = $0 } next }
        /^path:[[:space:]]+/ {
            if (path == "") { sub(/^path:[[:space:]]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
            next
        }
        END { if (id != "" && path != "") print id "\t" path }
    ' | awk -F'\t' -v want="$identifier" '$1 == want { print $2 }' | sort -u
    return 0
}

# Deletes every *.app claiming <identifier> under the repo's own build roots
# (<repo>/build and <repo>/.build), except <keep>, and prints each path removed.
#
# The registration sweep is not enough on its own. On 2026-09-01, an hour
# after a clean install, the owner reopened the app and got an eleven-hour-old
# gate build from build/quickcheck: the sweep had dropped its record, but the
# bundle still existed under ~/Documents, which Spotlight indexes and the Dock
# remembers, and launching it by path registered it again. A bundle that no
# longer exists cannot come back. These roots are gitignored build output the
# repo owns, so removing them destroys nothing that cannot be rebuilt; bundles
# anywhere else are still only unregistered, never deleted.
wilted_prune_build_products() {
    local repo_root="$1" identifier="$2" keep="${3:-}" root app
    for root in "$repo_root/build" "$repo_root/.build"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r app; do
            [[ -n "$app" && "$app" != "$keep" ]] || continue
            [[ "$(wilted_bundle_identifier "$app")" == "$identifier" ]] || continue
            rm -rf "$app"
            printf '%s\n' "$app"
        done < <(find "$root" -type d -name '*.app' -prune -print 2>/dev/null | sort)
    done
    return 0
}

# Prints the pid of every running process whose executable lives inside a
# bundle claiming <identifier>, whatever path that bundle has. The installer
# used to look only at the install path, which is how a stale build kept
# running through an install that was meant to replace it.
wilted_running_bundle_pids() {
    local identifier="$1" pid path app
    while read -r pid path; do
        [[ -n "$pid" && "$path" == *.app/Contents/MacOS/* ]] || continue
        app="${path%%.app/Contents/MacOS/*}.app"
        [[ "$(wilted_bundle_identifier "$app")" == "$identifier" ]] && printf '%s\n' "$pid"
    done < <(ps -axo pid=,comm= 2>/dev/null || true)
    return 0
}

# Unregisters every bundle claiming <identifier> except <keep>, then registers
# <keep>. Stale records for paths that no longer exist are dropped the same way.
wilted_sweep_registrations() {
    local identifier="$1" keep="$2" lsregister path
    lsregister="$(wilted_lsregister)"
    [[ -x "$lsregister" ]] || return 0
    while IFS= read -r path; do
        [[ -n "$path" && "$path" != "$keep" ]] || continue
        "$lsregister" -u "$path" >/dev/null 2>&1 || true
    done < <(wilted_registered_bundle_paths "$identifier")
    "$lsregister" -f "$keep" >/dev/null 2>&1 || true
    return 0
}
