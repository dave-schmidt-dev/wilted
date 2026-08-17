# PersistenceProbe

This macOS 14 Phase 0 probe tests SwiftData behind a small actor-isolated adapter. The adapter maps pure `Codable`, `Sendable` probe values to six local categories: articles, immutable revision metadata, playback, preparation journal, sync state, and deletion tombstones.

The store always uses an explicit versioned schema (`v1` to `v2`) and `cloudKitDatabase: .none`; automatic SwiftData CloudKit mirroring is intentionally excluded. v2 persists required opaque `engineState` bytes for CKSyncEngine plus separate playback system-fields/change-tag bytes. The v2 migration adds optional article source metadata and uses empty `engineState` only as an explicit legacy migration sentinel. Store URLs are deterministic and scenario-isolated under the system temporary directory.

Run `tests/test-persistence-probe.sh` from the repository root. Status is emitted to stderr while exactly one JSON result is emitted to stdout by each CLI invocation. `--durable-child` writes and exits after SwiftData save; the gate reopens that store with `--inspect` to falsify durable-before-exit behavior.

If SwiftData cannot open, migrate, or inspect the store, the executable emits `stage=probe.failed` and a JSON error containing the exact thrown SwiftData/Foundation description, then exits nonzero. The shell gate fails closed; it does not substitute an in-memory or SQLite result.
