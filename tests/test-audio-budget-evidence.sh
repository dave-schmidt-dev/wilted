#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
validator="$root_dir/scripts/validate-audio-budget-evidence.swift"
evidence="$root_dir/contracts/audio/evidence/2026-08-17-audio-budget-sizing.json"
schema="$root_dir/contracts/cloudkit/schema.json"
tmp_dir="$(mktemp -d -t wilted-audio-budget-evidence.XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT

output="$(swift "$validator" "$evidence" "$schema")"
printf '%s\n' "$output"
grep -Fq 'derive 80,000,000 bytes per revision' <<<"$output"
grep -Fq 'schema aggregate is 10x app-owned policy' <<<"$output"

sed 's/"appOwnedPerRevisionBudgetBytes":80000000/"appOwnedPerRevisionBudgetBytes":80000001/' \
  "$evidence" > "$tmp_dir/mutated-evidence.json"
if swift "$validator" "$tmp_dir/mutated-evidence.json" "$schema" > "$tmp_dir/evidence-failure.txt" 2>&1; then
  echo 'error: validator accepted mutated evidence' >&2
  exit 1
fi
grep -Fq 'app-owned per-revision budget does not match' "$tmp_dir/evidence-failure.txt"

sed 's/"maxRevisionAssetBytes": 80000000/"maxRevisionAssetBytes": 80000001/' \
  "$schema" > "$tmp_dir/mutated-schema.json"
if swift "$validator" "$evidence" "$tmp_dir/mutated-schema.json" > "$tmp_dir/schema-failure.txt" 2>&1; then
  echo 'error: validator accepted mutated schema' >&2
  exit 1
fi
grep -Fq 'schema maxRevisionAssetBytes does not match' "$tmp_dir/schema-failure.txt"

echo 'Audio budget evidence gate passed'
