# Wilted Device-Acceptance Correction Spec

**Date:** 2026-08-23
**Status:** Authoritative pre-Hydra plan
**Scope:** Correct the iPhone acceptance failures found in the 0.2.0 MVP and make the Mac-to-iPhone contract observable and truthful.

## Current disposition

Candidate `0.2.0-12` is processed but unassigned and failed device acceptance. It is evidence, not release completion. A new immutable candidate is required after these corrections. No release claim may be based on a simulator, a locally passing test, or a processed-but-unassigned build.

The audit found:

- iOS shows “Library” twice, bare playback controls that read as hyperlinks, and an oversized capsule-shaped Downloads row.
- Settings is static and does not expose connection or sync state.
- The app can derive truthful local download count, download bytes, and last successful iPhone fetch; it must show those values without inventing a producer identity.
- There is no producer/Mac identity contract. Do not claim “Connected Mac” until a persisted, authenticated producer identity exists.
- Mac has no exact duplicate-heading/button defect in the audited surface, but it must expose persisted last-fetch and last-send status.
- Transcript text is discarded after TTS. It must be persisted, synced, and rendered end to end.
- Production CloudKit must contain the promoted schema required by the transcript and observability contract.

## Goals

1. Persist transcript text alongside its audio identity, sync it through CloudKit, and render it on iOS and Mac.
2. Expose truthful, persisted fetch/send and local-download observability on both platforms.
3. Correct the iOS hierarchy and controls so every action is visibly actionable, legible, and testable.
4. Produce device-visible evidence from a signed TestFlight build using Production CloudKit.

## Non-goals

- No fabricated Mac connection, online, sync, or producer claims.
- No redesign of the product beyond the audited acceptance corrections.
- No new analytics, tracking, or third-party telemetry.
- No silent migration, destructive data rewrite, or schema change without migration and rollback evidence.
- No reuse of `0.2.0-12` as the release candidate.

## Immutable lane plan

Each lane has exclusive ownership of its listed surfaces. Lanes may not edit another lane’s files, alter its interfaces, or absorb its tests. Cross-lane changes are captain-owned integration work after both interface checkpoints are recorded.

### Lane 1 — Transcript data path

**Owner:** Transcript persistence, CloudKit mapping, migration, and sync contract.
**Owns:** Transcript model/repository, CloudKit record mapping and schema artifacts, producer transcript extraction boundary, and related data tests.
**Depends on:** Existing audio/item identity and current sync transport.
**Publishes checkpoint:** Versioned transcript interface with stable item ID, transcript text, language/format metadata, revision identity, and availability state. The checkpoint includes migration status, CloudKit field mapping, and fixture data for Lane 3.

**Required work:** Preserve transcript text before/after TTS, sync it bidirectionally where supported, handle absent/stale transcript states explicitly, and expose a read-only consumer interface for both UIs.

**Tests:** Domain round-trip and migration tests; codec/encoding and empty/large transcript cases; CloudKit mapping and record-version tests; sync retry/account-change tests; producer-to-store integration test proving text is not discarded.

### Lane 2 — Listener/Mac observability

**Owner:** Mac producer/listener status and the iOS-observable sync/download facts.
**Owns:** Persisted last successful fetch/send timestamps and outcomes, local download count/byte aggregation, and the producer-status interface.
**Depends on:** Existing producer and sync events; Lane 1’s stable item/revision identity where transcript status is shown.

**Required work:** Persist and expose last successful iPhone fetch, last successful Mac fetch, and last successful Mac send with timestamps and failure states. Derive download count and bytes from local records. Define a producer identity contract before any “connected Mac” label is permitted; until then, display “Mac status unavailable” or equivalent truthful copy.

**Publishes checkpoint:** Versioned observability interface, sample persisted state, freshness semantics, and explicit unavailable/error states consumed by Lane 3.

**Tests:** Domain aggregation tests for count/bytes and timestamp freshness; persistence/relaunch tests; listener/send/fetch success and failure tests; CloudKit mapping tests; no-identity test proving the UI cannot emit a fake connected claim.

### Lane 3 — Cross-platform presentation

**Owner:** iOS and Mac presentation, interaction, accessibility, and visual acceptance.
**Owns:** Screen hierarchy, labels, action controls, transcript presentation, Downloads layout, Settings content, and UI/pixel tests.
**Depends on:** Lane 1 and Lane 2 interface checkpoints. It may use fixtures before integration but may not invent production fields.

**Required work:** Remove the duplicate iOS “Library” heading; render playback actions as buttons with clear affordance and states; replace the giant Downloads capsule with a readable list/card layout; add transcript content and unavailable/loading/error states; add Settings sections for truthful sync/fetch/download facts; keep Mac presentation consistent with its persisted status contract.

**Tests:** Model/view-model tests for every state; accessibility identifiers and action-state tests; iOS and Mac pixel/snapshot tests at supported sizes; UI tests for download, play/pause/restart, transcript visibility, Settings, and empty/error states; layout tests preventing duplicate headings and clipped/oversized rows.

## Orchestration and integration rules

The captain must create one bounded task contract per lane, dispatch exactly these three lanes, and record ownership, dependency, provider/model, start/deadline, retries, and checkpoint paths before execution. Hydra may retry a transient provider failure once. A missing capability, dirty base, lock conflict, missing checkpoint, failing test, or ambiguous ownership is fail-closed and must stop that lane; no lock bypass or speculative integration is allowed.

Lane 3 cannot enter final integration until Lane 1 and Lane 2 checkpoints are immutable and validated. The captain owns only minimal conflict resolution, interface adaptation, and shared release plumbing. Any scope expansion returns to planning.

All long-running dispatch, build, browser, and device operations must emit browser/device-visible progress. No silent wait is acceptable.

## Release gates and evidence

Before publication, the captain must retain:

1. Full local gate: domain, migration, codec, CloudKit mapping, producer/listener, model, UI, pixel, and integration tests on a clean worktree.
2. A dated refreshed screen-by-screen walkthrough covering iOS and Mac reachable screens, controls, disabled/recovery states, transcript states, Settings, Downloads, and system-owned sheets.
3. Production CloudKit schema exactness evidence, including the transcript and observability record/field mapping and promotion result.
4. A signed archive whose entitlements target Production CloudKit and whose candidate identity is new and immutable.
5. TestFlight upload, processing, and assignment receipts for the new candidate.
6. Signed iPhone acceptance evidence: install from TestFlight, fetch, download, play/pause/restart, transcript display, Settings facts, recovery/error behavior, and persisted state after relaunch.
7. Mac acceptance evidence: producer identity behavior, last fetch/send status, transcript publication, and matching Production CloudKit behavior.

The release remains incomplete until processing, assignment, receipt, and signed-device acceptance are all evidenced. Local success, schema promotion, or an uploaded build alone is insufficient.
