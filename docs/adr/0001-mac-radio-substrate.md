# ADR 0001 — Wilted Mac-first Personal Radio substrate

**Status:** **APPROVED by David 2026-07-10** — Decisions 1, 2, 3, 4, 6 approved (their headers below read *APPROVED*); **Decision 5 (latency/resume/F4 targets) finalized 2026-07-10** from the M5 Max hardware measurements (`spikes/hardware-measurements-2026-07-10/RESULTS-TEMPLATE.md`). Of the deferred hardware dims, audio-route recovery and awake/sleep are now measured (see Decision 5); Mac UX velocity remains the only open 0.7 dim, exercised in Plan A itself. Canonical committed copy: `docs/adr/0001-mac-radio-substrate.md`.
**Date:** 2026-07-10 · **Plan:** `mac-first-personal-radio-2026-07-10` · **Evidence:** phase0-inventory, phase0-3-substrate-scorecard, the three disposable spikes, and the security-auditor review — all 2026-07-10.

## Context

Wilted is being repositioned from an article reader into a Mac-first personal radio station with a later local iPhone handoff. Phase 0 built a substrate-neutral station contract layer (`src/wilted/station/`) and measured two candidate substrates plus migration, long-media, and pairing/TLS feasibility, without committing to a UI or store. This ADR selects the substrate for Plan A.

**Meta-finding that frames every decision:** the committed contract layer is genuinely substrate-neutral — both candidates drove the identical fixture through the same reducer to identical results (`station_revision=6`, `owned_by_iphone`, 0 rejections). So the choice is not "which reducer" but two orthogonal axes: **where authoritative state lives** and **how clients reach it**.

---

## Decision 1 — Substrate: headless core + versioned manifest boundary *(APPROVED 2026-07-10)*

Adopt **candidate (a): an extracted headless station core that owns authoritative state and exposes a versioned, JSON-serializable manifest/checkpoint boundary + idempotent commands (`mutation_id` + `expected_revision`).** Clients (a Mac UI now, the iPhone later) consume the boundary; none mutate state directly.

**Why (measured):**
- **Multi-process ownership** — candidate (a) fences cleanly across clients (owner mutates → non-owner rejected → monotonic handoff → former owner fenced). Candidate (b) in-process **split-brains**: two processes (TUI + nightly daemon) both claim the lease and diverge with zero rejection. The radio architecture *has* multiple processes (monitor daemon + playback UI + phone), so this is decisive.
- **iPhone readiness** — the manifest boundary **is** the Phase-B handoff protocol; a Swift client consumes it with no Python present.
- **Bug-class elimination** — clients see an opaque `entry_id` + media summary, so the confirmed `_start_playback` podcast-mis-routing defect class and UI-couples-to-state bugs are structurally harder to reintroduce.

### Failure-class ledger (plan requirement CR-5)

Both candidates **RETAIN** every reducer rejection (owner-loss, stale revision, repeated mutation-id, expired entry, incomplete bulletin media, missing safe checkpoint, stale epoch).

| Candidate | ELIMINATES | INTRODUCES |
|---|---|---|
| **(a) headless core + boundary** *(chosen)* | UI-couples-to-state bugs; content-routing bugs (podcast-mis-routing class) | manifest **schema-version drift** (mitigate: enforce `MANIFEST_SCHEMA_VERSION` on read); **sync-latency** once remote (mitigated by existing `mutation_id`/`expected_revision`) |
| **(b) in-process controller** *(rejected)* | none beyond the reducer | **split-brain across OS processes** (measured) |

---

## Decision 2 — Store & migration: versioned atomic JSON doc + `media/<sha256>` index *(APPROVED 2026-07-10)*

Authoritative state persists as a **versioned atomic JSON state document** (tempfile + `os.replace`, same pattern as `cache.py:save_manifest`) plus a **durable-media index** keyed by content SHA-256. This is the persisted form of the chosen boundary; the existing SQLite `Item` table remains an **import source, never converted in place**.

**Migration rehearsed (0.6):** export → import → hash-verify → rollback on isolated data — all four gates passed, real `data/wilted.db` untouched. **Known cost, common to any substrate:** 7 fields have no clean `Item` equivalent; critically **`finalization` cannot be derived from `Item.status`** — a real hash/size pass is required before an artifact may claim `published` (INV-4). Budget for that pass in Plan A.

---

## Decision 3 — NWS coverage for ZIP 20169 *(VERIFIED — confirm sign-off)*

