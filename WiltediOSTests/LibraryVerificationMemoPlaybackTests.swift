import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// Reads the walk count synchronously at engine load, before player callbacks enqueue more work.
final class MemoWalkMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var atLoad: Int?

    var count: Int { lock.withLock { total } }
    var countAtLoad: Int? { lock.withLock { atLoad } }
    func walked() { lock.withLock { total += 1 } }
    func loaded() { lock.withLock { atLoad = total } }
}

/// Preserves the normal player wiring while sampling the cache work before audio is loaded.
final class MemoLoadEngine: ListenerAudioEngine, @unchecked Sendable {
    private let base = RuntimeFakeEngine()
    private let measurement: MemoWalkMeasurement

    init(measurement: MemoWalkMeasurement) { self.measurement = measurement }
    var duration: Double { base.duration }
    var currentTime: Double {
        get { base.currentTime }
        set { base.currentTime = newValue }
    }
    var isPlaying: Bool { base.isPlaying }
    func load(url: URL) throws { try load(url: url, completionGeneration: 0) }
    func load(url: URL, completionGeneration: UInt64) throws {
        measurement.loaded()
        try base.load(url: url, completionGeneration: completionGeneration)
    }
    func play() -> Bool { base.play() }
    func pause() { base.pause() }
}

/// The real file cache, counting inventory walks so a test can see how often one action walks it.
actor WalkCountingCache: LibraryMediaCache {
    let inner: FileMediaCache
    nonisolated let measurement = MemoWalkMeasurement()
    var walks: Int { measurement.count }

    init(inner: FileMediaCache) { self.inner = inner }

    func cachedEntries() async -> [ItemID: CachedMedia] {
        measurement.walked()
        return await inner.cachedEntries()
    }
    func storedAudioByteCounts() async -> [ItemID: Int64] { await inner.storedAudioByteCounts() }
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
        await inner.cachedTranscript(entryID: entryID, revisionID: revisionID)
    }
    func storeTranscript(_ transcript: LibraryTranscript) async { await inner.storeTranscript(transcript) }
    func bindOwner(ownerToken: String?, libraryScope: String, held: Bool) async throws {
        try await inner.bindOwner(ownerToken: ownerToken, libraryScope: libraryScope, held: held)
    }
    func admission(entryID: ItemID, ownerToken: String, libraryScope: String, transportGeneration: UInt64) async -> MediaCacheAdmission? {
        await inner.admission(entryID: entryID, ownerToken: ownerToken, libraryScope: libraryScope, transportGeneration: transportGeneration)
    }
    func revokePreparation(entryID: ItemID) async throws { try await inner.revokePreparation(entryID: entryID) }
    func verifies(_ cached: CachedMedia) async -> Bool { await inner.verifies(cached) }
    func permits(_ admission: MediaCacheAdmission, for offer: LibraryMediaOffer) async -> Bool {
        await inner.permits(admission, for: offer)
    }
    func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL? {
        await inner.cachedFile(for: offer, admission: admission)
    }
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL {
        try await inner.adopt(verifiedFile: verifiedFile, for: offer, admission: admission)
    }
    func remove(entryID: ItemID) async throws { try await inner.remove(entryID: entryID) }
}

