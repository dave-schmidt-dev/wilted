#!/usr/bin/env bash
# Copies the iPhone app's CloudKit operations file over the network (no cable) and prints a
# per-launch summary: requests, records, and whether iCloud limited the phone.
#
# The phone's unified log keeps only a few hours, so the 24-hour soak reads this file instead.
# Needs the phone paired with this Mac and reachable (`xcrun devicectl list devices`).
#
# Usage: WILTED_DEVICE_ID=<udid> scripts/pull-iphone-cloudkit-log.sh [destination-dir]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device="${WILTED_DEVICE_ID:?set WILTED_DEVICE_ID to the iPhone UDID}"
dest="${1:-$repo_root/.logs/iphone-cloudkit/$(date +%Y-%m-%d-%H%M)}"
mkdir -p "$dest"

echo "Copying the operations file from $device to $dest ..."
timeout 300 xcrun devicectl device copy from --device "$device" \
  --domain-type appDataContainer --domain-identifier com.zerodelta.wilted.ios \
  --source Library/Logs --destination "$dest" --quiet

log="$dest/cloudkit-operations.log"
[[ -f "$log" ]] || { echo "No cloudkit-operations.log on the phone yet (build older than the archive?)." >&2; exit 1; }
files=("$log")
[[ -f "$log.1" ]] && files=("$log.1" "$log")

# Each launch starts with a "launch" line; its last summary holds that launch's totals.
cat "${files[@]}" | awk '
  function flush() { if (have) { printf "%s  %6d reqs  %8d records  %s\n", start, reqs, recs, lim; treqs += reqs; trecs += recs; if (lim != "no limits") limited++ } have = 0 }
  $2 == "launch" { flush(); start = $1; launches++; next }
  /since launch:/ {
    match($0, /since launch: [0-9]+ reqs \([0-9]+ records/); split(substr($0, RSTART, RLENGTH), f, /[ (]+/)
    reqs = f[3]; recs = f[5]; have = 1
    lim = ($0 ~ /no limits since launch/) ? "no limits" : "LIMITED"
  }
  END { flush(); printf "launches %d, requests %d, records %d, launches with a limit %d\n", launches, treqs, trecs, limited }'
