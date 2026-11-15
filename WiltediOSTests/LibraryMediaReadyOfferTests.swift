import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Probe transport tracking direct offer reads, sent intents, and simulating fetch conditions.
private final class ReadyOfferProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _directOfferReads = 0
    private var _sentIntents: [LibraryIntent] = []

    enum FetchMode: Sendable {
        case normal
        case assetGone
        case shortData(Int)
        case corruptHash
    }
    private var _fetchMode: FetchMode = .normal
    private var _revocationsAtRequest: Int?
    /// Reads the cache's revocation count; sampled when the first request is sent.
    var revocationProbe: (@Sendable () -> Int)?
    var revocationsAtRequest: Int? { lock.withLock { _revocationsAtRequest } }

    var directOfferReads: Int { lock.lock(); defer { lock.unlock() }; return _directOfferReads }
    var sentIntents: [LibraryIntent] { lock.lock(); defer { lock.unlock() }; return _sentIntents }
    var requestIntents: [LibraryIntent] {
        lock.lock(); defer { lock.unlock() }
        return _sentIntents.filter { if case .requestMedia = $0.action { true } else { false } }
    }
    var mediaCachedIntents: [LibraryIntent] {
        lock.lock(); defer { lock.unlock() }
        return _sentIntents.filter { if case .mediaCached = $0.action { true } else { false } }
    }

    func setFetchMode(_ mode: FetchMode) {
        lock.lock(); _fetchMode = mode; lock.unlock()
    }

    func noteOfferRead() {
        lock.lock(); _directOfferReads += 1; lock.unlock()
    }

    func noteSent(_ intent: LibraryIntent) {
        let revoked = revocationProbe?()
        lock.withLock {
            _sentIntents.append(intent)
            if case .requestMedia = intent.action, _revocationsAtRequest == nil { _revocationsAtRequest = revoked }
        }
    }

    func nextFetchMode() -> FetchMode {
        lock.withLock { defer { _fetchMode = .normal }; return _fetchMode }
    }
}

private struct ReadyOfferScriptedTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let script: ReadyOfferProbeScript

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }

    func mediaOffers() async throws -> [LibraryMediaOffer] {
        script.noteOfferRead()
        return try await inner.mediaOffers()
    }

    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }

    func send(intent: LibraryIntent) async throws {
        script.noteSent(intent)
        try await inner.send(intent: intent)
    }

    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        switch script.nextFetchMode() {
        case .normal:
            return try await inner.fetchMedia(offer, progress: progress)
        case .assetGone:
            throw LibraryTransportError.transport("no ready media is offered for \(offer.entryID)")
        case let .shortData(count):
            let normalURL = try await inner.fetchMedia(offer, progress: progress)
            let fullData = try Data(contentsOf: normalURL)
            try? FileManager.default.removeItem(at: normalURL)
            let shortURL = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString)")
            try fullData.prefix(count).write(to: shortURL)
            return shortURL
        case .corruptHash:
            let normalURL = try await inner.fetchMedia(offer, progress: progress)
            var fullData = try Data(contentsOf: normalURL)
            try? FileManager.default.removeItem(at: normalURL)
            if !fullData.isEmpty { fullData[0] ^= 0xff }
            let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString)")
            try fullData.write(to: corruptURL)
            return corruptURL
        }
    }
}

private actor ReadyOfferStoreWrapper: LibraryStore {
    private var saved: LibraryStoreState
    init(_ state: LibraryStoreState) { saved = state }
    func state() -> LibraryStoreState { saved }
    func commit(_ staged: StagedLibraryBatch) { saved = staged.nextState; saved.revision += 1 }
    func enqueue(_ change: LibraryChange) { saved.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) { saved.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) { saved.resolveConflict(key, keepLocal: keepLocal) }
}

private final class TrackingMediaCache: LibraryMediaCache, @unchecked Sendable {
    let inner: FileMediaCache
    private let lock = NSLock()
    private var _revocations: [ItemID] = []

    init(_ inner: FileMediaCache) { self.inner = inner }

    var revocations: [ItemID] { lock.lock(); defer { lock.unlock() }; return _revocations }

    func revokePreparation(entryID: ItemID) async throws {
        lock.withLock { _revocations.append(entryID) }
        try await inner.revokePreparation(entryID: entryID)
    }

