import CloudKit
import Foundation
import OSLog
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary

/// An engine driver wrapper that counts every CloudKit operation before delegating.
final class CountingEngineDriver: CloudKitEngineDriver, @unchecked Sendable {
    let inner: any CloudKitEngineDriver
    let counters: CloudKitOperationCounters
    private let outbox: CloudKitLibraryOutbox?
    private let mapper: LibraryRecordMapper?
    private let lock = NSLock()
    private var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

    init(inner: any CloudKitEngineDriver, counters: CloudKitOperationCounters,
         outbox: CloudKitLibraryOutbox? = nil, mapper: LibraryRecordMapper? = nil) {
        self.inner = inner
        self.counters = counters
        self.outbox = outbox
        self.mapper = mapper
    }

    var events: AsyncStream<CloudKitEngineEvent> {
        get async { await inner.events }
    }

    func currentAccountIdentity() async throws -> CloudKitAccountIdentity? {
        try await inner.currentAccountIdentity()
    }

    func ensureZone() async throws {
        try await inner.ensureZone()
    }

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        try await inner.ensureZone(zoneID)
    }

    func cancelOperations() async {
        lock.withLock { pendingChanges = [] }
        await inner.cancelOperations()
    }

    func resetZoneBootstrap() async {
        await inner.resetZoneBootstrap()
    }

    nonisolated func isValidStateData(_ data: Data) -> Bool {
        inner.isValidStateData(data)
    }

    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {
        lock.withLock { pendingChanges.append(contentsOf: changes) }
        await inner.addPendingRecordZoneChanges(changes)
    }

    func sendChanges() async throws {
        let (pending, caller) = lock.withLock { () -> ([CKSyncEngine.PendingRecordZoneChange], CloudKitOperationCaller) in
            let p = self.pendingChanges
            self.pendingChanges = []
            let c = CloudKitOperationContext.caller ?? resolveCaller(forPending: p)
            return (p, c)
        }
        var bytes: Int64 = 0
        if let outbox {
            for change in pending {
                if case let .saveRecord(id) = change, let record = outbox.record(for: id) {
                    bytes += recordBytes(record)
                }
            }
        }
        do {
            try await inner.sendChanges()
            counters.record(caller: caller, recordCount: pending.count, bytes: bytes, result: .ok)
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: pending.count, bytes: bytes, result: result)
            throw error
        }
    }

    func fetchRecordsIfPresent(_ ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        let caller = CloudKitOperationContext.caller ?? resolveCaller(for: ids)
        do {
            let records = try await inner.fetchRecordsIfPresent(ids, desiredKeys: desiredKeys)
            let bytes = records.reduce(0) { $0 + recordBytes($1) }
            counters.record(caller: caller, recordCount: records.count, bytes: bytes, result: .ok)
            return records
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: 0, bytes: 0, result: result)
            throw error
        }
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        let caller = CloudKitOperationContext.caller ?? resolveCaller(for: ids)
        do {
            let records = try await inner.fetchRecords(ids)
            let bytes = records.reduce(0) { $0 + recordBytes($1) }
            counters.record(caller: caller, recordCount: records.count, bytes: bytes, result: .ok)
            return records
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: 0, bytes: 0, result: result)
            throw error
        }
    }

    func saveRecordRaw(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws {
        let caller = CloudKitOperationContext.caller ?? resolveCaller(for: [record.recordID])
        let bytes = recordBytes(record)
        do {
            try await inner.saveRecordRaw(record, progress: progress)
            counters.record(caller: caller, recordCount: 1, bytes: bytes, result: .ok)
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: 1, bytes: bytes, result: result)
            throw error
        }
    }

    func fetchAssetRecordRaw(_ id: CKRecord.ID, assetField: String, to destination: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord {
        let caller = CloudKitOperationContext.caller ?? resolveCaller(for: [id])
        do {
            let record = try await inner.fetchAssetRecordRaw(id, assetField: assetField, to: destination, progress: progress)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            let bytes = max(fileSize, recordBytes(record))
            counters.record(caller: caller, recordCount: 1, bytes: bytes, result: .ok)
            return record
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: 1, bytes: 0, result: result)
            throw error
        }
    }

    func deleteRecordsRaw(_ ids: [CKRecord.ID]) async throws {
        let caller = CloudKitOperationContext.caller ?? resolveCaller(for: ids)
        do {
            try await inner.deleteRecordsRaw(ids)
            counters.record(caller: caller, recordCount: ids.count, bytes: 0, result: .ok)
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: ids.count, bytes: 0, result: result)
            throw error
        }
    }

    func fetchChanges(zoneIDs: Set<CKRecordZone.ID>) async throws {
        let caller = CloudKitOperationContext.caller ?? .poll
        do {
            try await inner.fetchChanges(zoneIDs: zoneIDs)
            counters.record(caller: caller, recordCount: 0, bytes: 0, result: .ok)
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: 0, bytes: 0, result: result)
            throw error
        }
    }

    func fetchChanges() async throws {
        let caller = CloudKitOperationContext.caller ?? .poll
        do {
            try await inner.fetchChanges()
            counters.record(caller: caller, recordCount: 0, bytes: 0, result: .ok)
        } catch {
            let result = CloudKitOperationCounters.classifyResult(error: error)
            counters.record(caller: caller, recordCount: 0, bytes: 0, result: result)
            throw error
        }
    }

    private func resolveCaller(forPending changes: [CKSyncEngine.PendingRecordZoneChange]) -> CloudKitOperationCaller {
        var ids: [CKRecord.ID] = []
        for change in changes {
            switch change {
            case let .saveRecord(id): ids.append(id)
            case let .deleteRecord(id): ids.append(id)
            @unknown default: break
            }
        }
        return resolveCaller(for: ids)
    }

    private func resolveCaller(for ids: [CKRecord.ID]) -> CloudKitOperationCaller {
        if let caller = CloudKitOperationContext.caller {
            return caller
        }
        for id in ids {
            if let mapper, id.zoneID == mapper.mediaZoneID || id.zoneID.zoneName.contains("Media") || id.zoneID.zoneName.contains("media") {
                if id.recordName.hasPrefix("transcript:") {
                    return .transcripts
                } else {
                    return .media
                }
            }
            let name = id.recordName.lowercased()
            if name.hasPrefix("nowplaying:") || name.hasPrefix("progress:") {
                return .handoff
            }
            if name.hasPrefix("offer:") || name.hasPrefix("offerindex:") {
                return .offers
            }
            if name.hasPrefix("transcript:") {
                return .transcripts
            }
            if name.hasPrefix("stats:") {
                return .stats
            }
            if name.hasPrefix("bulletins:") {
                return .bulletins
            }
            if name.hasPrefix("devicedirectory:") || name.hasPrefix("devicelink:") {
                return .deviceLink
            }
            if name.hasPrefix("publication:") {
                return .publication
            }
        }
        return .poll
    }

    private func recordBytes(_ record: CKRecord) -> Int64 {
        var bytes: Int64 = 0
        if let data = record[LibraryRecordMapper.payloadField] as? Data {
            bytes += Int64(data.count)
        }
        var assetBytes: Int64 = 0
        for key in record.allKeys() {
            if let asset = record[key] as? CKAsset, let url = asset.fileURL {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                assetBytes += size
            }
        }
        if assetBytes > 0 {
            bytes += assetBytes
        } else if let count = record["byteCount"] as? NSNumber {
            bytes += count.int64Value
        }
        return bytes
    }
}
