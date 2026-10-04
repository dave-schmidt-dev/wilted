#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$repo_root/scripts/lib/test-runner.sh"
    wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Proves the normal Mac install is the live Development build, and that the
# library publisher is its default engine without any launch-only flag.
#
# Hermetic on purpose: it never builds, never signs, never contacts the
# developer portal or CloudKit, and never launches or installs an app. The
# installer runs against PATH-scoped fakes that record xcodebuild's arguments
# and serve synthetic entitlements, so the audit's refusal is exercised before
# any quit or bundle replacement could happen.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo_root/project.yml"
entitlements_file="$repo_root/WiltedMac/WiltedMac.entitlements"
installer="$repo_root/scripts/install-mac-app.sh"
attended="$repo_root/scripts/attended-cloudkit-run.sh"
selection_source="$repo_root/WiltedMac/Sync/WiltedMacLibraryRuntimeSelection.swift"
bootstrap_source="$repo_root/WiltedMac/ViewModel/WiltedMacModel+StoreBootstrap.swift"
sync_source="$repo_root/WiltedMac/ViewModel/WiltedMacModel+LibrarySync.swift"
container='iCloud.com.zerodelta.wilted'
failures=0

fail() {
    printf 'install-contract.fail %s\n' "$*" >&2
    failures=$((failures + 1))
}

pass() { printf 'install-contract.ok %s\n' "$*" >&2; }

tmp_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-install-contract.XXXXXX")"
cleanup() { [[ -d "$tmp_root" ]] && rm -rf "$tmp_root"; }
trap cleanup EXIT

for required in "$project" "$entitlements_file" "$installer" "$attended" \
    "$selection_source" "$bootstrap_source" "$sync_source"; do
    [[ -f "$required" ]] || { fail "missing $required"; exit 1; }
done

# Prints one build configuration's settings block of the WiltedMac target.
# Indentation-scoped rather than a YAML parse, so it needs no Python module.
mac_config() {
    awk -v wanted="$1" '
        /^  [A-Za-z]/ { in_target = ($0 == "  WiltedMac:") ; in_config = 0; next }
        in_target && /^        [A-Za-z]+:$/ {
            name = $1; sub(":", "", name); in_config = (name == wanted); next
        }
        in_target && in_config && /^          / { print }
        in_target && in_config && !/^          / && !/^ *$/ { in_config = 0 }
    ' "$project"
}

expect_setting() {
    local config="$1" setting="$2" label="$3"
    if mac_config "$config" | grep -Fq -- "$setting"; then
        pass "$label"
    else
        fail "$label (missing '$setting' in WiltedMac $config)"
    fi
}

# 1. project.yml: Development is the live, entitled, Apple Development build;
#    Debug compiles no live transport; Release is the separate Production build.
development="$(mac_config Development)"
[[ -n "$development" ]] || fail 'project.yml has no WiltedMac Development configuration'
expect_setting Development 'WILTED_CLOUDKIT_LIVE' 'Development compiles the live CloudKit transport'
expect_setting Development 'CODE_SIGN_ENTITLEMENTS: WiltedMac/WiltedMac.entitlements' \
    'Development carries the Development entitlements'
expect_setting Development 'CODE_SIGN_IDENTITY: "Apple Development"' 'Development signs as Apple Development'
expect_setting Development 'CODE_SIGN_STYLE: Automatic' 'Development uses the cached automatic profile'
expect_setting Development 'DEVELOPMENT_TEAM: 4CJ49V6QHW' 'Development names the team'
if mac_config Debug | grep -Fq 'WILTED_CLOUDKIT_LIVE'; then
    fail 'Debug compiles the live transport; unit tests would default to the publisher'
else
    pass 'Debug compiles no live transport'
fi
expect_setting Debug 'CODE_SIGN_ENTITLEMENTS: ""' 'Debug carries no CloudKit entitlement'
expect_setting Release 'CODE_SIGN_ENTITLEMENTS: WiltedMac/WiltedMacProduction.entitlements' \
    'Release keeps the separate Production entitlements'