    func bindOwner(ownerToken: String?, libraryScope: String, held: Bool) async throws {
        try await inner.bindOwner(ownerToken: ownerToken, libraryScope: libraryScope, held: held)
    }
    func admission(entryID: ItemID, ownerToken: String, libraryScope: String, transportGeneration: UInt64) async -> MediaCacheAdmission? {
        await inner.admission(entryID: entryID, ownerToken: ownerToken, libraryScope: libraryScope, transportGeneration: transportGeneration)
    }
    func cachedEntries() async -> [ItemID: CachedMedia] { await inner.cachedEntries() }
    func storedAudioByteCounts() async -> [ItemID: Int64] { await inner.storedAudioByteCounts() }
    func partialDirectory(for entryID: ItemID) -> URL? { inner.partialDirectory(for: entryID) }
    func discardPartials(entryID: ItemID, keeping offer: LibraryMediaOffer?) async { await inner.discardPartials(entryID: entryID, keeping: offer) }
    func discardAllPartials() async { await inner.discardAllPartials() }
    func purgePartials(olderThan cutoff: Date) async { await inner.purgePartials(olderThan: cutoff) }
    func reclaimUnplayableAudio(keeping kept: Set<ItemID>) async -> Set<ItemID> { await inner.reclaimUnplayableAudio(keeping: kept) }
    func verifies(_ cached: CachedMedia) async -> Bool { await inner.verifies(cached) }
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
        await inner.cachedTranscript(entryID: entryID, revisionID: revisionID)
    }
    func storeTranscript(_ transcript: LibraryTranscript) async { await inner.storeTranscript(transcript) }

    func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL? {
        await inner.cachedFile(for: offer, admission: admission)
    }
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL {
        try await inner.adopt(verifiedFile: verifiedFile, for: offer, admission: admission)
    }
    func permits(_ admission: MediaCacheAdmission, for offer: LibraryMediaOffer) async -> Bool {
        await inner.permits(admission, for: offer)
    }
    func remove(entryID: ItemID) async throws {
        try await inner.remove(entryID: entryID)
    }
}

private final class ReadyOfferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_700_000_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

