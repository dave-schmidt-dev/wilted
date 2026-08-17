import Foundation
import WiltedSync
import WiltedDomain

private func itemIdentity(of record: WiltedRecordEnvelope) -> String? {
    guard case let .string(value)? = record.fields["itemID"] else { return nil }
    return value
}

/// An in-memory transport with controllable delay/failure, suitable for deterministic tests.
public actor FakeSyncTransport: SyncTransport {
    private let batch: SyncFetchBatch
    private let failure: WiltedSyncError?
    private let delayNanoseconds: UInt64
    private let configuredSendResult: SyncSendResult?
    private var continuation: AsyncStream<SyncStatus>.Continuation?
    public let statuses: AsyncStream<SyncStatus>

    public init(batch: SyncFetchBatch, delayNanoseconds: UInt64 = 0, failure: WiltedSyncError? = nil, sendResult: SyncSendResult? = nil) {
        self.batch = batch; self.delayNanoseconds = delayNanoseconds; self.failure = failure; self.configuredSendResult = sendResult
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        statuses = stream
        self.continuation = continuation
    }

    public func fetchChanges() async throws -> SyncFetchBatch {
        continuation?.yield(.init(phase: .fetching, message: "Fake transport waiting", generationID: batch.generationID))
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let failure { throw failure }
        continuation?.yield(.init(phase: .fetching, message: "Fake transport fetched", generationID: batch.generationID))
        return batch
    }

    public func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        for change in changes {
            let operation: SyncOperation = switch change.operation {
            case .create: .create
            case .update: .update
            case .delete: .delete
            }
            try SyncOwnershipPolicy().validate(role: role, operation: operation, recordType: change.recordID.recordType)
        }
        continuation?.yield(.init(phase: .committing, message: "Fake transport saved \(changes.count) records"))
        if let failure { throw failure }
        if let configuredSendResult { return configuredSendResult }
        return try SyncSendResult(engineState: Data([0x53, 0x59, 0x4E, 0x43]), acknowledgedRecordIDs: changes.map(\.recordID), serverEnvelopes: changes.compactMap(\.record))
    }

    public func finishStatusStream() { continuation?.finish(); continuation = nil }
}

