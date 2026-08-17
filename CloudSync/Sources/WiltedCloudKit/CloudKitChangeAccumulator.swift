import CloudKit
import Foundation
import WiltedSync

/// Collects fetched modifications/deletions and publishes only complete generations.
public actor CloudKitChangeAccumulator {
    private let mapper: CloudKitRecordMapper
    private var records: [WiltedRecordEnvelope] = []
    private var deletedRecordIDs: [WiltedRecordID] = []
    private var state: Data?
    private var generation = 0
    private var stagedAssetURLs: [URL] = []
    private var ownedAssetURLs: [URL] = []
    private var decodedRecords: [CloudKitDecodedRecord] = []
    private var handoff: [WiltedRecordID: [String: URL]] = [:]
    private var remoteChangeSequence = 0
    private var stateSequence = 0

    public init(mapper: CloudKitRecordMapper) { self.mapper = mapper }

    public func begin() {
        cleanupStagedAssets()
        records = []; deletedRecordIDs = []; generation += 1; decodedRecords = []; handoff = [:]
        remoteChangeSequence = 0; stateSequence = 0
    }

    public func append(modified record: CKRecord) throws {
        let decoded = try mapper.decode(record)
        guard !deletedRecordIDs.contains(decoded.envelope.id) else { throw CloudKitSyncError.invalidRecordIdentity }
        if let previous = decodedRecords.first(where: { $0.envelope.id == decoded.envelope.id }) {
            for url in previous.stagedAssets.values {
                mapper.removeStagedAsset(at: url)
                stagedAssetURLs.removeAll { $0 == url }
            }
        }
        records.removeAll { $0.id == decoded.envelope.id }
        records.append(decoded.envelope)
        remoteChangeSequence += 1
        stagedAssetURLs.append(contentsOf: decoded.stagedAssets.values)
        decodedRecords.removeAll { $0.envelope.id == decoded.envelope.id }
        decodedRecords.append(decoded)
    }

    public func append(deleted id: CKRecord.ID, recordType: String) throws {
        guard id.zoneID.zoneName == mapper.zoneID.zoneName,
              id.zoneID.ownerName == mapper.zoneID.ownerName,
              let type = WiltedRecordType(rawValue: recordType) else { throw CloudKitSyncError.invalidRecordIdentity }
        let neutral: WiltedRecordID
        do { neutral = try WiltedRecordID(recordType: type, recordName: id.recordName, zoneName: mapper.zoneID.zoneName) }
        catch { throw CloudKitSyncError.invalidRecordIdentity }
        guard !records.contains(where: { $0.id == neutral }) else { throw CloudKitSyncError.invalidRecordIdentity }
        if !deletedRecordIDs.contains(neutral) { deletedRecordIDs.append(neutral) }
        remoteChangeSequence += 1
    }

    public func updateState(_ serialization: CKSyncEngine.State.Serialization) throws {
        state = try JSONEncoder().encode(serialization)
        stateSequence = remoteChangeSequence
    }

    public func updateState(_ data: Data) { state = data; stateSequence = remoteChangeSequence }
    public func seedState(_ data: Data?) { state = data }

    public func finish(requireFreshState: Bool = false) throws -> SyncFetchBatch {
        if let state {
            guard !state.isEmpty else { throw WiltedSyncError.missingEngineState }
        } else if remoteChangeSequence > 0 {
            throw WiltedSyncError.missingEngineState
        }
        guard !requireFreshState || stateSequence >= remoteChangeSequence else { throw WiltedSyncError.missingEngineState }
        var publishedRecords: [WiltedRecordEnvelope] = []
        for decoded in decodedRecords {
            let published = try mapper.publish(decoded)
            publishedRecords.append(published.envelope)
            if !published.stagedAssets.isEmpty { handoff[published.envelope.id] = published.stagedAssets }
            ownedAssetURLs.append(contentsOf: published.ownedAssets)
        }
        let result = try SyncFetchBatch(generationID: "cloudkit-\(generation)", records: publishedRecords.isEmpty ? records : publishedRecords, engineState: state,
                                        kind: .incremental, deletedRecordIDs: deletedRecordIDs)
        stagedAssetURLs.removeAll()
        ownedAssetURLs.removeAll()
        decodedRecords.removeAll()
        return result
    }

    public func cleanupStagedAssets() {
        for url in stagedAssetURLs { mapper.removeStagedAsset(at: url) }
        for url in ownedAssetURLs { mapper.removeStagedAsset(at: url) }
        stagedAssetURLs.removeAll()
        ownedAssetURLs.removeAll()
        decodedRecords.removeAll()
    }

    public func assetHandoff() -> [WiltedRecordID: [String: URL]] { handoff }
    public func hasRemoteChanges() -> Bool { remoteChangeSequence > 0 }
}
