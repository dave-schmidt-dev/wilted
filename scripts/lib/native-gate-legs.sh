# shellcheck shell=bash
# Single-leg reruns for scripts/test-gate.sh.
#
# WILTED_GATE_LEGS=<comma list of leg names> runs only those legs and reports
# the rest as skipped. A filtered run is a diagnostic, never evidence: its
# `native.passed` line carries `filtered=<n>` so it cannot match the full-gate
# line a receipt requires, and native-ui-receipt.py refuses to record while
# the variable is set. Unknown or empty names fail closed before any leg (or
# the simulator sweep) runs.

skipped_leg_names=()

# Usage: wilted_gate_legs_validate <known leg name>...
wilted_gate_legs_validate() {
  [[ -n "${WILTED_GATE_LEGS+x}" ]] || return 0
  local name known found selected=()
  if [[ -z "$WILTED_GATE_LEGS" ]]; then
    printf '%s\n' 'native.error WILTED_GATE_LEGS is set but empty; name legs or unset it' >&2
    return 1
  fi
  IFS=',' read -r -a selected <<<"$WILTED_GATE_LEGS"
  for name in "${selected[@]}"; do
    found=0
    for known in "$@"; do [[ "$name" == "$known" ]] && found=1; done
    if [[ "$found" -eq 0 ]]; then
      printf 'native.error unknown leg in WILTED_GATE_LEGS: "%s"; known legs: %s\n' "$name" "$*" >&2
      return 1
    fi
  done
}

wilted_gate_leg_selected() {
  [[ -n "${WILTED_GATE_LEGS+x}" ]] || return 0
  [[ ",$WILTED_GATE_LEGS," == *",$1,"* ]]
}

# Runs every selected leg in order; relies on the gate's `leg_names`,
# `leg_reports` and `leg_fns` arrays and its `run_leg`.
wilted_gate_run_legs() {
  local i name
  for i in "${!leg_names[@]}"; do
    name="${leg_names[$i]}"
    if wilted_gate_leg_selected "$name"; then
      run_leg "$name" "${leg_reports[$i]}" "${leg_fns[$i]}"
    else
      skipped_leg_names+=("$name")
      printf 'native.leg.skipped name=%s reason=not-in-WILTED_GATE_LEGS\n' "$name" >&2
    fi
  done
}

# Suffix for the native.passed line of a filtered run.
wilted_gate_legs_suffix() {
  [[ -n "${WILTED_GATE_LEGS+x}" ]] || return 0
  printf ' filtered=%s' "${#skipped_leg_names[@]}"
}

# Names the filter and the skipped legs, and says no receipt can come from it.
wilted_gate_legs_summary() {
  [[ -n "${WILTED_GATE_LEGS+x}" ]] || return 0
  printf 'native.filtered selected=%s skipped=%s receipt=never\n' \
    "$WILTED_GATE_LEGS" "${skipped_leg_names[*]:-none}" >&2
}
