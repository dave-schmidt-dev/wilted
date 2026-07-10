#!/usr/bin/env bash
# Guided walkthrough of the HUMAN-IN-THE-LOOP hardware measurements (steps A-D).
#
# Sequences the four interactive harness scripts with the real prepared-episode
# and transcript paths pre-filled, an intro + safety note before each, and a
# per-step [run / skip / quit] gate. The automated §4 residency measurement is
# NOT included here (already run — see RESULTS-TEMPLATE.md §4).
#
# The sub-scripts read from THIS terminal (stdin is inherited, never piped), so
# their own prompts — safe-volume gates, "unplug headphones now", "did resume
# sound right? [y/n]" — work exactly as if you ran them by hand. This wrapper
# only adds the framing, the paths, and the skip/quit control between steps.
#
# Usage (run from anywhere; it cd's to the repo root itself):
#   spikes/hardware-measurements-2026-07-10/walkthrough.sh
#
# Each sub-script appends a timestamped block to results.log in this directory.

# NOTE: deliberately NOT `set -e` — a sub-script that exits non-zero (or that you
# abort) should drop back to the walkthrough, not kill the whole session.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || { echo "cannot cd to repo root ${REPO_ROOT}" >&2; exit 1; }

# Terminal hygiene. A previous run aborted mid-progress-bar, or Ctrl-C'd during a
# hung playback, can leave the tty in raw / no-icrnl mode — where Enter echoes as
# ^M and input()/read never see a completed line. Restore sane mode NOW (repairs
# an inherited broken tty before the first prompt) and again on any exit (so we
# never hand a broken terminal back to the shell or the next step).
if [[ -t 0 ]]; then
  stty sane 2>/dev/null || true
  trap 'stty sane 2>/dev/null || true' EXIT INT TERM
fi

export UV_PROJECT_ENVIRONMENT="${HOME}/.venvs/wilted"

EPISODE="data/podcasts/measure-404-best-game/80391e99cf24d187eec49da364a45858.mp3"
TRANSCRIPT="data/transcripts/measure-404-best-game_transcript.json"
BULLETIN="Severe thunderstorm warning for your area until 5pm."
RESULTS_LOG="${SCRIPT_DIR}/results.log"

# ANSI (fall back to empty if not a tty)
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  B=""; DIM=""; GRN=""; YEL=""; CYN=""; RST=""
fi

py() { PYTHONPATH=src uv run python "$@"; }

RAN=(); SKIPPED=()

hr() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

# gate <letter> <title> <safety-note...>
# Prints the banner, then asks run/skip/quit. Returns 0 to run, 1 to skip.
gate() {
  local letter="$1"; local title="$2"; shift 2
  # Re-sane the tty before every prompt: the previous sub-script (audio + model
  # progress bars) may have left it in a state where Enter reads as ^M.
  [[ -t 0 ]] && stty sane 2>/dev/null || true
  echo
  hr
  echo "${B}STEP ${letter} — ${title}${RST}"
  local line
  for line in "$@"; do echo "  ${line}"; done
  hr
  local choice
  read -r -p "  ${CYN}[Enter]${RST} run   ${DIM}·${RST}   ${YEL}[s]${RST} skip   ${DIM}·${RST}   [q] quit: " choice
  case "${choice}" in
    s|S) echo "  ${YEL}(skipped ${letter})${RST}"; SKIPPED+=("${letter}"); return 1 ;;
    q|Q) echo; echo "Exiting walkthrough."; summary; exit 0 ;;
    *)   RAN+=("${letter}"); return 0 ;;
  esac
}

summary() {
  echo
  hr
  echo "${B}Walkthrough summary${RST}"
  echo "  ran:     ${RAN[*]:-(none)}"
  echo "  skipped: ${SKIPPED[*]:-(none)}"
  if [[ -f "${RESULTS_LOG}" ]]; then
    echo
    echo "  ${GRN}Results appended to:${RST} ${RESULTS_LOG}"
    echo "  ${DIM}Last block:${RST}"
    # show the final timestamped block so you can copy it straight to Claude
    awk 'BEGIN{RS="=== "} END{if(NR>0) printf "=== %s", $0}' "${RESULTS_LOG}" | sed 's/^/    /'
  fi
  echo
  echo "  Next: paste the new results.log blocks back to Claude (or drop the values"
  echo "  into ${SCRIPT_DIR#"${REPO_ROOT}"/}/RESULTS-TEMPLATE.md §1–3 + §4 alert-latency)."
  hr
}

