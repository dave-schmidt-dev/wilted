import Foundation
import WiltedDomain

public extension LibrarySnapshot {
    /// Applies one change. Total and order-insensitive per key: a removal for an entry
    /// this replica has not seen is a no-op, because the server log is ordered and an
    /// entry upsert always carries its own removal state.
    func applying(_ change: LibraryChange) -> LibrarySnapshot {
        var next = self
        switch change {
        case let .source(source): next.sources[source.id] = source
        case let .entry(entry): next.entries[entry.id] = entry
        case let .removal(entryID, state):
            if let entry = entries[entryID], entry.removal != state, let updated = try? entry.applyingRemoval(state) {
                next.entries[entryID] = updated
            }
        case let .slot(slot): next.slots[slot.entryID] = slot
        case let .slotRemoved(entryID): next.slots[entryID] = nil
        case let .listening(record): next.listening[record.itemID] = record
        }
        return next
    }
}

public enum LibrarySyncPhase: String, Sendable, Equatable { case fetching, committing, sending, completed, failed }

public struct LibrarySyncStatus: Sendable, Equatable {
    public let phase: LibrarySyncPhase
    public let message: String

    public init(phase: LibrarySyncPhase, message: String) {
        self.phase = phase
        self.message = message
    }
}

/// Drives fetch, reconcile, commit and send against a transport and a store, with the
/// same commit discipline as `SyncCoordinator`: work is validated against the operation
/// generation before it is committed, the store cursor and the transport's committed
/// token advance only after the store commit succeeds, and conflicted records are held.
public actor LibraryReconciler {
    /// Maximum stage/commit attempts for one fetched batch after local mutation races.
    public static let maximumStaleStageAttempts = 3

    private let transport: any LibraryTransport
    private let store: any LibraryStore
    private var continuation: AsyncStream<LibrarySyncStatus>.Continuation?
    public let statuses: AsyncStream<LibrarySyncStatus>

    public init(transport: any LibraryTransport, store: any LibraryStore) {
        self.transport = transport
        self.store = store
        let (stream, continuation) = AsyncStream<LibrarySyncStatus>.makeStream()
        statuses = stream
        self.continuation = continuation
    }

    /// Pure and idempotent: a change at or below the recorded version of its key is
    /// skipped, so re-applying a batch returns an equal state. A change that meets a
    /// different pending local change for the same key is held as a conflict instead
    /// of overwriting local work; an identical one is the echo of our own send.
    public static func reconcile(_ state: LibraryStoreState, with batch: LibraryChangeBatch) -> LibraryStoreState {
        var next = state
        for incoming in batch.changes {
            let key = incoming.change.key
            guard incoming.version > (next.versions[key] ?? 0) else { continue }
            if let local = next.pending.first(where: { $0.key == key }) {
                if local.change == incoming.change {
                    next.pending.removeAll { $0.key == key }
                    next.conflicts[key] = nil
                    next.versions[key] = incoming.version
                } else {
                    next.conflicts[key] = LibraryConflict(local: local, server: incoming)
                }
            } else {
                next.content = next.content.applying(incoming.change)
                next.versions[key] = incoming.version
            }
        }
        next.cursor = batch.token ?? next.cursor
        return next
    }

    /// Fetches since the committed cursor and commits one complete generation; a failure
    /// leaves the store and the transport's committed token unchanged.
    public func synchronize() async -> Result<LibraryChangeBatch, Error> {
        emit(.fetching, "Fetching changes")
        do {
            let generation = await transport.operationGeneration()
            let cursor = await store.state().cursor
            let batch = try await transport.fetchChanges(since: cursor)
            for attempt in 1...Self.maximumStaleStageAttempts {
                let prior = await store.state()
                let staged = StagedLibraryBatch(batch: batch, priorState: prior, nextState: Self.reconcile(prior, with: batch))
                try await ensureCurrent(generation)
                emit(.committing, "Committing fetched changes")
                do {
                    try await store.commit(staged)
                    try await transport.commitFetchedState(batch.token)
                    emit(.completed, "Sync completed")
                    return .success(batch)
                } catch let error as LibraryTransportError where error == .staleStagedBatch {
                    guard attempt < Self.maximumStaleStageAttempts else { throw error }
                }
            }
            throw LibraryTransportError.staleStagedBatch
        } catch {
            emit(.failed, String(describing: error))
            return .failure(error)
        }
    }

    /// Sends queued changes and applies the acknowledgement to exactly what was sent.
    /// Conflicted records are withheld; if nothing else is queued the send fails loudly
    /// with `sendBlockedByConflicts` rather than reporting success.
    public func sendPending() async -> Result<LibraryPushResult, Error> {
        do {
            let state = await store.state()
            let sendable = state.sendable
            guard !sendable.isEmpty else {
                let blocked = state.conflictBlocked.count
                guard blocked == 0 else { throw LibraryTransportError.sendBlockedByConflicts(count: blocked) }
                emit(.completed, "No pending changes to upload.")
                return .success(LibraryPushResult())
            }
            emit(.sending, "Uploading \(sendable.count) changes")
            let generation = await transport.operationGeneration()
            let result = try await transport.push(changes: sendable)
            try await ensureCurrent(generation)
            try await store.acknowledge(result, sent: sendable)
            try await transport.commitSentState(result.token)
            let held = await store.state().conflictBlocked.count
            if result.failures.isEmpty {
                emit(.completed, "Uploaded \(result.acknowledged.count) changes. \(held) held.")
            } else {
                emit(.failed, "\(result.failures.count) changes need attention.")
            }
            return .success(result)
        } catch {
            emit(.failed, String(describing: error))
            return .failure(error)
        }
    }

    public func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) async throws {
        try await store.resolveConflict(key, keepLocal: keepLocal)
    }

    public func finishStatusStream() {
        continuation?.finish()
        continuation = nil
    }

    private func emit(_ phase: LibrarySyncPhase, _ message: String) {
        continuation?.yield(LibrarySyncStatus(phase: phase, message: message))
    }

    private func ensureCurrent(_ expected: UInt64) async throws {
        guard await transport.operationGeneration() == expected else { throw LibraryTransportError.superseded }
    }
}
