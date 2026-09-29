import CloudKit
import Foundation

/// What each fetch path did with the asset field of one record.
public struct EagerFetchResult: Codable, Sendable, Equatable {
    /// `CKSyncEngine` delivered the record.
    public var syncEngineDeliveredRecord = false
    /// The asset file existed on disk at the moment the sync engine's fetch event was handled.
    public var syncEngineAssetFileExistsAtFetch: Bool?
    public var syncEngineAssetBytesAtFetch: Int64?
    public var syncEngineSeconds: Double?
    /// A raw `CKFetchRecordsOperation` with every field: the asset baseline.
    public var rawFullAssetFileExists: Bool?
    public var rawFullSeconds: Double?
    /// A raw fetch whose `desiredKeys` exclude the asset field.
    public var rawDesiredKeysAssetFieldPresent: Bool?
    public var rawDesiredKeysByteCountField: Int64?
    public var rawDesiredKeysSeconds: Double?
    public var errorText: String?

    public init() {}
}

/// Answers: does a `CKSyncEngine` fetch pull asset bytes eagerly, and does a raw fetch with
/// `desiredKeys` avoid them? Point it at a record written by `SingleAssetStrategy`.
public struct EagerFetchProbe: Sendable {
    private let context: SpikeCloudKitContext

    public init(context: SpikeCloudKitContext = SpikeCloudKitContext()) {
        self.context = context
    }

    public func run(recordName: String) async -> EagerFetchResult {
        var result = EagerFetchResult()
        do {
            try await runRaw(recordName: recordName, into: &result)
            try await runSyncEngine(recordName: recordName, into: &result)
        } catch {
            result.errorText = String(describing: error)
        }
        return result
    }

    private func runRaw(recordName: String, into result: inout EagerFetchResult) async throws {
        let id = context.recordID(named: recordName)
        let clock = ContinuousClock()

        var start = clock.now
        let full = try await CloudKitOperations.fetch([id], desiredKeys: nil, in: context.database, progress: nil)
        result.rawFullSeconds = Self.seconds(start.duration(to: clock.now))
        if let url = (full.first?[SpikeNames.assetField] as? CKAsset)?.fileURL {
            result.rawFullAssetFileExists = FileManager.default.fileExists(atPath: url.path)
        } else {
            result.rawFullAssetFileExists = false
        }

        start = clock.now
        let partial = try await CloudKitOperations.fetch(
            [id], desiredKeys: [SpikeNames.byteCountField], in: context.database, progress: nil
        )
        result.rawDesiredKeysSeconds = Self.seconds(start.duration(to: clock.now))
        result.rawDesiredKeysAssetFieldPresent = partial.first?[SpikeNames.assetField] != nil
        result.rawDesiredKeysByteCountField = (partial.first?[SpikeNames.byteCountField] as? NSNumber)?.int64Value
    }

    private func runSyncEngine(recordName: String, into result: inout EagerFetchResult) async throws {
        let observer = SyncEngineObserver(targetRecordName: recordName)
        // Nil state serialization: a fresh engine that fetches everything in the database.
        var configuration = CKSyncEngine.Configuration(
            database: context.database, stateSerialization: nil, delegate: observer
        )
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.fetchChanges()
        result.syncEngineSeconds = Self.seconds(start.duration(to: clock.now))
        let seen = observer.snapshot()
        result.syncEngineDeliveredRecord = seen.delivered
        result.syncEngineAssetFileExistsAtFetch = seen.assetFileExists
        result.syncEngineAssetBytesAtFetch = seen.assetBytes
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Delegate that inspects the target record's asset inside the fetch event, before the engine
/// can clean up or defer anything. It never sends changes.
final class SyncEngineObserver: CKSyncEngineDelegate, @unchecked Sendable {
    struct Snapshot {
        var delivered = false
        var assetFileExists: Bool?
        var assetBytes: Int64?
    }

    private let targetRecordName: String
    private let lock = NSLock()
    private var seen = Snapshot()

    init(targetRecordName: String) {
        self.targetRecordName = targetRecordName
    }

    func snapshot() -> Snapshot { lock.withLock { seen } }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard case .fetchedRecordZoneChanges(let changes) = event else { return }
        for modification in changes.modifications where modification.record.recordID.recordName == targetRecordName {
            var update = Snapshot(delivered: true)
            if let url = (modification.record[SpikeNames.assetField] as? CKAsset)?.fileURL {
                update.assetFileExists = FileManager.default.fileExists(atPath: url.path)
                update.assetBytes = CloudKitOperations.fileSize(of: url)
            } else {
                update.assetFileExists = false
            }
            lock.withLock { seen = update }
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}
