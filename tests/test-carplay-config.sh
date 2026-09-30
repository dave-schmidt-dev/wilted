#!/usr/bin/env bash
# CarPlay configuration contract (docs/carplay-requirements.md): the Development build signs manually
# with the CarPlay audio profile and carries the entitlement; Production carries it only when CarPlay
# is ready for every user (its icon appears for everyone); the scene manifest declares the CarPlay scene.
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }

ios_block="$(awk '/^  WiltediOS:/{f=1; next} f && /^  [A-Za-z]/{f=0} f' project.yml)"
dev_block="$(printf '%s\n' "$ios_block" | awk '/^        Development:/{f=1; next} f && /^        [A-Za-z]/{f=0} f')"
[[ -n "$dev_block" ]] || fail 'could not read the WiltediOS Development block'
for line in 'CODE_SIGN_STYLE: Manual' 'PROVISIONING_PROFILE_SPECIFIER: Wilted iOS Development' \
  'CODE_SIGN_ENTITLEMENTS: WiltediOS/WiltediOS.entitlements'; do
  printf '%s\n' "$dev_block" | grep -Fq "$line" || fail "iOS Development config lacks: $line"
done
plutil -p WiltediOS/WiltediOS.entitlements | grep -Fq 'com.apple.developer.carplay-audio' \
  || fail 'iOS Development entitlements lack the CarPlay audio key'
if plutil -p WiltediOS/WiltediOSProduction.entitlements | grep -Fq 'carplay'; then
  fail 'iOS Production entitlements carry a CarPlay key before CarPlay is ready for all users'
fi
plutil -p WiltediOS/Info.plist | grep -Fq 'CPTemplateApplicationSceneSessionRoleApplication' \
  || fail 'iOS Info.plist lacks the CarPlay template scene role'
plutil -p WiltediOS/Info.plist | grep -Fq 'CarPlaySceneDelegate' \
  || fail 'iOS Info.plist does not name the CarPlay scene delegate'
printf '%s\n' 'carplay config test passed'
