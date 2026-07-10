# Hardware measurement results — Task 0.4 / Task 0.3 deferred dims

Fill in every **Measured value** cell after running the corresponding
script in this directory (see `README.md` for run instructions). Once
this table is complete, its values directly finalize ADR 0001 Decision 5
(`docs/adr/0001-mac-radio-substrate.md`) — replace the provisional targets
there with the measured ones and flip the sign-off checkbox.

Date run: **2026-07-10** (section 4 residency) · Mac model / chip: **Mac17,6 / Apple M5 Max, 128 GB** ·
Episode used: **data/podcasts/measure-404-best-game/80391e99cf24d187eec49da364a45858.mp3** (93.9 min, 756-segment transcript) — for sections 1–2

> Status: **ALL sections filled** (2026-07-10, M5 Max). §1 playback, §2 route-recovery,
> §3 sleep, and §4 residency + alert-latency all measured. Decision 5 can now be
> finalized from these values (see checklist below).

---

## 1. Real-speaker podcast playback — `measure_playback.py`

Source: ADR Decision 5 ("Interruption-latency & resume-fidelity targets")
and the "Streaming playback rework" consequence.

Measured 2026-07-10 (M5 Max) via `measure_playback.py`, streaming `play_file`:

| Metric | Provisional ADR target | Measured value | Notes |
|---|---|---|---|
| Episode duration | 90–120 min (PREPARED episode) | **94.1 min** (5645.6 s) | 404 Media episode, 756-segment transcript |
| Startup latency (time to first audio) | No explicit number yet — ADR notes current full-decode `play_file` costs "~4 s cold start for 94 min at 24 kHz mono" as the baseline to beat/confirm | **506 ms** | Streaming decode: first audio in ~0.5 s vs the ADR's ~4 s full-decode baseline (~8× faster to first sound) |
| Peak memory (RSS) during playback | ADR baseline estimate: "542 MB ... for 94 min at 24 kHz mono" (current full-decode buffer) | **70 MB** | **~8× below the 542 MB estimate** — the streaming O(chunk) rework validated on hardware; the headline Decision-5 win |
| Seek time (mid-episode segment jump) | None set — ADR notes current full-decode gives "O(1) seek *once decoded*"; measurement should confirm/refute in practice | **2.0 s** (2010 ms) | Seek to segment 378/756 via ffmpeg `-ss`; accurate output seek decodes from the prior keyframe (the cost trade for boundary-accurate resume) |
| Checkpoint/resume fidelity | "Transcript/chapter-boundary resume initially" (Decision 5, item "Resume fidelity (#3)") | **PASS** | Boundary-accurate: stopped after seg 0, resumed at seg 1 (start_s=8.2 s); first segment reported after the seek = 1; `playback_time_s` at resume = 8.3 s. Programmatic check — seek to seg N+1 landed exactly on seg N+1 |

## 2. Audio-route recovery — `measure_route_recovery.py`

Source: ADR "Deferred to your hardware" consequence — "audio-route
recovery ... (0.3 deferred dims)". No provisional numeric target exists;
the deliverable is a qualitative behavior classification per scenario.

Measured 2026-07-10 (M5 Max). **Key finding: playback does NOT follow output-device
changes** — the stream binds to the device active at open time and stays there.

| Metric | Provisional ADR target | Measured value | Notes |
|---|---|---|---|
| Unplug headphones mid-playback | Not yet defined — should NOT crash; should pause into a visible no-output state or follow the new default device, never silently misroute | **wrong-device** | "started on MacBook speakers and never left despite changing audio output to Bluetooth speaker" — no crash, no exception, playback thread stayed alive |
| Switch to AirPods mid-playback | Same as above | **wrong-device** | Same behavior — audio stayed on the original device |
| Switch back to built-in speakers mid-playback | Same as above | **other** | "audio has never left the MacBook speakers despite whatever output I select in the mac menu" |
| App/terminal stayed responsive across all route changes | Must stay responsive (no hang) | **yes** | Responsive across all three scenarios; no crash, no raised exception, `play_file` thread alive throughout |

**Consequence for Plan A:** `sd.OutputStream` binds to the default device at open
and does not follow later default-device changes (expected PortAudio behavior). The
station will keep playing on whichever device was active when playback started —
switching to AirPods/headphones mid-episode is silently ignored. Remediation options
for Plan A: subscribe to CoreAudio default-device-change notifications and reopen the
stream on change, or accept + document the limitation. Not a crash/robustness bug (it
stayed responsive), but a real UX gap for an always-on radio.

