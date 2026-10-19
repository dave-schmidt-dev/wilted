#!/bin/bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo_root/Probes/ArticleExtractionProbe"
fixtures="$package/Fixtures"

manifest_count="$(grep -c '"id":' "$fixtures/manifest.json")"
html_count="$(find "$fixtures" -maxdepth 1 -type f -name '*.html' | wc -l | tr -d ' ')"
if [[ "$manifest_count" -ne 10 || "$html_count" -ne 10 ]]; then
  echo "expected exactly 10 manifest entries and 10 HTML fixtures" >&2
  exit 1
fi

test_output="$(python3 "$repo_root/scripts/build-with-cache.py" run swiftpm article-extraction-probe -- swift test --package-path "$package" 2>&1)"
printf '%s\n' "$test_output"
test_count="$(printf '%s\n' "$test_output" | sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' | tail -1)"
if [[ -z "$test_count" || "$test_count" -eq 0 ]]; then
  echo "swift test executed zero detectable tests" >&2
  exit 1
fi

source "$repo_root/scripts/lib/test-temp-state.sh"
work_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-article-extraction-probe.XXXXXX")"; wilted_temp_mark_owned "$work_dir"
trap 'rm -rf "$work_dir"' EXIT
status_file="$work_dir/status.log"
summary="$(python3 "$repo_root/scripts/build-with-cache.py" run swiftpm article-extraction-probe -- swift run --package-path "$package" article-extraction-probe --fixtures "$fixtures" 2> >(tee "$status_file" >&2))"
printf '%s\n' "$summary"

finished_count="$(grep -c 'stage=finished' "$status_file")"
if [[ "$finished_count" -ne 10 ]]; then
  echo "expected visible completion progress for 10 fixtures" >&2
  exit 1
fi
if ! printf '%s\n' "$summary" | grep -q '"total":10'; then
  echo "summary did not report 10 fixtures" >&2
  exit 1
fi
if ! printf '%s\n' "$summary" | grep -q '"passed":10'; then
  echo "summary did not report 10 passing fixtures" >&2
  exit 1
fi
