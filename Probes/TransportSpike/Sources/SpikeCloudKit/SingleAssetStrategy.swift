import CloudKit
import Foundation
import SpikeCore

/// Names shared by every spike record, zone and subscription. Everything is prefixed `Spike` so
/// the teardown can find it and nothing collides with production record types.
public enum SpikeNames {
    public static let zoneName = "SpikeZone"
    public static let subscriptionPrefix = "SpikeSubscription"
    public static let singleRecordType = "SpikeSingleAsset"
    public static let chunkRecordType = "SpikeChunkAsset"
    public static let handoffRecordType = "SpikeHandoff"
    /// Asset field name on `singleRecordType` and `chunkRecordType`.
    public static let assetField = "payload"
    public static let byteCountField = "byteCount"

    /// `SpikeSingle-<transfer id>`
    public static func singleRecordName(transferID: String) -> String { "SpikeSingle-\(transferID)" }

    /// `SpikeChunked-<transfer id>`: the shared prefix of every chunk of one transfer.
    public static func chunkedTransferID(_ transferID: String) -> String { "SpikeChunked-\(transferID)" }

    /// `<chunked transfer id>-c0007`. Zero-padded so names sort in chunk order.
    public static func chunkRecordName(chunkedTransferID: String, index: Int) -> String {
        let digits = String(index)
        return "\(chunkedTransferID)-c\(String(repeating: "0", count: max(0, 4 - digits.count)))\(digits)"
    }

    /// The single record overwritten by every handoff publish.
    public static let handoffRecordName = "SpikeHandoff-current"
    public static let handoffSubscriptionID = "\(subscriptionPrefix)-handoff-database"
}

/// Where the spike talks to CloudKit. The container is only touched on first use, so building
/// strategies in a process without the iCloud entitlement (unit tests) is safe.
public struct SpikeCloudKitContext: Sendable {
    public static let defaultContainerIdentifier = "iCloud.com.zerodelta.wilted"

    public let containerIdentifier: String

    public init(containerIdentifier: String = SpikeCloudKitContext.defaultContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    public var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SpikeNames.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public var database: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    public func recordID(named name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// Creates `SpikeZone` if needed. Saving an existing zone is a no-op.
    public func ensureZone() async throws {
        let result = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        for (_, saved) in result.saveResults { _ = try saved.get() }
    }
}

/// Collects cumulative bytes from per-record progress fractions.
final class ByteProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private let sizes: [String: Int64]
    private var fractions: [String: Double] = [:]
    private let counter: ProgressCounter
    private let forward: TransferProgress

    init(sizes: [String: Int64], counter: ProgressCounter, forward: @escaping TransferProgress) {
        self.sizes = sizes
        self.counter = counter
        self.forward = forward
    }

    func update(recordName: String, fraction: Double) {
        let total: Int64 = lock.withLock {
            fractions[recordName] = min(1, max(0, fraction))
            return sizes.reduce(into: Int64(0)) { sum, entry in
                sum += Int64(Double(entry.value) * (fractions[entry.key] ?? 0))
            }
        }
        counter.record(bytes: total)
        forward(total)
    }
}

/// Collects the first failure and the fetched records from operation callbacks.
final class OperationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var firstError: Error?
    private var fetched: [CKRecord] = []

    func fail(_ error: Error) { lock.withLock { if firstError == nil { firstError = error } } }
    func add(_ record: CKRecord) { lock.withLock { fetched.append(record) } }
    var error: Error? { lock.withLock { firstError } }
    var records: [CKRecord] { lock.withLock { fetched } }
}

