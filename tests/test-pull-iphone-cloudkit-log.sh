#!/usr/bin/env bash
# scripts/pull-iphone-cloudkit-log.sh against a stand-in `xcrun` that copies only approved files.
# The fixture includes legacy title-bearing data to prove it is not exported or printed.
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-temp-state.sh"
fixture="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-pull-iphone-log.XXXXXX")"; wilted_temp_mark_owned "$fixture"
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }

mkdir -p "$fixture/bin" "$fixture/phone/Library/Logs/playback-v2" \
  "$fixture/phone/Library/Application Support/Wilted" "$fixture/out"
line() { printf '%s CloudKit operations: last 5m 1 reqs (1 records, 1 B) · since launch: %s reqs (%s records, 9 B) · callers: [poll: %s] · %s\n' "$1" "$2" "$3" "$2" "$4"; }
{
  printf '2026-11-03T10:00:00Z launch\n'
  line 2026-11-03T10:05:00Z 2 5 'no limits since launch'
  line 2026-11-03T10:10:00Z 5 12 'last limit: 10:08 (retry-after: 30s)'
} > "$fixture/phone/Library/Logs/cloudkit-operations.log.1"
{
  line 2026-11-03T10:15:00Z 6 14 'last limit: 10:08 (retry-after: 30s)'
  printf '2026-11-03T11:00:00Z launch\n'
  line 2026-11-03T11:05:00Z 4 60 'no limits since launch'
  printf '2026-11-03T12:00:00Z launch\n'
} > "$fixture/phone/Library/Logs/cloudkit-operations.log"

{
  for i in $(seq 1 25); do
    printf '2026-11-03T10:%02d:00Z journal-old line %d\n' "$i" "$i"
  done
} > "$fixture/phone/Library/Logs/playback-journal.log.1"
{
  for i in $(seq 26 50); do
    printf '2026-11-03T11:%02d:00Z journal-new line %d\n' "$((i - 25))" "$i"
  done
} > "$fixture/phone/Library/Logs/playback-journal.log"
printf 'legacy title-bearing story: Secret old headline\n' > "$fixture/phone/Library/Logs/playback-journal.log"
{
  for i in $(seq 1 45); do
    printf '2026-11-03T12:%02d:00Z schema=2 source=phone event=pause item=item-private-tag position=%d.0\n' "$((i % 60))" "$i"
  done
} > "$fixture/phone/Library/Logs/playback-v2/playback-journal.log"
printf 'voice routing title: Secret local episode\n' > "$fixture/phone/Library/Application Support/Wilted/voice-routing.log"

cat > "$fixture/bin/xcrun" <<EOF
#!/usr/bin/env bash
dest=""
source=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == --destination ]] && dest="\$2"
  [[ "\$1" == --source ]] && source="\$2"
  shift
done
printf '%s\n' "\$source" >> "$fixture/copied-paths"
source_file="$fixture/phone/\$source"
[[ -f "\$source_file" ]] || exit 1
cp "\$source_file" "\$dest"
EOF
chmod +x "$fixture/bin/xcrun"

out="$(PATH="$fixture/bin:$PATH" WILTED_DEVICE_ID=test-device "$repo_root/scripts/pull-iphone-cloudkit-log.sh" "$fixture/out")"
grep -q '^2026-11-03T10:00:00Z  *6 reqs  *14 records  LIMITED$' <<<"$out" || fail "first launch spans the rotation: $out"
grep -q '^2026-11-03T11:00:00Z  *4 reqs  *60 records  no limits$' <<<"$out" || fail "second launch: $out"
grep -q '^launches 3, requests 10, records 74, launches with a limit 1$' <<<"$out" || fail "overall line: $out"
grep -q '^Playback journal v2 (times are UTC; item tags are pseudonymous):$' <<<"$out" || fail "missing v2 journal header: $out"
grep -q 'item=item-private-tag position=45.0' <<<"$out" || fail "missing newest v2 journal line: $out"
! grep -q 'Secret old headline\|journal-old line' <<<"$out" || fail "legacy journal records must not be exported: $out"
grep -q 'Voice routing diagnostics saved locally' <<<"$out" || fail "missing voice routing save notice: $out"
! grep -q 'Secret local episode' <<<"$out" || fail "voice routing contents must not be printed: $out"
! grep -q 'Library/Logs/playback-journal.log' "$fixture/copied-paths" || fail "legacy journal must not be fetched"
[[ "$(stat -f '%Lp' "$fixture/out")" == 700 ]] || fail "output directory is not owner-only"
[[ "$(stat -f '%Lp' "$fixture/out/playback-v2")" == 700 ]] || fail "v2 directory is not owner-only"
for copied in "$fixture/out"/cloudkit-operations.log* "$fixture/out"/voice-routing.log \
  "$fixture/out/playback-v2"/playback-journal.log*; do
  [[ -f "$copied" ]] || continue
  [[ "$(stat -f '%Lp' "$copied")" == 600 ]] || fail "copied file is not owner-only: $copied"
done
[[ ! -e "$fixture/out/playback-journal.log" ]] || fail "legacy journal file was copied"

mkdir "$fixture/out-nonempty"
printf 'keep me\n' > "$fixture/out-nonempty/sentinel"
if PATH="$fixture/bin:$PATH" WILTED_DEVICE_ID=test-device "$repo_root/scripts/pull-iphone-cloudkit-log.sh" "$fixture/out-nonempty" >/dev/null 2>&1; then
  fail "nonempty destination must be rejected"
fi
[[ -f "$fixture/out-nonempty/sentinel" ]] || fail "existing destination content must be preserved"

rm -f "$fixture/phone/Library/Logs/cloudkit-operations.log" "$fixture/phone/Library/Logs/cloudkit-operations.log.1"
if PATH="$fixture/bin:$PATH" WILTED_DEVICE_ID=test-device "$repo_root/scripts/pull-iphone-cloudkit-log.sh" "$fixture/out2" 2>/dev/null; then
  fail "a phone without the file must fail"
fi
echo "pull-iphone-cloudkit-log: ok"
