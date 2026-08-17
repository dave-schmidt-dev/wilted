import Foundation
import WiltedDomain

/// The device role used for schema ownership checks.
public enum SyncDeviceRole: String, Codable, Sendable { case mac, iphone }

/// A mutation kind used by the ownership policy.
public enum SyncOperation: String, Codable, Sendable { case create, update, delete }

/// The only record mutations each platform may perform.
public struct SyncOwnershipPolicy: Sendable {
    public init() {}

    public func allows(role: SyncDeviceRole, operation: SyncOperation, recordType: WiltedRecordType) -> Bool {
        switch role {
        case .mac:
            switch operation {
            case .create: return true
            case .update: return recordType == .item || recordType == .playbackState
            case .delete: return true
            }
        case .iphone:
            return (operation == .create || operation == .update) && recordType == .playbackState
        }
    }

    public func validate(role: SyncDeviceRole, operation: SyncOperation, recordType: WiltedRecordType) throws {
        guard allows(role: role, operation: operation, recordType: recordType) else {
            throw WiltedSyncError.ownershipViolation(role: role, operation: operation, recordType: recordType)
        }
    }
}

public enum SyncPhase: String, Codable, Sendable { case idle, fetching, staging, committing, completed, failed }

/// A status event emitted while a transport/repository operation is in flight.
public struct SyncStatus: Codable, Equatable, Sendable {
    public let phase: SyncPhase
    public let message: String
    public let generationID: String?

    public init(phase: SyncPhase, message: String, generationID: String? = nil) {
        self.phase = phase; self.message = message; self.generationID = generationID
    }
}

/// A complete remote generation. Engine bytes are opaque and are never decoded here.
public struct SyncFetchBatch: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case incremental, fullSnapshot }
    public let generationID: String
    public let records: [WiltedRecordEnvelope]
    public let engineState: Data?
    public let kind: Kind
    public let deletedRecordIDs: [WiltedRecordID]

    public init(generationID: String, records: [WiltedRecordEnvelope], engineState: Data? = nil, kind: Kind = .incremental, deletedRecordIDs: [WiltedRecordID] = []) throws {
        guard !generationID.isEmpty else { throw WiltedSyncError.invalidValue(field: "generationID") }
        let deleted = Set(deletedRecordIDs)
        guard deleted.count == deletedRecordIDs.count,
              records.allSatisfy({ !deleted.contains($0.id) }) else {
            throw WiltedSyncError.invalidValue(field: "deletedRecordIDs")
        }
        if let engineState {
            guard !engineState.isEmpty else { throw WiltedSyncError.invalidValue(field: "engineState") }
        } else {
            guard records.isEmpty, deletedRecordIDs.isEmpty, kind == .incremental else {
                throw WiltedSyncError.invalidValue(field: "engineState")
            }
        }
        self.generationID = generationID; self.records = records; self.engineState = engineState; self.kind = kind; self.deletedRecordIDs = deletedRecordIDs
    }

    private enum CodingKeys: String, CodingKey { case generationID, records, engineState, kind, deletedRecordIDs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(generationID: c.decode(String.self, forKey: .generationID),
                      records: c.decode([WiltedRecordEnvelope].self, forKey: .records),
                      engineState: c.decodeIfPresent(Data.self, forKey: .engineState),
                      kind: c.decodeIfPresent(Kind.self, forKey: .kind) ?? .incremental,
                      deletedRecordIDs: c.decodeIfPresent([WiltedRecordID].self, forKey: .deletedRecordIDs) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generationID, forKey: .generationID); try c.encode(records, forKey: .records)
        try c.encodeIfPresent(engineState, forKey: .engineState); try c.encode(kind, forKey: .kind)
        try c.encode(deletedRecordIDs, forKey: .deletedRecordIDs)
    }
}

/// A durable tombstone retained until remote deletion is acknowledged.
public struct SyncTombstone: Codable, Equatable, Sendable {
    public let itemID: ItemID
    public let generationID: String
    public let requestedAt: Timestamp
    public let remoteAcknowledged: Bool

    public init(itemID: ItemID, generationID: String, requestedAt: Timestamp, remoteAcknowledged: Bool = false) {
        self.itemID = itemID; self.generationID = generationID; self.requestedAt = requestedAt; self.remoteAcknowledged = remoteAcknowledged
    }
}

/// A queued mutation, including delete intent when no record payload exists.
public struct SyncPendingChange: Codable, Equatable, Sendable {
    public let operation: SyncOperation
    public let recordID: WiltedRecordID
    public let record: WiltedRecordEnvelope?
    public let tombstone: SyncTombstone?

    public init(operation: SyncOperation, recordID: WiltedRecordID, record: WiltedRecordEnvelope? = nil, tombstone: SyncTombstone? = nil) throws {
        if operation == .delete {
            guard record == nil, let tombstone else { throw WiltedSyncError.invalidValue(field: "delete shape") }
            let parts = recordID.recordName.split(separator: ":")
            guard parts.count >= 2, tombstone.itemID.rawValue == parts[1] else { throw WiltedSyncError.invalidRecordIdentity }
        } else {
            guard tombstone == nil, let record, record.id == recordID else { throw WiltedSyncError.invalidRecordIdentity }
        }
        self.operation = operation; self.recordID = recordID; self.record = record; self.tombstone = tombstone
    }
}

/// The neutral disposition for one failed send; adapters map service errors into these cases.
public enum SyncFailureDisposition: String, Codable, Equatable, Sendable { case conflict, retryable, terminal, cancelled }