/// Thin async wrappers over `CKModifyRecordsOperation` and `CKFetchRecordsOperation`. The async
/// `database.modifyRecords` conveniences report no per-record progress, hence the operations.
enum CloudKitOperations {
    static func save(
        _ records: [CKRecord],
        in database: CKDatabase,
        progress: ByteProgressAggregator?
    ) async throws {
        let collector = OperationCollector()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.isAtomic = false
            operation.qualityOfService = .userInitiated
            operation.perRecordProgressBlock = { record, fraction in
                progress?.update(recordName: record.recordID.recordName, fraction: fraction)
            }
            operation.perRecordSaveBlock = { _, result in
                if case .failure(let error) = result { collector.fail(error) }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    if let error = collector.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    /// Fetches records by ID, optionally restricted to `desiredKeys` (nil fetches every field,
    /// including asset bytes).
    static func fetch(
        _ recordIDs: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]?,
        in database: CKDatabase,
        progress: ByteProgressAggregator?
    ) async throws -> [CKRecord] {
        let collector = OperationCollector()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            operation.desiredKeys = desiredKeys
            operation.qualityOfService = .userInitiated
            operation.perRecordProgressBlock = { recordID, fraction in
                progress?.update(recordName: recordID.recordName, fraction: fraction)
            }
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record): collector.add(record)
                case .failure(let error): collector.fail(error)
                }
            }
            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success:
                    if let error = collector.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
        return collector.records
    }

    static func fileSize(of url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return size?.int64Value ?? 0
    }
}

/// One `CKAsset` in one record. CloudKit's asset limit is far above the payloads under test, so
/// this measures the simplest possible path.
public struct SingleAssetStrategy: TransferStrategy {
    public let name = "cloudkit-single-asset"
    private let context: SpikeCloudKitContext

    public init(context: SpikeCloudKitContext = SpikeCloudKitContext()) {
        self.context = context
    }

    public func upload(file: URL, progress: @escaping TransferProgress) async -> UploadOutcome {
        let counter = ProgressCounter()
        let byteCount = CloudKitOperations.fileSize(of: file)
        let recordName = SpikeNames.singleRecordName(transferID: UUID().uuidString)
        var handle: TransferHandle?
        let measurement = await measure(strategy: name, direction: .upload, bytes: byteCount, counter: counter) {
            guard byteCount > 0 else { throw SpikeCloudKitError.emptyFile(file.path) }
            try await context.ensureZone()
            let record = CKRecord(recordType: SpikeNames.singleRecordType, recordID: context.recordID(named: recordName))
            record[SpikeNames.assetField] = CKAsset(fileURL: file)
            record[SpikeNames.byteCountField] = byteCount as NSNumber
            let aggregator = ByteProgressAggregator(sizes: [recordName: byteCount], counter: counter, forward: progress)
            try await CloudKitOperations.save([record], in: context.database, progress: aggregator)
            handle = TransferHandle(id: recordName, byteCount: byteCount)
        }
        return UploadOutcome(handle: measurement.succeeded ? handle : nil, measurement: measurement)
    }

    public func download(handle: TransferHandle, progress: @escaping TransferProgress) async -> SpikeCore.Measurement {
        let counter = ProgressCounter()
        var received: Int64 = 0
        let measurement = await measure(strategy: name, direction: .download, bytes: handle.byteCount, counter: counter) {
            let aggregator = ByteProgressAggregator(sizes: [handle.id: handle.byteCount], counter: counter, forward: progress)
            let records = try await CloudKitOperations.fetch(
                [context.recordID(named: handle.id)], desiredKeys: nil, in: context.database, progress: aggregator
            )
            guard let asset = records.first?[SpikeNames.assetField] as? CKAsset, let url = asset.fileURL else {
                throw SpikeCloudKitError.missingAsset(handle.id)
            }
            received = CloudKitOperations.fileSize(of: url)
        }
        return SpikeCore.Measurement(
            strategy: measurement.strategy,
            direction: .download,
            bytes: measurement.succeeded ? received : counter.bytes,
            wallSeconds: measurement.wallSeconds,
            progressCallbackCount: measurement.progressCallbackCount,
            errorText: measurement.errorText ?? (received == handle.byteCount ? nil : "size mismatch: got \(received), expected \(handle.byteCount)")
        )
    }
}

/// Failures the spike strategies report through `Measurement.errorText`.
public enum SpikeCloudKitError: Error, Equatable, Sendable {
    case emptyFile(String)
    case missingAsset(String)
    case skipped(String)
    case timedOut(String)
}