# ── preflight ──────────────────────────────────────────────────────────────
echo "${B}Wilted hardware-measurement walkthrough${RST} ${DIM}(steps A–D, human-in-the-loop)${RST}"
echo "repo:  ${REPO_ROOT}"
echo "venv:  ${UV_PROJECT_ENVIRONMENT}"

missing=0
if [[ ! -e "${EPISODE}" ]]; then
  echo "${YEL}!! episode not found:${RST} ${EPISODE}  (steps A & B will fail)"; missing=1
fi
if [[ ! -e "${TRANSCRIPT}" ]]; then
  echo "${YEL}!! transcript not found:${RST} ${TRANSCRIPT}  (step A seek/resume will report n/a)"; missing=1
fi
for tool in ffmpeg ffprobe; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "${YEL}!! ${tool} not on PATH${RST} (playback steps need it)"; missing=1; }
done
if [[ ! -x "${UV_PROJECT_ENVIRONMENT}/bin/python" ]]; then
  echo "${YEL}!! wilted venv missing at ${UV_PROJECT_ENVIRONMENT}${RST}"; missing=1
fi
if [[ "${missing}" -eq 1 ]]; then
  echo
  read -r -p "Preflight found issues above. Continue anyway? [y/N]: " cont
  [[ "${cont}" =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
fi

echo
echo "${DIM}Four measurements. Two play audio (A, D) — have your volume somewhere safe.${RST}"
echo "${DIM}You can skip any step, or quit after any step; partial results are still saved.${RST}"

# ── STEP A — real-speaker playback ─────────────────────────────────────────
if gate "A" "Real-speaker playback  (startup latency · peak memory · seek · resume)" \
  "${B}Plays real audio${RST} in short bursts (~40s total)." \
  "It will ask you to confirm a safe volume (STEP 0), then at the end:" \
  "  ${DIM}\"did playback resume at the expected text with no gap you noticed? [y/n]\"${RST}" \
  "Have the episode audible so you can answer that honestly."; then
  py "${SCRIPT_DIR}/measure_playback.py" --episode "${EPISODE}" --transcript "${TRANSCRIPT}"
fi

# ── STEP B — audio-route recovery ──────────────────────────────────────────
if gate "B" "Audio-route recovery  (unplug / switch device mid-playback)" \
  "${B}Plays real audio${RST}, then walks you through three route changes:" \
  "  1) physically UNPLUG headphones (or disconnect current Bluetooth)" \
  "  2) switch output to AirPods / another device via the Sound menu" \
  "  3) switch back to built-in speakers" \
  "After each, it asks what you heard (paused / crashed / wrong-device / followed / silent)."; then
  py "${SCRIPT_DIR}/measure_route_recovery.py" --episode "${EPISODE}"
fi

# ── STEP C — awake/sleep availability ──────────────────────────────────────
if gate "C" "Awake/sleep availability  (display sleep · lid close · system sleep)" \
  "${DIM}No audio.${RST} You'll physically: let the display sleep, close the lid, and sleep/wake the Mac." \
  "It probes process + LAN reachability before/after each and records your observations." \
  "${YEL}Heads-up:${RST} lid-close / system-sleep will suspend the Mac unless you're in clamshell mode —" \
  "you'll reopen/wake to continue the script."; then
  bash "${SCRIPT_DIR}/measure_sleep_availability.sh"
fi

# ── STEP D — alert-detected → bulletin-start latency ───────────────────────
if gate "D" "Alert latency  (TTS synthesis → bulletin start)" \
  "${B}Plays a ~3s TTS bulletin${RST} through your speakers — set a safe volume." \
  "Press Enter when it says so to start the clock; it measures synth wall-clock time." \
  "Bulletin text: ${DIM}\"${BULLETIN}\"${RST}"; then
  py "${SCRIPT_DIR}/measure_ml_residency.py" --mode alert-latency --bulletin-text "${BULLETIN}"
fi

summary