@MainActor
final class LibraryMediaReadyOfferTests: XCTestCase {
    private var scratch: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private let entryID = try! ItemID(rawValue: "item-ready-a")
    private let revisionID = try! RevisionID(rawValue: "rev-ready-1")
    private let payload = Data((0..<50_000).map { UInt8($0 % 251) })
    private let owner = "ready-offer-owner"
    private var store: ReadyOfferStoreWrapper!
    private var cache: TrackingMediaCache!
    private var script: ReadyOfferProbeScript!
    private var clock: ReadyOfferClock!
    private let fast = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30))

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ready-offer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fileCache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        cache = TrackingMediaCache(fileCache)
        script = ReadyOfferProbeScript()
        script.revocationProbe = { [cache] in cache?.revocations.count ?? 0 }
        clock = ReadyOfferClock()

        let entry = try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: ItemID(rawValue: "show"),
            title: "Ready Episode", summary: "", publishedAt: Date(timeIntervalSince1970: 1_000))
        let slot = try QueueSlot(entryID: entryID, sortKey: 0)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .slot(slot), baseVersion: 0),
        ])
        var state = LibraryStoreState()
        state.ownerToken = owner
        state.content = LibrarySnapshot(entries: [entry], slots: [slot])
        store = ReadyOfferStoreWrapper(state)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeOffer(
        state: LibraryMediaOffer.State = .ready, hashOf other: Data? = nil, byteCount: Int64? = nil
    ) throws -> LibraryMediaOffer {
        try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash(other ?? payload),
            byteCount: byteCount ?? Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 60,
            state: state,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000))))
    }

    private func macPublish(_ offer: LibraryMediaOffer, data: Data? = nil) async throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try (data ?? payload).write(to: file)
        try await mac.publishMedia(offer: offer, fileURL: file)
    }

    private func makeModel() -> LibraryAppModel {
        let innerPhone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: owner)
        let transport = ReadyOfferScriptedTransport(inner: innerPhone, script: script)
        let clock = clock!
        return LibraryAppModel(
            transport: transport, store: store, deviceID: "phone", mediaCache: cache,
            mediaTiming: fast, outboxURL: scratch.appendingPathComponent("pending-intents.json"),
            now: { clock.now })
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Tests

    func testUploadedOfferInRoundCopyCachesWithoutRequestIntentOrDirectOfferReadAndSendsMediaCached() async throws {
        let offer = try makeOffer()
        try await macPublish(offer)
        let model = makeModel()
        model.noteOffers([offer])

        let readsBefore = script.directOfferReads
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.directOfferReads, readsBefore, "no direct offer read is made")
        XCTAssertTrue(script.requestIntents.isEmpty, "no requestMedia intent is sent")
        XCTAssertEqual(script.mediaCachedIntents.count, 1, "exactly one mediaCached intent is sent")
    }

    func testRoundCopyAbsentMakesExactlyOneDirectOfferRead() async throws {
        let offer = try makeOffer()
        try await macPublish(offer)
        let model = makeModel()

        let readsBefore = script.directOfferReads
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.directOfferReads - readsBefore, 1, "makes exactly one direct offer read when copy is absent")
        XCTAssertTrue(script.requestIntents.isEmpty, "no requestMedia intent is sent")
        XCTAssertEqual(script.mediaCachedIntents.count, 1, "sends one mediaCached intent")
    }

    func testRoundCopyOlderThan60SecondsMakesExactlyOneDirectOfferRead() async throws {
        let offer = try makeOffer()
        try await macPublish(offer)
        let model = makeModel()
        model.noteOffers([offer])
        clock.advance(65)

        let readsBefore = script.directOfferReads
        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.directOfferReads - readsBefore, 1, "makes exactly one direct offer read when older than 60s")
        XCTAssertTrue(script.requestIntents.isEmpty, "no requestMedia intent is sent")
        XCTAssertEqual(script.mediaCachedIntents.count, 1, "sends one mediaCached intent")
    }

    func testAvailableOfferSendsIntentAndRevokesNoPreparation() async throws {
        let availableOffer = try makeOffer(state: .available)
        try await macPublish(availableOffer, data: Data())
        let model = makeModel()
        model.noteOffers([availableOffer])

        model.performMediaAction(.request, entryID: entryID)
        try await eventually("request sent") { !self.script.requestIntents.isEmpty }

        XCTAssertEqual(script.requestIntents.count, 1, "requestMedia intent is sent")
        XCTAssertEqual(script.revocationsAtRequest, 0, "no preparation is revoked for available offer")

        try await macPublish(makeOffer())
        await model.waitForMedia(entryID: entryID)
        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
    }

    func testStaleNotReadyOfferSendsIntentAndRevokesNoPreparation() async throws {
        let notReady = LibraryMediaOffer.notReady(entryID: entryID)
        let file = scratch.appendingPathComponent("empty")
        try Data().write(to: file)
        try await mac.publishMedia(offer: notReady, fileURL: file)
        let model = makeModel()
        model.noteOffers([notReady])
        clock.advance(70)

        model.performMediaAction(.request, entryID: entryID)
        try await eventually("request sent") { !self.script.requestIntents.isEmpty }

        XCTAssertEqual(script.requestIntents.count, 1, "requestMedia intent is sent")
        XCTAssertEqual(script.revocationsAtRequest, 0, "no preparation is revoked for stale notReady offer before request")

        // The request path then applies the Mac's standing notReady answer as it always has.
        await model.waitForMedia(entryID: entryID)
    }

    func testAssetGoneAtFetchTimeSendsIntentAndFinishesFromMacAnswer() async throws {
        let offer = try makeOffer()
        try await macPublish(offer)
        script.setFetchMode(.assetGone)
        let model = makeModel()
        model.noteOffers([offer])

        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.requestIntents.count, 1, "same job sends intent after asset gone")
        XCTAssertEqual(script.mediaCachedIntents.count, 1, "sends mediaCached once cached")
    }

    func testSizeMismatchAtFetchTimeSendsIntentAndFinishesFromMacAnswer() async throws {
        let offer = try makeOffer()
        try await macPublish(offer)
        script.setFetchMode(.shortData(100))
        let model = makeModel()
        model.noteOffers([offer])

        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.requestIntents.count, 1, "same job sends intent after size mismatch")
        XCTAssertEqual(script.mediaCachedIntents.count, 1, "sends mediaCached once cached")
    }

    func testHashMismatchAtFetchTimeSendsIntentAndFinishesFromMacAnswer() async throws {
        let offer = try makeOffer()
        try await macPublish(offer)
        script.setFetchMode(.corruptHash)
        let model = makeModel()
        model.noteOffers([offer])

        model.performMediaAction(.request, entryID: entryID)
        await model.waitForMedia(entryID: entryID)

        XCTAssertEqual(model.mediaState(for: entryID), .onPhone)
        XCTAssertEqual(script.requestIntents.count, 1, "same job sends intent after hash mismatch")
        XCTAssertEqual(script.mediaCachedIntents.count, 1, "sends mediaCached once cached")
    }
}
