#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge="$root/app/wilted_app_store_connect_bridge.py"

[[ -x "$root/app/release-status" ]] || { echo 'release wrapper missing: release-status' >&2; exit 1; }
[[ -x "$root/app/release-testflight" ]] || { echo 'release wrapper missing: release-testflight' >&2; exit 1; }
[[ -f "$bridge" ]] || { echo 'release bridge missing' >&2; exit 1; }
cd "$root"
python3 -m unittest tests.test_release_archive_ios
python3 -m unittest app.test_release_stage_readiness
python3 -m unittest app.test_wilted_device_profile
python3 "$root/tests/test_wilted_release_bridge.py"
python3 "$root/tests/test_wilted_release_bridge_worktree.py"

for wrapper in "$root/app/release-status" "$root/app/release-testflight" "$root/app/verify-release-ui"; do
  output="$("$wrapper" --adapter /private/var/unsafe 2>&1 || true)"
  grep -Fq 'caller-selected paths and credentials are not permitted' <<<"$output" || {
    echo "release wrapper accepted a caller-selected adapter: $wrapper" >&2
    exit 1
  }
done

# Every release entry point runs from the tool-owned release checkout, after its
# argument guard: prepare refreshes it, everything else stays where it is.
for entry in release-status release-testflight verify-release-ui; do
  [[ -x "$root/app/$entry" ]] || { echo "release wrapper missing: $entry" >&2; exit 1; }
  grep -Fq "release_checkout_exec \"\$CENTRAL_ROOT\" .release/release-adapter.json app/$entry" "$root/app/$entry" || {
    echo "release wrapper does not re-exec in the release checkout: $entry" >&2
    exit 1
  }
  guard_line="$(grep -n 'caller-selected paths and credentials are not permitted' "$root/app/$entry" | head -n 1 | cut -d: -f1)"
  exec_line="$(grep -n 'release_checkout_exec "' "$root/app/$entry" | head -n 1 | cut -d: -f1)"
  [[ -n "$guard_line" && -n "$exec_line" && "$guard_line" -lt "$exec_line" ]] || {
    echo "release wrapper must refuse caller-selected paths before it creates a checkout: $entry" >&2
    exit 1
  }
done
grep -Fq -- '--prepare-only) checkout_mode=refresh' "$root/app/release-testflight" || { echo 'prepare must refresh the release checkout' >&2; exit 1; }
grep -Fq 'app/release-status stay' "$root/app/release-status" || { echo 'status must stay in the release checkout' >&2; exit 1; }
grep -Fq 'app/verify-release-ui stay' "$root/app/verify-release-ui" || { echo 'UI verification must stay in the release checkout' >&2; exit 1; }
python3 -m unittest tests.test_gate_diagnostic

source "$root/scripts/lib/test-temp-state.sh"
temporary_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-release-bridge.XXXXXX")"; wilted_temp_mark_owned "$temporary_root"
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
