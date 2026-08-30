#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readme="$repo_root/README.md"
invariants="$repo_root/INVARIANTS.md"

fail() {
  printf 'mac-first docs assertion failed: %s\n' "$1" >&2
  exit 1
}

assert_fixed() {
  local needle="$1"
  local file="$2"
  local label="$3"
  grep -Fq -- "$needle" "$file" || fail "$label"
}

assert_absent() {
  local needle="$1"
  local file="$2"
  local label="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$label"
  fi
}

for required_file in "$readme" "$invariants"; do
  [[ -f "$required_file" ]] || fail "missing required file: $required_file"
done

assert_fixed "must reach Phase 3 Mac owner acceptance before any fresh iPhone/CloudKit qualification" "$readme" "README must place Mac daily use before iPhone/CloudKit qualification"
if grep -Eiq 'excluded[^[:cntrl:]]*(RSS discovery|podcasts?)' "$readme"; then
  fail "README must not exclude RSS discovery or podcasts from the active Mac milestone"
fi

assert_fixed "Podcast feed ItemID derives from its canonical feed URL" "$invariants" "missing stable podcast feed ItemID contract"
assert_fixed "podcast episode ItemID derives from canonical feed URL plus normalized RSS GUID" "$invariants" "missing stable podcast episode GUID identity contract"
assert_fixed "falling back to canonical enclosure URL only when the GUID is absent" "$invariants" "missing GUID-less episode identity fallback"
assert_fixed "Both podcast ItemID derivations are source-kind-namespaced" "$invariants" "missing source-kind ItemID namespace"
assert_fixed "Downloaded-media RevisionID is source-kind-namespaced and derived from the verified audio content hash" "$invariants" "missing downloaded-media RevisionID contract"
assert_fixed "one atomic move publishes the immutable local revision" "$invariants" "missing atomic podcast import contract"

assert_fixed "before fresh iPhone or CloudKit qualification begins" "$invariants" "Mac owner acceptance must precede fresh iPhone or CloudKit qualification"

printf '%s\n' "mac-first docs assertion passed"
