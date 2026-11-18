import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// "I listened on the way there, and when I got back in the car the episode started over." The phone
/// is locked and suspended between trips, so the position has to reach the phone's own store while the
/// app is still awake, never behind a network call that a parked car can leave hanging.
@MainActor
final class LibraryResumePersistenceTests: XCTestCase {
    private var scratch: URL!
    private var positionsURL: URL!
    private var cache: FileMediaCache!
    private let gate = NetworkGate()
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private let entryID = try! ItemID(rawValue: "item-a")
    private let revisionID = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        positionsURL = scratch.appendingPathComponent("state/own-positions.json")
        cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let entry = try LibraryEntry(id: entryID, kind: .podcastEpisode, sourceID: entryID,
            title: "Episode", summary: "", publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 3_600)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .slot(try QueueSlot(entryID: entryID, sortKey: 0)), baseVersion: 0)])
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        try await PreparedMediaFixture.bootstrap(FileLibraryStore(url: scratch.appendingPathComponent("library-state.json")), transport: phone)
        let file = scratch.appendingPathComponent("incoming.mp4")
        try payload.write(to: file)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash, byteCount: Int64(payload.count),
            mediaType: "audio/mp4", durationSeconds: 3_600))
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: offer, owner: "fixture-owner")
    }

    override func tearDown() async throws {
        await gate.release()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: doubles

    /// The in-memory server whose record reads and writes can be made to hang, as in a car park.
    private actor NetworkGate {
        private(set) var hanging = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var arrival: CheckedContinuation<Void, Never>?
        func hang() { hanging = true }
        /// Returns once a call is waiting at the gate.
        func waitUntilHeld() async {
            if waiters.isEmpty { await withCheckedContinuation { arrival = $0 } }
        }
        func release() {
            hanging = false
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
        func passThrough() async {
            guard hanging else { return }
            await withCheckedContinuation {
                waiters.append($0)
                arrival?.resume()
                arrival = nil
            }
        }
    }

    private struct GatedTransport: LibraryTransport {
        let inner: InMemoryLibraryTransport
        let gate: NetworkGate
        /// Holds a poll's answer after the server was read, so the answer is stale when it lands.
        var answerGate: NetworkGate?
        func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
        func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
        func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
        func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
        func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
        func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
        func publishIntentOutcome(_ outcome: IntentOutcome) async throws { try await inner.publishIntentOutcome(outcome) }
        func intentOutcomes() async throws -> [IntentOutcome] { try await inner.intentOutcomes() }
        func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
            await gate.passThrough()
            try await inner.publish(record, as: channel)
        }
        func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
            await gate.passThrough()
            return try await inner.fetchDeviceRecords()
        }
        func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws {
            await gate.passThrough()
            try await inner.publish(records)
        }
        func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
            await gate.passThrough()
            let result = try await inner.poll(options)
            await answerGate?.passThrough()
            return result
        }
        func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws { try await inner.publishMedia(offer: offer, fileURL: fileURL) }
        func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
        func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
            try await inner.fetchMedia(offer, progress: progress)
        }
        func removeMedia(entryID: ItemID) async throws { try await inner.removeMedia(entryID: entryID) }
        func publishStats(_ stats: LibraryStats) async throws { try await inner.publishStats(stats) }
        func readStats() async throws -> LibraryStats? { try await inner.readStats() }
        func publishTranscript(_ transcript: LibraryTranscript) async throws { try await inner.publishTranscript(transcript) }
        func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
            try await inner.transcript(entryID: entryID, revisionID: revisionID)
        }
    }

    private final class FakeEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
        private let lock = NSLock()
        private var time = 0.0
        private var playing = false
        var duration = 3_600.0
        var rate: Float = 1
        var currentTime: Double {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
        var isPlaying: Bool {
            get { lock.withLock { playing } }
            set { lock.withLock { playing = newValue } }
        }
        func load(url: URL) throws {}
        func load(url: URL, completionGeneration: UInt64) throws { currentTime = 0 }
        func play() -> Bool { isPlaying = true; return true }
        func pause() { isPlaying = false }
        func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
    }

    private final class FakeSession: ListenerAudioSession, @unchecked Sendable {
        func activate() throws {}
        func deactivate() {}
    }

    private final class FakeNowPlaying: ListenerNowPlaying, @unchecked Sendable {
        func update(title: String, duration: Double, position: Double, rate: Double) {}
        func clear() {}
    }

    @MainActor private final class FakeRemote: LibraryRemoteCommands {
        func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    }

    @MainActor private final class FakeEvents: LibrarySessionEvents {
        func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
    }

    // MARK: fixtures

    /// Holds exactly the first cache lookup so a local save can be overtaken deterministically.
    private actor GatedCache: LibraryMediaCache {
        let base: FileMediaCache
        private var first = true
        private var pending: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        init(base: FileMediaCache) { self.base = base }
        func storedAudioByteCounts() async -> [ItemID: Int64] { await base.storedAudioByteCounts() }
        func cachedEntries() async -> [ItemID: CachedMedia] {
            let entries = await base.cachedEntries()
            if first {
                first = false
                await withCheckedContinuation { continuation in
                    pending = continuation
                    arrival?.resume()
                    arrival = nil
                }
            }
            return entries
        }
        func waitUntilBlocked() async {
            if pending == nil { await withCheckedContinuation { arrival = $0 } }
        }
        func release() { pending?.resume(); pending = nil }
        func bindOwner(ownerToken: String?, libraryScope: String, held: Bool) async throws {
            try await base.bindOwner(ownerToken: ownerToken, libraryScope: libraryScope, held: held)
        }
        func admission(entryID: ItemID, ownerToken: String, libraryScope: String, transportGeneration: UInt64) async -> MediaCacheAdmission? {
            await base.admission(entryID: entryID, ownerToken: ownerToken, libraryScope: libraryScope, transportGeneration: transportGeneration)
        }
        func revokePreparation(entryID: ItemID) async throws { try await base.revokePreparation(entryID: entryID) }
        func verifies(_ cached: CachedMedia) async -> Bool { await base.verifies(cached) }
        func permits(_ admission: MediaCacheAdmission, for offer: LibraryMediaOffer) async -> Bool {
            await base.permits(admission, for: offer)
        }
        func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL? {
            await base.cachedFile(for: offer, admission: admission)
        }
        func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL {
            try await base.adopt(verifiedFile: verifiedFile, for: offer, admission: admission)
        }
        func remove(entryID: ItemID) async throws { try await base.remove(entryID: entryID) }
        func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
            await base.cachedTranscript(entryID: entryID, revisionID: revisionID)
        }
        func storeTranscript(_ transcript: LibraryTranscript) async { await base.storeTranscript(transcript) }

    }

    private func makeModel(transport: any LibraryTransport, mediaCache: (any LibraryMediaCache)? = nil) -> LibraryAppModel {
        let suite = "wilted.resume.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LibraryAppModel(
            transport: transport, store: FileLibraryStore(url: scratch.appendingPathComponent("library-state.json")),
            deviceID: "phone", mediaCache: mediaCache ?? cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
                settleSleep: { _ in }),
            preferences: defaults, ownPositionsURL: positionsURL)
    }

    private func makePlayer() -> (LibraryPlayer, FakeEngine) {
        let engine = FakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: FakeSession(), nowPlaying: FakeNowPlaying(), remoteCommands: FakeRemote(),
            sessionEvents: FakeEvents(), tickInterval: .seconds(3_600))
        return (player, engine)
    }

    private func loadedItem() async throws -> LibraryPlayer.Item {
        let entries = await cache.cachedEntries()
        let cached = try XCTUnwrap(entries[entryID])
        return LibraryPlayer.Item(entryID: entryID, title: "Episode", showTitle: "Show", fileURL: cached.url)
    }

    /// A launch with no signal, the way CarPlay's cold start reads the phone's own store: `prepare()` ->
    /// `loadLocalState()`, then Play.
    private func coldLaunch(transport: (any LibraryTransport)? = nil) async -> LibraryAppModel {
        let model = makeModel(transport: transport ?? UnavailableLibraryTransport(reason: "no signal"))
        await model.loadLocalState()
        return model
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Adds `item-b` to the Larder and to the phone's cache; returns its id and audio file.
    private func addSecondEpisode() async throws -> (ItemID, URL) {
        let secondID = try ItemID(rawValue: "item-b")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let second = try LibraryEntry(id: secondID, kind: .podcastEpisode, sourceID: secondID,
            title: "Episode", summary: "", publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 3_600)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 3, change: .entry(second), baseVersion: 0),
            PendingLibraryChange(localSeq: 4, change: .slot(try QueueSlot(entryID: secondID, sortKey: 1)), baseVersion: 0)])
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        try await PreparedMediaFixture.bootstrap(FileLibraryStore(url: scratch.appendingPathComponent("library-state.json")), transport: phone)
        let secondFile = scratch.appendingPathComponent("incoming-second.mp4")
        try payload.write(to: secondFile)
        let secondOffer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: secondID, revisionID: revisionID, contentHash: PreparedMediaFixture.hash(payload),
            byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 3_600))
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: secondFile, for: secondOffer, owner: "fixture-owner")
        let cached = await cache.cachedEntries()
        return (secondID, try XCTUnwrap(cached[secondID]).url)
    }

    private func phoneTransport(answerGate: NetworkGate? = nil) -> GatedTransport {
        GatedTransport(inner: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
                       gate: gate, answerGate: answerGate)
    }

    /// The phone's NowPlaying record, as the Mac reads it.
    private func phoneNowPlaying() async throws -> DevicePlaybackPosition? {
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        return try await mac.fetchDeviceRecords().nowPlaying.first { $0.record.deviceID == "phone" }?.record
    }

    private func storedPosition() -> Double? {
        LibraryOwnPositionStore(url: positionsURL).load().positions[entryID]?.record.positionSeconds
    }

    // MARK: tests

    func testDifferentEpisodeDoesNotDiscardPendingLocalSave() async throws {
        let (secondID, media) = try await addSecondEpisode()
        let gated = GatedCache(base: cache)
        let model = makeModel(transport: UnavailableLibraryTransport(reason: "no signal"), mediaCache: gated)
        let (player, _) = makePlayer()
        // Wire only the local-save seam: unrelated player handoff tasks cannot consume the gate.
        model.handoffState.player = player
        player.start(try await loadedItem(), at: 0)
        let pending = try XCTUnwrap(model.saveLoadedPositionLocally(123))
        await gated.waitUntilBlocked()
        player.start(.init(entryID: secondID, title: "Second", showTitle: "Show", fileURL: media), at: 0)
        model.saveLoadedPositionLocally(456)
        try await eventually("the second episode save") { model.handoffState.unpublished[secondID]?.position == 456 }
        await gated.release()
        await pending.value
        XCTAssertEqual(model.handoffState.unpublished[entryID]?.position, 123)
        let stored = LibraryOwnPositionStore(url: positionsURL).load()
        XCTAssertEqual(stored.positions[entryID]?.record.positionSeconds, 123)
        XCTAssertEqual(stored.positions[secondID]?.record.positionSeconds, 456)
        XCTAssertEqual(stored.unpublished[entryID]?.position, 123)
        XCTAssertEqual(stored.unpublished[secondID]?.position, 456)
    }

    func testNewerSameEpisodeSaveWins() async throws {
        let entries = await cache.cachedEntries()
        let gated = GatedCache(base: cache)
        let model = makeModel(transport: UnavailableLibraryTransport(reason: "no signal"), mediaCache: gated)
        let (player, _) = makePlayer()
        model.handoffState.player = player
        player.start(try await loadedItem(), at: 0)
        let pending = try XCTUnwrap(model.saveLoadedPositionLocally(123))
        await gated.waitUntilBlocked()
        model.saveLoadedPositionLocally(456)
        try await eventually("the newer same-episode save") { model.handoffState.unpublished[entryID]?.position == 456 }
        await gated.release()
        await pending.value
        XCTAssertEqual(storedPosition(), 456)
        XCTAssertEqual(model.handoffState.unpublished[entryID]?.position, 456)
    }

    func testAPauseBehindAHangingNetworkCallStillResumesAfterAColdLaunch() async throws {
        let model = makeModel(transport: GatedTransport(inner: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"), gate: gate))
        let (player, engine) = makePlayer()
        model.attachPlayer(player)
        player.start(try await loadedItem(), at: 0)
        await model.waitForHandoff()

        // The car park: every record call now hangs, and the pause lands behind it.
        await gate.hang()
        engine.currentTime = 1_234
        player.pause()
        try await eventually("the pause to reach the phone's own store") { storedPosition() == 1_234 }

        let relaunched = await coldLaunch()
        XCTAssertEqual(relaunched.resumeStart(for: entryID, cachedRevision: revisionID), 1_234, "an offline cold launch resumes where it paused")

        // Back in signal, the server still holds the start of the session; it must not win.
        let online = await coldLaunch(transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"))
        await online.refresh()
        XCTAssertEqual(online.resumeStart(for: entryID, cachedRevision: revisionID), 1_234, "the saved position outranks the older server copy")
    }

    func testAKillDuringPlaybackLosesAtMostTheLastFewSeconds() async throws {
        let model = makeModel(transport: GatedTransport(inner: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"), gate: gate))
        let (player, engine) = makePlayer()
        model.attachPlayer(player)
        player.start(try await loadedItem(), at: 0)
        await model.waitForHandoff()

        engine.currentTime = 900
        player.refreshPosition()
        try await eventually("the playing position to be saved") { storedPosition() == 900 }

        engine.currentTime = 904
        player.refreshPosition()
        let relaunched = await coldLaunch()
        XCTAssertEqual(relaunched.resumeStart(for: entryID, cachedRevision: revisionID), 900, "killed while playing: back to the last save, not the start")
    }

    func testEnteringTheBackgroundSavesThePlayingPositionBeforeAnyNetworkCall() async throws {
        let model = makeModel(transport: GatedTransport(inner: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"), gate: gate))
        let (player, engine) = makePlayer()
        model.attachPlayer(player)
        player.start(try await loadedItem(), at: 0)
        await model.waitForHandoff()

        await gate.hang()
        engine.currentTime = 55
        player.refreshPosition()
        Task { await model.sceneEnteredBackground() }
        try await eventually("the position to be saved on backgrounding") { storedPosition() == 55 }
    }

    // MARK: 2026-11-18, the episode that came back minutes behind

    /// A skip to the end while the seek is still being published: the next episode starts, takes playback
    /// over, and only then does the pause for the finished episode run. It must not pause the next one.
    func testALatePauseForTheFinishedEpisodeDoesNotPauseTheNextOne() async throws {
        let (secondID, secondFile) = try await addSecondEpisode()
        let model = makeModel(transport: phoneTransport())
        let (player, engine) = makePlayer()
        model.attachPlayer(player)
        player.start(try await loadedItem(), at: 0)
        await model.waitForHandoff()

        await gate.hang()
        engine.currentTime = 3_000
        player.refreshPosition()            // a seek: its publish now hangs at the gate
        await gate.waitUntilHeld()
        engine.currentTime = 3_001
        player.refreshPosition()            // one more sync waits behind it
        player.start(.init(entryID: secondID, title: "Second", showTitle: "Show", fileURL: secondFile), at: 0)
        await gate.release()
        await model.waitForHandoff()

        let record = try await phoneNowPlaying()
        XCTAssertEqual(record?.entryID, secondID)
        XCTAssertEqual(record?.isPlaying, true, "the finished episode's pause must not land on the next episode")
        XCTAssertEqual(model.handoffState.ownPositions[entryID]?.record.positionSeconds, 3_001, "the finished episode keeps its own position")
        player.stop()
    }

    /// Whatever silenced the session, a phone that is still playing takes playback over again at the
    /// next round rather than playing on with no checkpoints.
    func testAPlayingPhoneWhoseSessionWentQuietTakesOverAgain() async throws {
        let model = makeModel(transport: phoneTransport())
        let (player, _) = makePlayer()
        model.attachPlayer(player)
        player.start(try await loadedItem(), at: 0)
        await model.waitForHandoff()
        try await model.coordinator.paused(at: 5)
        let quiet = try await phoneNowPlaying()
        XCTAssertEqual(quiet?.isPlaying, false)

        await model.refresh()
        await model.waitForHandoff()
        let record = try await phoneNowPlaying()
        XCTAssertEqual(record?.isPlaying, true, "the round noticed nothing was published and took over again")
        player.stop()
    }

    /// A round read the server before the pause and applied its answer after it. That older copy of this
    /// phone's own position must not replace the pause.
    func testAnOlderPolledCopyDoesNotReplaceTheNewerPause() async throws {
        let answers = NetworkGate()
        addTeardownBlock { await answers.release() }
        let model = makeModel(transport: phoneTransport(answerGate: answers))
        let (player, engine) = makePlayer()
        model.attachPlayer(player)
        player.start(try await loadedItem(), at: 0)
        await model.waitForHandoff()
        engine.currentTime = 92
        await model.sceneEnteredBackground()   // the server now holds 92 s

        await answers.hang()
        let round = Task { await model.refresh() }
        await answers.waitUntilHeld()          // the round holds an answer that says 92 s
        engine.currentTime = 931
        player.pause()
        try await eventually("the pause to reach the phone's own store") { storedPosition() == 931 }
        await model.waitForHandoff()
        await model.republishUnpublishedPositions()
        XCTAssertNil(model.handoffState.unpublished[entryID], "the pause was published")
        await answers.release()
        await round.value

        XCTAssertEqual(model.resumeStart(for: entryID, cachedRevision: revisionID), 931, "the older polled copy must not win")
        XCTAssertEqual(storedPosition(), 931)
    }
}
