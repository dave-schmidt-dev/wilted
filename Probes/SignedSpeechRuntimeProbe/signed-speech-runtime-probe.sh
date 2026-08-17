#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
probe_path=""
harness_path="$script_dir/fake-speech-socket-harness.py"
temp_dir=""
harness_pid=""
final_emitted=0
socket_mode="fake-unix-socket"
live_socket=""
harness_requested=0

emit_json() {
    local ok="$1"
    local error="$2"
    local test_count="$3"
    local exact_echo="$4"
    local app_sandbox="$5"
    local signature_valid="$6"
    local hardened_runtime="$7"
    local socket_harness="$8"

    python3 - "$ok" "$error" "$test_count" "$exact_echo" "$app_sandbox" "$signature_valid" "$hardened_runtime" "$socket_harness" <<'PY'
import json
import sys

def boolean(value):
    return value.lower() == "true"

ok, error, count, exact, sandbox, signature, runtime, socket_harness = sys.argv[1:]
payload = {
    "ok": boolean(ok),
    "app_executed": boolean(ok),
    "app_sandbox": boolean(sandbox),
    "app_sandbox_entitlement": boolean(sandbox),
    "app_sandbox_status": "present" if boolean(sandbox) else "absent",
    "distribution_shape": "non-app-sandbox-personal-mvp",
    "hardened_runtime": boolean(runtime),
    "selftest_exact_echo": boolean(exact),
    "signature_valid": boolean(signature),
    "socket_harness": socket_harness,
    "socket_path_scope": "mktemp-only" if socket_harness == "fake-unix-socket" else "explicit-live-socket",
    "test_count": int(count),
    "human_gates": ["Developer ID identity", "notarization", "actual installed app"],
}
if error:
    payload["error"] = error
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
    final_emitted=1
}

fail() {
    local reason="$1"
    emit_json false "$reason" 0 false false false false "$socket_mode"
    exit 1
}

cleanup() {
    if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
        kill "$harness_pid" 2>/dev/null || true
        wait "$harness_pid" 2>/dev/null || true
    fi
    if [[ -n "$temp_dir" ]]; then
        rm -rf "$temp_dir"
    fi
}

on_exit() {
    local status=$?
    cleanup
    if (( status != 0 && final_emitted == 0 )); then
        emit_json false "unexpected wrapper failure" 0 false false false false "$socket_mode"
    fi
    return "$status"
}
trap on_exit EXIT

