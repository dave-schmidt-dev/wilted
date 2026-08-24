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
  "PASS 09-invalid-aggregate-budget.json" \
  "PASS 10-valid-transcript.json"; do
  if ! printf '%s\n' "$output" | grep -Fqx "$expected"; then
    echo "error: missing fixture result: $expected" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
transcript_fixture="$fixture_dir/10-valid-transcript.json"

expect_transcript_rejection() {
  local name="$1"
  if ! swift "$validator" "$tmp_dir/$name" >"$tmp_dir/$name.out" 2>&1; then
    echo "error: invalid transcript fixture was not rejected cleanly: $name" >&2
    cat "$tmp_dir/$name.out" >&2
    exit 1
  fi
  if ! grep -Fq "PASS case.json" "$tmp_dir/$name.out"; then
    echo "error: invalid transcript fixture did not report a passing rejection: $name" >&2
    cat "$tmp_dir/$name.out" >&2
    exit 1
  fi
}

mkdir "$tmp_dir/unstable-name" "$tmp_dir/invalid-language" "$tmp_dir/missing-text"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "unstable-record-name"/' \
  -e 's/transcript:item-transcript:rev-transcript-v1/transcript:wrong:identity/g' \
  "$transcript_fixture" >"$tmp_dir/unstable-name/case.json"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "invalid-language-code"/' \
  -e 's/"en-US"/"en_US"/' "$transcript_fixture" >"$tmp_dir/invalid-language/case.json"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "missing-transcript-text"/' \
  -e '/"text":/d' "$transcript_fixture" >"$tmp_dir/missing-text/case.json"

expect_transcript_rejection unstable-name
expect_transcript_rejection invalid-language
expect_transcript_rejection missing-text

echo "CloudKit contract gate passed"
