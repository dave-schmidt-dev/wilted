#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Proves verify_nested_signatures in scripts/attended-cloudkit-run.sh rejects an
# embedded Watch app whose seal was broken after signing (the 2026-10-07 stale
# embedded.mobileprovision regression) and accepts a cleanly signed one.
#
# Hermetic: ad-hoc signs throwaway bundles under $TMPDIR; no build, no device.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/attended-cloudkit-run.sh"
failures=0

fail() { printf 'attended-nested-signature.fail %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'attended-nested-signature.ok %s\n' "$*" >&2; }

tmp_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-nested-sig.XXXXXX")"
cleanup() { [[ -d "$tmp_root" ]] && rm -rf "$tmp_root"; }
trap cleanup EXIT

# Load only the function under test plus the script's fail().
lib="$tmp_root/lib.sh"
{
  printf '%s\n' "fail() { printf 'attended.error %s\\n' \"\$*\" >&2; exit 1; }"
  sed -n '/^verify_nested_signatures() {/,/^}/p' "$script"
} >"$lib"
grep -q 'verify_nested_signatures()' "$lib" && pass 'function extracted' || fail 'function not found in script'

make_bundle() { # <dir> <executable-name>
  mkdir -p "$1"
  cp /usr/bin/true "$1/$2"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>%s</string><key>CFBundleIdentifier</key><string>test.%s</string></dict></plist>\n' "$2" "$2" >"$1/Info.plist"
  printf 'profile-v1' >"$1/embedded.mobileprovision"
  codesign --force -s - "$1" >/dev/null 2>&1
}

app="$tmp_root/Outer.app"
make_bundle "$app/Watch/Inner.app" Inner
make_bundle "$app" Outer

run_check() { bash -c "source '$lib'; verify_nested_signatures test '$app'" 2>"$tmp_root/err"; }

if run_check; then pass 'clean nested app accepted'; else fail "clean nested app rejected: $(cat "$tmp_root/err")"; fi

# Regression: replace the nested profile after signing, as the incremental build did.
printf 'profile-v2' >"$app/Watch/Inner.app/embedded.mobileprovision"
if run_check; then
  fail 'tampered nested app accepted'
else
  grep -qF 'nested Watch/Inner.app signature does not verify' "$tmp_root/err" \
    && pass 'tampered nested app rejected with its path' \
    || fail "unexpected message: $(cat "$tmp_root/err")"
fi

if (( failures > 0 )); then
  printf 'attended-nested-signature.fail %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'attended-nested-signature.ok all checks passed\n' >&2
