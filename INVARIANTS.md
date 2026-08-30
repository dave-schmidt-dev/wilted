# Invariants — wilted

> Native Mac producer and iOS listener contract for the post-reset project. Invariant identifiers use the harvest-compatible `W-INV-*` namespace and must not be confused with the archived Python charter.

## What `gate_test: test-gate.sh` proves

Every invariant below names `test-gate.sh` as its gate. As of 2026-08-26 that
script runs eight of its nine legs unconditionally and **defers the ninth**,
`macos-ui-tests`, unless `WILTED_MAC_UI=1` (`make native-ui`).

macOS XCUITest has no headless mode. It drives real HID events through
WindowServer, so the leg seizes the cursor, keyboard, and window focus for its
entire run and cannot share a machine with its operator. Deferring it by
default is a deliberate trade, recorded here because it changes what a green
gate means.

A deferred leg is not a passed leg. The gate counts deferrals separately, names
them in `native.deferred`, and never emits an unqualified `native.passed` when
any leg was deferred; `tests/test-native-gate.sh` asserts all three and is
mutation-tested against both the "silently pass" and "never defer" regressions.
So a green `make validate` is honest about owing the Mac UI leg, but it is not
evidence that leg ran. Only `make native-ui` is.

Invariants whose evidence depends on the real Mac UI surface — W-INV-005 and
W-INV-010 in particular — are therefore only fully gated by `make native-ui`.
Two facts about the Mac UI suite make it irreplaceable rather than merely
convenient, and both were measured rather than assumed (see HISTORY.md,
2026-08-26): a `NavigationSplitView`'s navigation column is not drawn by
`NSHostingView.cacheDisplay`, so no pixel baseline can cover the sidebar; and
the AppKit accessibility tree does not materialize without an attached AX
client, so no offscreen unit test can prove an accessibility identifier or
label reached the tree.

## Standing invariants

### W-INV-001 — No silent blocking waits
area: ["WiltedMac/**", "WiltediOS/**", "Producer/**", "WiltedKit/**", "CloudSync/**", "Listener/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Every network, subprocess, extraction, speech, transfer, cache, and other stall-prone operation exposes live, cancellable progress on the active UI surface and reaches a bounded failure state.

## Project-specific invariants

### W-INV-002 — Mac-only producer and iOS listener
area: ["WiltedMac/**", "WiltediOS/**", "Producer/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Mac owns ingestion, preparation, and publication; iOS is a listener. No target silently assumes the other's responsibilities.

### W-INV-003 — Source-kind-namespaced stable IDs and immutable audio revisions
area: ["WiltedKit/**", "Producer/**", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Stable item identity and immutable revision identity prevent mutations from attaching playback or delivery state to the wrong audio. Existing article identity remains unchanged. Podcast feed ItemID derives from its canonical feed URL; podcast episode ItemID derives from canonical feed URL plus normalized RSS GUID, falling back to canonical enclosure URL only when the GUID is absent. Both podcast ItemID derivations are source-kind-namespaced so they cannot collide with articles. Downloaded-media RevisionID is source-kind-namespaced and derived from the verified audio content hash, so unchanged bytes retain identity across re-downloads or enclosure URL churn, changed bytes produce a new immutable revision, and podcast revisions cannot collide with TTS revisions.

### W-INV-004 — Atomic producer outputs
area: ["Producer/**", "WiltedMac/**"]
gate_test: test-gate.sh
threshold: 3
rationale: A failed or cancelled preparation never replaces the last valid media; a ready revision is exposed only after its complete, self-contained transfer file is durable. Podcast enclosure downloads remain temporary until bounds, content hash, and media validation succeed and one atomic move publishes the immutable local revision. Cancellation or failure removes only temporary bytes and preserves every prior playable revision.

### W-INV-005 — UI does not write producer state
area: ["WiltedMac/**", "WiltedKit/**"]
gate_test: test-gate.sh
threshold: 3
rationale: SwiftUI presentation and interaction invoke domain operations; producer/library state is changed only through the producer service and shared contracts.

### W-INV-006 — Resume merge preserves intent
area: ["WiltedKit/**", "WiltediOS/**", "WiltedMac/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Playback state carries revision ID, position, completion, session epoch, explicit restart/rewind intent, and update time. Merge rules preserve intentional rewinds/restarts and reject incompatible revisions.

### W-INV-007 — CloudKit transfer with local cache
area: ["WiltedKit/**", "WiltedMac/**", "WiltediOS/**", "CloudSync/**", "Listener/**"]
gate_test: test-gate.sh
threshold: 3
rationale: CloudKit is a transfer service, not the source of truth or a real-time channel. Both apps retain local state; completed Mac revisions automatically publish metadata plus deterministic bounded byte chunks, catalog fetches never stage audio, and iOS explicitly fetches, validates, and atomically reconstructs a selected revision before caching it for offline playback. Persisted zone changes/deletions survive relaunch, every typed account change quarantines local work until explicit review resumes the current engine, and an operation generation prevents pre-quarantine fetch/send completions from committing afterward.

### W-INV-008 — Cross-target fixtures are authoritative
area: ["WiltedKit/**", "WiltedMacTests/**", "WiltediOSTests/**", "CloudSync/**", "Listener/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Publish, decode, merge, completion, deletion, version mismatch, offline cache, partial failure, delayed delivery, typed account transitions, and deterministic account-change interleavings use shared fixtures so Mac and iOS cannot silently diverge.

### W-INV-009 — Release evidence remains separated
area: ["README.md", "TASKS.md", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Native Mac daily use is implemented and reaches Phase 3 Mac owner acceptance before fresh iPhone or CloudKit qualification begins. Mac owner acceptance, portal capability configuration, local tests, simulator results, effective signed entitlements, Development CloudKit runtime, Production CloudKit, physical-device behavior, App Store Connect processing, and user-visible TestFlight are distinct evidence; none substitutes for another.

### W-INV-010 — Zero Delta Lettuce remains legible and native
area: ["Shared/**", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Wilted preserves Zero Delta structure, status semantics, native typography, accessibility, and flat surfaces while limiting the lettuce motif to a restrained identity mark and accent. Navigation stays literal, color never carries state alone, and light/dark behavior is snapshot- and contrast-tested.
