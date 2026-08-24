import Foundation
import WiltedDomain
import WiltedSync

/// Persisted facts about the listener's sync boundary. This intentionally contains no
/// producer identity: an iCloud account owner token is not a device identity.
public struct ListenerSyncObservability: Codable, Equatable, Sendable {
    public let lastSuccessfulFetchAt: Date?
    public let lastFetchFailure: String?

    public init(lastSuccessfulFetchAt: Date? = nil, lastFetchFailure: String? = nil) {
        self.lastSuccessfulFetchAt = lastSuccessfulFetchAt
        self.lastFetchFailure = lastFetchFailure
    }
}

/// A durable, actor-isolated iPhone repository. The file is replaced atomically after every mutation.
public actor ListenerRepository: SyncRepository {
    public nonisolated let statuses: AsyncStream<SyncStatus>
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    private let stateURL: URL
    private let metadataURL: URL
    private let observabilityURL: URL
    private var current: SyncRepositoryState
    private var generation = 0

    public init(directoryURL: URL) throws {
        self.stateURL = directoryURL.appendingPathComponent("listener-state.json")
        self.metadataURL = directoryURL.appendingPathComponent("listener-metadata.json")
        self.observabilityURL = directoryURL.appendingPathComponent("listener-observability.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = stream
        self.statusContinuation = continuation
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                self.current = try JSONDecoder().decode(SyncRepositoryState.self, from: Data(contentsOf: stateURL))
            } catch {
                throw ListenerError.stateCorrupt
            }
        } else {
            self.current = SyncRepositoryState()
        }
    }

    public func state() async -> SyncRepositoryState { current }

    public func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch {
        emit(.init(phase: .staging, message: "Validating listener sync batch", generationID: batch.generationID))
        let codec = WiltedRecordCodec()
        for record in batch.records {
            switch record.id.recordType {
            case .item: _ = try codec.decodeArticleRecord(record)
            case .revision: _ = try codec.decodeRevisionRecord(record)
            case .transcript: _ = try codec.decodeTranscriptRecord(record)
            // Audio chunks are transport-only assets. They are fetched by the
            // download path and must never enter the listener catalog state.
            case .revisionChunk: break
            case .playbackState: _ = try codec.decodePlaybackRecord(record)
            }
        }
        guard Set(batch.records.map(\.id)).isDisjoint(with: Set(batch.deletedRecordIDs)) else {
            throw WiltedSyncError.invalidValue(field: "sync batch overlap")
        }
        return StagedSyncBatch(batch: batch, priorState: current)
    }

    public func commit(_ staged: StagedSyncBatch) async throws {
        guard staged.priorState == current else { throw ListenerError.staleStage }
        emit(.init(phase: .committing, message: "Persisting listener sync batch", generationID: staged.batch.generationID))
        let effectiveEngineState = staged.batch.engineState ?? current.engineState
        guard staged.batch.records.isEmpty && staged.batch.deletedRecordIDs.isEmpty || effectiveEngineState != nil else {
            throw WiltedSyncError.missingEngineState
        }
        let catalogRecords = staged.batch.records.filter { $0.id.recordType != .revisionChunk }
        let catalogDeletedRecordIDs = staged.batch.deletedRecordIDs.filter { $0.recordType != .revisionChunk }
        var records = Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) })
        let fetchedIDs = Set(catalogRecords.map(\.id))
        let pendingIDs = Set(current.pendingChanges.map(\.recordID))
        var deleted = Set(catalogDeletedRecordIDs)
        let unsafeFamilies: Set<String>
        if staged.batch.kind == .fullSnapshot {
            unsafeFamilies = Set(current.records.compactMap { record in
                let family = familyKey(for: record)
                let unsafe = current.protectedRecordIDs.contains(record.id)
                    || pendingIDs.contains(record.id)
                    || current.conflictedRecordIDs.contains(record.id)
                return unsafe ? family : nil
            })
        } else {
            unsafeFamilies = []
        }
        if staged.batch.kind == .fullSnapshot {
            for record in current.records where current.remoteAcknowledgedRecordIDs.contains(record.id)
                && !fetchedIDs.contains(record.id)
                && !current.protectedRecordIDs.contains(record.id)
                && !pendingIDs.contains(record.id)
                && !current.conflictedRecordIDs.contains(record.id)
                && !unsafeFamilies.contains(familyKey(for: record)) {
                deleted.insert(record.id)
            }
        }
        var acknowledgedDeletes = deleted
        var tombstones = current.tombstones
        var pending = current.pendingChanges
        var conflicts = current.conflictedRecordIDs
        var quarantinedIDs: Set<WiltedRecordID> = []
        for id in deleted {
            records.removeValue(forKey: id)
            if id.recordType == .item, let itemID = try? ItemID(rawValue: id.recordName.split(separator: ":").dropFirst().first.map(String.init) ?? "") {
                tombstones = tombstones.map { tombstone in
                    tombstone.itemID == itemID
                        ? SyncTombstone(itemID: tombstone.itemID, generationID: tombstone.generationID, requestedAt: tombstone.requestedAt, remoteAcknowledged: true)
                        : tombstone
                }
            }
            if id.recordType == .item,
               let itemID = id.recordName.split(separator: ":").dropFirst().first {
                let deletedItemID = String(itemID)
                let quarantined = pending.filter { change in
                    guard let record = change.record,
                          record.fields["itemID"] == .string(deletedItemID) else { return false }
                    return true
                }
                for change in quarantined { conflicts.insert(change.recordID) }
                quarantinedIDs.formUnion(quarantined.map(\.recordID))
                pending.removeAll { change in quarantined.contains(where: { $0.recordID == change.recordID }) }
                var retained: [WiltedRecordID: WiltedRecordEnvelope] = [:]
                for (recordID, record) in records {
                    guard let value = record.fields["itemID"], case let .string(recordItemID) = value else {
                        retained[recordID] = record
                        continue
                    }
                    if recordItemID != deletedItemID { retained[recordID] = record }
                    else { acknowledgedDeletes.insert(recordID) }
                }
                records = retained
            }
        }
        for record in catalogRecords { records[record.id] = record }
        let next = SyncRepositoryState(records: Array(records.values).sorted { $0.id.description < $1.id.description },
                                       engineState: effectiveEngineState, pendingChanges: pending,
                                       tombstones: tombstones, remoteAcknowledgedRecordIDs: current.remoteAcknowledgedRecordIDs.union(acknowledgedDeletes).union(fetchedIDs),
                                       protectedRecordIDs: current.protectedRecordIDs.subtracting(acknowledgedDeletes), conflictedRecordIDs: conflicts.subtracting(acknowledgedDeletes.subtracting(quarantinedIDs)),
                                       conflictServerRecords: current.conflictServerRecords,
                                       accountOwnerToken: current.accountOwnerToken)
        try persist(next)
        current = next
        generation += 1
        emit(.init(phase: .completed, message: "Listener sync batch committed", generationID: staged.batch.generationID))
    }

    public func enqueue(_ change: SyncPendingChange) async throws {
        try SyncOwnershipPolicy().validate(role: .iphone, operation: change.operation, recordType: change.recordID.recordType)
        var pending = current.pendingChanges.filter { $0.recordID != change.recordID }
        pending.append(change)
        var records = Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) })
        var protected = current.protectedRecordIDs
        var conflicts = current.conflictedRecordIDs
        var conflictRecords = current.conflictServerRecords
        if let record = change.record {
            records[record.id] = record
            protected.insert(record.id)
            conflicts.remove(record.id)
            conflictRecords.removeValue(forKey: record.id)
        }
        let next = snapshot(records: records, pendingChanges: pending, protectedRecordIDs: protected,
                            conflictedRecordIDs: conflicts, conflictServerRecords: conflictRecords)
        try persist(next)
        current = next
        emit(.init(phase: .completed, message: "Listener playback change queued"))
    }

    /// Persists a local deletion tombstone until a later remote acknowledgement.
    public func retainTombstone(_ tombstone: SyncTombstone) async throws {
        var tombstones = current.tombstones.filter { $0.itemID != tombstone.itemID }
        tombstones.append(tombstone)
        let next = SyncRepositoryState(records: current.records, engineState: current.engineState, pendingChanges: current.pendingChanges,
                                       tombstones: tombstones, remoteAcknowledgedRecordIDs: current.remoteAcknowledgedRecordIDs,
                                       protectedRecordIDs: current.protectedRecordIDs, conflictedRecordIDs: current.conflictedRecordIDs,
                                       conflictServerRecords: current.conflictServerRecords,
                                       accountOwnerToken: current.accountOwnerToken)
        try persist(next)
        current = next
    }

    /// Records the iCloud account that owns this device's local listener work.
    ///
    /// Persisted at adoption rather than at first successful send, so a failure before
    /// the first acknowledgement cannot leave the listener prompting for review of an
    /// account it has no record of.
    public func adoptAccountOwner(_ token: String) async throws {
        guard current.accountOwnerToken != token else { return }
        let next = current.recordingAccountOwner(token)
        try persist(next)
        current = next
    }

    /// Quarantines unsent work after an account change without deleting local records or cache metadata.
    public func quarantineAfterAccountChange() async throws {
        let pendingIDs = Set(current.pendingChanges.map(\.recordID))
        var conflicts = current.conflictedRecordIDs
        conflicts.formUnion(pendingIDs)
        let next = SyncRepositoryState(records: current.records, engineState: nil, pendingChanges: [],
                                       tombstones: current.tombstones, remoteAcknowledgedRecordIDs: current.remoteAcknowledgedRecordIDs,
                                       protectedRecordIDs: current.protectedRecordIDs.subtracting(pendingIDs), conflictedRecordIDs: conflicts,
                                       conflictServerRecords: current.conflictServerRecords,
                                       accountOwnerToken: current.accountOwnerToken)
        try persist(next)
        current = next
        emit(.init(phase: .failed, message: "Listener work quarantined after account change"))
    }

    public func acknowledge(_ result: SyncSendResult) async throws {
        emit(.init(phase: .committing, message: "Applying listener acknowledgement"))
        let acknowledged = Set(result.acknowledgedRecordIDs)
        let failures = Set(result.failures.map(\.recordID))
        let terminalFailures = Set(result.failures.filter { $0.disposition == .terminal }.map(\.recordID))
        let effectiveEngineState = result.engineState ?? current.engineState
        guard acknowledged.isEmpty && failures.isEmpty || effectiveEngineState != nil else {
            throw WiltedSyncError.missingEngineState
        }
        let pendingIDs = Set(current.pendingChanges.map(\.recordID))
        guard acknowledged.isSubset(of: pendingIDs), failures.isSubset(of: pendingIDs) else {
            throw WiltedSyncError.invalidValue(field: "acknowledgement IDs")
        }
        let envelopesByID = Dictionary(uniqueKeysWithValues: result.serverEnvelopes.map { ($0.id, $0) })
        for id in acknowledged {
            guard let change = current.pendingChanges.first(where: { $0.recordID == id }) else { continue }
            if change.operation != .delete {
                guard let envelope = envelopesByID[id], envelope.sidecar?.encodedSystemFields != nil,
                      envelope.sidecar?.changeTag != nil else {
                    throw WiltedSyncError.invalidValue(field: "acknowledgement server envelope")
                }
            }
        }
        let pending = current.pendingChanges.filter { !acknowledged.contains($0.recordID) && !terminalFailures.contains($0.recordID) }
        var records = Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) })
        for envelope in result.serverEnvelopes { records[envelope.id] = envelope }
        var conflicts = current.conflictedRecordIDs
        var conflictRecords = current.conflictServerRecords
        conflicts.formUnion(terminalFailures)
        for failure in result.failures {
            if failure.disposition == .conflict {
                conflicts.insert(failure.recordID)
                if let server = failure.serverRecord { conflictRecords[failure.recordID] = server }
            }
        }
        var retainedConflictRecords = conflictRecords
        for id in acknowledged { retainedConflictRecords.removeValue(forKey: id) }
        let next = SyncRepositoryState(records: Array(records.values).sorted { $0.id.description < $1.id.description }, engineState: effectiveEngineState,
                                       pendingChanges: pending, tombstones: current.tombstones,
                                       remoteAcknowledgedRecordIDs: current.remoteAcknowledgedRecordIDs.union(acknowledged),
                                       protectedRecordIDs: current.protectedRecordIDs.subtracting(acknowledged), conflictedRecordIDs: conflicts.subtracting(acknowledged),
                                       conflictServerRecords: retainedConflictRecords,
                                       accountOwnerToken: current.accountOwnerToken)
        try persist(next)
        current = next
        emit(.init(phase: result.failures.isEmpty ? .completed : .failed, message: "Listener acknowledgement applied"))
    }

    public func saveMetadata(_ metadata: ListenerMetadata?) throws {
        if let metadata { try atomicWrite(JSONEncoder().encode(metadata), to: metadataURL) }
        else { try? FileManager.default.removeItem(at: metadataURL) }
    }

    public func loadMetadata() -> ListenerMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        do { return try JSONDecoder().decode(ListenerMetadata.self, from: data) }
        catch {
            emit(.init(phase: .failed, message: "Optional listener metadata was ignored"))
            return nil
        }
    }

    /// Records a successful remote fetch and clears the previous fetch failure.
    public func recordSuccessfulFetch(at date: Date = Date()) throws {
        try saveObservability(ListenerSyncObservability(lastSuccessfulFetchAt: date))
    }

    /// Records a bounded, user-safe description of a failed fetch without inventing freshness.
    public func recordFetchFailure(_ message: String) throws {
        let prior = loadObservability()
        try saveObservability(ListenerSyncObservability(
            lastSuccessfulFetchAt: prior?.lastSuccessfulFetchAt,
            lastFetchFailure: message
        ))
    }

    public func saveObservability(_ value: ListenerSyncObservability?) throws {
        if let value { try atomicWrite(JSONEncoder().encode(value), to: observabilityURL) }
        else { try? FileManager.default.removeItem(at: observabilityURL) }
    }

    public func loadObservability() -> ListenerSyncObservability? {
        guard let data = try? Data(contentsOf: observabilityURL) else { return nil }
        return try? JSONDecoder().decode(ListenerSyncObservability.self, from: data)
    }

    private func snapshot(records: [WiltedRecordID: WiltedRecordEnvelope]? = nil,
                          pendingChanges: [SyncPendingChange],
                          protectedRecordIDs: Set<WiltedRecordID>? = nil,
                          conflictedRecordIDs: Set<WiltedRecordID>? = nil,
                          conflictServerRecords: [WiltedRecordID: WiltedRecordEnvelope]? = nil) -> SyncRepositoryState {
        SyncRepositoryState(records: Array((records ?? Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) })).values), engineState: current.engineState, pendingChanges: pendingChanges,
                            tombstones: current.tombstones, remoteAcknowledgedRecordIDs: current.remoteAcknowledgedRecordIDs,
                            protectedRecordIDs: protectedRecordIDs ?? current.protectedRecordIDs, conflictedRecordIDs: conflictedRecordIDs ?? current.conflictedRecordIDs,
                            conflictServerRecords: conflictServerRecords ?? current.conflictServerRecords,
                            accountOwnerToken: current.accountOwnerToken)
    }

    private func familyKey(for record: WiltedRecordEnvelope) -> String {
        if case let .string(itemID)? = record.fields["itemID"] { return itemID }
        let components = record.id.recordName.split(separator: ":")
        return components.count > 1 ? String(components[1]) : record.id.recordName
    }

    private func persist(_ state: SyncRepositoryState) throws { try atomicWrite(JSONEncoder().encode(state), to: stateURL) }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func emit(_ status: SyncStatus) { statusContinuation.yield(status) }
}