/// An actor-backed repository whose commit is one atomic state replacement.
public actor FakeSyncRepository: SyncRepository {
    private var storedState: SyncRepositoryState
    private let stageFailure: WiltedSyncError?
    private let commitFailure: WiltedSyncError?
    private var continuation: AsyncStream<SyncStatus>.Continuation?
    public let statuses: AsyncStream<SyncStatus>

    public init(state: SyncRepositoryState = .init(), stageFailure: WiltedSyncError? = nil, commitFailure: WiltedSyncError? = nil) {
        storedState = state; self.stageFailure = stageFailure; self.commitFailure = commitFailure
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        statuses = stream
        self.continuation = continuation
    }

    public func state() async -> SyncRepositoryState { storedState }

    public func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch {
        continuation?.yield(.init(phase: .staging, message: "Fake repository staged", generationID: batch.generationID))
        if let stageFailure { throw stageFailure }
        return StagedSyncBatch(batch: batch, priorState: storedState)
    }

    public func commit(_ staged: StagedSyncBatch) async throws {
        continuation?.yield(.init(phase: .committing, message: "Fake repository committing", generationID: staged.batch.generationID))
        if let commitFailure { throw commitFailure }
        var records = staged.priorState.records
        var acknowledged = storedState.remoteAcknowledgedRecordIDs
        let tombstones = storedState.tombstones
        var conflicts = storedState.conflictedRecordIDs
        let pendingIDs = Set(staged.priorState.pendingChanges.map(\.recordID))
        let protectedIDs = staged.priorState.protectedRecordIDs

        for deletedID in staged.batch.deletedRecordIDs {
            let affected = records.filter { candidate in
                candidate.id == deletedID || (deletedID.recordType == .item && itemIdentity(of: candidate) == String(deletedID.recordName.dropFirst(5)))
            }.map(\.id)
            let blocked = affected.filter { pendingIDs.contains($0) || protectedIDs.contains($0) }
            let atomicFamilyBlocked = deletedID.recordType == .item && !blocked.isEmpty
            conflicts.formUnion(atomicFamilyBlocked ? affected : blocked)
            let removable = atomicFamilyBlocked ? [] : Set(affected).subtracting(blocked)
            records.removeAll { removable.contains($0.id) }
            acknowledged.subtract(removable)
        }
        if staged.batch.kind == .fullSnapshot {
            let fetchedIDs = Set(staged.batch.records.map(\.id))
            let absent = records.filter { !fetchedIDs.contains($0.id) }
            let eligibleAbsent = absent.filter { acknowledged.contains($0.id) &&
                !pendingIDs.contains($0.id) && !protectedIDs.contains($0.id) && !conflicts.contains($0.id) }
            records = records.filter { fetchedIDs.contains($0.id) ||
                !acknowledged.contains($0.id) || pendingIDs.contains($0.id) || protectedIDs.contains($0.id) || conflicts.contains($0.id) }
            acknowledged.subtract(eligibleAbsent.map(\.id))
            acknowledged.formUnion(fetchedIDs)
            for fetched in staged.batch.records {
                records.removeAll { $0.id == fetched.id }
                records.append(fetched)
            }
        } else {
            for fetched in staged.batch.records {
                records.removeAll { $0.id == fetched.id }
                records.append(fetched)
            }
        }
        storedState = SyncRepositoryState(records: records, engineState: staged.batch.engineState ?? storedState.engineState,
                                          pendingChanges: storedState.pendingChanges, tombstones: tombstones,
                                          remoteAcknowledgedRecordIDs: acknowledged, protectedRecordIDs: protectedIDs, conflictedRecordIDs: conflicts,
                                          conflictServerRecords: storedState.conflictServerRecords)
    }

    public func enqueue(_ change: SyncPendingChange) async throws {
        storedState = SyncRepositoryState(records: storedState.records, engineState: storedState.engineState,
                                          pendingChanges: storedState.pendingChanges + [change], tombstones: change.tombstone.map { storedState.tombstones + [$0] } ?? storedState.tombstones,
                                          remoteAcknowledgedRecordIDs: storedState.remoteAcknowledgedRecordIDs, protectedRecordIDs: storedState.protectedRecordIDs.union([change.recordID]), conflictedRecordIDs: storedState.conflictedRecordIDs,
                                          conflictServerRecords: storedState.conflictServerRecords)
    }

    public func acknowledge(_ result: SyncSendResult) async throws {
        let acknowledged = Set(result.acknowledgedRecordIDs)
        let pendingByID = Dictionary(storedState.pendingChanges.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
        let outcomeIDs = acknowledged.union(result.failures.map(\.recordID))
        guard outcomeIDs.isSubset(of: pendingByID.keys) else { throw WiltedSyncError.invalidValue(field: "acknowledgement") }
        var records = storedState.records
        for envelope in result.serverEnvelopes where acknowledged.contains(envelope.id) {
            records.removeAll { $0.id == envelope.id }
            records.append(envelope)
        }
        let acknowledgedDeletes = acknowledged.compactMap { id -> WiltedRecordID? in
            guard pendingByID[id]?.operation == .delete else { return nil }
            return id
        }
        let acknowledgedItems = Set(acknowledgedDeletes.compactMap(itemIDFromRecordID))
        let pending = storedState.pendingChanges.filter { !acknowledged.contains($0.recordID) }
        let tombstones = storedState.tombstones.map { tombstone in
            guard acknowledgedItems.contains(tombstone.itemID), !tombstone.remoteAcknowledged else { return tombstone }
            return SyncTombstone(itemID: tombstone.itemID, generationID: tombstone.generationID,
                                 requestedAt: tombstone.requestedAt, remoteAcknowledged: true)
        }
        var conflicts = storedState.conflictedRecordIDs
        var conflictServers = storedState.conflictServerRecords
        for failure in result.failures where failure.disposition == .conflict {
            conflicts.insert(failure.recordID)
            if let serverRecord = failure.serverRecord { conflictServers[failure.recordID] = serverRecord }
        }
        storedState = SyncRepositoryState(records: records, engineState: result.engineState ?? storedState.engineState, pendingChanges: pending,
                                          tombstones: tombstones, remoteAcknowledgedRecordIDs: storedState.remoteAcknowledgedRecordIDs,
                                          protectedRecordIDs: storedState.protectedRecordIDs.subtracting(acknowledged), conflictedRecordIDs: conflicts,
                                          conflictServerRecords: conflictServers)
    }

    public func finishStatusStream() { continuation?.finish(); continuation = nil }
}

private func itemIDFromRecordID(_ id: WiltedRecordID) -> ItemID? {
    let parts = id.recordName.split(separator: ":")
    guard parts.count >= 2 else { return nil }
    return try? ItemID(rawValue: String(parts[1]))
}
