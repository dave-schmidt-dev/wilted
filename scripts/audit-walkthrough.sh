#!/usr/bin/env bash
set -Eeuo pipefail

say() { printf '%s\n' "$*" >&2; }
fail() { printf 'audit.error %s\n' "$1" >&2; exit 1; }
blocked() { printf 'audit.blocked %s\n' "$1" >&2; exit 2; }
[[ $# -eq 1 ]] || fail 'usage: audit-walkthrough.sh PATH'
report="$1"
[[ -f "$report" ]] || fail "missing report: $report"
command -v file >/dev/null 2>&1 || fail 'missing required tool: file'
html="$(<"$report")"
# Rendered-copy contracts must not be satisfied by a coincidental byte sequence
# inside one of the multi-megabyte embedded PNG payloads. Image evidence is
# validated separately below against the unmodified document.
html_text="$(printf '%s' "$html" | perl -0777 -pe 's#(data:image/png;base64,)[^"[:space:]<]+#$1#g')"
need() { [[ "$html_text" == *"$1"* ]] || fail "missing token: $1"; }

say "audit.stage=structure path=$report"
for token in '<html' 'data-candidate-commit=' 'data-gate-receipt=' 'data-capture-status=' \
  'id="setup"' 'id="current"' 'id="method"' 'id="feeds"' 'id="menu"' 'id="playback"' \
  'id="settings"' 'id="recovery"' 'id="system-boundaries"' 'id="non-claims"' 'id="owner-checklist"' \
  'always-visible bottom rail' 'Feeds' 'Larder' 'Settings' 'Transcript' 'Notes' 'Escape' 'focus' \
  'download' 'recovery' 'Finder' 'system-owned' 'Accessibility tree' 'content viewport' \
  'id="onboarding"' 'id="roles"' 'id="limits"' 'onboarding' 'role' 'disabled' \
  'id="fig-menu-deferred-prepare-now"' 'Prepare now' 'wilted-menu-prepare-now-&lt;id&gt;' \
  'Group by: Status' 'Feed and Date' 'Sort by: Custom order' '&lt;release date&gt;' \
  'Play Now inserts the selected episode immediately before the current episode' \
  'XCUIElement.screenshot()' 'NSApp.mainWindow.contentView' 'systemAttachmentLifetime' \
  'Production CloudKit is not claimed' \
  'physical-device is not claimed' 'App Store Connect is not claimed' 'TestFlight is not claimed' \
  'deployment is not claimed' 'publication is not claimed' 'owner acceptance remains pending'; do need "$token"; done

if LC_ALL=C grep -Eiq 'https?://|<link[[:space:]]|<script[^>]*[[:space:]]src[[:space:]]*=|@import' "$report"; then
  fail 'external resource'
fi
ids="$(printf '%s' "$html" | perl -ne 'while(/\bid="([^"]+)"/g){print "$1\n"}')"
[[ -n "$ids" ]] || fail 'missing anchors'
duplicates="$(printf '%s\n' "$ids" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "duplicate anchors: $duplicates"
while IFS= read -r anchor; do
  [[ -z "$anchor" || "$(printf '%s\n' "$ids" | grep -Fxc "$anchor")" -eq 1 ]] || fail "broken anchor: $anchor"
done < <(printf '%s' "$html" | perl -ne 'while(/\bhref="#([^"]+)"/g){print "$1\n"}')

candidate="$(printf '%s' "$html" | perl -ne 'print "$1\n" if /data-candidate-commit="([^"]+)"/' | head -1)"
gate="$(printf '%s' "$html" | perl -ne 'print "$1\n" if /data-gate-receipt="([^"]+)"/' | head -1)"
capture_status="$(printf '%s' "$html" | perl -ne 'print "$1\n" if /data-capture-status="([^"]+)"/' | head -1)"
[[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || [[ "$candidate" == PENDING_CURRENT_COMMIT ]] || fail 'invalid candidate metadata'
[[ "$gate" == current-native-ui-receipt || "$gate" == PENDING_CURRENT_GATE ]] || fail 'invalid gate metadata'
[[ "$capture_status" == verified-content-viewport || "$capture_status" == pending-content-viewport ]] || fail 'invalid capture status'

if LC_ALL=C grep -Eiq 'owner acceptance[^<]{0,80}(complete|approved|accepted)|Production CloudKit[^<]{0,80}(complete|approved|accepted)|physical-device[^<]{0,80}(complete|approved|accepted)|App Store Connect[^<]{0,80}(complete|approved|accepted)|TestFlight[^<]{0,80}(complete|approved|accepted)|deployment[^<]{0,80}(complete|approved|accepted)|publication[^<]{0,80}(complete|approved|accepted)' "$report"; then
  fail 'release or owner-acceptance claim drift'
fi

if [[ "$capture_status" == pending-content-viewport ]]; then
  need 'id="capture-slot"'
  if LC_ALL=C grep -Eiq '<img\b|data:image/' "$report"; then fail 'pending capture report embeds image evidence'; fi
  [[ "$candidate" == PENDING_CURRENT_COMMIT ]] || blocked 'current candidate metadata is required before capture'
  [[ "$gate" == PENDING_CURRENT_GATE ]] || blocked 'current gate receipt is required before capture'
  blocked 'safe signed-process content-viewport PNGs and metadata are pending'
fi

[[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || fail 'verified report needs exact candidate commit'
[[ "$gate" == current-native-ui-receipt ]] || fail 'verified report needs current gate receipt'
deferred_figure="$(printf '%s' "$html" | perl -0777 -ne 'if (/<figure id="fig-menu-deferred-prepare-now">.*?<\/figure>/s) { print $& }')"
[[ -n "$deferred_figure" ]] || fail 'missing deferred Prepare now frame'
[[ "$deferred_figure" == *'content viewport'* ]] || fail 'deferred Prepare now frame missing content-viewport caption'
[[ "$deferred_figure" == *'data:image/png;base64,'* ]] || fail 'deferred Prepare now frame missing image evidence'
[[ "$deferred_figure" == *'Prepare now'* ]] || fail 'deferred Prepare now frame missing control copy'
[[ "$deferred_figure" == *'wilted-menu-prepare-now-&lt;id&gt;'* ]] || fail 'deferred Prepare now frame missing control identifier'
figure_count="$(printf '%s' "$html" | perl -ne '$count += () = /<figure\b/g; END { print $count }')"
[[ "$figure_count" -gt 0 ]] || fail 'missing content-viewport image evidence'
printf '%s' "$html" | perl -0777 -ne 'while(/<figure\b.*?<\/figure>/sg){my $f = $&; exit 1 unless $f =~ /<figcaption\b/ && $f =~ /content viewport/ && $f =~ /data:image\/png;base64,/} exit 0' || fail 'missing content-viewport caption'
img_data="$(printf '%s' "$html" | perl -0777 -ne 'while(/data:image\/png;base64,([^"[:space:]<]+)/sg){print "$1\n"}')"
[[ -n "$img_data" ]] || fail 'missing embedded PNG evidence'
img_count="$(printf '%s\n' "$img_data" | grep -c .)"
[[ "$img_count" -eq "$figure_count" ]] || fail "figure/image mismatch: figures=$figure_count images=$img_count"
while IFS= read -r data; do
  tmp="$(mktemp -t wilted-audit.XXXXXX)"
  trap 'rm -f "${tmp:-}"' EXIT
  printf '%s' "$data" | base64 -D >"$tmp" 2>/dev/null || fail 'malformed embedded PNG evidence'
  file -b "$tmp" | grep -q '^PNG image data' || fail 'malformed embedded PNG evidence'
  rm -f "$tmp"
done <<<"$img_data"
printf '{"status":"pass","report":"%s","figures":%s}\n' "$report" "$figure_count"