## 3. Awake/sleep availability — `measure_sleep_availability.sh`

Source: ADR "Deferred to your hardware" consequence — "awake/sleep
availability (0.3 deferred dims)". No provisional numeric target exists;
the deliverable is a qualitative availability classification per
scenario.

Measured 2026-07-10 (M5 Max). No wilted/station process was running during the test,
so process-survival was not exercised; the useful signal is **LAN reachability, which
survived all three** (same IPv4 before/after each) — relevant to phone-pairing.

| Metric | Provisional ADR target | Measured value | Notes |
|---|---|---|---|
| Display sleep — station/process survives | Not yet defined — process should survive; note any behavior change | **LAN survived** | IPv4 stable 192.168.1.194 before/after; no station process running to observe (process-survival dimension not exercised) |
| Lid close — actually sleeps vs clamshell mode, and effect on station | Not yet defined | **clamshell mode** | Mac stayed awake on lid close (external display/power) — it did not suspend; LAN stable |
| Full system sleep — process survives, network/LAN reachability recovers on wake | Not yet defined — this determines whether a phone-pairing LAN connection needs re-establishment logic | **LAN recovered on wake** | "everything seemed fine"; same IPv4 after wake — LAN reachability recovered automatically, so a phone-pairing connection likely needs only a reconnect, not a full re-establish |

**Note:** to test process/playback survival across sleep, re-run with a `wilted`
process actually playing in another terminal — this run measured the network/LAN
dimension only (which is the one that gates phone-pairing re-establishment logic).

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
| Alert-detected → bulletin-start latency | Decision 5: "target alert-detected→bulletin-start measured first, then set a ceiling" — **no ceiling exists yet; this measurement sets it** | **5.12 s** (cold) | 0.97 s model load + **4.15 s TTS synthesis** for a one-sentence bulletin. Cold path (includes a Kokoro load); with the model already resident, ~4.15 s is the floor. TTS synthesis dominates — the lever for any tighter ceiling is synthesis speed (shorter bulletins, a faster/warm TTS, or pre-synth) |

---

## Decision 5 finalization checklist

Once the table above is filled in:

- [x] Set the interruption-latency ceiling in Decision 5 from the measured value: **alert-detected→bulletin-start = 5.12 s cold / ~4.15 s warm** (TTS-synthesis bound). **Ceiling set: 6 s cold / 5 s warm** for a one-sentence safe-boundary bulletin; pre-synth/shorter bulletins/streaming TTS are the levers if a tighter ceiling is wanted later (not required for the MVP). *(2026-07-10)*
- [x] Confirm or revise the resume-fidelity target from the measured result: **boundary-accurate resume PASS** — the "transcript-boundary resume initially" target is met by the current implementation.
- [x] Set F4's ±N ms safe-interruption band (Decision 5 item 3) — informed by measured startup **≈0.5 s** and seek **≈2.0 s**. **Set: ±250 ms band** around segment boundaries (conservative given ~6.7 s mean segments / 0.5 s segmentation silence gap; widen as confidence grows). *(2026-07-10)*
- [x] Note the audio-route-recovery behavior as a consequence for Plan A: **wrong-device (does not follow device changes), but responsive/no-crash** — recorded in §2 with remediation options.
- [x] Note the awake/sleep availability behavior as a consequence for Plan A: **LAN reachability survived display sleep / clamshell / system sleep**; process-survival untested (no station running) — recorded in §3.
- [x] Confirm the one-model-residency property held (or file a follow-up if it didn't). **HELD (2026-07-10)** — MLX Metal pool returns to baseline between all three models. Follow-up noted: GGUF LLM RSS (~5.4 GB) is retained by llama.cpp after close (separate allocator); coordinator should budget MLX-Metal residency and llama.cpp RSS separately.
- [x] Update `docs/adr/0001-mac-radio-substrate.md` Decision 5's status line and the sign-off checklist's Decision 5 row from "NEEDS the Plan A measurement" to a dated, signed-off decision. **Done 2026-07-10** — Decision 5 header now reads *FINALIZED*, body carries measured values + ceiling, status line and checklist flipped to signed-off.
