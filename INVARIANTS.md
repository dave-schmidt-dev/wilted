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
rationale: Playback state carries revision ID, position, completion, session epoch, explicit restart/rewind intent, and update time. Merge rules preserve intentional rewinds/restarts and reject incompatible revisions. After an explicit rewind or restart, later Mac and iPhone checkpoints retain that intent for the session; compatible pending listener playback rebases against fetched server state before retry.

### W-INV-007 — CloudKit transfer with local cache
area: ["WiltedKit/**", "WiltedMac/**", "WiltediOS/**", "CloudSync/**", "Listener/**"]
gate_test: test-gate.sh
threshold: 3
rationale: CloudKit is a transfer service, not the source of truth or a real-time channel. Both apps retain local state; completed Mac revisions automatically publish metadata plus deterministic bounded byte chunks, catalog fetches never stage audio, and iOS explicitly fetches, validates, and atomically reconstructs a selected revision before caching it for offline playback. Persisted zone changes/deletions survive relaunch, but engine tokens advance only after corresponding local data or send acknowledgements commit; pending chunks gate publication only for their own revision. Every typed account change quarantines local work until explicit review resumes the current engine, and an operation generation prevents pre-quarantine fetch/send completions from committing afterward.

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
rationale: Wilted preserves Zero Delta structure, status semantics, native typography, accessibility, and flat surfaces while limiting the lettuce motif to a restrained identity mark and accent. Navigation stays literal, color never carries state alone, and light/dark behavior is snapshot- and contrast-tested. Larder's Add article action remains accessible after its last article is removed and when a search has no article matches. Larder never repeats Feeds' Keep/Skip decision; its Played label requires a durable completion record, and its completion control appears only for a started, unfinished row.

### W-INV-011 — Episode state dimensions stay orthogonal and locally durable
area: ["Producer/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Download progress, preparation outcome, listening completion, and retirement are independent, separately-persisted facts about a podcast episode; no single stored enum collapses them, and any user-facing lifecycle label is derived from the current combination at read time rather than written as its own column. Preparation outcomes are keyed by revision, so a superseded revision's outcome never masks the current one; listening completion is keyed by item, since a listener's "done with this episode" intent outlives any one revision's replacement. `LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord` and `PodcastListeningRecord` are local-only SwiftData rows with no `WiltedRecordType` counterpart; podcast sync (W-INV-007) is not implemented for them, and if it ever is, the item-scoped listening record needs its own last-writer-wins-by-`updatedAt` merge rule distinct from the revision-scoped merge rules the CloudKit contract already covers, because two devices can independently mark the same item complete against different revisions.

### W-INV-012 — Verification is headless first; the screen-seizing Mac UI suite stays a few journeys
area: ["WiltedMacUITests/**", "WiltedMacTests/**", "scripts/test-gate.sh"]
gate_test: test-gate.sh
threshold: 3
rationale: The Mac XCUITest leg takes over the owner's cursor, keyboard, and focus, so it is reserved for what nothing headless can prove: real clicks reaching controls, popover and window presentation, keyboard shortcuts, hit-testing, and the live accessibility tree. Every other UI check is a model test, a pixel baseline, or a source assertion in `WiltedMacTests`, which run in `make validate` without touching the screen. `WiltedMacSmokeUITests` holds a few multi-step journeys, one launch each. An assertion that genuinely needs a real window joins an existing journey that already has the right fixture, and a new journey is added only when no existing launch can reach the state. The gate reads its test-count floor from the suite instead of pinning a number, so the suite can grow or shrink with the product, and a run that executes fewer tests than the suite declares still fails. The pre-push hook enforces the deferred leg without driving the screen: it compares pushed refs with the clean-commit, zero-failure, zero-deferral `make native-ui` receipt for the explicit Mac UI surface in `scripts/mac-ui-surface.paths`; a changed surface without that receipt cannot pass the hook.

### W-INV-013 — Ad recovery preserves uncertain programme
area: ["Producer/Workers/**", "Producer/Runtime/**", "Producer/Sources/WiltedProducer/PodcastPreparationPipeline.swift"]
gate_test: test-gate.sh
threshold: 3
rationale: A classifier label, sponsor name, or pause is a reason to review audio, not permission to remove it. Unanchored host-read recovery is bounded by explicit commercial evidence, time and call limits, complete candidate text, and independent programme checks on the proposed cues and both sides. A cue still judged programme or mixed stays audible; a separately confirmed commercial suffix may be removed. Invalid or incomplete review keeps the audio. A changed worker records a new semantic version and source hashes so future preparations have distinct provenance; the production invalidation-rule table remains empty, so that fingerprint change alone does not condemn existing prepared audio. Prepared-copy diagnostics and owner reports identify gaps but cannot stand in for replay of a missing original aligned input or prove a current library revision has been repaired.
