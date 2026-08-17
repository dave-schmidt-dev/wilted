#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$root_dir/contracts/fixtures"
validator="$root_dir/scripts/validate-contract-fixtures.swift"

fixture_count="$(find "$fixture_dir" -type f -name '*.json' | wc -l | tr -d ' ')"
if [[ ! "$fixture_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: expected a nonzero JSON fixture count" >&2
  exit 1
fi

output="$(swift "$validator" "$fixture_dir")"
printf '%s\n' "$output"

reported_count="$(printf '%s\n' "$output" | sed -n 's/^Validated \([1-9][0-9]*\) fixture cases$/\1/p')"
if [[ -z "$reported_count" ]]; then
  echo "error: validator did not report a nonzero case count" >&2
  exit 1
fi
if [[ "$reported_count" -ne "$fixture_count" ]]; then
  echo "error: discovered $fixture_count fixtures but validator executed $reported_count" >&2
  exit 1
fi
