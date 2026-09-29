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

assert_fixed "iPhone library sync now proceeds in parallel with Mac acceptance rather than after it" "$readme" "README must preserve parallel iPhone library-sync development"
assert_fixed "Mac owner acceptance no longer gates library-sync development" "$readme" "README must not restore the superseded Mac-first development gate"
assert_fixed "physical-device and CloudKit qualification remain pending" "$readme" "README must retain pending physical-device and CloudKit qualification"
if grep -Eiq 'excluded[^[:cntrl:]]*(RSS discovery|podcasts?)' "$readme"; then
  fail "README must not exclude RSS discovery or podcasts from the active Mac milestone"
fi

assert_fixed "### W-INV-009 — Release evidence remains separated" "$invariants" "missing release-evidence invariant"
assert_fixed "Mac owner acceptance no longer gates iPhone library-sync development, which proceeds in parallel" "$invariants" "W-INV-009 must permit parallel library-sync development"
assert_fixed "fresh iPhone or CloudKit qualification still needs its own evidence" "$invariants" "fresh iPhone or CloudKit qualification must remain separately evidenced"
assert_fixed "are distinct evidence; none substitutes for another" "$invariants" "Mac, CloudKit, and release evidence must remain distinct"

assert_fixed "Podcast feed ItemID derives from its canonical feed URL" "$invariants" "missing stable podcast feed ItemID contract"
assert_fixed "podcast episode ItemID derives from canonical feed URL plus normalized RSS GUID" "$invariants" "missing stable podcast episode GUID identity contract"
assert_fixed "falling back to canonical enclosure URL only when the GUID is absent" "$invariants" "missing GUID-less episode identity fallback"
assert_fixed "Both podcast ItemID derivations are source-kind-namespaced" "$invariants" "missing source-kind ItemID namespace"
assert_fixed "Downloaded-media RevisionID is source-kind-namespaced and derived from the verified audio content hash" "$invariants" "missing downloaded-media RevisionID contract"
assert_fixed "one atomic move publishes the immutable local revision" "$invariants" "missing atomic podcast import contract"

printf '%s\n' "mac-first docs assertion passed"
