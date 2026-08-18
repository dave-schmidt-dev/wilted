# Invariants — wilted

> Native Mac producer and iOS listener contract for the post-reset project. Invariant identifiers use the harvest-compatible `W-INV-*` namespace and must not be confused with the archived Python charter.

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

### W-INV-003 — Stable IDs and immutable audio revisions
area: ["WiltedKit/**", "Producer/**", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Stable item identity and immutable revision identity prevent mutations from attaching playback or delivery state to the wrong audio.

### W-INV-004 — Atomic producer outputs
area: ["Producer/**", "WiltedMac/**"]
gate_test: test-gate.sh
threshold: 3
rationale: A failed or cancelled preparation never replaces the last valid media; a ready revision is exposed only after its complete, self-contained transfer file is durable.

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
rationale: CloudKit is a transfer service, not the source of truth or a real-time channel. Both apps retain local state; iOS can play cached audio offline, persisted zone changes/deletions survive relaunch, every typed account change quarantines local work until explicit review resumes the current engine, and an operation generation prevents pre-quarantine fetch/send completions from committing afterward.

### W-INV-008 — Cross-target fixtures are authoritative
area: ["WiltedKit/**", "WiltedMacTests/**", "WiltediOSTests/**", "CloudSync/**", "Listener/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Publish, decode, merge, completion, deletion, version mismatch, offline cache, partial failure, delayed delivery, typed account transitions, and deterministic account-change interleavings use shared fixtures so Mac and iOS cannot silently diverge.

### W-INV-009 — Release evidence remains separated
area: ["README.md", "TASKS.md", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Portal capability configuration, local tests, simulator results, effective signed entitlements, Development CloudKit runtime, Production CloudKit, physical-device behavior, App Store Connect processing, and user-visible TestFlight are distinct evidence; none substitutes for another.

### W-INV-010 — Zero Delta Lettuce remains legible and native
area: ["Shared/**", "WiltedMac/**", "WiltediOS/**"]
gate_test: test-gate.sh
threshold: 3
rationale: Wilted preserves Zero Delta structure, status semantics, native typography, accessibility, and flat surfaces while limiting the lettuce motif to a restrained identity mark and accent. Navigation stays literal, color never carries state alone, and light/dark behavior is snapshot- and contrast-tested.
