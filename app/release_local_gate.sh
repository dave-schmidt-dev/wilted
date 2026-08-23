#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -n "${READINESS_MANIFEST:-}" ] || exit 4
bash "$ROOT/scripts/test-gate.sh"
exec env READINESS_MANIFEST="$READINESS_MANIFEST" python3 "$ROOT/app/release_stage_readiness.py" --local-gate