# 2. The Development entitlements name the container, CloudKit and push.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements_file" 2>/dev/null || true; }
[[ "$(plist_value com.apple.developer.icloud-container-identifiers)" == *"$container"* ]] \
    && pass 'entitlements name the CloudKit container' || fail "entitlements omit $container"
[[ "$(plist_value com.apple.developer.icloud-services)" == *CloudKit* ]] \
    && pass 'entitlements enable CloudKit' || fail 'entitlements omit the CloudKit service'
[[ "$(plist_value com.apple.developer.aps-environment)" == development ]] \
    && pass 'entitlements use the development push environment' || fail 'aps-environment is not development'

# 3. Installer static contract.
assert_installer() {
    local needle="$1" label="$2"
    grep -Fq -- "$needle" "$installer" && pass "$label" || fail "$label (missing '$needle')"
}
refute_installer() {
    local pattern="$1" label="$2"
    # Comments may name what the installer deliberately avoids; code may not.
    if grep -Ev '^[[:space:]]*#' "$installer" | grep -Eq -- "$pattern"; then
        fail "$label"
    else
        pass "$label"
    fi
}
assert_installer "configuration='Development'" 'installer builds the Development configuration'
assert_installer '-configuration "$configuration"' 'installer passes its configuration to xcodebuild'
assert_installer 'app="$derived/Build/Products/$configuration/WiltedMac.app"' \
    'installer installs the Development product'
assert_installer 'codesign --display --entitlements' 'installer audits the built entitlements'
assert_installer 'aps-environment</key><string>development</string>' 'installer requires the development push entitlement'
assert_installer 'embedded.provisionprofile' 'installer requires an embedded cached profile'
refute_installer '-configuration Debug' 'installer no longer builds Debug'
refute_installer 'allowProvisioningUpdates' 'installer never asks the developer portal for a profile'
refute_installer 'WILTED_LIBRARY_SYNC' 'installer sets no library-sync launch flag'
refute_installer '(^|[[:space:]])open([[:space:]]|$)' 'installer never launches the app'

# 4. Installer stubbed run: the build receives -configuration Development, and a
#    product without the container entitlement is refused before any quit or
#    replacement.
fake_bin="$tmp_root/bin"
destination="$tmp_root/destination"
mkdir -p "$fake_bin" "$destination"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_bin/xcodegen"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\\n" "$@" >"$WILTED_TEST_ARGV"' \
    'configuration=unset' \
    'while (( $# > 0 )); do [[ "$1" == -configuration ]] && configuration="$2"; shift; done' \
    'app="$WILTED_TEST_DERIVED/Build/Products/$configuration/WiltedMac.app"' \
    'mkdir -p "$app/Contents"' \
    '[[ "${WILTED_TEST_NO_PROFILE:-0}" == 1 ]] || : >"$app/Contents/embedded.provisionprofile"' \
    '/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.zerodelta.wilted.mac" "$app/Contents/Info.plist" >/dev/null' \
    >"$fake_bin/xcodebuild"
printf '%s\n' '#!/usr/bin/env bash' \
    'shift' \
    'case "$1" in' \
    '  path) printf "%s\\n" "$WILTED_TEST_DERIVED" ;;' \
    '  run) shift 5; exec "$@" ;;' \
    '  *) exit 64 ;;' \
    'esac' \
    >"$fake_bin/python3"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ " $* " == *" --display "* ]] && printf "%s\\n" "$WILTED_TEST_ENTITLEMENTS"' \
    'exit 0' >"$fake_bin/codesign"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$fake_bin/pgrep"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_bin/ps"
for marked in osascript ditto open; do
    printf '%s\n' '#!/usr/bin/env bash' ": >\"\$WILTED_TEST_MARKERS/$marked\"" 'exit 1' >"$fake_bin/$marked"
