#!/usr/bin/env bash
set -euo pipefail

# Gate leg for the podcast preparation worker.
#
# The worker is the Python side of the ad-removal and transcript pipeline. Its
# heavy imports are all lazy, so this leg runs under the system interpreter
# with no virtualenv and no model: what is under test is the timing arithmetic,
# the format dispatch, the fallbacks, and the stdin/stdout protocol.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker="$repo_root/Producer/Workers/wilted_pipeline.py"
suite="$repo_root/Producer/Workers/test_wilted_pipeline.py"
output_file="$(mktemp -t wilted-pipeline-worker.XXXXXX)"
trap 'rm -f "$output_file"' EXIT

command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'missing required tool: python3' >&2; exit 1; }
[[ -f "$worker" ]] || { printf 'missing worker: %s\n' "$worker" >&2; exit 1; }
[[ -f "$suite" ]] || { printf 'missing worker test suite: %s\n' "$suite" >&2; exit 1; }

printf '%s\n' 'stage=pipeline-worker-tests.start' >&2
# The worker must never depend on an inherited PYTHONPATH to import cleanly;
# the caller supplies the previous project's source tree explicitly.
env -u PYTHONPATH python3 "$suite" 2>&1 | tee "$output_file" >&2

test_count="$(sed -nE 's/^Ran ([0-9]+) tests? in .*/\1/p' "$output_file" | tail -1)"
if [[ -z "$test_count" || "$test_count" -lt 20 ]]; then
  printf 'pipeline worker suite ran %s tests; at least 20 are expected\n' "${test_count:-0}" >&2
  exit 1
fi
grep -q '^OK' "$output_file" || { printf '%s\n' 'pipeline worker suite did not report OK' >&2; exit 1; }

# The worker answers a malformed request instead of dying, which is what keeps
# a failed episode from looking like a crashed app.
protocol="$(printf 'not json' | env -u PYTHONPATH python3 "$worker" || true)"
printf '%s\n' "$protocol" | grep -q '"code": "bad-request"' \
  || { printf '%s\n' 'worker did not answer a malformed request'; exit 1; } >&2

printf 'stage=pipeline-worker-tests.complete tests=%s\n' "$test_count" >&2
