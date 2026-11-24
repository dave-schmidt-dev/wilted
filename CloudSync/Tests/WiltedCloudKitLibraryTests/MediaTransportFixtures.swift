import CloudKit
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

// MARK: - Fakes (no CloudKit)

/// The "server" two fake drivers share: named records, asset bytes and an ordered operation log.
actor FakeMediaServer {
    private(set) var records: [String: CKRecord] = [:]
    private(set) var log: [String] = []
    private var assetBytes: [String: Data] = [:]
    private var tick: TimeInterval = 1_700_000_000
    var stallTransfers = false
    var fractions: [Double] = [0.25, 0.5, 1]
    private(set) var uploadedAssetURLs: [URL] = []

    func setStall(_ value: Bool) { stallTransfers = value }
    func setFractions(_ value: [Double]) { fractions = value }
    func note(_ line: String) { log.append(line) }

    func putEngine(_ record: CKRecord) -> CKRecord {
        tick += 1
        let saved = stamped(record, tick)
        records[record.recordID.recordName] = saved
        log.append("engine save \(record.recordID.recordName)")
        return saved
    }

    func putRaw(_ record: CKRecord) {
        let name = record.recordID.recordName
        if let asset = record[LibraryMediaRecord.assetField] as? CKAsset, let url = asset.fileURL {
            assetBytes[name] = try? Data(contentsOf: url)
            uploadedAssetURLs.append(url)
        }
        records[name] = record
        log.append("raw save \(name)")
    }

    func remove(_ id: CKRecord.ID, via: String) {
        records[id.recordName] = nil
        assetBytes[id.recordName] = nil
        log.append("\(via) delete \(id.recordName)")
    }

    func present(_ ids: [CKRecord.ID]) -> [CKRecord] { ids.compactMap { records[$0.recordName] } }
    func allRecords() -> [CKRecord] { Array(records.values) }
    func bytes(_ name: String) -> Data? { assetBytes[name] }
    func mutate(_ name: String, _ change: (CKRecord) -> Void) { if let record = records[name] { change(record) } }
}

actor FakeMediaDriver: CloudKitEngineDriver {
    nonisolated let stream: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private let server: FakeMediaServer
    private let outbox: CloudKitLibraryOutbox
    private var pending: [CKSyncEngine.PendingRecordZoneChange] = []
    private(set) var scopes: [Set<CKRecordZone.ID>] = []
    private(set) var unscopedFetches = 0
    private(set) var targetedFetches = 0
    /// The names each targeted fetch asked for, in order, and how many sends the engine made.
    private(set) var askedNames: [[String]] = []
    private(set) var sendCount = 0
    var failSends = false

    func setFailSends(_ value: Bool) { failSends = value }

    private var beforeNextAssetFetch: (@Sendable () async -> Void)?
    func onNextAssetFetch(_ action: @escaping @Sendable () async -> Void) { beforeNextAssetFetch = action }


    init(server: FakeMediaServer, outbox: CloudKitLibraryOutbox) {
        (stream, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        self.server = server
        self.outbox = outbox
    }

    var events: AsyncStream<CloudKitEngineEvent> { get async { stream } }
    func fetchChanges() async throws { unscopedFetches += 1; continuation.yield(.fetchCompleted) }
    func fetchChanges(zoneIDs: Set<CKRecordZone.ID>) async throws {
        scopes.append(zoneIDs)
        let matching = await server.allRecords().filter { zoneIDs.contains($0.recordID.zoneID) }
        if !matching.isEmpty {
            continuation.yield(.fetched(modifications: matching, deletions: []))
        }
        continuation.yield(.fetchCompleted)
    }
    func cancelOperations() async {}
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async { pending += changes }
    nonisolated func isValidStateData(_ data: Data) -> Bool { true }

    func sendChanges() async throws {
        sendCount += 1
        if failSends {
            throw CKError(.networkFailure)
        }
        var saved: [CKRecord] = [], deleted: [CKRecord.ID] = []
        for change in pending {
            switch change {
            case let .saveRecord(id): if let record = outbox.record(for: id) { saved.append(await server.putEngine(record)) }
            case let .deleteRecord(id): await server.remove(id, via: "engine"); deleted.append(id)
            @unknown default: break
            }
        }
        pending = []
        continuation.yield(.sent(saved: saved, failed: [], deleted: deleted, failedDeletes: [:]))
        continuation.yield(.sendCompleted)
    }

    func fetchRecordsIfPresent(_ ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        targetedFetches += 1
        askedNames.append(ids.map(\.recordName))
        return await server.present(ids)
    }

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws { await server.note("ensureZone \(zoneID.zoneName)") }

    func saveRecordRaw(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws {
        await server.putRaw(record)
        progress(1)
    }

    func fetchAssetRecordRaw(_ id: CKRecord.ID, assetField: String, to destination: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord {
        let beforeFetch = beforeNextAssetFetch
        beforeNextAssetFetch = nil
        await beforeFetch?()
        if await server.stallTransfers { try await Task.sleep(nanoseconds: 60_000_000_000) }
        guard let record = await server.present([id]).first, let data = await server.bytes(id.recordName) else {
            throw CloudKitSyncError.assetUnavailable(id.recordName)
        }
        for fraction in await server.fractions { progress(fraction) }
        try data.write(to: destination)
        return record
    }

    func deleteRecordsRaw(_ ids: [CKRecord.ID]) async throws { for id in ids { await server.remove(id, via: "raw") } }
}

final class MediaFixture {
    let mapper = LibraryRecordMapper()
    let server = FakeMediaServer()
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("media-record-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    struct Endpoint {
        let transport: CloudKitLibraryTransport
        let driver: FakeMediaDriver
        let log: FactoryLog
    }

    func endpoint(_ deviceID: String, writer: Bool, watchdog: TimeInterval = 300) throws -> Endpoint {
        let outbox = CloudKitLibraryOutbox()
        let driver = FakeMediaDriver(server: server, outbox: outbox)
        let log = FactoryLog()
        let server = self.server
        let transport = try CloudKitLibraryTransport(
            deviceID: deviceID, isLibraryWriter: writer, driver: driver,
            driverFactory: { state in _ = log.record(state); return FakeMediaDriver(server: server, outbox: outbox) },
            outbox: outbox, mediaWatchdogInterval: watchdog)
        return Endpoint(transport: transport, driver: driver, log: log)
    }

    func audioFile(_ byteCount: Int = 100) throws -> URL {
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try Data((0..<byteCount).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    func offer(_ entry: String = "ep-1", bytes: Int64 = 100, revision: String = "rev-1") throws -> LibraryMediaOffer {
        try LibraryMediaOffer(entryID: item(entry), revisionID: RevisionID(rawValue: revision),
                              contentHash: "sha256:" + String(repeating: "a", count: 64), byteCount: bytes,
                              mediaType: "audio/mpeg", durationSeconds: 61,
                              preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 946684800))))
    }
}