/// One failed mutation and an optional server version for conflict reconciliation.
public struct SyncSendFailure: Codable, Equatable, Sendable {
    public let recordID: WiltedRecordID
    public let disposition: SyncFailureDisposition
    public let serverRecord: WiltedRecordEnvelope?

    public init(recordID: WiltedRecordID, disposition: SyncFailureDisposition, serverRecord: WiltedRecordEnvelope? = nil) {
        self.recordID = recordID; self.disposition = disposition; self.serverRecord = serverRecord
    }
}

/// A partial send outcome. Acknowledged IDs and failure dispositions are independent.
public struct SyncSendResult: Codable, Equatable, Sendable {
    public let engineState: Data?
    public let acknowledgedRecordIDs: [WiltedRecordID]
    public let serverEnvelopes: [WiltedRecordEnvelope]
    public let failures: [SyncSendFailure]

    public init(engineState: Data? = nil, acknowledgedRecordIDs: [WiltedRecordID] = [], serverEnvelopes: [WiltedRecordEnvelope] = [], failures: [SyncSendFailure] = []) throws {
        if let engineState {
            guard !engineState.isEmpty else { throw WiltedSyncError.invalidValue(field: "engineState") }
        } else {
            guard acknowledgedRecordIDs.isEmpty, serverEnvelopes.isEmpty, failures.isEmpty else {
                throw WiltedSyncError.invalidValue(field: "engineState")
            }
        }
        let acknowledged = Set(acknowledgedRecordIDs)
        let failureIDs = Set(failures.map(\.recordID))
        let serverIDs = Set(serverEnvelopes.map(\.id))
        guard acknowledged.count == acknowledgedRecordIDs.count,
              failureIDs.count == failures.count,
              serverIDs.count == serverEnvelopes.count,
              acknowledged.isDisjoint(with: failureIDs),
              serverEnvelopes.allSatisfy({ envelope in acknowledged.contains(envelope.id) }) &&
              failures.allSatisfy({ failure in failure.serverRecord == nil || (failure.disposition == .conflict && failure.serverRecord?.id == failure.recordID) }) else {
            throw WiltedSyncError.invalidValue(field: "send result")
        }
        self.engineState = engineState; self.acknowledgedRecordIDs = acknowledgedRecordIDs; self.serverEnvelopes = serverEnvelopes; self.failures = failures
    }

    private enum CodingKeys: String, CodingKey { case engineState, acknowledgedRecordIDs, serverEnvelopes, failures }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(engineState: c.decodeIfPresent(Data.self, forKey: .engineState),
                      acknowledgedRecordIDs: c.decode([WiltedRecordID].self, forKey: .acknowledgedRecordIDs),
                      serverEnvelopes: c.decode([WiltedRecordEnvelope].self, forKey: .serverEnvelopes),
                      failures: c.decode([SyncSendFailure].self, forKey: .failures))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(engineState, forKey: .engineState); try c.encode(acknowledgedRecordIDs, forKey: .acknowledgedRecordIDs); try c.encode(serverEnvelopes, forKey: .serverEnvelopes); try c.encode(failures, forKey: .failures)
    }
}

/// A repository snapshot used to preserve pending local work across syncs/restarts.
public struct SyncRepositoryState: Codable, Equatable, Sendable {
    public let records: [WiltedRecordEnvelope]
    public let engineState: Data?
    public let pendingChanges: [SyncPendingChange]
    public let tombstones: [SyncTombstone]
    public let remoteAcknowledgedRecordIDs: Set<WiltedRecordID>
    public let protectedRecordIDs: Set<WiltedRecordID>
    public let conflictedRecordIDs: Set<WiltedRecordID>
    public let conflictServerRecords: [WiltedRecordID: WiltedRecordEnvelope]

    public init(records: [WiltedRecordEnvelope] = [], engineState: Data? = nil, pendingChanges: [SyncPendingChange] = [], tombstones: [SyncTombstone] = [], remoteAcknowledgedRecordIDs: Set<WiltedRecordID> = [], protectedRecordIDs: Set<WiltedRecordID> = [], conflictedRecordIDs: Set<WiltedRecordID> = [], conflictServerRecords: [WiltedRecordID: WiltedRecordEnvelope] = [:]) {
        self.records = records; self.engineState = engineState; self.pendingChanges = pendingChanges; self.tombstones = tombstones
        self.remoteAcknowledgedRecordIDs = remoteAcknowledgedRecordIDs; self.protectedRecordIDs = protectedRecordIDs; self.conflictedRecordIDs = conflictedRecordIDs; self.conflictServerRecords = conflictServerRecords
    }
}

/// A staged batch; repositories must not expose it as committed state before commit succeeds.
public struct StagedSyncBatch: Sendable {
    public let batch: SyncFetchBatch
    public let priorState: SyncRepositoryState

    public init(batch: SyncFetchBatch, priorState: SyncRepositoryState) {
        self.batch = batch; self.priorState = priorState
    }
}

/// Shared status stream surface for the fake and future platform adapters.
public protocol SyncStatusReporting: Sendable {
    var statuses: AsyncStream<SyncStatus> { get }
}

/// CloudKit-neutral transport contract. Concrete adapters own all CloudKit imports.
public protocol SyncTransport: SyncStatusReporting {
    func fetchChanges() async throws -> SyncFetchBatch
    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult
}

/// CloudKit-neutral local repository contract.
public protocol SyncRepository: SyncStatusReporting {
    func state() async -> SyncRepositoryState
    func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch
    func commit(_ staged: StagedSyncBatch) async throws
    func enqueue(_ change: SyncPendingChange) async throws
    func acknowledge(_ result: SyncSendResult) async throws
}
