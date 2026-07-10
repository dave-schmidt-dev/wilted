# Hardware-measurement spike — 2026-07-10 (Task 0.4 / Task 0.3 deferred dims)

**This is a disposable architecture spike. It is not production code.**
It is removable at any time (`rm -rf spikes/hardware-measurements-2026-07-10`)
without touching any production code or data — see "Isolation guard" below.

## Purpose

ADR 0001 (`docs/adr/0001-mac-radio-substrate.md`) Decision 5 is the one
decision still marked **provisional** — its "Consequences & prerequisites"
section explicitly lists measurements "deferred to your hardware" because
they need a human, a real Mac, real speakers, and real sleep/wake/route
events, none of which the automated Phase-0 spikes
(`spikes/mac-substrate-2026-07-10/`, `spikes/migration-rehearsal-2026-07-10/`,
`spikes/pairing-security-2026-07-10/`) could produce. This directory holds
the guided scripts that produce those measurements, plus a results
template. **Filling in `RESULTS-TEMPLATE.md` and updating ADR Decision 5
with the measured values is what finalizes Decision 5** and closes out
Task 0.4 / the Task 0.3 deferred dims.

These scripts are **not automated pass/fail gates**. They start real
playback/model-loading, prompt David through the manual steps (unplug
headphones, close the lid, trigger sleep, etc.), and log whatever
automatic timing/memory signals are available alongside David's own
observation. A human reads the results and decides what the final ADR
targets should be — the scripts don't decide that for him.

## What each measurement feeds

| Script | Measures | ADR Decision 5 target / deferred dim |
|---|---|---|
| `measure_playback.py` | Startup latency, peak memory, seek time, checkpoint/resume fidelity on a real 90–120 min PREPARED episode through the real audio device | Interruption-latency ceiling, resume-fidelity target, and the "streaming playback rework" consequence (the ADR already estimates 542 MB / ~4s cold start for 94 min at 24kHz mono from the current full-decode `play_file` — this re-measures on your actual hardware/episode) |
| `measure_route_recovery.py` | Behavior when the output device changes/disconnects mid-playback (unplug headphones, switch to AirPods) — pauses cleanly vs crashes vs continues to wrong device, and whether the app stays responsive | "Deferred to your hardware" — audio-route recovery (Task 0.3 deferred) |
| `measure_sleep_availability.sh` | Station/process/network availability across display sleep, lid close, and full system sleep | "Deferred to your hardware" — awake/sleep availability (Task 0.3 deferred) |
| `measure_ml_residency.py --mode residency` | Confirms at most one MLX/Metal model resident at a time across the LLM backend, TTS (Kokoro), and transcription (parakeet_mlx); measures load time and close/Metal-reclaim time per model | "Model lifecycle" consequence — the `ModelCoordinator` single-lease assumption |
| `measure_ml_residency.py --mode alert-latency` | Wall-clock delta from "alert detected" to "bulletin audio starts" for a live TTS synthesis, isolating the TTS-synthesis latency component | Interruption-latency ceiling (alert-detected → bulletin-start is explicitly the measurement Decision 5 says must happen before a ceiling can be set) |

## Prerequisites

- **A prepared 90–120 minute podcast episode**, i.e. one with an
  admitted/finalized audio file (and ideally a cached transcript JSON —
  see `wilted.transcribe.save_transcript`/`load_transcript` — so the
  segment-boundary seek/resume measurements aren't skipped). None of the
  sample files currently under `data/podcasts/<id>/*.mp3` in this repo
  fall in the 90–120 min range (the longest is ~69 min, in
  `data/podcasts/6/`) — **you'll need to supply your own path** to a
  real prepared episode via `--episode`. A short clip is fine for
  `measure_route_recovery.py` (it only needs continuous playback to
  survive a route change, not the specific 90–120 min duration).
- macOS with a real audio output device, `ffmpeg`/`ffprobe` on `PATH`
  (already required by `wilted.engine`), and this project's `.venv`
  (`uv sync`).
- For `measure_ml_residency.py`: whichever of `mlx_audio`, `mlx_vlm` /
  `llama-cpp-python`, and `parakeet_mlx` you want to exercise must
  already be installed and their models already downloaded to the local
  Hugging Face cache (first-run downloads will just make the "load"
  timing measurement include download time — note that in your results
  if it happens).
- `psutil` is used **only if already installed** in your environment;
  every script falls back to `resource.getrusage` (stdlib) otherwise. No
  new dependency is required or added by this spike.

## How to run

All commands run from the project root. Each script's `--help` (or
omitting the flag that would trigger real hardware access) runs a
dry-run guard that touches no audio device, no model, and no `data/`
files:

