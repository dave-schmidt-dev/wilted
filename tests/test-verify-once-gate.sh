#!/usr/bin/env bash
# Keeps the verify-once release gate honest: the legs declared in the release adapter,
# the legs scripts/verify-once-gate.sh runs, and the legs scripts/test-gate.sh defines
# must be the same set, every declared input glob must match tracked files, and the
# ui leg must stay out of the headless modes. Nothing here runs a native leg.
set -Eeuo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
central="$repo_root/../apple_developer"
adapter="$repo_root/.release/release-adapter.json"
gate="$repo_root/scripts/verify-once-gate.sh"

fail() { printf 'assertion failed: %s\n' "$*" >&2; exit 1; }

bash -n "$gate" || fail 'verify-once-gate.sh does not parse'
bash -n "$repo_root/app/verify-release-ui" || fail 'verify-release-ui does not parse'
bash -n "$repo_root/app/release_local_gate.sh" || fail 'release_local_gate.sh does not parse'
python3 "$repo_root/tests/test_gate_diagnostic.py" >/dev/null 2>&1 || fail 'gate diagnostic tests failed'

# The three leg lists agree. The adapter is JSON, the other two are bash arrays.
python3 - "$repo_root" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

def array(text: str, name: str) -> list[str]:
    match = re.search(rf"^{name}=\(([^)]*)\)", text, re.M)
    assert match, name
    return match.group(1).split()

gate_legs = array((root / "scripts/test-gate.sh").read_text(), "leg_names")
script = (root / "scripts/verify-once-gate.sh").read_text()
headless, ui = array(script, "headless_legs"), array(script, "ui_legs")
declared = json.loads((root / ".release/release-adapter.json").read_text())["gateLegs"]["legs"]
kinds = {leg: entry["kind"] for leg, entry in declared.items()}
assert sorted(gate_legs) == sorted(kinds), (gate_legs, sorted(kinds))
assert sorted(headless) == sorted(l for l, k in kinds.items() if k == "headless"), headless
assert sorted(ui) == sorted(l for l, k in kinds.items() if k == "ui"), ui
assert ui == ["macos-ui-tests"], ui
# The deferred leg in test-gate.sh is the one ui leg.
assert 'is_deferred_leg() {\n  [[ "$1" == "macos-ui-tests"' in (root / "scripts/test-gate.sh").read_text()
# Every variable the adapter names as narrowing a run is refused by release and ui-verify.
refused = set(array(script, "scope_variables"))
for leg, entry in declared.items():
    missing = set(entry.get("scopeEnv", [])) - refused
    assert not missing, (leg, missing)
print(f"verify-once legs agree: headless={len(headless)} ui={len(ui)}")
PY

# The ui leg is never run by a headless mode, and neither mode takes the ui leg's command.
if grep -n 'WILTED_MAC_UI=1' "$gate" | grep -v 'caffeinate -disu' >/dev/null; then
  fail 'WILTED_MAC_UI=1 appears outside the ui leg command'
fi

if [[ ! -f "$central/release_tools/templates/gate_receipts.sh" ]]; then
  printf 'test-verify-once-gate: apple_developer sibling not found; skipped receipt checks\n' >&2
  printf 'verify-once gate contract passed (receipt checks skipped)\n'
  exit 0
fi

# Every declared input glob matches tracked files in this checkout, and the central
# tool accepts the adapter: `begin` computes each leg's digest without running anything.
for leg in xcodegen-reproducible wiltedkit-tests cloudsync-tests playback-tests wiltedproducer-tests \
  macos-unit-tests ios-unit-tests ios-pixel-snapshot-tests macos-ui-tests; do
  output="$(cd "$repo_root" && PYTHONPATH="$central" python3 -m release_tools gate-receipt --action begin \
    --adapter .release/release-adapter.json --repository . --leg "$leg" -- \
    env "WILTED_GATE_LEGS=$leg" bash scripts/test-gate.sh 2>&1)" || { printf '%s\n' "$output" >&2; fail "begin failed for $leg"; }
  grep -Eq '"digest":"[0-9a-f]{64}"' <<<"$output" || { printf '%s\n' "$output" >&2; fail "no digest for $leg"; }
done

# A leg narrowed by the environment, or the ui leg's own selector, is refused before it runs.
for name in WILTED_GATE_LEGS WILTED_MAC_UNIT_SELECTORS WILTED_MAC_UI_SELECTOR NATIVE_SELF_TEST; do
  status=0
  output="$(env "$name=x" bash "$gate" release 0.0.0-0 2>&1)" || status=$?
  [[ "$status" -eq 2 ]] || { printf '%s\n' "$output" >&2; fail "$name was not refused (status $status)"; }
  grep -Fq "$name is set" <<<"$output" || fail "$name refusal did not name the variable"
done

# The install-time check honours its documented override and says so loudly.
output="$(WILTED_SKIP_UI_RECEIPT=1 bash "$gate" check-ui 2>&1)" || fail 'check-ui override failed'
grep -Fq 'WARNING skipped=true' <<<"$output" || fail 'check-ui override did not warn'

# The failure diagnostic the local gate writes is accepted by the release runner's own validator.
source "$repo_root/scripts/lib/test-temp-state.sh"
tmp="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-verify-once.XXXXXX")"; wilted_temp_mark_owned "$tmp"
trap 'rm -rf "$tmp"' EXIT
printf "Test Case '-[WiltedMacTests.FooTests testBar]' failed (0.1 seconds).\n" >"$tmp/attempt.log"
(cd "$tmp" && python3 "$repo_root/scripts/gate-diagnostic.py" --log attempt.log --output out.json --failed-legs macos-unit-tests)
PYTHONPATH="$central" python3 - "$tmp/out.json" <<'PY'
import json
import sys
from types import SimpleNamespace

from release_tools.adapter_evidence import validate_operation_diagnostic

document = json.load(open(sys.argv[1]))
accepted = validate_operation_diagnostic(SimpleNamespace(operation_id="local-gate"), document)
assert accepted["failingTests"] == ["FooTests/testBar"], accepted
PY

printf 'verify-once gate contract passed\n'
