#!/usr/bin/env bash
# Counts the CloudKit operations a running Wilted process made, from the unified log, and prints
# operations per minute by kind. Usage: scripts/sync-ops-rate.sh <pid> [minutes=5]
# Or, to read a saved capture:  scripts/sync-ops-rate.sh --file <capture.txt> <minutes>
# Idle target (docs/2026-10-01-sync-cadence.md): about 2 operations a minute per device.
set -euo pipefail

if [[ "${1:-}" == "--file" ]]; then
  source_cmd=(cat "${2:?capture file}")
  minutes="${3:?minutes covered by the capture}"
else
  pid="${1:?pid of the running Wilted process}"
  minutes="${2:-5}"
  source_cmd=(/usr/bin/log show --last "${minutes}m" --style compact --predicate "processID == ${pid}")
fi

# Each CloudKit request the client makes logs one "(CloudKit) client/<op>" line; the metric
# submissions are not requests.
"${source_cmd[@]}" 2>/dev/null |
  grep -o '(CloudKit) client/[a-z-]*' |
  sed 's|(CloudKit) client/||' |
  grep -v '^submit-event-metric$' |
  sort | uniq -c | sort -rn |
  awk -v m="$minutes" '{ total += $1; printf "%-28s %5d  %6.2f /min\n", $2, $1, $1 / m }
    END { printf "%-28s %5d  %6.2f /min\n", "TOTAL", total, total / m }'
