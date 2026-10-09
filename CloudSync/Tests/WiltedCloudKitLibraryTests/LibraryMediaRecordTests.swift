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

    init(server: FakeMediaServer, outbox: CloudKitLibraryOutbox) {
        (stream, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        self.server = server
        self.outbox = outbox
    }

    var events: AsyncStream<CloudKitEngineEvent> { get async { stream } }
    func fetchChanges() async throws { unscopedFetches += 1; continuation.yield(.fetchCompleted) }
    func fetchChanges(zoneIDs: Set<CKRecordZone.ID>) async throws { scopes.append(zoneIDs); continuation.yield(.fetchCompleted) }
    func cancelOperations() async {}
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async { pending += changes }
    nonisolated func isValidStateData(_ data: Data) -> Bool { true }

    func sendChanges() async throws {
        sendCount += 1
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

// MARK: - Tests

final class LibraryMediaRecordTests: XCTestCase {
    private let mapper = LibraryRecordMapper()

    private func certifiedWireOffer() throws -> LibraryMediaOffer {
        let legacy = try MediaFixture().offer()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object["preparation"] = ["schemaVersion": 1, "preparedAt": "2000-01-01T00:00:00Z"]
        return try JSONDecoder().decode(LibraryMediaOffer.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func assertWirePreparation(_ offer: LibraryMediaOffer, file: StaticString = #filePath,
                                       line: UInt = #line) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any],
                                   file: file, line: line)
        let proof = try XCTUnwrap(object["preparation"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(proof["schemaVersion"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(proof["preparedAt"] as? String, "2000-01-01T00:00:00Z", file: file, line: line)
    }

    func testCertifiedOfferPayloadRetainsPreparationThroughLibraryMapper() throws {
        let record = try mapper.record(offer: certifiedWireOffer())
        guard case let .offer(decoded) = try mapper.decode(record) else { return XCTFail("expected offer") }
        try assertWirePreparation(decoded)
        XCTAssertTrue(decoded.isPrepared)
    }

    func testCertifiedAudioAssetRecordRetainsExactPreparationAuthority() throws {
        let fixture = try MediaFixture()
        let input = try certifiedWireOffer()
        let record = try LibraryMediaRecord.record(offer: input, assetURL: fixture.audioFile(), zoneID: mapper.mediaZoneID)
        let decoded = try LibraryMediaRecord.offer(from: record)
        XCTAssertEqual(decoded.entryID, input.entryID)
        XCTAssertEqual(decoded.revisionID, input.revisionID)
        XCTAssertEqual(decoded.contentHash, input.contentHash)
        XCTAssertEqual(decoded.byteCount, input.byteCount)
        XCTAssertEqual(decoded.mediaType, input.mediaType)
        try assertWirePreparation(decoded)
    }

    func testOfferRecordLivesInTheLibraryZoneAndRoundTripsIncludingNotReady() throws {
        let ready = try MediaFixture().offer()
        let available = try LibraryMediaOffer(
            entryID: item("ep-3"), revisionID: RevisionID(rawValue: "rev-1"), contentHash: "", byteCount: 100,
            mediaType: "audio/mpeg", durationSeconds: 61, state: .available)
        for offer in [ready, available, .notReady(entryID: try item("ep-2"))] {
            let record = try mapper.record(offer: offer)
            XCTAssertEqual(record.recordType, LibraryRecordType.offer.rawValue)
            XCTAssertEqual(record.recordID.recordName, "offer:" + offer.entryID.rawValue)
            XCTAssertEqual(record.recordID.zoneID, mapper.zoneID)
            XCTAssertEqual(record.allKeys(), [LibraryRecordMapper.payloadField], "no asset field in the library zone")
            XCTAssertEqual(try mapper.decode(record), .offer(offer))
        }
        let forged = try mapper.record(offer: ready)
        XCTAssertThrowsError(try mapper.decode(CKRecord(recordType: forged.recordType, recordID: CKRecord.ID(recordName: "offer:other", zoneID: mapper.zoneID)).with(payload: forged)))
        let index = LibraryOfferIndex(entryIDs: [try item("ep-1")])
        XCTAssertEqual(try mapper.decode(mapper.record(offerIndex: index)), .offerIndex(index))
        let intents = LibraryIntentIndex(deviceID: "phone", intentIDs: ["a", "b"])
        XCTAssertEqual(try mapper.decode(mapper.record(intentIndex: intents)), .intentIndex(intents))
    }

    func testAnOfferWithAnUnknownStateDecodesAsNotReadyThroughTheMapper() throws {
        let known = try mapper.record(offer: .notReady(entryID: try item("ep-9")))
        let json = #"{"entryID":"ep-9","revisionID":"rev-1","contentHash":"","byteCount":5,"mediaType":"audio/mpeg","state":"streaming"}"#
        known[LibraryRecordMapper.payloadField] = Data(json.utf8) as CKRecordValue
        guard case let .offer(decoded) = try mapper.decode(known) else { return XCTFail("expected an offer") }
        XCTAssertEqual(decoded.state, .notReady)
    }

    func testAudioRecordIsOneAssetInTheMediaZoneAndRejectsOversizedOffers() throws {
        let fixture = try MediaFixture()
        let offer = try fixture.offer()
        let record = try LibraryMediaRecord.record(offer: offer, assetURL: try fixture.audioFile(), zoneID: mapper.mediaZoneID)
        XCTAssertEqual(record.recordType, "WiltedAudio")
        XCTAssertEqual(record.recordID.recordName, "audio:ep-1")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "WiltedMediaZone")
        XCTAssertNotEqual(record.recordID.zoneID, mapper.zoneID)
        XCTAssertTrue(record[LibraryMediaRecord.assetField] is CKAsset)
        XCTAssertEqual(try LibraryMediaRecord.offer(from: record), offer)
        let oversized = try fixture.offer(bytes: LibraryMediaRecord.maximumByteCount + 1)
        XCTAssertThrowsError(try LibraryMediaRecord.record(offer: oversized, assetURL: try fixture.audioFile(), zoneID: mapper.mediaZoneID))
    }

    func testFetchScopeExcludesTheMediaZoneAndEveryEngineFetchIsScoped() async throws {
        let options = CloudKitFetchScope.options(zoneIDs: [mapper.zoneID])
        XCTAssertTrue(options.scope.contains(mapper.zoneID))
        XCTAssertFalse(options.scope.contains(mapper.mediaZoneID))
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        _ = try await phone.transport.fetchChanges(since: nil)
        try await phone.transport.discoverPeers()
        let mainScopes = await phone.driver.scopes
        let unscoped = await phone.driver.unscopedFetches
        XCTAssertEqual(mainScopes, [[mapper.zoneID]])
        XCTAssertEqual(unscoped, 0)
        XCTAssertEqual(phone.log.states.count, 1, "the discovery scan builds one stateless engine")
    }

    func testPublishUploadsTheAssetBeforeItsOfferAndAPhoneDownloadsWithByteProgress() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let file = try fixture.audioFile()
        let offer = try fixture.offer()
        try await mac.transport.publishMedia(offer: offer, fileURL: file)

        let log = await fixture.server.log
        XCTAssertEqual(log, ["ensureZone WiltedMediaZone", "raw save audio:ep-1", "engine save offer:ep-1", "engine save offerindex:library"])
        let uploaded = await fixture.server.uploadedAssetURLs
        XCTAssertNotEqual(uploaded.first, file, "the transport uploads its own copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploaded.first?.path ?? ""), "the copy is removed afterwards")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let offers = try await phone.transport.mediaOffers()
        XCTAssertEqual(offers, [offer])
        let received = ProgressLog()
        let delivered = try await phone.transport.fetchMedia(offer) { received.add($0) }
        defer { try? FileManager.default.removeItem(at: delivered) }
        XCTAssertEqual(received.values, [25, 50, 100], "fractions of the record become cumulative bytes")
        XCTAssertEqual(try Data(contentsOf: delivered), try Data(contentsOf: file), "the file is in place when fetchMedia returns")
    }

    func testAnAvailableOfferHasNoAssetAndReplacesAReadyOneWithoutItsAudio() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let ready = try fixture.offer()
        try await mac.transport.publishMedia(offer: ready, fileURL: try fixture.audioFile())
        let available = try LibraryMediaOffer(
            entryID: item("ep-1"), revisionID: RevisionID(rawValue: "rev-1"), contentHash: ready.contentHash, byteCount: 100,
            mediaType: "audio/mpeg", durationSeconds: 61, state: .available, preparation: ready.preparation)
        try await mac.transport.publishMedia(offer: available, fileURL: URL(fileURLWithPath: "/dev/null"))
        let audio = await fixture.server.records["audio:ep-1"]
        XCTAssertNil(audio, "going back to available drops the uploaded audio")
        let offers = try await phone.transport.mediaOffers()
        XCTAssertEqual(offers, [available])
        await XCTAssertThrowsErrorAsync(try await phone.transport.fetchMedia(available) { _ in }) {
            XCTAssertEqual($0 as? LibraryTransportError, .transport("no ready audio is offered for ep-1"))
        }
    }

    func testFetchedAssetRejectsChangedEntryTypeAndPreparationForTheSameRevision() async throws {
        for field in ["entryID", "mediaType", LibraryMediaRecord.preparationField] {
            let fixture = try MediaFixture()
            let mac = try fixture.endpoint("mac", writer: true)
            let phone = try fixture.endpoint("phone", writer: false)
            let offer = try fixture.offer()
            try await mac.transport.publishMedia(offer: offer, fileURL: fixture.audioFile())
            let changedProof = try JSONEncoder().encode(LibraryMediaPreparation(
                preparedAt: Timestamp(Date(timeIntervalSince1970: 946771200))))
            await fixture.server.mutate("audio:ep-1") { record in
                if field == LibraryMediaRecord.preparationField { record[field] = changedProof as CKRecordValue }
                else { record[field] = (field == "entryID" ? "different-episode" : "audio/mp4") as CKRecordValue }
            }
            await XCTAssertThrowsErrorAsync(try await phone.transport.fetchMedia(offer) { _ in }) {
                guard case .transport? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
            }
        }
    }

    func testChangedRevisionOnTheServerFailsTheDownloadAndLeavesNoFile() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let old = try fixture.offer(revision: "rev-1")
        try await mac.transport.publishMedia(offer: old, fileURL: try fixture.audioFile())
        try await mac.transport.publishMedia(offer: try fixture.offer(revision: "rev-2"), fileURL: try fixture.audioFile())
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasSuffix(".download") }
        await XCTAssertThrowsErrorAsync(try await phone.transport.fetchMedia(old) { _ in }) {
            guard case .transport? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasSuffix(".download") }
        XCTAssertEqual(before.count, after.count)
    }

    func testOversizedMismatchedAndNotReadyOffersAreRejected() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let big = try fixture.offer(bytes: LibraryMediaRecord.maximumByteCount + 1)
        await XCTAssertThrowsErrorAsync(try await mac.transport.publishMedia(offer: big, fileURL: try fixture.audioFile())) {
            guard case .transport? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        await XCTAssertThrowsErrorAsync(try await mac.transport.publishMedia(offer: try fixture.offer(bytes: 999), fileURL: try fixture.audioFile(10))) {
            guard case .transport? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        await XCTAssertThrowsErrorAsync(try await phone.transport.fetchMedia(big) { _ in }) {
            guard case .transport? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        await XCTAssertThrowsErrorAsync(try await phone.transport.fetchMedia(.notReady(entryID: try item("ep-1"))) { _ in }) {
            guard case .transport? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        let empty = await fixture.server.records
        XCTAssertTrue(empty.isEmpty, "nothing reached the server")
        try await mac.transport.publishMedia(offer: .notReady(entryID: try item("ep-3")), fileURL: URL(fileURLWithPath: "/nonexistent"))
        let offers = try await phone.transport.mediaOffers()
        XCTAssertEqual(offers, [.notReady(entryID: try item("ep-3"))])
    }

    func testOnlyTheLibraryWriterPublishesOrRemovesMedia() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        await XCTAssertThrowsErrorAsync(try await phone.transport.publishMedia(offer: try fixture.offer(), fileURL: try fixture.audioFile())) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        await XCTAssertThrowsErrorAsync(try await phone.transport.removeMedia(entryID: try item("ep-1"))) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
    }

    func testRemoveWithdrawsOfferBeforeAssetAndEmptiesTheIndex() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await mac.transport.publishMedia(offer: try fixture.offer(), fileURL: try fixture.audioFile())
        try await mac.transport.removeMedia(entryID: try item("ep-1"))
        let log = await fixture.server.log
        XCTAssertEqual(Array(log.suffix(3)), ["engine delete offer:ep-1", "engine save offerindex:library", "raw delete audio:ep-1"])
        let audio = await fixture.server.records["audio:ep-1"]
        XCTAssertNil(audio)
        let offers = try await phone.transport.mediaOffers()
        XCTAssertTrue(offers.isEmpty)
    }

    func testStalledDownloadIsAbandonedByTheWatchdog() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false, watchdog: 0.2)
        try await mac.transport.publishMedia(offer: try fixture.offer(), fileURL: try fixture.audioFile())
        await fixture.server.setStall(true)
        let started = Date()
        await XCTAssertThrowsErrorAsync(try await phone.transport.fetchMedia(try fixture.offer()) { _ in }) {
            guard case let .transport(message)? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("stalled"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testPollingReadsNamedRecordsAndNeverCreatesAnEngineOrScansTheZone() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let intent = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "phone", createdAt: Date(timeIntervalSince1970: 5), id: "i-1")
        try await phone.transport.send(intent: intent)
        try await phone.transport.publish(makePosition(device: "phone", entry: "ep-1"), as: .nowPlaying)
        try await phone.transport.publish(makePosition(device: "phone", entry: "ep-1"), as: .progress)
        try await mac.transport.publishMedia(offer: try fixture.offer(), fileURL: try fixture.audioFile())

        await mac.transport.track(devices: ["phone"])
        for _ in 0..<3 {
            let intents = try await mac.transport.listIntents()
            XCTAssertEqual(intents, [intent])
            let records = try await mac.transport.fetchDeviceRecords()
            XCTAssertEqual(records.nowPlaying.map(\.record.deviceID), ["phone"])
            XCTAssertEqual(records.progress.map(\.record.entryID.rawValue), ["ep-1"])
            let offers = try await mac.transport.mediaOffers()
            XCTAssertEqual(offers.map(\.entryID.rawValue), ["ep-1"])
        }
        XCTAssertTrue(mac.log.states.isEmpty, "no engine was created for polling")
        XCTAssertTrue(phone.log.states.isEmpty)
        let scopes = await mac.driver.scopes
        XCTAssertTrue(scopes.isEmpty, "no engine fetch either")
        let targeted = await mac.driver.targetedFetches
        XCTAssertGreaterThan(targeted, 0)
    }

    func testIntentIndexAccumulatesAcrossSendsAndDuplicateSendsAreNoOps() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        let first = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "phone", createdAt: Date(timeIntervalSince1970: 1), id: "i-1")
        let second = try LibraryIntent.requestMedia(entryID: item("ep-2"), deviceID: "phone", createdAt: Date(timeIntervalSince1970: 2), id: "i-2")
        try await phone.transport.send(intent: first)
        try await phone.transport.send(intent: second)
        try await phone.transport.send(intent: first)
        await mac.transport.track(devices: ["phone"])
        let intents = try await mac.transport.listIntents()
        XCTAssertEqual(intents, [first, second])
        XCTAssertTrue(mac.log.states.isEmpty)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int64] = []
    func add(_ value: Int64) { lock.withLock { recorded.append(value) } }
    var values: [Int64] { lock.withLock { recorded } }
}

private extension CKRecord {
    /// Copies the payload of `source` into this record, used to forge a record whose name disagrees with it.
    func with(payload source: CKRecord) -> CKRecord {
        self[LibraryRecordMapper.payloadField] = source[LibraryRecordMapper.payloadField]
        return self
    }
}
