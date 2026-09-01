#!/usr/bin/env bash
set -Eeuo pipefail

# Mutation meta-test for scripts/audit-walkthrough.sh.
#
# The shipping walkthrough is the passing baseline: if the real report stops
# auditing clean, this leg fails. Every `reject` case then mutates a copy of
# that same report and asserts the audit refuses it, so the audit cannot rot
# into a script that passes everything.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
audit="$root/scripts/audit-walkthrough.sh"
report="$root/docs/2026-09-01-mac-daily-driver-walkthrough.html"
tmp="$(mktemp -d -t wilted-walkthrough-tests.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

[[ -f "$report" ]] || { printf 'missing walkthrough: %s\n' "$report" >&2; exit 1; }

printf '%s\n' 'test.stage=report-baseline' >&2
bash "$audit" "$report" >/dev/null

# A pending report must block (exit 2) rather than pass or error. Strip only the
# <img> tags so the copy carries no image evidence at all, which is what the
# pending branch checks before it blocks; every prose token stays intact.
pending="$tmp/pending.html"
cp "$report" "$pending"
perl -0pi -e 's/<img\b[^>]*>//gs' "$pending"
perl -0pi -e 's/data-candidate-commit="[0-9a-f]{40}"/data-candidate-commit="PENDING_CURRENT_COMMIT"/' "$pending"
perl -0pi -e 's/data-gate-receipt="current-native-ui-receipt"/data-gate-receipt="PENDING_CURRENT_GATE"/' "$pending"
perl -0pi -e 's/data-capture-status="verified-content-viewport"/data-capture-status="pending-content-viewport"/' "$pending"
perl -0pi -e 's#<body><main>#<body><main><div id="capture-slot" class="card">Pending safe capture slot.</div>#' "$pending"
printf '%s\n' 'test.stage=pending-blocked' >&2
set +e
bash "$audit" "$pending" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || { printf 'pending report must be blocked, got %s\n' "$status" >&2; exit 1; }

declare -i cases=0
reject() {
  local name="$1"
  shift
  local candidate="$tmp/$name.html"
  cp "$report" "$candidate"
  "$@" "$candidate"
  if bash "$audit" "$candidate" >/dev/null 2>&1; then
    printf 'expected rejection: %s\n' "$name" >&2
    exit 1
  fi
  ((cases += 1))
}

reject missing-anchor perl -0pi -e 's/id="settings"/id="settings-removed"/'
reject broken-fragment perl -0pi -e 's/href="#prep"/href="#not-present"/'
reject duplicate-anchor perl -0pi -e 's/id="prep"/id="library"/'
reject missing-rail-contract perl -0pi -e 's/always-visible bottom rail/conditional rail/g'
reject missing-onboarding perl -0pi -e 's/onboarding/ONBOARDING_REMOVED/g'
reject missing-roles perl -0pi -e 's/id="roles"/id="roles-removed"/; s/\brole/ROLE_REMOVED/g'
reject missing-limits perl -0pi -e 's/id="limits"/id="limits-removed"/'
reject missing-disabled-state perl -0pi -e 's/disabled/DISABLED_REMOVED/g'
reject invalid-candidate perl -0pi -e 's/data-candidate-commit="[0-9a-f]{40}"/data-candidate-commit="not-a-commit"/'
reject invalid-gate perl -0pi -e 's/current-native-ui-receipt/stale-gate/g'
reject missing-method perl -0pi -e 's/XCUIElement\.screenshot\(\)/missing-method/g'
reject missing-geometry-scope perl -0pi -e 's/NSApp\.mainWindow\.contentView/missing-scope/g'
reject missing-fullscreen-suppression perl -0pi -e 's/systemAttachmentLifetime/missing-suppression/g'
reject missing-system-boundary perl -0pi -e 's/Finder/FINDER_REMOVED/g'
reject external-resource perl -0pi -e 's#</head>#<link href="https://example.test/x.css"></head>#'
reject missing-image perl -0pi -e 's#data:image/png;base64,[^"[:space:]<]+#data:image/png;base64,#g'
reject malformed-image perl -0pi -e 's#data:image/png;base64,[^"[:space:]<]+#data:image/png;base64,not-a-png#g'
reject truncated-image perl -0pi -e 's#(data:image/png;base64,)[^"[:space:]<]+#$1aGVsbG8=#g'
reject missing-caption perl -0pi -e 's/<figcaption>.*?<\/figcaption>//s'
reject figure-image-mismatch perl -0pi -e 's/<img\b[^>]*>//s'
reject pending-with-image perl -0pi -e 's/data-capture-status="verified-content-viewport"/data-capture-status="pending-content-viewport"/'
reject release-claim perl -0pi -e 's/owner acceptance remains pending/owner acceptance approved/'

printf '%s\n' "test.stage=complete cases=$cases" >&2
