#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
schema="$root_dir/contracts/domain/schema.json"
fixtures="$root_dir/contracts/fixtures"

# The domain gate must agree with the existing executable fixture gate.
bash "$root_dir/tests/test-contract-fixtures.sh"
swift "$root_dir/scripts/validate-domain-contract.swift" "$schema" "$fixtures"

# Unknown operations are contractual errors and must fail closed.
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wilted-domain-contract.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
cp -R "$fixtures" "$tmp_dir/fixtures"
mutated="$tmp_dir/fixtures/01-publish-decode.json"
sed -i.bak 's/"operation": "publishDecode"/"operation": "unknownOperation"/' "$mutated"
rm -f "$mutated.bak"
if swift "$root_dir/scripts/validate-domain-contract.swift" "$schema" "$tmp_dir/fixtures" >/dev/null 2>&1; then
    echo "error: domain validator accepted an unknown operation" >&2
    exit 1
fi
echo "PASS negative mutation: unknown operation rejected"

# Unknown fields in a contractual fixture must also fail closed.
cp -R "$fixtures" "$tmp_dir/field-fixtures"
field_mutated="$tmp_dir/field-fixtures/01-publish-decode.json"
sed -i.bak 's/"title": "Alpha"/"title": "Alpha", "unexpectedField": true/' "$field_mutated"
rm -f "$field_mutated.bak"
if swift "$root_dir/scripts/validate-domain-contract.swift" "$schema" "$tmp_dir/field-fixtures" >/dev/null 2>&1; then
    echo "error: domain validator accepted an unknown field" >&2
    exit 1
fi
echo "PASS negative mutation: unknown field rejected"

# Readiness cannot be moved back onto an AudioRevision.
readiness_schema="$tmp_dir/readiness-schema.json"
cp "$schema" "$readiness_schema"
sed -i.bak 's/"values": \["ready"\]/"values": ["preparing"]/' "$readiness_schema"
rm -f "$readiness_schema.bak"
if swift "$root_dir/scripts/validate-domain-contract.swift" "$readiness_schema" "$fixtures" >/dev/null 2>&1; then
    echo "error: domain validator accepted non-ready revision readiness" >&2
    exit 1
fi
echo "PASS negative mutation: non-ready revision readiness rejected"

# Create-time playback records must not require CloudKit system fields.
cloudkit_schema="$tmp_dir/cloudkit-schema.json"
cp "$schema" "$cloudkit_schema"
sed -i.bak 's/"encodedCloudKitRecordSystemFields": {"type": "string", "required": false/"encodedCloudKitRecordSystemFields": {"type": "string", "required": true/' "$cloudkit_schema"
rm -f "$cloudkit_schema.bak"
if swift "$root_dir/scripts/validate-domain-contract.swift" "$cloudkit_schema" "$fixtures" >/dev/null 2>&1; then
    echo "error: domain validator accepted required create-time CloudKit fields" >&2
    exit 1
fi
echo "PASS negative mutation: create-time CloudKit fields remain optional"

# Tagged producer streams must declare exactly one terminal message.
stream_schema="$tmp_dir/stream-schema.json"
cp "$schema" "$stream_schema"
sed -i.bak 's/"terminalCount": "exactlyOne"/"terminalCount": "atMostOne"/g' "$stream_schema"
rm -f "$stream_schema.bak"
if swift "$root_dir/scripts/validate-domain-contract.swift" "$stream_schema" "$fixtures" >/dev/null 2>&1; then
    echo "error: domain validator accepted a non-exact terminal count" >&2
    exit 1
fi
echo "PASS negative mutation: exactly-one terminal rule enforced"

# The CloudKit/domain spelling is publishedTime, never publishedAt.
naming_schema="$tmp_dir/naming-schema.json"
cp "$schema" "$naming_schema"
sed -i.bak 's/"publishedTime": {"type"/"publishedAt": {"type"/' "$naming_schema"
rm -f "$naming_schema.bak"
if swift "$root_dir/scripts/validate-domain-contract.swift" "$naming_schema" "$fixtures" >/dev/null 2>&1; then
    echo "error: domain validator accepted non-authoritative publishedAt naming" >&2
    exit 1
fi
echo "PASS negative mutation: publishedTime naming enforced"

# Timeout fixtures must retain the terminal timedOut error contract.
timeout_fixtures="$tmp_dir/timeout-fixtures"
cp -R "$fixtures" "$timeout_fixtures"
timeout_mutated="$timeout_fixtures/16-timeout-terminal-error.json"
sed -i.bak 's/"terminalErrorCode": "timedOut"/"terminalErrorCode": "failed"/' "$timeout_mutated"
rm -f "$timeout_mutated.bak"
if swift "$root_dir/scripts/validate-domain-contract.swift" "$schema" "$timeout_fixtures" >/dev/null 2>&1; then
    echo "error: domain validator accepted a non-timedOut timeout terminal error" >&2
    exit 1
fi
echo "PASS negative mutation: timeout terminal error code enforced"
