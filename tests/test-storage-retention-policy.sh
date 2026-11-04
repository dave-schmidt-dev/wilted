#!/bin/bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$root/scripts/lib/test-runner.sh"
    wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$root/tests/test-storage-retention-policy.py"
python3 "$root/tests/test-storage-retention-runtime.py"
python3 "$root/tests/test-storage-retention-bundles.py"
python3 "$root/tests/test-storage-retention-manifest.py"
