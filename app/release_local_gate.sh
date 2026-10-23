#!/usr/bin/env bash
# The authoritative local gate for a frozen candidate: each native leg runs once per
# input digest (reused from any worktree when nothing it reads has changed), the
# receipts used are bound into the candidate, and the proof names their digest.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -n "${READINESS_MANIFEST:-}" ] || exit 4
cd "$ROOT"
candidate=$(basename "$(dirname "$READINESS_MANIFEST")")
[[ "$candidate" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 4
# shellcheck source=/dev/null
source "$ROOT/../apple_developer/release_tools/templates/attempt_log.sh"
logs=".release-state/logs/$candidate"
log=$(attempt_log_open "$logs" local-gate-output) || exit 4
digest_file="$logs/leg-receipts.sha256"
rm -f "$digest_file"
diagnostic=".release-state/evidence/$candidate/local-gate-diagnostic.json"
rm -f "$diagnostic"

# Output streams live and every attempt keeps its own log.
set +e
bash scripts/verify-once-gate.sh release "$candidate" --receipts-digest-file "$digest_file" 2>&1 \
  | tee -a "$log" >&2
gate_status=${PIPESTATUS[0]}
set -e
if [ "$gate_status" -ne 0 ]; then
  failed_legs=$(sed -n 's/^verify-once: failed legs: //p' "$log" | tail -n 1)
  python3 scripts/gate-diagnostic.py --log "$log" --output "$diagnostic" --failed-legs "$failed_legs" || true
  exit "$gate_status"
fi
GATE_LEG_RECEIPTS_SHA256=$(cat "$digest_file")
export GATE_LEG_RECEIPTS_SHA256
exec env READINESS_MANIFEST="$READINESS_MANIFEST" python3 "$ROOT/app/release_stage_readiness.py" --local-gate
