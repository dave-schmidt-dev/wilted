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
source "$repo_root/scripts/lib/test-temp-state.sh"
work_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-pipeline-worker.XXXXXX")"; wilted_temp_mark_owned "$work_dir"
trap 'rm -rf "$work_dir"' EXIT
output_file="$work_dir/output.log"
pipeline_python="${WILTED_PIPELINE_PYTHON:-$repo_root/Producer/Runtime/.venv/bin/python}"

[[ -x "$pipeline_python" ]] || { printf 'missing required Python interpreter: %s\n' "$pipeline_python" >&2; exit 1; }
[[ -f "$worker" ]] || { printf 'missing worker: %s\n' "$worker" >&2; exit 1; }
[[ -f "$suite" ]] || { printf 'missing worker test suite: %s\n' "$suite" >&2; exit 1; }

# The file list is frozen before the run so the count and the discovery check
# below describe one suite. A file unittest never collects (no test methods, a
# class that stopped deriving from TestCase) still leaves the run reporting OK,
# so every file must appear in the verbose output.
test_file_list="$(find "$repo_root/Producer/Workers" -maxdepth 1 -type f -name 'test_*.py' | sort)"
test_files="$(printf '%s\n' "$test_file_list" | wc -l | tr -d '[:space:]')"

python3 "$repo_root/tests/test_pipeline_suite_discovery.py"

printf '%s\n' 'stage=pipeline-worker-tests.start' >&2
# The worker must never depend on an inherited PYTHONPATH to import cleanly;
# the caller supplies the previous project's source tree explicitly.
(cd "$repo_root" && env -u PYTHONPATH "$pipeline_python" -m unittest discover \
  -s Producer/Workers -t Producer/Workers -p 'test_*.py' -v) 2>&1 | tee "$output_file" >&2

test_count="$(sed -nE 's/^Ran ([0-9]+) tests? in .*/\1/p' "$output_file" | tail -1)"
if [[ -z "$test_count" || "$test_count" -lt 420 ]]; then
  printf 'pipeline worker suite ran %s tests; at least 420 are expected\n' "${test_count:-0}" >&2
  exit 1
fi
grep -q '^OK' "$output_file" || { printf '%s\n' 'pipeline worker suite did not report OK' >&2; exit 1; }

printf '%s\n' "$test_file_list" | python3 "$repo_root/tests/pipeline_suite_discovery.py" "$output_file"

# The worker answers a malformed request instead of dying, which is what keeps
# a failed episode from looking like a crashed app.
protocol="$(printf 'not json' | env -u PYTHONPATH "$pipeline_python" "$worker" || true)"
printf '%s\n' "$protocol" | grep -q '"code": "bad-request"' \
  || { printf '%s\n' 'worker did not answer a malformed request'; exit 1; } >&2

printf 'stage=pipeline-worker-tests.complete tests=%s test_files=%s\n' "$test_count" "$test_files" >&2
