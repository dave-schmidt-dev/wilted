#!/usr/bin/env bash
# Runs Wilted's native gate legs once per input digest (verify-once).
#
#   verify-once-gate.sh release <candidate-id> [--receipts-digest-file <path>]
#   verify-once-gate.sh headless
#   verify-once-gate.sh ui-verify
#   verify-once-gate.sh check-ui
#
# Each leg is one `scripts/test-gate.sh` run narrowed with WILTED_GATE_LEGS. The
# release_tools receipt layer (apple_developer/release_tools/templates/gate_receipts.sh)
# skips a leg whose inputs match a fresh receipt from any worktree and records a
# receipt for one that passes. The leg ids and kinds are declared as `gateLegs` in
# .release/release-adapter.json; tests/test-verify-once-gate.sh keeps them in step
# with `leg_names` in scripts/test-gate.sh.
#
#   release     headless legs run or are reused; the screen-seizing leg is only listed.
#               Binds the receipts used into the candidate and writes their digest to
#               --receipts-digest-file for the local-gate proof.
#   headless    the same without a candidate (the pre-push gate, `make validate`).
#   ui-verify   the screen-seizing macos-ui-tests leg only (app/verify-release-ui).
#   check-ui    exits non-zero unless every ui leg has a fresh receipt for this source.
#
# A leg's argv carries no absolute or per-worktree path: it runs from the repository
# root and the build caches are resolved by the gate itself.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
central="$repo_root/../apple_developer"
adapter=.release/release-adapter.json

headless_legs=(
  xcodegen-reproducible
  wiltedkit-tests
  cloudsync-tests
  playback-tests
  wiltedproducer-tests
  macos-unit-tests
  ios-unit-tests
  ios-pixel-snapshot-tests
)
ui_legs=(macos-ui-tests)
# Variables that narrow a run or fake a leg: set in the caller, they stop a receipt.
scope_variables=(
  WILTED_GATE_LEGS WILTED_MAC_UNIT_SELECTORS WILTED_MAC_UNIT_ITERATIONS
  WILTED_IOS_UNIT_SELECTORS WILTED_IOS_UNIT_ITERATIONS WILTED_MAC_UI_SELECTOR
  NATIVE_SELF_TEST NATIVE_FORCE_FAIL_LEG NATIVE_FORCE_ZERO_TEST_LEG
  NATIVE_FORCE_SNAPSHOT_BASELINE NATIVE_FORCE_MISSING_IOS_MVP_JOURNEY
  NATIVE_FORCE_SCREEN_LOCKED NATIVE_INTERRUPT_TEST_COMMAND
)

say() { printf 'verify-once: %s\n' "$*" >&2; }

usage() {
  say 'usage: verify-once-gate.sh release <candidate-id> [--receipts-digest-file <path>] | headless | ui-verify | check-ui'
  exit 64
}

mode="${1:-}"
[[ -n "$mode" ]] || usage
shift
candidate=""
digest_file=""
case "$mode" in
  release)
    [[ $# -ge 1 ]] || usage
    candidate="$1"
    shift
    if [[ "${1:-}" == --receipts-digest-file ]]; then
      [[ $# -eq 2 ]] || usage
      digest_file="$2"
      shift 2
    fi
    [[ $# -eq 0 ]] || usage
    ;;
  headless | ui-verify | check-ui) [[ $# -eq 0 ]] || usage ;;
  *) usage ;;
esac

receipt_tools() {
  PYTHONPATH="$central${PYTHONPATH:+:$PYTHONPATH}" python3 -m release_tools gate-receipt \
    --adapter "$adapter" --repository "$repo_root" "$@"
}

if [[ "$mode" == check-ui ]]; then
  # Replaces the retired native-ui-receipt: `make install` needs a fresh ui receipt.
  if [[ "${WILTED_SKIP_UI_RECEIPT:-}" == 1 ]]; then
    say 'WARNING skipped=true reason=WILTED_SKIP_UI_RECEIPT=1 detail="installing a Mac UI surface no verified screen-seizing run covers"'
    exit 0
  fi
  receipt_tools --action check-ui >/dev/null || {
    say 'block reason=ui-verification-required action="app/verify-release-ui (screen-seizing; run it when away from the Mac)"'
    exit 1
  }
  say 'pass reason=ui-receipts-current'
  exit 0
fi

if [[ ! -f "$central/release_tools/templates/gate_receipts.sh" ]]; then
  # A clone without the sibling tool keeps the plain gate, with no receipts.
  [[ "$mode" == headless ]] || { say "error: $central is required for $mode"; exit 4; }
  say 'apple_developer sibling not found; running the plain gate without receipts'
  exec bash scripts/test-gate.sh
fi

if [[ "$mode" != headless ]]; then
  for name in "${scope_variables[@]}"; do
    if [[ -n "${!name+x}" ]]; then
      say "error: $name is set; a narrowed run cannot stand for a leg. Unset it."
      exit 2
    fi
  done
fi

# shellcheck source=/dev/null
source "$central/release_tools/templates/gate_receipts.sh"
gate_legs_init "$central" "$adapter" "$mode" || exit $?

# The simulator runtime the iOS legs will pick; a new runtime must rerun them.
ios_runtime() {
  xcrun simctl list devices available -j | python3 scripts/select-ios-simulator.py | cut -f1
}

failed=()
headless_leg() {
  local id="$1"
  shift
  gate_leg "$id" "$@" -- env "WILTED_GATE_LEGS=$id" bash scripts/test-gate.sh || failed+=("$id")
}

if [[ "$mode" != ui-verify ]]; then
  runtime="$(ios_runtime)" || { say 'error: no usable iOS simulator runtime'; exit 1; }
  macos_version="$(sw_vers -productVersion)"
  for id in "${headless_legs[@]}"; do
    case "$id" in
      macos-unit-tests) headless_leg "$id" --context "macos=$macos_version" ;;
      ios-unit-tests | ios-pixel-snapshot-tests) headless_leg "$id" --context "runtime=$runtime" ;;
      *) headless_leg "$id" ;;
    esac
  done
fi

# The ui leg is only listed by release and headless; ui-verify runs it. Keep the
# declaration so a mode that forgets a leg fails closed in gate_legs_finish.
for id in "${ui_legs[@]}"; do
  macos_version="${macos_version:-$(sw_vers -productVersion)}"
  gate_leg "$id" --context "macos=$macos_version" -- \
    env "WILTED_GATE_LEGS=$id" WILTED_MAC_UI=1 caffeinate -disu bash scripts/test-gate.sh || failed+=("$id")
done

if ((${#failed[@]} > 0)); then
  say "failed legs: ${failed[*]}"
  exit 1
fi
gate_legs_finish "$candidate" || exit 1
if [[ -n "$digest_file" ]]; then
  [[ -n "${GATE_LEG_RECEIPTS_SHA256:-}" ]] || { say 'error: no leg receipts digest was produced'; exit 1; }
  printf '%s\n' "$GATE_LEG_RECEIPTS_SHA256" >"$digest_file"
fi
say "ok mode=$mode"