done
chmod +x "$fake_bin"/*

run_installer() {
    local output="$1" entitlements="$2" no_profile="${3:-0}"
    rm -rf "$tmp_root/derived" "$tmp_root/markers"
    mkdir -p "$tmp_root/markers"
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        WILTED_INSTALL_LIBRARY_URL="$tmp_root/absent.sqlite" \
        WILTED_TEST_ARGV="$tmp_root/argv" \
        WILTED_TEST_DERIVED="$tmp_root/derived" \
        WILTED_TEST_ENTITLEMENTS="$entitlements" \
        WILTED_TEST_NO_PROFILE="$no_profile" \
        WILTED_TEST_MARKERS="$tmp_root/markers" \
        bash "$installer" "$destination" >"$output" 2>&1
}

assert_refused() {
    local output="$1" message="$2" label="$3"
    if [[ -n "$(ls -A "$tmp_root/markers")" ]]; then
        fail "$label: quit, replace or launch ran ($(ls "$tmp_root/markers" | tr '\n' ' '))"
    elif ! grep -Fq -- "$message" "$output"; then
        fail "$label: missing '$message'"
    elif [[ -e "$destination/WiltedMac.app" ]]; then
        fail "$label: a bundle reached the destination"
    else
        pass "$label"
    fi
}

if run_installer "$tmp_root/no-container.out" '<dict/>'; then
    fail 'installer accepted a product without the container entitlement'
else
    assert_refused "$tmp_root/no-container.out" "install.error built app does not carry the $container entitlement" \
        'a product without the container entitlement is refused before quit or replace'
fi
if grep -Fxq -- '-configuration' "$tmp_root/argv" && grep -Fxq -- 'Development' "$tmp_root/argv"; then
    pass 'the stubbed build receives -configuration Development'
else
    fail "the stubbed build did not receive -configuration Development: $(tr '\n' ' ' <"$tmp_root/argv" 2>/dev/null)"
fi
if grep -Fq -- 'allowProvisioningUpdates' "$tmp_root/argv"; then
    fail 'the stubbed build was asked to contact the developer portal'
else
    pass 'the stubbed build is not asked to contact the developer portal'
fi

entitled="<key>com.apple.developer.aps-environment</key>
<string>development</string><string>$container</string>"
if run_installer "$tmp_root/no-push.out" "<string>$container</string>"; then
    fail 'installer accepted a product without the development push entitlement'
else
    assert_refused "$tmp_root/no-push.out" 'install.error built app does not carry the development push entitlement' \
        'a product without the development push entitlement is refused before quit or replace'
fi
if run_installer "$tmp_root/no-profile.out" "$entitled" 1; then
    fail 'installer accepted a product without an embedded provisioning profile'
else
    assert_refused "$tmp_root/no-profile.out" 'install.error built app has no embedded provisioning profile' \
        'a product without the cached profile is refused before quit or replace'
fi

# 5. Swift source contract: one pure selection decides the engine; no env-only gate.
grep -Fq 'struct WiltedMacLibraryRuntimeSelection' "$selection_source" \
    && pass 'the runtime selection is a named policy type' || fail 'runtime selection type missing'
grep -Fq 'libraryRuntimeSelection().engine' "$bootstrap_source" \
    && pass 'store bootstrap picks the engine from the runtime selection' \
    || fail 'store bootstrap does not consult the runtime selection'
if grep -Fq 'WiltedMacLibraryPublisher.isEnabled()' "$bootstrap_source" "$sync_source"; then
    fail 'an env-only publisher gate still decides the engine'
else
    pass 'no env-only publisher gate decides the engine'
fi
grep -Fq 'selection.admits(managedTransport:' "$sync_source" \
    && pass 'a live default refuses a transport that reports no account changes' \
    || fail 'library start does not apply the managed-transport admission'

# 6. The attended run relies on the live default, not a launch-only flag.
grep -Fq 'open -n "$mac_app_path"' "$attended" \
    && pass 'attended run launches the Development app plainly' || fail 'attended plain launch missing'
if grep -Fq -- '--env WILTED_LIBRARY_SYNC' "$attended"; then
    fail 'attended run still forces the publisher with a launch-only flag'
else
    pass 'attended run sets no launch-only library flag'
fi

bash -n "$installer" || fail 'installer failed a syntax check'

if (( failures > 0 )); then
    printf 'install-contract.failed count=%s\n' "$failures" >&2
    exit 1
fi
printf 'install-contract.passed\n' >&2
