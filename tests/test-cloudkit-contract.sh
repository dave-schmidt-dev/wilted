#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$root_dir/contracts/cloudkit/fixtures"
validator="$root_dir/scripts/validate-cloudkit-contract.swift"

fixture_count="$(find "$fixture_dir" -type f -name '*.json' | wc -l | tr -d ' ')"
if [[ ! "$fixture_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: expected CloudKit fixtures" >&2
  exit 1
fi

output="$(swift "$validator" "$fixture_dir")"
printf '%s\n' "$output"
reported_count="$(printf '%s\n' "$output" | sed -n 's/^Validated \([1-9][0-9]*\) CloudKit contract fixtures$/\1/p')"
if [[ -z "$reported_count" || "$reported_count" -ne "$fixture_count" ]]; then
  echo "error: validator count did not match fixture count" >&2
  exit 1
fi

for expected in \
  "PASS 01-valid-publish-decode.json" \
  "PASS 02-invalid-missing-field.json" \
  "PASS 03-invalid-type.json" \
  "PASS 04-invalid-schema-version.json" \
  "PASS 05-invalid-reference-zone.json" \
  "PASS 06-invalid-query.json" \
  "PASS 07-valid-publication-budget.json" \
  "PASS 08-invalid-revision-budget.json" \
  "PASS 09-invalid-aggregate-budget.json"; do
  if ! printf '%s\n' "$output" | grep -Fqx "$expected"; then
    echo "error: missing fixture result: $expected" >&2
    exit 1
  fi
done

echo "CloudKit contract gate passed"
