#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge="$root/app/wilted_app_store_connect_bridge.py"

[[ -x "$root/app/release-status" ]] || { echo 'release wrapper missing: release-status' >&2; exit 1; }
[[ -x "$root/app/release-testflight" ]] || { echo 'release wrapper missing: release-testflight' >&2; exit 1; }
[[ -f "$bridge" ]] || { echo 'release bridge missing' >&2; exit 1; }
python3 "$root/tests/test_wilted_release_bridge.py"

for wrapper in "$root/app/release-status" "$root/app/release-testflight"; do
  output="$("$wrapper" --adapter /tmp/unsafe 2>&1 || true)"
  grep -Fq 'caller-selected paths and credentials are not permitted' <<<"$output" || {
    echo "release wrapper accepted a caller-selected adapter: $wrapper" >&2
    exit 1
  }
done

prepare_branch="$(awk '/^[[:space:]]*--prepare-only\)/,/^[[:space:]]*;;/' "$root/app/release-testflight")"
grep -Fq -- '--successor-correction' <<<"$prepare_branch" || {
  echo 'release-testflight prepare wrapper omitted successor correction' >&2
  exit 1
}

for operation in --stage --upload; do
  operation_branch="$(awk "/^[[:space:]]*${operation}\\)/,/^[[:space:]]*;;/" "$root/app/release-testflight")"
  if grep -Fq -- '--successor-correction' <<<"$operation_branch"; then
    echo "release-testflight ${operation} wrapper must not use successor correction" >&2
    exit 1
  fi
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-release-bridge.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
cp "$bridge" "$temporary_root/bridge.py"
chmod 700 "$temporary_root/bridge.py"
output="$(python3 "$temporary_root/bridge.py" --operation upload --product wilted-ios --candidate invalid/identity 2>&1 || true)"
grep -Fq 'candidate-identity-invalid' <<<"$output" || {
  echo 'release bridge accepted an invalid candidate identity' >&2
  exit 1
}
if grep -Eq 'APP_STORE_CONNECT_(API_KEY|KEY_ID|ISSUER_ID)=' <<<"$output"; then
  echo 'release bridge printed a credential environment name/value pair' >&2
  exit 1
fi

echo 'release wrapper contract passed'
