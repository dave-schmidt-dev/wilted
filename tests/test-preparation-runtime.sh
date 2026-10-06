#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Gate leg for the vendored preparation runtime's Python suite.
#
# It covers the modules the preparation worker loads (ads, transcribe, llm, the
# execution-capability gate, feed references, the ffmpeg check and the GGUF
# repair utility). The Python app that used to sit beside them (CLI, TUI,
# scheduler, station runtime, database) was retired on 2026-10-03.
#
# The suite must run with Producer/Runtime as the working directory: its
# pyproject pins `testpaths = ["tests"]`, so a run launched from the repository
# root collects nothing.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$repo_root/Producer/Runtime"
python_bin="$runtime_root/.venv/bin/python"
output_file="$(mktemp -t wilted-preparation-runtime.XXXXXX)"
trap 'rm -f "$output_file"' EXIT

# The floor is deliberately well under the current count so ordinary test
# additions never touch it, while a collection collapse -- a broken conftest, a
# wrong working directory, a missing dependency -- still fails loudly instead of
# reporting a green run of nothing.
readonly MINIMUM_TESTS=250

[[ -d "$runtime_root" ]] || { printf 'missing runtime: %s\n' "$runtime_root" >&2; exit 1; }
[[ -x "$python_bin" ]] || {
  printf 'missing runtime virtualenv: %s\nCreate it with: cd Producer/Runtime && uv sync --group dev\n' \
    "$python_bin" >&2
  exit 1
}

ruff_bin="$runtime_root/.venv/bin/ruff"
vulture_bin="$runtime_root/.venv/bin/vulture"

printf '%s\n' 'stage=preparation-runtime-lint.start' >&2

# Lint and dead-code rank with tests in this repository's standard, so the leg
# runs the runtime's own `make validate` trio rather than pytest alone. vulture
# is invoked bare: its paths and the baseline allowlist come from the runtime's
# pyproject [tool.vulture], so passing paths here would silently diverge from
# what `make deadcode` and the pre-commit hook check.
for tool_path in "$ruff_bin" "$vulture_bin"; do
  [[ -x "$tool_path" ]] || {
    printf 'missing dev tool: %s\nCreate it with: cd Producer/Runtime && uv sync --group dev\n' \
      "$tool_path" >&2
    exit 1
  }
done

( cd "$runtime_root" && "$ruff_bin" check src tests ) >&2 || {
  printf 'preparation runtime lint failed\n' >&2
  exit 1
}
( cd "$runtime_root" && "$vulture_bin" ) >&2 || {
  printf 'preparation runtime dead-code check failed\n' >&2
  exit 1
}

printf '%s\n' 'stage=preparation-runtime-lint.complete' >&2
printf '%s\n' 'stage=preparation-runtime-tests.start' >&2

status=0
( cd "$runtime_root" && "$python_bin" -m pytest -q -p no:randomly ) >"$output_file" 2>&1 || status=$?
cat "$output_file" >&2

# Match the count, not a suffix of it: a greedy leading `.*` silently turns
# "2140 passed" into "0 passed" and reads as a collection collapse.
passed="$(grep -oE '[0-9]+ passed' "$output_file" | tail -1 | cut -d' ' -f1)"

if (( status != 0 )); then
  printf 'preparation runtime suite failed (exit %d)\n' "$status" >&2
  exit 1
fi
if [[ -z "$passed" || "$passed" -lt "$MINIMUM_TESTS" ]]; then
  printf 'preparation runtime suite passed %s tests; at least %d are expected\n' \
    "${passed:-0}" "$MINIMUM_TESTS" >&2
  exit 1
fi

printf 'stage=preparation-runtime-tests.complete tests=%s\n' "$passed" >&2
