#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Gate leg for the podcast preparation worker.
#
# The worker is the Python side of the ad-removal and transcript pipeline. Its
# heavy imports are all lazy, so this leg runs without a model: what is under
# test is the timing arithmetic, the format dispatch, the fallbacks, and the
# stdin/stdout protocol.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker="$repo_root/Producer/Workers/wilted_pipeline.py"
suite="$repo_root/Producer/Workers/test_wilted_pipeline.py"
output_file="$(mktemp -t wilted-pipeline-worker.XXXXXX)"
trap 'rm -f "$output_file"' EXIT
pipeline_python="${WILTED_PIPELINE_PYTHON:-$repo_root/Producer/Runtime/.venv/bin/python}"
expected_test_files=20

[[ -x "$pipeline_python" ]] || { printf 'missing required Python interpreter: %s\n' "$pipeline_python" >&2; exit 1; }
[[ -f "$worker" ]] || { printf 'missing worker: %s\n' "$worker" >&2; exit 1; }
[[ -f "$suite" ]] || { printf 'missing worker test suite: %s\n' "$suite" >&2; exit 1; }

test_files="$(find "$repo_root/Producer/Workers" -maxdepth 1 -type f -name 'test_*.py' | wc -l | tr -d '[:space:]')"
if [[ "$test_files" -ne "$expected_test_files" ]]; then
  printf 'pipeline worker suite found %s test files; exactly %s are expected\n' \
    "$test_files" "$expected_test_files" >&2
  exit 1
fi

printf '%s\n' 'stage=pipeline-worker-tests.start' >&2
# The worker must never depend on an inherited PYTHONPATH to import cleanly;
# the caller supplies the previous project's source tree explicitly.
(cd "$repo_root" && env -u PYTHONPATH "$pipeline_python" -m unittest discover \
  -s Producer/Workers -t Producer/Workers -p 'test_*.py' -v) 2>&1 | tee "$output_file" >&2

test_count="$(sed -nE 's/^Ran ([0-9]+) tests? in .*/\1/p' "$output_file" | tail -1)"
if [[ -z "$test_count" || "$test_count" -lt 422 ]]; then
  printf 'pipeline worker suite ran %s tests; at least 422 are expected\n' "${test_count:-0}" >&2
  exit 1
fi
grep -q '^OK' "$output_file" || { printf '%s\n' 'pipeline worker suite did not report OK' >&2; exit 1; }

# The worker answers a malformed request instead of dying, which is what keeps
# a failed episode from looking like a crashed app.
protocol="$(printf 'not json' | env -u PYTHONPATH "$pipeline_python" "$worker" || true)"
printf '%s\n' "$protocol" | grep -q '"code": "bad-request"' \
  || { printf '%s\n' 'worker did not answer a malformed request'; exit 1; } >&2

printf 'stage=pipeline-worker-tests.complete tests=%s test_files=%s\n' "$test_count" "$test_files" >&2
