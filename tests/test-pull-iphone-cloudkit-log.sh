#!/usr/bin/env bash
# scripts/pull-iphone-cloudkit-log.sh against a stand-in `xcrun` that "copies" a fixture
# operations file (a rotated backup plus the current file, three launches, one limited). The
# per-launch totals and the overall line must read the last summary of each launch.
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

mkdir -p "$fixture/bin" "$fixture/phone/Logs" "$fixture/out"
line() { printf '%s CloudKit operations: last 5m 1 reqs (1 records, 1 B) · since launch: %s reqs (%s records, 9 B) · callers: [poll: %s] · %s\n' "$1" "$2" "$3" "$2" "$4"; }
{
  printf '2026-11-03T10:00:00Z launch\n'
  line 2026-11-03T10:05:00Z 2 5 'no limits since launch'
  line 2026-11-03T10:10:00Z 5 12 'last limit: 10:08 (retry-after: 30s)'
} > "$fixture/phone/Logs/cloudkit-operations.log.1"
{
  line 2026-11-03T10:15:00Z 6 14 'last limit: 10:08 (retry-after: 30s)'
  printf '2026-11-03T11:00:00Z launch\n'
  line 2026-11-03T11:05:00Z 4 60 'no limits since launch'
  printf '2026-11-03T12:00:00Z launch\n'
} > "$fixture/phone/Logs/cloudkit-operations.log"

cat > "$fixture/bin/xcrun" <<EOF
#!/usr/bin/env bash
dest=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == --destination ]] && dest="\$2"; shift; done
cp "$fixture/phone/Logs/"* "\$dest/"
EOF
chmod +x "$fixture/bin/xcrun"

out="$(PATH="$fixture/bin:$PATH" WILTED_DEVICE_ID=test-device "$repo_root/scripts/pull-iphone-cloudkit-log.sh" "$fixture/out")"
grep -q '^2026-11-03T10:00:00Z  *6 reqs  *14 records  LIMITED$' <<<"$out" || fail "first launch spans the rotation: $out"
grep -q '^2026-11-03T11:00:00Z  *4 reqs  *60 records  no limits$' <<<"$out" || fail "second launch: $out"
grep -q '^launches 3, requests 10, records 74, launches with a limit 1$' <<<"$out" || fail "overall line: $out"

rm "$fixture/phone/Logs/"*
if PATH="$fixture/bin:$PATH" WILTED_DEVICE_ID=test-device "$repo_root/scripts/pull-iphone-cloudkit-log.sh" "$fixture/out2" 2>/dev/null; then
  fail "a phone without the file must fail"
fi
echo "pull-iphone-cloudkit-log: ok"
