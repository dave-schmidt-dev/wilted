#!/usr/bin/env bash
# Copies approved iPhone diagnostics over the network and prints CloudKit request totals plus
# the sanitized playback-v2 journal. Title-bearing voice-routing data stays in a private file.
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
[[ -d "$dest" ]] || { echo "Destination must be a directory." >&2; exit 1; }
[[ ! -L "$dest" ]] || { echo "Destination must not be a symlink." >&2; exit 1; }
[[ "$(stat -f '%u' "$dest")" == "$(id -u)" ]] || { echo "Destination must be owned by the current user." >&2; exit 1; }
[[ -z "$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  echo "Destination must be empty so existing diagnostics are not overwritten." >&2
  exit 1
}
chmod 700 "$dest"
mkdir "$dest/playback-v2"
chmod 700 "$dest/playback-v2"

echo "Copying approved phone diagnostics to $dest ..."
copy_phone_file() {
  local source="$1" target="$2"
  if timeout 300 xcrun devicectl device copy from --device "$device" \
      --domain-type appDataContainer --domain-identifier com.zerodelta.wilted.ios \
      --source "$source" --destination "$target" --quiet; then
    chmod 600 "$target" || { rm -f "$target"; return 1; }
    return 0
  fi
  rm -f "$target"
  return 1
}

copy_phone_file "Library/Logs/cloudkit-operations.log" "$dest/cloudkit-operations.log" || {
  echo "No cloudkit-operations.log on the phone yet (build older than the archive?)." >&2
  exit 1
}
copy_phone_file "Library/Logs/cloudkit-operations.log.1" "$dest/cloudkit-operations.log.1" || true
copy_phone_file "Library/Logs/playback-v2/playback-journal.log" \
  "$dest/playback-v2/playback-journal.log" || true
copy_phone_file "Library/Logs/playback-v2/playback-journal.log.1" \
  "$dest/playback-v2/playback-journal.log.1" || true

# This older, title-bearing log remains useful in Settings diagnostics; export it only
# to the owner-only run folder and never print its contents into command output.
copy_phone_file "Library/Application Support/Wilted/voice-routing.log" "$dest/voice-routing.log" || true

log="$dest/cloudkit-operations.log"
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

journal_log="$dest/playback-v2/playback-journal.log"
journal_files=()
[[ -f "$journal_log.1" ]] && journal_files+=("$journal_log.1")
[[ -f "$journal_log" ]] && journal_files+=("$journal_log")
if [[ ${#journal_files[@]} -gt 0 ]]; then
  echo ""
  echo "Playback journal v2 (times are UTC; item tags are pseudonymous):"
  cat "${journal_files[@]}" | tail -n 40
else
  echo "No playback journal v2 found; legacy playback logs on the phone were not exported."
fi
if [[ -f "$dest/voice-routing.log" ]]; then
  echo "Voice routing diagnostics saved locally; the file may contain show or episode titles."
fi
