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
  "PASS 10-valid-transcript.json" \
  "PASS 11-valid-timed-transcript.json"; do
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

# Timing and cues are one fact stated twice, so each half alone must be
# refused. A record with timing and no cues would scroll against nothing; a
# record with cues and no timing would present them as evidence it never
# claimed; and version one predates timing entirely.
timed_fixture="$fixture_dir/11-valid-timed-transcript.json"
mkdir "$tmp_dir/timing-without-cues" "$tmp_dir/cues-without-timing" "$tmp_dir/unknown-timing" \
  "$tmp_dir/version-one-with-timing" "$tmp_dir/cues-not-compressed"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "missing-transcript-cues"/' \
  -e '/"cues":/d' "$timed_fixture" >"$tmp_dir/timing-without-cues/case.json"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "unexpected-transcript-cues"/' \
  -e '/"timing":/d' "$timed_fixture" >"$tmp_dir/cues-without-timing/case.json"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "invalid-enum"/' \
  -e 's/"value": "published"/"value": "guessed"/' "$timed_fixture" >"$tmp_dir/unknown-timing/case.json"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "unsupported-schema-version"/' \
  -e 's/"schemaVersion": {"type": "Int64", "value": 2}/"schemaVersion": {"type": "Int64", "value": 1}/' \
  "$timed_fixture" >"$tmp_dir/version-one-with-timing/case.json"
sed -e 's/"expectedValid": true/"expectedValid": false, "expectedError": "invalid-transcript-cues"/' \
  -e 's/"cues": {"type": "Bytes", "value": "[^"]*"}/"cues": {"type": "Bytes", "value": "bm90LXpsaWI="}/' \
  "$timed_fixture" >"$tmp_dir/cues-not-compressed/case.json"

expect_transcript_rejection timing-without-cues
expect_transcript_rejection cues-without-timing
expect_transcript_rejection unknown-timing
expect_transcript_rejection version-one-with-timing
expect_transcript_rejection cues-not-compressed

echo "CloudKit contract gate passed"