while (( $# > 0 )); do
    case "$1" in
        --probe)
            [[ $# -ge 2 ]] || fail "--probe requires an executable path"
            probe_path="$2"
            shift 2
            ;;
        --harness)
            [[ $# -ge 2 ]] || fail "--harness requires a harness path"
            [[ -z "$live_socket" ]] || fail "--harness cannot be combined with --live-socket"
            (( harness_requested == 0 )) || fail "--harness may be provided only once"
            harness_path="$2"
            harness_requested=1
            shift 2
            ;;
        --live-socket)
            [[ $# -ge 2 ]] || fail "--live-socket requires an absolute socket path"
            [[ "$2" == /* ]] || fail "--live-socket requires an absolute socket path"
            [[ -z "$live_socket" ]] || fail "--live-socket may be provided only once"
            (( harness_requested == 0 )) || fail "--live-socket cannot be combined with --harness"
            live_socket="$2"
            socket_mode="live-existing-socket"
            shift 2
            ;;
        --help)
            printf '%s\n' 'usage: signed-speech-runtime-probe.sh [--probe EXECUTABLE] [--harness HARNESS | --live-socket ABSOLUTE_PATH]' >&2
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required for codesign"
for tool in codesign plutil python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool unavailable: $tool"
done
if [[ -z "$live_socket" ]]; then
    [[ -f "$harness_path" ]] || fail "fake socket harness not found"
else
    [[ -S "$live_socket" ]] || fail "live socket does not exist: $live_socket"
fi

temp_dir="$(mktemp -d -t wilted-signed-runtime.XXXXXX)" || fail "could not create temporary workspace"
socket_path="$temp_dir/s.sock"
if [[ -n "$live_socket" ]]; then
    socket_path="$live_socket"
fi
app_path="$temp_dir/SignedSpeechRuntimeProbe.app"
app_executable="$app_path/Contents/MacOS/SpeechIPCProbe"

if [[ -z "$probe_path" ]]; then
    command -v swift >/dev/null 2>&1 || fail "required tool unavailable: swift"
    build_path="$temp_dir/swift-build"
    printf '%s\n' 'stage=build-speech-probe' >&2
    if ! swift build --package-path "$repo_root/Probes/SpeechIPCProbe" \
        --configuration release --product speech-ipc-probe --scratch-path "$build_path" >&2; then
        fail "speech probe build failed"
    fi
    if ! probe_bin_dir="$(swift build --package-path "$repo_root/Probes/SpeechIPCProbe" \
        --configuration release --show-bin-path --scratch-path "$build_path")"; then
        fail "speech probe binary path lookup failed"
    fi
    probe_path="$probe_bin_dir/speech-ipc-probe"
fi
[[ -x "$probe_path" ]]

printf '%s\n' 'stage=assemble-disposable-app' >&2
mkdir -p "$(dirname "$app_executable")" || fail "could not create app bundle"
# Deliberately unguarded: -e plus the EXIT trap must fail closed with JSON here.
cp "$probe_path" "$app_executable"
chmod 755 "$app_executable" || fail "could not mark app executable"
codesign --remove-signature "$app_executable" 2>/dev/null || true
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SpeechIPCProbe</string>
    <key>CFBundleIdentifier</key>
    <string>com.zerodelta.wilted.signed-speech-runtime-probe</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SignedSpeechRuntimeProbe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST
if ! plutil -lint "$app_path/Contents/Info.plist" >&2; then
    fail "Info.plist is invalid"
fi

printf '%s\n' 'stage=sign-ad-hoc-hardened-runtime' >&2
if ! codesign -s - --options runtime "$app_path" >&2; then
    fail "ad-hoc hardened-runtime signing failed"
fi

printf '%s\n' 'stage=verify-signature-and-entitlements' >&2
if ! codesign --verify --deep --strict --verbose=2 "$app_path" >&2; then
    fail "signature verification failed"
fi
signature_details="$temp_dir/signature-details.txt"
if ! codesign -d --verbose=4 "$app_path" >"$signature_details" 2>&1; then
    fail "signature details unavailable"
fi
grep -Eq 'flags=.*runtime' "$signature_details" || fail "hardened runtime flag is absent"
entitlements="$temp_dir/entitlements.txt"
codesign -d --entitlements :- "$app_path" >"$entitlements" 2>&1 || true
if grep -Fq 'com.apple.security.app-sandbox' "$entitlements"; then
    fail "App Sandbox entitlement is present"
fi

if [[ "$socket_mode" == "fake-unix-socket" ]]; then
    printf '%s\n' 'stage=start-fake-unix-socket-harness' >&2
    ready_file="$temp_dir/harness.ready"
    PYTHONDONTWRITEBYTECODE=1 python3 "$harness_path" \
        --socket "$socket_path" --ready-file "$ready_file" >"$temp_dir/harness.stdout" 2>"$temp_dir/harness.stderr" &
    harness_pid=$!
    for attempt in $(seq 1 50); do
        if [[ -f "$ready_file" && -S "$socket_path" ]]; then
            break
        fi
        if ! kill -0 "$harness_pid" 2>/dev/null; then
            fail "fake socket harness exited before readiness"
        fi
        if (( attempt % 10 == 0 )); then
            printf 'stage=wait-fake-harness attempt=%s\n' "$attempt" >&2
        fi
        sleep 0.01
    done
    [[ -f "$ready_file" && -S "$socket_path" ]] || fail "fake socket harness readiness timed out"
else
    printf '%s\n' 'stage=use-live-existing-socket' >&2
fi

printf '%s\n' 'stage=execute-signed-app-selftest' >&2
app_output="$temp_dir/app-output.json"
if ! "$app_executable" selftest --socket "$socket_path" >"$app_output"; then
    fail "signed app selftest execution failed"
fi
if [[ "$socket_mode" == "fake-unix-socket" ]]; then
    if ! wait "$harness_pid"; then
        cat "$temp_dir/harness.stderr" >&2 || true
        fail "fake socket harness rejected the selftest request"
    fi
    harness_pid=""
fi

if ! python3 - "$app_output" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        actual = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    print(f"selftest JSON could not be read: {error}", file=sys.stderr)
    raise SystemExit(1)

expected = {
    "mode": "selftest",
    "ok": True,
    "result": {"value": "wilted-swift"},
}
if actual != expected:
    print("selftest echo did not match the exact expected round-trip", file=sys.stderr)
    raise SystemExit(1)
PY
then
    fail "selftest echo validation failed"
fi

emit_json true "" 5 true false true true "$socket_mode"