/// Resume, play and grouped starts take the hash from the cache's memo once a file passed in this
/// process (W-INV-040), while changed bytes are still hashed again and refused.
@MainActor
final class LibraryVerificationMemoPlaybackTests: XCTestCase {
    private let episode = try! ItemID(rawValue: "memo-episode")
    private let a = try! ItemID(rawValue: "memo-alias-a")
    private let b = try! ItemID(rawValue: "memo-alias-b")
    private let feed = try! ItemID(rawValue: "memo-feed")
    private let date = Date(timeIntervalSince1970: 10_000)
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("memo-play-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func certifiedOffer(_ entryID: ItemID, bytes: Data) throws -> LibraryMediaOffer {
        try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: RevisionID(rawValue: "memo-rev"), contentHash: PreparedMediaFixture.hash(bytes),
            byteCount: Int64(bytes.count), mediaType: "audio/mp4", durationSeconds: 600))
    }

    private func incoming(_ bytes: Data) throws -> URL {
        let url = scratch.appendingPathComponent("incoming-\(UUID())")
        try bytes.write(to: url)
        return url
    }

    /// The production runtime over a real counting cache, with the one queued episode loaded.
    private func runtimeRig() async throws -> (runtime: LibraryRuntime, counter: HashCounter, file: URL) {
        let suite = "wilted.memo.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let server = InMemoryLibraryServer(writerDeviceID: "fixture-mac")
        let mac = InMemoryLibraryTransport(deviceID: "fixture-mac", server: server, verifiedOwnerToken: "fixture-owner")
        let showID = try ItemID(rawValue: "memo-show")
        let entry = try LibraryEntry(id: episode, kind: .podcastEpisode, sourceID: showID, title: "Episode",
            summary: "", publishedAt: Date(timeIntervalSince1970: 1_000), durationSeconds: 600)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .source(LibrarySource(id: showID, kind: .podcastFeed, title: "Show")), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 3, change: .slot(try QueueSlot(entryID: episode, sortKey: 0)), baseVersion: 0)])
        let phone = InMemoryLibraryTransport(deviceID: "fixture-phone", server: server, verifiedOwnerToken: "fixture-owner")
        let store = FileLibraryStore(url: scratch.appendingPathComponent("library-state.json"))
        try await PreparedMediaFixture.bootstrap(store, transport: phone)
        let counter = HashCounter()
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"), byteVerifier: counter.verifier)
        let bytes = Data([1, 2, 3, 4])
        let file = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: incoming(bytes),
                                                        for: certifiedOffer(episode, bytes: bytes), owner: "fixture-owner")
        let model = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "test"), store: store,
                                    deviceID: "phone", mediaCache: cache, preferences: defaults)
        let player = LibraryPlayer(
            engine: RuntimeFakeEngine(), session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let runtime = LibraryRuntime(model: model, player: player, settings: LibrarySettingsStore(defaults: defaults),
                                     pushHandler: RuntimeFakePushHandler())
        await runtime.prepare()
        XCTAssertNotNil(player.authorizePlayback, "every resume goes through the runtime's admission")
        XCTAssertEqual(model.media[episode], .onPhone)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(player.start(LibraryPlayer.Item(entryID: episode, title: "Episode", showTitle: "Show", fileURL: file)))
        return (runtime, counter, file)
    }

    /// A grouped episode: `a` is shown, its member `b` holds the certified file and a saved position.
    private func groupedRig() async throws -> (model: LibraryAppModel, cache: WalkCountingCache, counter: HashCounter) {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner")
        let association = LibraryEpisodeAssociation(groupID: UUID(), representativeID: a, memberIDs: [a, b],
                                                    associationVersion: 1, isTerminal: false)
        let entries = try [a, b].map { id in
            try LibraryEntry(id: id, kind: .podcastEpisode, sourceID: feed, title: id == a ? "Representative" : "Backing",
                summary: "", publishedAt: date, durationSeconds: 600, episodeAssociation: association)
        }
        var changes = entries.map(LibraryChange.entry)
        changes.append(.slot(try QueueSlot(entryID: b, sortKey: 0)))
        let push = try await mac.push(changes: changes.enumerated().map {
            .init(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        XCTAssertTrue(push.failures.isEmpty)
        let store = FileLibraryStore(url: scratch.appendingPathComponent("mirror.json"))
        _ = try await LibraryReconciler(transport: phone, store: store).synchronize().get()
        let counter = HashCounter()
        let inner = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"), byteVerifier: counter.verifier)
        let bytes = Data([1, 2, 3, 4])
        _ = try await PreparedMediaFixture.adopt(into: inner, verifiedFile: incoming(bytes),
                                                 for: certifiedOffer(b, bytes: bytes), owner: "owner")
        let cache = WalkCountingCache(inner: inner)
        let model = LibraryAppModel(transport: phone, store: store, deviceID: "phone", mediaCache: cache)
        await model.loadLocalState()
        model.handoffState.ownPositions[b] = ObservedPlayback(record: try DevicePlaybackPosition(deviceID: "mac",
            entryID: b, revision: RevisionID(rawValue: "memo-rev"), positionSeconds: 123, isPlaying: false, epoch: 2),
            serverModifiedAt: date)
        model.rebuildRows()
        XCTAssertEqual(model.visibleRows.map(\.id), [a])
        return (model, cache, counter)
    }

    private func player(for model: LibraryAppModel, engine: any ListenerAudioEngine = RuntimeFakeEngine()) -> LibraryPlayer {
        let player = LibraryPlayer(engine: engine, session: RuntimeFakeSession(),
            nowPlaying: RuntimeFakeNowPlaying(), remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        model.attachPlayer(player)
        return player
    }

    func testSecondResumeOfAnUnchangedEpisodeDoesNotHashIt() async throws {
        let (runtime, counter, file) = try await runtimeRig()
        let player = runtime.player
        defer { player.stop() }
        let loaded = await counter.calls
        for resume in 1...3 {
            player.pause()
            _ = player.play()
            await player.admissionTask?.value
            XCTAssertTrue(player.isPlaying, "resume \(resume) plays")
            let hashes = await counter.calls - loaded
            XCTAssertEqual(hashes, 1, "only the first resume in this process hashes the file (resume \(resume))")
        }
        // A press-and-hold seek is admitted the same way, without hashing again.
        XCTAssertTrue(player.handle(.beginSeeking(.forward)))
        await player.admissionTask?.value
        XCTAssertTrue(player.isRemoteSeeking)
        XCTAssertTrue(player.handle(.endSeeking(.forward)))
        await player.admissionTask?.value
        XCTAssertTrue(player.isPlaying)
        let afterSeek = await counter.calls - loaded
        XCTAssertEqual(afterSeek, 1, "a held seek after a verified resume does not hash")

        // Positive control: same-size changed bytes are hashed again and refused.
        player.pause()
        try Data([9, 9, 9, 9]).write(to: file)
        _ = player.play()
        await player.admissionTask?.value
        XCTAssertFalse(player.isPlaying, "changed bytes never play")
        XCTAssertNil(player.item)
        let total = await counter.calls - loaded
        XCTAssertEqual(total, 2, "the changed file was hashed again rather than admitted from the memo")
    }

    func testGroupedStartWalksAndHashesOnce() async throws {
        let (model, cache, counter) = try await groupedRig()
        let player = player(for: model, engine: MemoLoadEngine(measurement: cache.measurement))
        let row = try XCTUnwrap(model.visibleRows.first)
        let hashesBefore = await counter.calls
        let walksBefore = await cache.walks
        let outcome = await model.playCachedWithoutToggling(row)
        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(player.item?.entryID, b)
        XCTAssertEqual(player.position, 123)
        let hashes = await counter.calls - hashesBefore
        // Loading/playing also queues position persistence and handoff, which walk the cache after
        // admission. Only the work before engine load can stand in front of this start (W-INV-040).
        let walks = try XCTUnwrap(cache.measurement.countAtLoad) - walksBefore
        XCTAssertEqual(hashes, 1, "the grouped start's final re-admission reuses the first verification")
        XCTAssertEqual(walks, 1, "verification and the position lookup share one cache walk before engine load")
        await model.waitForHandoff()
    }

    func testReadmissionNeitherWalksNorHashesButStillRefusesChangedBytes() async throws {
        let (model, cache, counter) = try await groupedRig()
        let first = await model.verifiedCachedMedia(b, token: model.beginExternalStart())
        let cached = try XCTUnwrap(first)
        let hashes = await counter.calls
        let walks = await cache.walks
        let again = await model.verifiedCachedMedia(b, token: model.beginExternalStart(), walked: [b: cached])
        XCTAssertEqual(again, cached)
        let readmitHashes = await counter.calls - hashes
        let readmitWalks = await cache.walks - walks
        XCTAssertEqual(readmitHashes, 0)
        XCTAssertEqual(readmitWalks, 0)
        try Data([9, 9, 9, 9]).write(to: cached.url)
        let tampered = await model.verifiedCachedMedia(b, token: model.beginExternalStart(), walked: [b: cached])
        XCTAssertNil(tampered, "a re-admission of changed bytes is refused")
        let tamperHashes = await counter.calls - hashes
        XCTAssertEqual(tamperHashes, 1, "the changed file was hashed again")
    }
}
