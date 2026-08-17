#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_file="$(mktemp -t speech-ipc-probe-tests.XXXXXX)"
trap 'rm -f "$output_file"' EXIT

printf '%s\n' 'stage=speech-ipc-probe-tests.start' >&2
swift test --package-path "$repo_root/Probes/SpeechIPCProbe" 2>&1 | tee "$output_file"

test_count="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$output_file" | tail -1)"
if [[ -z "$test_count" || "$test_count" -eq 0 ]]; then
    printf '%s\n' 'speech IPC probe runner found zero XCTest cases' >&2
    exit 1
fi
printf 'stage=speech-ipc-probe-tests.complete count=%s\n' "$test_count" >&2