```bash
# 1. Real-speaker playback (Task 0.4) — startup latency, peak memory,
#    seek time, resume fidelity.
PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_playback.py \
    --episode /path/to/your/90-120-min-prepared-episode.mp3 \
    --transcript /path/to/cached-transcript.json   # optional but recommended

# 2. Audio-route recovery (Task 0.3 deferred).
PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_route_recovery.py \
    --episode /path/to/any/audio/file.mp3

# 3. Awake/sleep availability (Task 0.3 deferred) — pure shell, no episode needed.
spikes/hardware-measurements-2026-07-10/measure_sleep_availability.sh

# 4a. ML one-model-residency + load/close timing.
PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_ml_residency.py \
    --mode residency

# 4b. Alert-detected -> bulletin-start latency stopwatch.
PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_ml_residency.py \
    --mode alert-latency --bulletin-text "Severe thunderstorm warning for your area until 5pm."
```

Each script logs a timestamped block to its own `results.log` in this
directory (created on first run, gitignored-equivalent — see "Isolation
guard" below for why this is safe to leave around and easy to discard).
Re-running any script is safe and idempotent: it appends a new block, it
never mutates or depends on a previous run's state, and it never leaves
background processes running (every interactive scenario is bounded by
either a human "press Enter to continue" prompt or a watchdog timer that
calls `stop()`/exits).

After each run, copy the printed summary / `results.log` values into
`RESULTS-TEMPLATE.md`'s "Measured value" column. Once all rows are
filled in, that table **is** the evidence needed to replace ADR Decision
5's provisional targets with final ones — update
`docs/adr/0001-mac-radio-substrate.md` Decision 5 and its sign-off
checklist directly from the filled-in template.

To lint just this spike (intentionally outside `make validate`'s scope,
same convention as the sibling spikes):

```bash
uv run --group dev ruff check spikes/hardware-measurements-2026-07-10
```

## Isolation guard

- **Nothing under `src/wilted/` may import anything from `spikes/`.**
  This directory is removable at any time without touching production
  code or data.
- No script ever writes under the real `data/` tree. Every script
  resolves its own results-log path under this spike directory and
  asserts (in code, not just by convention) that the resolved path does
  not fall under `data/` before writing anything — see
  `_guard_no_data_writes()` / `_guard_isolation()` in the Python scripts
  and the `FORBIDDEN_WRITE_ROOT` check in `measure_sleep_availability.sh`.
- Every script only ever *reads* the episode/audio/transcript path you
  pass on the command line — none of them copy, move, or modify the
  source file.
- No script writes to `data/wilted.db` or any other DB file; none of
  them import `wilted.db`.
- ML models load from the existing Hugging Face cache
  (`~/.cache/huggingface`), the same cache the production code already
  uses — no separate spike-only model store is created.
- `results.log` files this spike creates are plain text living only
  inside `spikes/hardware-measurements-2026-07-10/`; deleting the whole
  directory removes every trace of having run these measurements.

## What this spike does NOT attempt

- **Automating the physically-manual observations.** Route changes
  (unplug/switch output device) and sleep/wake/lid-close cannot be
  scripted from software running on the same Mac that's about to sleep
  or change its audio route — these scripts set up the scenario,
  prompt David through the physical action, and capture whatever
  automated signal is available (process-alive checks, network
  reachability, Metal/RSS memory) alongside his observation. They do
  not claim to fully automate what the ADR itself calls out as
  hardware-dependent.
- **A full alert pipeline.** `measure_ml_residency.py --mode
  alert-latency` is a stopwatch harness around real TTS synthesis, not
  a live NWS-alert-to-interrupt integration test — the interruption
  scheduler, safe-boundary detection, and alert monitor don't need to
  exist yet for this measurement to be honest about the TTS-synthesis
  latency component.
- **Wiring into `make validate` or any CI gate.** These are one-off,
  human-run measurements that finalize a design decision, not
  regression tests. Nothing in this directory is imported or invoked by
  the test suite.
