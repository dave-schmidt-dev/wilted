#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo_root/Probes/AudioContractProbe"
output_file="$(mktemp -t audio-contract-probe-tests.XXXXXX)"
status_file="$(mktemp -t audio-contract-probe-status.XXXXXX)"
artifact="$(mktemp -t audio-contract-probe-artifact.XXXXXX).m4a"
artifact_seed="${artifact%.m4a}"
sizing_dir="$(mktemp -d -t audio-contract-sizing.XXXXXX)"
sizing_status_file="$(mktemp -t audio-contract-sizing-status.XXXXXX)"
trap 'rm -f "$output_file" "$status_file" "$artifact_seed" "$artifact" "$sizing_status_file"; rm -rf "$sizing_dir"' EXIT

printf '%s\n' 'stage=audio-contract-probe-tests.start' >&2
swift test --package-path "$package" 2>&1 | tee "$output_file"
test_count="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$output_file" | tail -1)"
if [[ -z "$test_count" || "$test_count" -eq 0 ]]; then
    printf '%s\n' 'audio contract probe runner found zero XCTest cases' >&2
    exit 1
fi

report="$(swift run --package-path "$package" audio-contract-probe --output "$artifact" 2> >(tee "$status_file" >&2))"
printf '%s\n' "$report"

if [[ "$(printf '%s\n' "$report" | wc -l | tr -d ' ')" -ne 1 ]]; then
    printf '%s\n' 'audio contract probe must emit exactly one JSON stdout line' >&2
    exit 1
fi
for required in '"container":"M4A"' '"codec":"AAC"' '"sampleRateHz":44100' '"channels":1' '"gaplessSingleFile":true' '"durationWithinTolerance":true' '"avFoundationValidation":true' '"durableAtomicPublication":true' '"failedPreparationTempCleanup":true' '"iosDeviceValidation":"unresolved:'; do
    if ! printf '%s\n' "$report" | grep -Fq "$required"; then
        printf 'missing report field: %s\n' "$required" >&2
        exit 1
    fi
done
if [[ ! -s "$artifact" ]]; then
    printf '%s\n' 'probe did not publish a nonempty M4A artifact' >&2
    exit 1
fi
for stage in generate-synthetic-pcm encode-m4a-aac flush-close-temp validate-avfoundation seek-decode interruption-reopen measure-first-byte-to-play hash atomic-rename verify-published-file verify-temp-failure-cleanup; do
    if ! grep -Fq "stage=$stage" "$status_file"; then
        printf 'missing progress stage: %s\n' "$stage" >&2
        exit 1
    fi
done

sizing_report="$(swift run --package-path "$package" audio-contract-probe --sizing --output-dir "$sizing_dir" 2> >(tee "$sizing_status_file" >&2))"
printf '%s\n' "$sizing_report"
if [[ "$(printf '%s\n' "$sizing_report" | wc -l | tr -d ' ')" -ne 1 ]]; then
    printf '%s\n' 'audio sizing probe must emit exactly one JSON stdout line' >&2
    exit 1
fi
for required in '"requestedDurationMinutes":5' '"requestedDurationMinutes":30' '"requestedDurationMinutes":90' '"peakWorkingPCMBytes":16384' '"measuredNinetyMinuteEncodedByteSize"' '"configuredBitrateReferenceBytes"' '"appOwnedPerRevisionBudgetBytes"' '"budgetDerivation":"ceil(max(budget-source encoded bytes * 2, configured 96 kbps 90-minute reference bytes) to next 10,000,000-byte boundary); app-owned budget only, not a CloudKit service limit"' '"iosDeviceValidation":"unresolved:'; do
    if ! printf '%s\n' "$sizing_report" | grep -Fq "$required"; then
        printf 'missing sizing report field: %s\n' "$required" >&2
        exit 1
    fi
done
if [[ "$(find "$sizing_dir" -type f -name '*.m4a' | wc -l | tr -d ' ')" -ne 3 ]]; then
    printf '%s\n' 'sizing probe did not publish exactly three M4A candidates' >&2
    exit 1
fi
for duration in 5.0 30.0 90.0; do
    if ! grep -Fq "stage=sizing-complete durationMinutes=$duration" "$sizing_status_file"; then
        printf 'missing sizing completion stage: %s\n' "$duration" >&2
        exit 1
    fi
done
printf 'stage=audio-contract-probe-tests.complete count=%s\n' "$test_count" >&2
