# ADR 0001 — Wilted Mac-first Personal Radio substrate

**Status:** Provisionally **APPROVED by David 2026-07-10** — Decisions 1, 2, 3, 4, 6 approved (their headers below read *APPROVED*); Decision 5 (latency/resume/F4 targets) remains pending the Plan A hardware measurement. Full 0.7 closure also needs the deferred hardware dims (Mac UX velocity, audio-route recovery, awake/sleep). Canonical committed copy: `docs/adr/0001-mac-radio-substrate.md`.
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

## Decision 5 — Interruption-latency & resume-fidelity targets *(NEEDS the Plan A measurement — provisional)*

These depend on the alert-latency measurement that requires your hardware (0.4 remainder), so they are **provisional starting targets, not final:**
- **Interruption latency:** interrupt only at a safe boundary; target alert-detected→bulletin-start measured first, then set a ceiling. MVP promises a controlled safe-boundary interrupt, **not** mid-sentence preemption.
- **Resume fidelity (#3):** transcript/chapter-boundary resume initially. Note: the current full-decode buffer gives O(1) seek *once decoded*, but the required streaming rework (below) changes this — decide second-level resume after that rework is scoped.
- **F4 (transcript interruption tolerance):** replace the current zero-width safe windows with a small ±N ms band around segment boundaries; N is set by this decision. Until then, transcript-sourced entries are conservatively near-no-interrupt (safe, but rarely interruptible).

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
- **Streaming playback rework:** current `play_file` buffers the whole episode (542 MB / ~4 s cold start for 94 min at 24 kHz mono) — needs streaming + continuous-time checkpoint to retain the Python adapter.
- **Invariant debt:** INV-2/3/5/6 still lack gate tests (only INV-1/INV-4 covered); A.1 must carry INV-1..6 forward covered-or-replaced.
- **Model lifecycle:** the LLM/Parakeet co-residency remediation (W5) is a prerequisite for any reused processing module; the chosen core introduces a single `ModelCoordinator` lease.
- **0.5 hardening backlog A–E** (in THREAT-MODEL.md) before the shipped pairing implementation.
- **Deferred to your hardware for full 0.7 closure:** Mac UX velocity, audio-route recovery, awake/sleep availability (0.3 deferred dims) and the 0.4 ML/speaker/alert-latency measurements.

## Sign-off checklist (David) — signed off 2026-07-10

- [x] Decision 1 — substrate (headless core + boundary) — **approved**
- [x] Decision 2 — store + migration path — **approved**
- [x] Decision 3 — NWS ZIP 20169 / US-only for prototype — **confirmed (verified against weather.gov)**
- [x] Decision 4 — podcast admission: auto-admit + **14-day** freshness cap, no relevance filter — **approved**
- [ ] Decision 5 — provisional latency/resume/F4 targets — **finalize after the Plan A hardware measurement**
- [x] Decision 6 — Python dependency path (`cryptography`+`keyring`) vs native companion — **approved (Python path)**
