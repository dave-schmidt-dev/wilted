# Hardware measurement results — Task 0.4 / Task 0.3 deferred dims

Fill in every **Measured value** cell after running the corresponding
script in this directory (see `README.md` for run instructions). Once
this table is complete, its values directly finalize ADR 0001 Decision 5
(`docs/adr/0001-mac-radio-substrate.md`) — replace the provisional targets
there with the measured ones and flip the sign-off checkbox.

Date run: **2026-07-10** (section 4 residency) · Mac model / chip: **Mac17,6 / Apple M5 Max, 128 GB** ·
Episode used: **data/podcasts/measure-404-best-game/80391e99cf24d187eec49da364a45858.mp3** (93.9 min, 756-segment transcript) — for sections 1–2

> Status: **§4 residency filled** (automated, run 2026-07-10). §1–3 and §4 alert-latency
> are the human-in-the-loop / audio-emitting runs — pending David's hardware session.

---

## 1. Real-speaker podcast playback — `measure_playback.py`

Source: ADR Decision 5 ("Interruption-latency & resume-fidelity targets")
and the "Streaming playback rework" consequence.

| Metric | Provisional ADR target | Measured value | Notes |
|---|---|---|---|
| Episode duration | 90–120 min (PREPARED episode) | | |
| Startup latency (time to first audio) | No explicit number yet — ADR notes current full-decode `play_file` costs "~4 s cold start for 94 min at 24 kHz mono" as the baseline to beat/confirm | | |
| Peak memory (RSS) during playback | ADR baseline estimate: "542 MB ... for 94 min at 24 kHz mono" (current full-decode buffer) | | |
| Seek time (mid-episode segment jump) | None set — ADR notes current full-decode gives "O(1) seek *once decoded*"; measurement should confirm/refute in practice | | |
| Checkpoint/resume fidelity | "Transcript/chapter-boundary resume initially" (Decision 5, item "Resume fidelity (#3)") | PASS / FAIL (human-observed) | |

## 2. Audio-route recovery — `measure_route_recovery.py`

Source: ADR "Deferred to your hardware" consequence — "audio-route
recovery ... (0.3 deferred dims)". No provisional numeric target exists;
the deliverable is a qualitative behavior classification per scenario.

| Metric | Provisional ADR target | Measured value | Notes |
|---|---|---|---|
| Unplug headphones mid-playback | Not yet defined — should NOT crash; should pause into a visible no-output state or follow the new default device, never silently misroute | paused / crashed / wrong-device / followed / silent / other | |
| Switch to AirPods mid-playback | Same as above | paused / crashed / wrong-device / followed / silent / other | |
| Switch back to built-in speakers mid-playback | Same as above | paused / crashed / wrong-device / followed / silent / other | |
| App/terminal stayed responsive across all route changes | Must stay responsive (no hang) | yes / no | |

## 3. Awake/sleep availability — `measure_sleep_availability.sh`

Source: ADR "Deferred to your hardware" consequence — "awake/sleep
availability (0.3 deferred dims)". No provisional numeric target exists;
the deliverable is a qualitative availability classification per
scenario.

| Metric | Provisional ADR target | Measured value | Notes |
|---|---|---|---|
| Display sleep — station/process survives | Not yet defined — process should survive; note any behavior change | survives / dies / notes | |
| Lid close — actually sleeps vs clamshell mode, and effect on station | Not yet defined | describe | |
| Full system sleep — process survives, network/LAN reachability recovers on wake | Not yet defined — this determines whether a phone-pairing LAN connection needs re-establishment logic | survives / dies / notes | |

## 4. ML worker-load, one-model-residency & alert latency — `measure_ml_residency.py`

Source: ADR "Model lifecycle" consequence — "the LLM/Parakeet
co-residency remediation (W5) is a prerequisite for any reused processing
module; the chosen core introduces a single `ModelCoordinator` lease" —
and Decision 5's "Interruption latency" target, which explicitly depends
on "the alert-latency measurement that requires your hardware."

| Metric | Provisional ADR target | Measured value | Notes |
|---|---|---|---|
| At most one MLX/Metal model resident at a time (LLM / TTS / transcription) | Required — zero co-residency (ADR's stated prerequisite for `ModelCoordinator`) | **PASS** | MLX Metal-pool (`mx.get_active_memory`) returns to baseline (~0) after every close, all three phases `[OK]`, drift +0 MB. **Caveat:** the GGUF LLM uses llama.cpp's separate allocator (Metal-pool reads ~0 on load), so its ~5.4 GB shows in RSS not the MLX pool — property holds for the Metal pool, not process RSS (see below). |
| LLM backend load time | None set | **0.54 s** | Gemma-4 E4B QAT-Q4_0 GGUF via llama-cpp-python 0.3.33 (prebuilt wheel; no M5 Metal tensor-compile error). RSS 21 → 5457 MB. |
| LLM backend close time (Metal reclaim) | None set | **0.06 s** | `del`+`gc.collect()` returns MLX pool to baseline but **RSS stays at 5472 MB** — llama.cpp retains the ~5.4 GB (mmap/allocator), not returned to OS. Harmless on 128 GB; note for the coordinator's RSS budget. |
| TTS (Kokoro) load time | None set | **0.50 s** | mlx_audio 0.4.2; Metal pool → 312 MB on load. (First cold load of a session measured ~1.1 s.) |
| TTS (Kokoro) close time (Metal reclaim) | None set | **0.03 s** | Metal pool → ~0 (fully reclaimed). |
| Transcription (parakeet_mlx) load time | None set | **0.92 s** | parakeet-mlx 0.5.1 / mlx 0.31.1; Metal pool → 39 MB on load. |
| Transcription (parakeet_mlx) close time (Metal reclaim) | None set | **0.03 s** | Metal pool → ~0 (fully reclaimed). |
| Alert-detected → bulletin-start latency | Decision 5: "target alert-detected→bulletin-start measured first, then set a ceiling" — **no ceiling exists yet; this measurement sets it** | _pending_ | `--mode alert-latency` emits a ~3 s TTS bulletin through the speakers — deferred to David's audio session. |

---

## Decision 5 finalization checklist

Once the table above is filled in:

- [ ] Set the interruption-latency ceiling in Decision 5 from the measured alert-detected → bulletin-start value.
- [ ] Confirm or revise the resume-fidelity target from the measured checkpoint/resume fidelity result.
- [ ] Set F4's ±N ms safe-interruption band (Decision 5 item 3) — informed by startup/seek timing, if applicable.
- [ ] Note the audio-route-recovery behavior classification as an accepted/rejected consequence for Plan A.
- [ ] Note the awake/sleep availability behavior as an accepted/rejected consequence for Plan A.
- [x] Confirm the one-model-residency property held (or file a follow-up if it didn't). **HELD (2026-07-10)** — MLX Metal pool returns to baseline between all three models. Follow-up noted: GGUF LLM RSS (~5.4 GB) is retained by llama.cpp after close (separate allocator); coordinator should budget MLX-Metal residency and llama.cpp RSS separately.
- [ ] Update `docs/adr/0001-mac-radio-substrate.md` Decision 5's status line and the sign-off checklist's Decision 5 row from "NEEDS the Plan A measurement" to a dated, signed-off decision.
