#!/usr/bin/env bash
# Disposable hardware-measurement spike -- Task 0.3 (deferred) awake/sleep
# station availability.
#
# **This is a disposable spike. It is not production code.** See README.md
# in this directory for context.
#
# Feeds ADR Decision 5 / the "Deferred to your hardware" consequence:
# station availability across display sleep, lid close, and system sleep.
#
# This cannot be automated: triggering real display sleep / lid close /
# system sleep and observing whether the station stays reachable (e.g. to
# a phone on the LAN, or whether local playback survives) requires a human
# to physically close the lid / wait out the sleep timer and then check
# from a second device or by waking the Mac. This script's job is to walk
# David through each scenario step by step, run automated checks it CAN
# do from software (pmset assertions, network reachability probes,
# process-alive checks) immediately before/after each manual step, and
# record the human's observation alongside those automated signals.
#
# Usage:
#   spikes/hardware-measurements-2026-07-10/measure_sleep_availability.sh
#
# Idempotent: appends one timestamped block to results.log per run.
# Never touches data/ (no episode/media file needed for this measurement
# -- it is about process/network availability, not playback correctness).

set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SPIKE_DIR}/../.." && pwd)"
RESULTS_LOG="${SPIKE_DIR}/results.log"
FORBIDDEN_WRITE_ROOT="${REPO_ROOT}/data"

# --- isolation guard -------------------------------------------------------
# This script must never write under the real data/ tree. It only appends
# to its own results.log inside the spike directory.
if [[ "${RESULTS_LOG}" == "${FORBIDDEN_WRITE_ROOT}"* ]]; then
  echo "REFUSING TO RUN: results log path resolved under data/ -- isolation guard tripped." >&2
  exit 1
fi

RESULT_BLOCK=()

# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT INT TERM`
cleanup() {
  # trap-based cleanup: always flush whatever we captured, even on Ctrl-C
  # or an unexpected exit, so a partial run still leaves a useful record
  # instead of silently losing observations.
  if [[ "${#RESULT_BLOCK[@]}" -gt 0 ]]; then
    {
      echo "=== measure_sleep_availability.sh run @ $(date '+%Y-%m-%dT%H:%M:%S%z') ==="
      printf '%s\n' "${RESULT_BLOCK[@]}"
      echo ""
    } >> "${RESULTS_LOG}"
    echo ""
    echo "Results appended to ${RESULTS_LOG}"
  fi
}
trap cleanup EXIT INT TERM

record() {
  # record <scenario> <key> <value>
  local line="  [$1] $2=$3"
  RESULT_BLOCK+=("${line}")
  echo "${line}"
}

sane_tty() {
  # Restore canonical tty mode before an interactive read. Display/system sleep,
  # lid close/wake (and any prior audio playback in a sibling step) can leave the
  # terminal in raw / no-icrnl mode, where Enter reads as ^M and `read` never
  # completes a line. Best-effort, gated on an interactive stdin.
  [[ -t 0 ]] && stty sane 2>/dev/null || true
}

ask() {
  # ask <prompt-var-name> <prompt-text>
  local __resultvar="$1"
  local prompt="$2"
  local reply
  sane_tty
  # shellcheck disable=SC2034  # reply is consumed indirectly via eval below
  read -r -p "${prompt} " reply
  eval "${__resultvar}=\"\${reply}\""
}

wilted_pid_probe() {
  # Best-effort: is a wilted process currently running? Purely informational
  # -- this spike doesn't require the app to be running to measure sleep
  # behavior, but it's a free automated signal to log alongside the human
  # observation when it IS running.
  pgrep -fl "wilted" 2>/dev/null | grep -v "measure_sleep_availability" || echo "(none found)"
}

network_probe() {
  # Best-effort LAN reachability signal: is this Mac's primary network
  # interface up? (Doesn't require any wilted server to exist yet --
  # this is a generic "did networking survive sleep" signal useful for the
  # eventual LAN-pairing availability question too.)
  if command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "(no active IPv4 on en0/en1)"
  else
    echo "(ipconfig not available)"
  fi
}

echo "Awake/sleep station availability measurement (Task 0.3 deferred)"
echo "This is a guided, human-observed walkthrough. No audio/data files are needed."
echo ""
echo "If wilted (or the eventual station process) is running, start it now in another"
echo "terminal so these scenarios can observe its behavior across sleep. It's fine to"
echo "run this without it running too -- you'll just note 'not running' for each step."
echo ""
sane_tty
read -r -p "Press Enter to begin..." _

# --- Scenario 1: display sleep ---------------------------------------------
echo ""
echo "--- SCENARIO 1: display sleep ---"
echo "STEP 1: note the current pmset display-sleep timer, then let the display sleep"
echo "        (wait it out, or trigger manually: press and hold Control+Shift+Eject,"
echo "        or run 'pmset displaysleepnow' in another terminal)."
pmset -g | grep -i "displaysleep" || true
record "display-sleep" "pid_before" "$(wilted_pid_probe)"
record "display-sleep" "ip_before" "$(network_probe)"
sane_tty
read -r -p "Trigger display sleep now, wait ~15s, then wake the display and press Enter..." _
record "display-sleep" "pid_after" "$(wilted_pid_probe)"
record "display-sleep" "ip_after" "$(network_probe)"
ask OBS1 "OBSERVATION: did station/local playback (if running) stay available/audible across display sleep? [y/n/notes]:"
record "display-sleep" "human_observation" "${OBS1}"

# --- Scenario 2: lid close (clamshell) --------------------------------------
echo ""
echo "--- SCENARIO 2: lid close ---"
echo "STEP 2: if you have an external display/power connected, closing the lid may not"
echo "        sleep the Mac (clamshell mode) -- that itself is a useful data point."
echo "        Otherwise this WILL suspend the Mac; you'll need to open the lid and"
echo "        wake it to continue this script."
record "lid-close" "pid_before" "$(wilted_pid_probe)"
record "lid-close" "ip_before" "$(network_probe)"
sane_tty
read -r -p "Close the lid now, wait ~15s, then reopen and wake the Mac, then press Enter..." _
record "lid-close" "pid_after" "$(wilted_pid_probe)"
record "lid-close" "ip_after" "$(network_probe)"
ask OBS2 "OBSERVATION: did the Mac actually sleep on lid close (or stay awake in clamshell mode)? What happened to station/local playback? [notes]:"
record "lid-close" "human_observation" "${OBS2}"

# --- Scenario 3: full system sleep ------------------------------------------
echo ""
echo "--- SCENARIO 3: full system sleep ---"
echo "STEP 3: trigger full system sleep (Apple menu > Sleep, or 'pmset sleepnow' in"
echo "        another terminal), wait ~15s, then wake the Mac."
record "system-sleep" "pid_before" "$(wilted_pid_probe)"
record "system-sleep" "ip_before" "$(network_probe)"
sane_tty
read -r -p "Trigger system sleep now, wait ~15s, then wake the Mac, then press Enter..." _
record "system-sleep" "pid_after" "$(wilted_pid_probe)"
record "system-sleep" "ip_after" "$(network_probe)"
ask OBS3 "OBSERVATION: did any wilted process survive system sleep? Did network/LAN reachability recover automatically on wake? [notes]:"
record "system-sleep" "human_observation" "${OBS3}"

echo ""
echo "=== Summary ==="
printf '%s\n' "${RESULT_BLOCK[@]}"

exit 0