Verified live against `api.weather.gov` (2026-07-10): ZIP 20169 = Haymarket, VA → forecast office **LWX**, forecast zone **VAZ526**, county **VAC153**, tz America/New_York; the active-alerts endpoint resolves (0 active at check time). **US/NWS-only is acceptable for the prototype** (US location). Monitor via `GET api.weather.gov/alerts/active?zone=VAZ526` at NWS's documented polite cadence; a descriptive `User-Agent` header is **required** by the API. Weather uses this deterministic provider payload with no LLM lease (per the plan).

---

## Decision 4 — Podcast admission policy *(APPROVED 2026-07-10)*

**Approved: automatic admission for subscribed podcasts (subscription = selection, matching `discover.py:283-313`) with a 14-day freshness cap — episodes older than 14 days are not auto-admitted to the station. No additional relevance filter for the MVP.** Rationale: the test feed alone has 212 episodes; the cap stops a new subscription from backfilling the entire archive into the queue.

---

## Decision 5 — Interruption-latency & resume-fidelity targets *(FINALIZED 2026-07-10 from M5 Max measurements)*

Measured on David's M5 Max via `spikes/hardware-measurements-2026-07-10/` (full evidence in that dir's `RESULTS-TEMPLATE.md`). Targets are now **final**:

- **Interruption latency:** measured **alert-detected→bulletin-start = 5.12 s cold** (0.97 s TTS model load + 4.15 s synthesis) / **~4.15 s warm**. TTS synthesis dominates. **Ceiling set: 6 s cold / 5 s warm** for a one-sentence bulletin interrupted at a safe boundary. MVP promises a controlled safe-boundary interrupt, **not** mid-sentence preemption. Lever to tighten later (not required for the MVP ceiling): pre-synthesize common bulletin templates, shorter bulletins, or streaming TTS.
- **Resume fidelity (#3):** **transcript/segment-boundary resume — PASS**, boundary-accurate (resume landed exactly on the target segment; `playback_time_s` = the segment's start). The streaming `play_file` rework shipped this session (see below), so `playback_time_s` now gives a continuous-time checkpoint — **second-level resume is feasible**; the MVP target stays the proven segment-boundary resume, with second-level as a follow-up.
- **F4 (transcript interruption tolerance):** **±250 ms band** around segment boundaries (replaces the zero-width safe windows). Conservative given ~6.7 s mean segments with natural inter-segment pauses (segmentation used a 0.5 s silence gap); widen as confidence grows. Measured startup ≈0.5 s and seek ≈2.0 s bound the real interrupt/resume cost.

**Hardware consequences measured (feed Plan A):**
- **Audio-route recovery — GAP:** playback does **not** follow output-device changes — it stays on the device active at stream-open (`sd.OutputStream` binds at open); all three route-change scenarios logged `wrong-device`. It stayed responsive and never crashed. Plan A: reopen the stream on CoreAudio default-device-change events, or document the limitation. (RESULTS §2.)
- **Awake/sleep:** LAN reachability survived display sleep, clamshell, and system sleep (same IPv4 before/after each). Process-survival not exercised (no station was running). Implication: a phone-pairing LAN connection likely needs only a reconnect, not full re-establishment. (RESULTS §3.)
- **Model lifecycle:** one-model-Metal-residency **holds** — the MLX Metal pool returns to baseline between LLM/TTS/transcribe, validating the `ModelCoordinator` single-lease assumption. Caveat: the GGUF LLM's ~5.4 GB RSS is retained by llama.cpp after `close()` (separate allocator) — budget MLX-Metal residency and llama.cpp RSS separately. (RESULTS §4.)

---

## Decision 6 — Native companion vs Python dependency (open-decision #1) *(APPROVED 2026-07-10)*

For the **Mac-side pairing/TLS**, adopt the **Python path**: `cryptography` (cert generation) + `keyring` (Keychain), both **genuinely new top-level dependencies** (verified absent from the 161-package `uv.lock`; `keyring` also pulls `pyobjc-framework-Security`). A native companion buys Secure-Enclave non-exportable keys but isn't proportionate for a single-user LAN project **unless** Decision 1's client independently goes native Swift — in which case Keychain/mTLS come free and this is revisited. The realistic LAN adversary is already defeated by "no plaintext server." *(0.5 spike proved one-time enrollment, authenticated transport, stale-revision/asset-hash rejection, secret hygiene; TLS 1.2+ with real cert-pinning; security-auditor confirmed no false-greens/leaks.)*

---

## Top-level validation command (plan requirement)

- **Plan A (Mac station, Python):** `make validate` (ruff + full pytest incl. the station contract tests). No native target unless Decision 1/6 selects a native Mac client.
- **Plan B (iPhone, native):** adds a concrete `xcodebuild test -scheme WiltedListener -destination 'platform=iOS Simulator,name=iPhone 15' ` target, named when the app is scaffolded. Real-device tests remain manual gates.

---

## Consequences & prerequisites carried into Plan A

- **Confirmed prerequisite bug:** `_start_playback` routes ready podcasts through `_play_article` (mis-routing) — fix in A.2, same class as the INV-4 fix.
- **Streaming playback rework — SHIPPED (2026-07-10):** `play_file` now streams (ffmpeg → PCM blocks) with a `playback_time_s` continuous-time checkpoint. Measured on the M5 Max: **70 MB peak RSS** (vs the 542 MB full-decode estimate, ~8×) and **506 ms** to first audio (vs ~4 s). Seek is ~2.0 s (accurate output seek decodes from the prior keyframe). Retains the Python adapter.
- **Invariant debt:** INV-2/3/5/6 still lack gate tests (only INV-1/INV-4 covered); A.1 must carry INV-1..6 forward covered-or-replaced.
- **Model lifecycle:** the LLM/Parakeet co-residency remediation (W5) is a prerequisite for any reused processing module; the chosen core introduces a single `ModelCoordinator` lease.
- **0.5 hardening backlog A–E** (in THREAT-MODEL.md) before the shipped pairing implementation.
- **Deferred hardware dims — measured 2026-07-10 (M5 Max):** audio-route recovery (GAP: does not follow device changes), awake/sleep availability (LAN survived all three), and the 0.4 ML/speaker/alert-latency measurements (residency HELD, alert→bulletin 5.12 s cold) are all captured in `spikes/hardware-measurements-2026-07-10/RESULTS-TEMPLATE.md` and folded into Decision 5. **Mac UX velocity** is the one remaining 0.7 dim — it can only be exercised by building Plan A's Mac UI, so it closes in Plan A rather than here.

## Sign-off checklist (David) — signed off 2026-07-10

- [x] Decision 1 — substrate (headless core + boundary) — **approved**
- [x] Decision 2 — store + migration path — **approved**
- [x] Decision 3 — NWS ZIP 20169 / US-only for prototype — **confirmed (verified against weather.gov)**
- [x] Decision 4 — podcast admission: auto-admit + **14-day** freshness cap, no relevance filter — **approved**
- [x] Decision 5 — latency/resume/F4 targets — **finalized 2026-07-10 from M5 Max measurements** (interruption ceiling 6 s cold / 5 s warm; resume boundary-accurate PASS; F4 ±250 ms band)
- [x] Decision 6 — Python dependency path (`cryptography`+`keyring`) vs native companion — **approved (Python path)**

---

## Plan A implementation outcome *(2026-07-11 — MVP landed)*

Plan A (Mac Station MVP) implemented all six decisions; the substrate held under implementation. What shipped vs. what the ADR anticipated:

- **Decision 1 (headless core + boundary):** shipped as `src/wilted/station/` (pure reducer) + `src/wilted/station_runtime/` (StationController single-writer, adapters, monitors). All station mutations funnel through one drain thread (INV-7) and no surface writes state directly (INV-8) — the split-brain the boundary exists to prevent is gate-tested closed.
- **Decision 2 (versioned atomic JSON store + `media/<sha256>` index):** shipped; content-addressed media store + `media_owners.json` drives bulletin GC (A.4.4). `Item` stayed an import source, never in-place converted.
- **Decision 3 (NWS):** in-process `WeatherMonitor` polls zone VAZ526 + county VAC153 in one request with a descriptive User-Agent; live-verified.
- **Decision 4 (14-day freshness cap):** shipped in `EntrySequencer`; `published_at=None` admits with a warning.
- **Decision 5 (latency/resume/F4):** interrupt/resume implemented at the ±250 ms safe band (A.2.4); the 6 s cold / 5 s warm ceiling is asserted only via a machine-independent bound in CI (stubbed TTS) — real observed latency is A.5.1, David's manual hardware gate, still pending.
- **Decision 5 route-recovery GAP:** shipped **floor-first** per the measured gap — a device change stops playback into a visible no-output banner, then recovery replays the current entry at the exact offset on the new default device (a fresh `OutputStream`). Follow-the-device was not pursued because the measurement showed `sd.OutputStream` binds at open.
- **Decision 6 (Python pairing path):** unchanged; not exercised by the single-process station MVP.

**Gate:** `make validate` green at 1095 passed / 1 skipped / 2 snapshots (2026-07-11). New invariants INV-7 (single-writer) and INV-8 (no non-controller write) added to `INVARIANTS.md` with gate tests. The one open dimension is **A.5.1** (full mixed session on real speakers + observed interruption latency), which only physical hardware can exercise.
