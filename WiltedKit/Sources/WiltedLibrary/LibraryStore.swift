import Foundation
import WiltedDomain

/// A local change and the server version that disagrees with it. Held until resolved,
/// never dropped and never sent.
public struct LibraryConflict: Sendable, Equatable {
    public var local: PendingLibraryChange
    public let server: VersionedLibraryChange

    public init(local: PendingLibraryChange, server: VersionedLibraryChange) {
        self.local = local
        self.server = server
    }
}

/// Everything a device persists about the library: mirrored content, the committed
/// cursor, and local work that has not been acknowledged.
public struct LibraryStoreState: Sendable, Equatable {
    /// Bumped by every commit; a staged batch built on an older revision is stale.
    public var revision: UInt64 = 0
    public var content = LibrarySnapshot()
    /// Last server version observed or acknowledged per record.
    public var versions: [LibraryRecordKey: UInt64] = [:]
    /// Advances only when a fetched batch commits.
    public var cursor: LibraryChangeToken?
    /// At most one queued mutation per key; a newer local write replaces an older one.
    public var pending: [PendingLibraryChange] = []
    public var conflicts: [LibraryRecordKey: LibraryConflict] = [:]
    /// Mutations the server refused permanently, kept for inspection.
    public var rejected: [PendingLibraryChange] = []
    public var nextLocalSeq: UInt64 = 1

    public init() {}

    /// Pending changes a send will carry; conflicted keys are withheld.
    public var sendable: [PendingLibraryChange] { pending.filter { conflicts[$0.key] == nil } }

    /// Pending changes withheld because their record is conflicted.
    public var conflictBlocked: [PendingLibraryChange] { pending.filter { conflicts[$0.key] != nil } }

    /// Queues a local mutation and applies it to the mirrored content optimistically.
    public mutating func enqueue(_ change: LibraryChange) {
        let key = change.key
        let queued = PendingLibraryChange(localSeq: nextLocalSeq, change: change, baseVersion: versions[key] ?? 0)
        nextLocalSeq += 1
        pending.removeAll { $0.key == key }
        pending.append(queued)
        if var conflict = conflicts[key] {
            conflict.local = queued
            conflicts[key] = conflict
        }
        content = content.applying(change)
    }

    /// Applies a send outcome to exactly the mutations that were sent.
    public mutating func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) {
        let sentBySeq = Dictionary(sent.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for ack in result.acknowledged {
            versions[ack.key] = max(versions[ack.key] ?? 0, ack.version)
            guard let index = pending.firstIndex(where: { $0.key == ack.key }) else { continue }
            if pending[index].localSeq == sentBySeq[ack.key]?.localSeq {
                pending.remove(at: index)
            } else {
                // A newer local write replaced the sent one mid-flight: keep it, rebased.
                let newer = pending[index]
                pending[index] = PendingLibraryChange(localSeq: newer.localSeq, change: newer.change, baseVersion: ack.version)
            }
        }
        for failure in result.failures {
            guard let index = pending.firstIndex(where: { $0.key == failure.key }),
                  pending[index].localSeq == sentBySeq[failure.key]?.localSeq else { continue }
            switch failure.disposition {
            case .conflict:
                if let server = failure.server {
                    conflicts[failure.key] = LibraryConflict(local: pending[index], server: server)
                }
            case .terminal:
                rejected.append(pending.remove(at: index))
            case .retryable:
                break
            }
        }
    }

    /// Releases a held conflict. Keeping local rebases the queued change onto the server
    /// version so the next send wins; discarding takes the server's record and drops the
    /// local change. Discarding a server removal-only change keeps the local entry body.
    public mutating func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) {
        guard let conflict = conflicts.removeValue(forKey: key) else { return }
        versions[key] = max(versions[key] ?? 0, conflict.server.version)
        if keepLocal {
            guard let index = pending.firstIndex(where: { $0.key == key }) else { return }
            pending[index] = PendingLibraryChange(
                localSeq: pending[index].localSeq, change: pending[index].change, baseVersion: conflict.server.version
            )
        } else {
            pending.removeAll { $0.key == key }
            content = content.applying(conflict.server.change)
        }
    }
}

/// A reconciled batch, not visible as committed state until `commit` succeeds.
public struct StagedLibraryBatch: Sendable {
    public let batch: LibraryChangeBatch
    public let priorState: LibraryStoreState
    public let nextState: LibraryStoreState

    public init(batch: LibraryChangeBatch, priorState: LibraryStoreState, nextState: LibraryStoreState) {
        self.batch = batch
        self.priorState = priorState
        self.nextState = nextState
    }
}

/// Local persistence contract for a library replica.
public protocol LibraryStore: Sendable {
    func state() async -> LibraryStoreState
    /// Atomically replaces state with `staged.nextState`, or throws
    /// `LibraryTransportError.staleStagedBatch` if state changed since staging.
    func commit(_ staged: StagedLibraryBatch) async throws
    func enqueue(_ change: LibraryChange) async throws
    /// Applies a send outcome only to the exact mutations that were sent.
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) async throws
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) async throws
}

/// Reference store. `failNextCommit` lets tests prove the cursor holds on a failed commit.
public actor InMemoryLibraryStore: LibraryStore {
    private var current = LibraryStoreState()
    private var commitFailure: (any Error)?

    public init() {}

    public func state() -> LibraryStoreState { current }

    public func failNextCommit(with error: any Error) { commitFailure = error }

    public func commit(_ staged: StagedLibraryBatch) throws {
        if let failure = commitFailure {
            commitFailure = nil
            throw failure
        }
        guard current.revision == staged.priorState.revision else { throw LibraryTransportError.staleStagedBatch }
        current = staged.nextState
        current.revision += 1
    }

    public func enqueue(_ change: LibraryChange) {
        current.enqueue(change)
        current.revision += 1
    }

    public func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) {
        current.acknowledge(result, sent: sent)
        current.revision += 1
    }

    public func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) {
        current.resolveConflict(key, keepLocal: keepLocal)
        current.revision += 1
    }
}
