import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedListener
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
        let file = scratch.appendingPathComponent("incoming.mp4")
        try payload.write(to: file)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let offer = try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash, byteCount: Int64(payload.count),
            mediaType: "audio/mp4", durationSeconds: 3_600)
        _ = try await cache.adopt(verifiedFile: file, for: offer)
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
        func hang() { hanging = true }
        func release() {
            hanging = false
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
        func passThrough() async {
            guard hanging else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private struct GatedTransport: LibraryTransport {
        let inner: InMemoryLibraryTransport
        let gate: NetworkGate
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
            return try await inner.poll(options)
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
        func uninstall() {}
    }

    @MainActor private final class FakeEvents: LibrarySessionEvents {
        func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
    }

    // MARK: fixtures

    /// Holds exactly the first cache lookup so a local save can be overtaken deterministically.
    private actor GatedCache: LibraryMediaCache {
        let entries: [ItemID: CachedMedia]
        private var first = true
        private var pending: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        init(entries: [ItemID: CachedMedia]) { self.entries = entries }
        func cachedEntries() async -> [ItemID: CachedMedia] {
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
        func cachedFile(for offer: LibraryMediaOffer) async -> URL? { entries[offer.entryID]?.url }
        func adopt(verifiedFile: URL, for offer: LibraryMediaOffer) async throws -> URL { verifiedFile }
        func remove(entryID: ItemID) async throws {}
        func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? { nil }
        func storeTranscript(_ transcript: LibraryTranscript) async {}
    }

    private func makeModel(transport: any LibraryTransport, mediaCache: (any LibraryMediaCache)? = nil) -> LibraryAppModel {
        let suite = "wilted.resume.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LibraryAppModel(
            transport: transport, deviceID: "phone", mediaCache: mediaCache ?? cache,
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

    private func storedPosition() -> Double? {
        LibraryOwnPositionStore(url: positionsURL).load().positions[entryID]?.record.positionSeconds
    }

    // MARK: tests

    func testDifferentEpisodeDoesNotDiscardPendingLocalSave() async throws {
        let secondID = try ItemID(rawValue: "item-b")
        let cached = await cache.cachedEntries()
        let media = try XCTUnwrap(cached[entryID])
        let gated = GatedCache(entries: [entryID: media, secondID: media])
        let model = makeModel(transport: UnavailableLibraryTransport(reason: "no signal"), mediaCache: gated)
        let (player, _) = makePlayer()
        // Wire only the local-save seam: unrelated player handoff tasks cannot consume the gate.
        model.handoffState.player = player
        player.start(try await loadedItem(), at: 0)
        let pending = try XCTUnwrap(model.saveLoadedPositionLocally(123))
        await gated.waitUntilBlocked()
        player.start(.init(entryID: secondID, title: "Second", showTitle: "Show", fileURL: media.url), at: 0)
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
        let gated = GatedCache(entries: entries)
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
        let model = makeModel(transport: GatedTransport(inner: InMemoryLibraryTransport(deviceID: "phone", server: server), gate: gate))
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
        let online = await coldLaunch(transport: InMemoryLibraryTransport(deviceID: "phone", server: server))
        await online.refresh()
        XCTAssertEqual(online.resumeStart(for: entryID, cachedRevision: revisionID), 1_234, "the saved position outranks the older server copy")
    }

    func testAKillDuringPlaybackLosesAtMostTheLastFewSeconds() async throws {
        let model = makeModel(transport: GatedTransport(inner: InMemoryLibraryTransport(deviceID: "phone", server: server), gate: gate))
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
        let model = makeModel(transport: GatedTransport(inner: InMemoryLibraryTransport(deviceID: "phone", server: server), gate: gate))
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
}
