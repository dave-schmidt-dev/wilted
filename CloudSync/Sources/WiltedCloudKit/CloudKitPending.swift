import CloudKit
import Foundation
import WiltedSync

/// The minimum information required to turn a neutral change into a CloudKit save.
public struct CloudKitPendingRecord: Sendable {
    public let change: SyncPendingChange
    public let record: CKRecord?

    public init(change: SyncPendingChange, record: CKRecord?) {
        self.change = change
        self.record = record
    }
}

/// Converts pending neutral changes into scoped CloudKit engine operations.
public struct CloudKitPendingMapper: Sendable {
    public let mapper: CloudKitRecordMapper

    public init(mapper: CloudKitRecordMapper) { self.mapper = mapper }

    public func filter(_ changes: [SyncPendingChange], scope: CKSyncEngine.SendChangesOptions.Scope,
                       role: SyncDeviceRole) throws -> [SyncPendingChange] {
        let policy = SyncOwnershipPolicy()
        return try changes.filter { change in
            try policy.validate(role: role, operation: change.operation, recordType: change.recordID.recordType)
            let id = CKRecord.ID(recordName: change.recordID.recordName, zoneID: mapper.zoneID)
            return scope.contains(change.operation == .delete ? .deleteRecord(id) : .saveRecord(id))
        }
    }

    public func pendingRecordZoneChanges(_ changes: [SyncPendingChange], scope: CKSyncEngine.SendChangesOptions.Scope,
                                         role: SyncDeviceRole) throws -> [CKSyncEngine.PendingRecordZoneChange] {
        try filter(changes, scope: scope, role: role).map { change in
            let id = CKRecord.ID(recordName: change.recordID.recordName, zoneID: mapper.zoneID)
            return change.operation == .delete ? .deleteRecord(id) : .saveRecord(id)
        }
    }

    public func record(for change: SyncPendingChange, assetURLs: [String: URL] = [:]) throws -> CKRecord? {
        guard let record = change.record else { return nil }
        return try mapper.encode(record, assetURLs: assetURLs)
    }
}

/// Maps CloudKit acknowledgement events without turning transient errors into success.
public struct CloudKitSendMapper: Sendable {
    public let mapper: CloudKitRecordMapper
    public init(mapper: CloudKitRecordMapper) { self.mapper = mapper }

    public func disposition(saved: [CKRecord], failed: [(CKRecord, Error)], deleted: [CKRecord.ID], failedDeletes: [CKRecord.ID: CKError]) throws -> CloudKitSendDisposition {
        var acknowledged: [WiltedRecordID] = []
        for record in saved { acknowledged.append(try neutralID(record.recordID, record.recordType)) }
        for id in deleted { acknowledged.append(try neutralID(id, nil)) }
        var failures: [WiltedRecordID: CloudKitSyncError] = [:]
        for (record, error) in failed { failures[try neutralID(record.recordID, record.recordType)] = CloudKitSyncError.map(error) }
        for (id, error) in failedDeletes { failures[try neutralID(id, nil)] = CloudKitSyncError.map(error) }
        return CloudKitSendDisposition(acknowledged: acknowledged, failures: failures)
    }

    public func result(engineState: Data?, pendingChanges: [SyncPendingChange] = [], saved: [CKRecord], failed: [(CKRecord, Error)], deleted: [CKRecord.ID], failedDeletes: [CKRecord.ID: CKError]) throws -> SyncSendResult {
        var acknowledged: [WiltedRecordID] = []
        var serverEnvelopes: [WiltedRecordEnvelope] = []
        var failures: [SyncSendFailure] = []
        let pendingByID = Dictionary(uniqueKeysWithValues: pendingChanges.compactMap { change in
            change.record.map { (change.recordID, $0) }
        })
        for record in saved {
            let id = try neutralID(record.recordID, record.recordType)
            guard let pending = pendingByID[id] else { throw CloudKitSyncError.invalidRecordIdentity }
            acknowledged.append(id)
            serverEnvelopes.append(try mapper.envelope(pending, updatedFrom: record))
        }
        for id in deleted { acknowledged.append(try neutralID(id, nil)) }
        for (record, error) in failed {
            let id = try neutralID(record.recordID, record.recordType)
            let mapped = CloudKitSyncError.map(error)
            let serverEnvelope = conflictEnvelope(error: error)
            failures.append(SyncSendFailure(recordID: id, disposition: disposition(for: error, mapped: mapped), serverRecord: serverEnvelope))
        }
        for (id, error) in failedDeletes {
            let neutral = try neutralID(id, nil)
            failures.append(SyncSendFailure(recordID: neutral, disposition: disposition(for: error, mapped: CloudKitSyncError.map(error))))
        }
        return try SyncSendResult(engineState: engineState, acknowledgedRecordIDs: acknowledged, serverEnvelopes: serverEnvelopes, failures: failures)
    }

    private func conflictEnvelope(error: Error) -> WiltedRecordEnvelope? {
        guard let error = error as? CKError, error.code == .serverRecordChanged, let record = error.serverRecord else { return nil }
        do {
            return try mapper.decode(record).envelope
        } catch CloudKitSyncError.assetUnavailable, CloudKitSyncError.assetCopyFailed, CloudKitSyncError.missingField, CloudKitSyncError.invalidField {
            return nil
        } catch {
            return nil
        }
    }

    private func disposition(for source: Error, mapped error: CloudKitSyncError) -> SyncFailureDisposition {
        guard let cloudKitError = source as? CKError else {
            return error == .cancelled ? .cancelled : .terminal
        }
        switch cloudKitError.code {
        case .serverRecordChanged: return .conflict
        case .requestRateLimited, .serviceUnavailable, .networkFailure, .networkUnavailable, .zoneBusy:
            return .retryable
        case .operationCancelled: return .cancelled
        default: return .terminal
        }
    }

    private func neutralID(_ id: CKRecord.ID, _ recordType: String?) throws -> WiltedRecordID {
        guard id.zoneID.zoneName == mapper.zoneID.zoneName,
              id.zoneID.ownerName == mapper.zoneID.ownerName else { throw CloudKitSyncError.invalidZone(id.zoneID.zoneName) }
        let type: WiltedRecordType
        if let recordType, let parsed = WiltedRecordType(rawValue: recordType) { type = parsed }
        else if id.recordName.hasPrefix("item:") { type = .item }
        else if id.recordName.hasPrefix("revision:") { type = .revision }
        else if id.recordName.hasPrefix("playback:") { type = .playbackState }
        else { throw CloudKitSyncError.invalidRecordIdentity }
        do { return try WiltedRecordID(recordType: type, recordName: id.recordName, zoneName: mapper.zoneID.zoneName) }
        catch { throw CloudKitSyncError.invalidRecordIdentity }
    }
}
