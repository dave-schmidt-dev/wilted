#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=../scripts/lib/test-runner.sh
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/scripts/assert-mac-first-docs.sh"
scratch="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-mac-first-docs.XXXXXX")"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

base="$scratch/base"
fixture="$scratch/fixture"
mkdir -p "$base/scripts" "$base/.logs" "$fixture/scripts" "$fixture/.logs"
cp "$checker" "$base/scripts/"
cp "$checker" "$fixture/scripts/"
cp "$repo_root/README.md" "$repo_root/INVARIANTS.md" "$base/"

assert_rejected() {
  local label="$1" document="$2" old="$3" replacement="$4" expected="$5" output="$scratch/$1.log"
  cp "$base/README.md" "$base/INVARIANTS.md" "$fixture/"
  python3 - "$fixture/$document" "$old" "$replacement" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle, replacement = sys.argv[2:]
if text.count(needle) != 1:
    raise SystemExit(f"fixture mutation expected one occurrence: {needle}")
path.write_text(text.replace(needle, replacement, 1))
PY
  if bash "$fixture/scripts/assert-mac-first-docs.sh" >"$output" 2>&1; then
    printf 'docs checker accepted invalid %s fixture\n' "$label" >&2
    exit 1
  fi
  grep -Fq "$expected" "$output" || {
    printf 'docs checker rejected %s for the wrong reason\n' "$label" >&2
    cat "$output" >&2
    exit 1
  }
  printf 'mac-first.docs-fixture.rejected case=%s\n' "$label"
}

cp "$base/README.md" "$base/INVARIANTS.md" "$fixture/"
bash "$fixture/scripts/assert-mac-first-docs.sh"

assert_rejected parallel-sync INVARIANTS.md \
  'Mac owner acceptance no longer gates iPhone library-sync development, which proceeds in parallel' \
  'Mac owner acceptance gates iPhone library-sync development until after Mac acceptance' \
  'W-INV-009 must permit parallel library-sync development'
assert_rejected separate-qualification INVARIANTS.md \
  'fresh iPhone or CloudKit qualification still needs its own evidence' \
  'fresh iPhone or CloudKit qualification inherits prior Mac evidence' \
  'fresh iPhone or CloudKit qualification must remain separately evidenced'
assert_rejected evidence-separation INVARIANTS.md \
  'are distinct evidence; none substitutes for another' \
  'are one shared evidence category' \
  'Mac, CloudKit, and release evidence must remain distinct'
assert_rejected identity-rule INVARIANTS.md \
  'Podcast feed ItemID derives from its canonical feed URL' \
  'Podcast feed ItemID derives from the feed title' \
  'missing stable podcast feed ItemID contract'

printf '%s\n' 'mac-first.docs-tests.passed'
