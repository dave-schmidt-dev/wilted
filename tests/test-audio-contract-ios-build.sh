#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo_root/Probes/AudioContractProbe"
build_path="$(mktemp -d -t audio-contract-ios-build.XXXXXX)"
core_output="$(mktemp -t audio-contract-ios-core-build.XXXXXX)"
test_output="$(mktemp -t audio-contract-ios-test-build.XXXXXX)"
trap 'rm -rf "$build_path"; rm -f "$core_output" "$test_output"' EXIT

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
core_source_count="$(grep -c 'Compiling AudioContractProbeCore AudioContractProbe.swift' "$core_output" || true)"
if [[ "$core_source_count" -eq 0 ]]; then
    printf '%s\n' 'iOS simulator core build compiled zero core source files' >&2
    exit 1
fi

swift build \
    --package-path "$package" \
    --target AudioContractProbeCoreTests \
    --sdk "$simulator_sdk" \
    --triple "$simulator_triple" \
    --build-path "$build_path" 2>&1 | tee "$test_output"
test_source_count="$(grep -c 'Compiling AudioContractProbeCoreTests AudioContractProbeTests.swift' "$test_output" || true)"
if [[ "$test_source_count" -eq 0 ]]; then
    printf '%s\n' 'iOS simulator test-target build compiled zero XCTest source files' >&2
    exit 1
fi

printf 'stage=audio-contract-ios-build.complete core_sources=%s test_sources=%s\n' "$core_source_count" "$test_source_count" >&2
