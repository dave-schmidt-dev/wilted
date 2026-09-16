#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo_root/Probes/AudioContractProbe"
build_path="$(mktemp -d -t audio-contract-ios-build.XXXXXX)"
core_output="$(mktemp -t audio-contract-ios-core-build.XXXXXX)"
test_output="$(mktemp -t audio-contract-ios-test-build.XXXXXX)"
trap 'rm -rf "$build_path"; rm -f "$core_output" "$test_output"' EXIT

# Xcode 27's SwiftPM drives Swift Build, which no longer prints the legacy
# driver line "Compiling <Module> <File>.swift"; it prints "[n / m] <Target>"
# progress instead. Verify compilation from build artifacts rather than log
# text: every source file in the target must have produced its own object file
# under the freshly minted build path, and that object must carry the iOS
# simulator platform. $build_path is mktemp -d per run, so an artifact found
# there cannot be a stale-cache read.
assert_compiled_sources() {
    local label="$1" sources_dir="$2"
    local sources=() expected=0 found=0 probe_object=""
    [[ -d "$sources_dir" ]] || {
        printf 'missing %s source directory: %s\n' "$label" "$sources_dir" >&2
        exit 1
    }
    while IFS= read -r source; do
        sources+=("$source")
    done < <(find "$sources_dir" -type f -name '*.swift' | sort)
    expected="${#sources[@]}"
    if [[ "$expected" -eq 0 ]]; then
        printf 'no %s Swift sources found in %s\n' "$label" "$sources_dir" >&2
        exit 1
    fi
    local source base object
    for source in "${sources[@]}"; do
        base="$(basename "$source" .swift)"
        # Exclude Products/: the linked per-target object lives there and is not
        # a per-source compile product. Accept the Xcode 27 name (<base>.o) and
        # the legacy SwiftPM name (<base>.swift.o).
        object="$(find "$build_path" -type f \( -name "$base.o" -o -name "$base.swift.o" \) \
            -not -path '*/Products/*' -print -quit)"
        if [[ -z "$object" ]]; then
            printf 'iOS simulator %s build produced no object file for %s\n' "$label" "$base.swift" >&2
            continue
        fi
        found=$((found + 1))
        probe_object="$object"
    done
    if [[ "$found" -ne "$expected" ]]; then
        printf 'iOS simulator %s build compiled %s of %s source files\n' "$label" "$found" "$expected" >&2
        exit 1
    fi
    local build_version
    build_version="$(vtool -show-build "$probe_object" 2>&1 || true)"
    if ! grep -q 'platform IOSSIMULATOR' <<<"$build_version"; then
        printf 'iOS simulator %s object %s is not built for the simulator platform\n' "$label" "$probe_object" >&2
        printf '%s\n' "$build_version" >&2
        exit 1
    fi
    if ! grep -qE '^ *minos 17\.' <<<"$build_version"; then
        printf 'iOS simulator %s object %s does not target iOS 17 minimum\n' "$label" "$probe_object" >&2
        printf '%s\n' "$build_version" >&2
        exit 1
    fi
    printf '%s\n' "$found"
}

printf '%s\n' 'stage=audio-contract-ios-build.start' >&2
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
simulator_triple="arm64-apple-ios17.0-simulator"
printf 'stage=audio-contract-ios-build.sdk path=%s triple=%s\n' "$simulator_sdk" "$simulator_triple" >&2

swift build \
    --package-path "$package" \
    --target AudioContractProbeCore \
    --sdk "$simulator_sdk" \
    --triple "$simulator_triple" \
    --build-path "$build_path" 2>&1 | tee "$core_output"
core_source_count="$(assert_compiled_sources core "$package/Sources/AudioContractProbeCore")"

swift build \
    --package-path "$package" \
    --target AudioContractProbeCoreTests \
    --sdk "$simulator_sdk" \
    --triple "$simulator_triple" \
    --build-path "$build_path" 2>&1 | tee "$test_output"
test_source_count="$(assert_compiled_sources test-target "$package/Tests/AudioContractProbeCoreTests")"

printf 'stage=audio-contract-ios-build.complete core_sources=%s test_sources=%s\n' "$core_source_count" "$test_source_count" >&2
