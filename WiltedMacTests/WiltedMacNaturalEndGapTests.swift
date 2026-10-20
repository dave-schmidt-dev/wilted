import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The gap between one podcast running out and the next one starting.
///
/// The owner heard 5 to 10 seconds of silence after a natural end and almost
/// none after Mark completed. Every rig here seeds episodes 19 to 21, queues
/// all three, starts 19 from the Larder and ends it through the controller's
/// own completion callback, the path a real end of file takes. The backend
/// timestamps each `play()`, so a gap is measured from end of file to the
/// moment the successor's audio was asked to start.
@MainActor
final class WiltedMacNaturalEndGapTests: XCTestCase {
    /// One slow library reload, the cost the natural end used to pay up to
    /// three times before the successor could start.
    private static let reloadDelay: Duration = .milliseconds(300)

    @MainActor struct Rig {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let ids: [Int: ItemID]
        let backend: WiltedMacStartRecordingBackend
        let directory: URL
        func id(_ number: Int) -> String { ids[number]!.rawValue }
        func episode(_ number: Int) throws -> WiltedMacEpisode {
            try XCTUnwrap(model.episodes.first { $0.id == id(number) })
        }
    }

    // MARK: - Measurement

    /// Every library reload is made slow. The successor must start sooner than
    /// one reload takes: nothing the natural end owes the library may run
    /// ahead of the audio.
    func testNaturalEndStartsTheNextEpisodeSoonerThanOneSlowReload() async throws {
        let rig = try await makeRig("gap-measure")
        try await startLarder(rig, at: 19)
        rig.model.librarySnapshotReadBarrierForTesting = { try? await Task.sleep(for: Self.reloadDelay) }
        defer { rig.model.librarySnapshotReadBarrierForTesting = nil }

        let startsBefore = rig.backend.starts.count
        let reachedEnd = endOfFile(rig)
        let started = await waitForStart(rig, after: startsBefore, timeout: .seconds(10))
        let gap = try XCTUnwrap(started, "the successor never started") - reachedEnd
        print("natural-end.gap ms=\(gap.components.seconds * 1_000 + gap.components.attoseconds / 1_000_000_000_000_000)"
              + " reload_delay_ms=300")
        XCTAssertLessThan(gap, Self.reloadDelay, "end of file to the successor's start waited on a library reload")

        await rig.model.waitForPlaybackOperationForTesting()
        try await settle()
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(20))
        let finished = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[19]))
        XCTAssertEqual(finished, .retired, "the finished episode is still retired, after the start")
        await rig.model.close()
    }

    // MARK: - Regression

    /// Every library reload blocks until the test releases it. The successor
    /// starts while they are held, and no reload began before it started.
    func testNaturalEndStartsTheSuccessorWhileEveryLibraryReloadIsHeld() async throws {
        let rig = try await makeRig("gap-held-reload")
        try await startLarder(rig, at: 19)
        var decisions: [String] = []
        WiltedMacModel.advanceDecisionLogObserverForTesting = { decisions.append($0) }
        defer { WiltedMacModel.advanceDecisionLogObserverForTesting = nil }
        let gate = ReloadGate()
        rig.model.librarySnapshotReadBarrierForTesting = { await gate.hold() }

        let startsBefore = rig.backend.starts.count
        _ = endOfFile(rig)
        let started = await waitForStart(rig, after: startsBefore, timeout: .seconds(3))
        let reloadsBeforeStart = await gate.arrivalsBefore(started)
        await gate.releaseAll()
        rig.model.librarySnapshotReadBarrierForTesting = nil

        XCTAssertNotNil(started, "the successor must start while library reloads are held")
        XCTAssertEqual(reloadsBeforeStart, 0, "no library reload may begin ahead of the successor's start")
        await rig.model.waitForPlaybackOperationForTesting()
        try await settle()

        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(20), "the first Ready row after 19 plays")
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertTrue(decisions.contains { $0.hasPrefix("advance.decision chosen=\(rig.id(20)) reason=first_ready_row ") })
        let finishedKind = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[19]))
        XCTAssertEqual(finishedKind, .retired, "the queued retirement ran once the reloads were released")
        XCTAssertFalse(rig.model.larderVisibleEpisodes.contains { $0.id == rig.id(19) }, "and 19 left the shelf")
        let queue = try await rig.store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID, rig.ids[20])
        XCTAssertFalse(queue.episodeIDs.contains(try XCTUnwrap(rig.ids[19])), "19 left the durable queue")
        XCTAssertEqual(rig.model.podcastOperationMessage, "Finished \(try rig.episode(19).title).")
        await rig.model.close()
    }

    // MARK: - Durability

    /// A normal quit right after the successor starts, while the retirement is
    /// still queued behind it: the quit drain waits for that job, and a
    /// reopened store has the finished episode completed and retired.
    func testQuitRightAfterTheSuccessorStartsStillRetiresTheFinishedEpisode() async throws {
        let rig = try await makeRig("gap-quit")
        try await startLarder(rig, at: 19)
        let lane = ReloadGate()
        rig.model.libraryFollowUps.beforeEachForTesting = { await lane.hold() }
        let finishedID = try XCTUnwrap(rig.ids[19])

        let startsBefore = rig.backend.starts.count
        _ = endOfFile(rig)
        let started = await waitForStart(rig, after: startsBefore, timeout: .seconds(3))
        XCTAssertNotNil(started, "the successor starts while the follow-up lane is held")
        let queuedKind = try await rig.store.removalKind(for: finishedID)
        XCTAssertNotEqual(queuedKind, .retired, "the retirement is still queued behind the start")

        let quit = QuitProbe()
        let drain = Task { @MainActor in
            try await rig.model.drainLocalWorkForTermination()
            quit.finished = true
        }
        try await settle(iterations: 10)
        XCTAssertFalse(quit.finished, "the quit drain waits for the queued retirement")
        await lane.releaseAll()
        try await drain.value
        rig.model.libraryFollowUps.beforeEachForTesting = nil
        await rig.model.close()

        let reopened = try LocalLibraryStore(url: rig.directory.appendingPathComponent("library.sqlite"))
        let kind = try await reopened.removalKind(for: finishedID)
        XCTAssertEqual(kind, .retired)
        let listening = try await reopened.listeningState(for: finishedID)
        XCTAssertNotNil(listening?.completedAt, "the completion was saved before the start")
        let queue = try await reopened.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID, rig.ids[20])
        XCTAssertFalse(queue.episodeIDs.contains(finishedID))
    }

    /// The controller drops the natural-end handler uncalled when a newer load
    /// lands after it saved the completion. The completion handler no longer
    /// retires a pending natural end itself, so releasing the handler must.
    func testADroppedNaturalEndHandlerStillRetiresTheFinishedEpisode() async throws {
        let rig = try await makeRig("gap-dropped")
        try await startLarder(rig, at: 19)
        let playback = try XCTUnwrap(rig.model.playback)
        let finishedID = try XCTUnwrap(rig.ids[19])

        var handler = playback.podcastNaturalCompletionHandlerFactory?(finishedID)
        XCTAssertNotNil(handler, "a Larder podcast end gets a natural-end handler")
        playback.podcastCompletionHandler?(finishedID)
        await rig.model.waitForPlaybackOperationForTesting()
        let pendingKind = try await rig.store.removalKind(for: finishedID)
        XCTAssertNotEqual(pendingKind, .retired, "the pending natural end owns the retirement")

        handler = nil
        try await settle(iterations: 4)
        await rig.model.waitForPlaybackOperationForTesting()
        let kind = try await rig.store.removalKind(for: finishedID)
        XCTAssertEqual(kind, .retired, "the released handler queued the retirement")
        await rig.model.close()
    }

    /// A quit after the completion was saved but before the continuation took
    /// the retirement: the drain queues and waits for it itself.
    func testQuitBeforeTheContinuationRunsStillRetiresTheFinishedEpisode() async throws {
        let rig = try await makeRig("gap-quit-pending")
        try await startLarder(rig, at: 19)
        let playback = try XCTUnwrap(rig.model.playback)
        let finishedID = try XCTUnwrap(rig.ids[19])

        let handler = playback.podcastNaturalCompletionHandlerFactory?(finishedID)
        playback.podcastCompletionHandler?(finishedID)
        try await rig.model.drainLocalWorkForTermination()
        let kind = try await rig.store.removalKind(for: finishedID)
        XCTAssertEqual(kind, .retired, "the quit drain retired the pending natural end")
        withExtendedLifetime(handler) {}
        await rig.model.close()
    }

    // MARK: - Rig

    private func makeRig(_ name: String) async throws -> Rig {
        let directory = wiltedTemporaryDirectory(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/\(name).xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        var ids: [Int: ItemID] = [:]
        var enclosures: [Int: URL] = [:]
        for number in 19...21 {
            let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/\(name)-\(number).mp3"))
            enclosures[number] = enclosure
            ids[number] = try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "\(name)-\(number)", enclosureURL: enclosure)
        }
        let queue = try (19...21).map { try XCTUnwrap(ids[$0]) }
        let seededIDs = ids, seededEnclosures = enclosures
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, storeBootstrap: { url in
            let store = try LocalLibraryStore(url: url)
            try await store.save(feed: try PodcastFeed(
                itemID: feedID, canonicalURL: feedURL, title: "Gap", createdAt: created))
            try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
            for number in 19...21 {
                try await WiltedMacModelTests.addReadyEpisode(
                    seededIDs[number]!, guid: "\(name)-\(number)", feedID: feedID, feedURL: feedURL,
                    enclosureURL: seededEnclosures[number]!, publishedAt: created.date.addingTimeInterval(Double(number) * 60),
                    directory: directory, store: store, created: created)
            }
            try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: queue, currentEpisodeID: queue.first))
            return store
        }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        try await settle()
        let backend = WiltedMacStartRecordingBackend()
        model.installPlaybackBackendForTesting(backend)
        return Rig(model: model, store: try XCTUnwrap(model.store), ids: ids, backend: backend, directory: directory)
    }

    /// A Larder-origin start of `number`, so the natural end follows the Ready rows.
    private func startLarder(_ rig: Rig, at number: Int) async throws {
        rig.model.playLarderEpisode(try rig.episode(number))
        await rig.model.waitForPlaybackOperationForTesting()
        try await settle()
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(number))
        XCTAssertTrue(rig.backend.isPlaying)
    }

    /// End of file on the loaded generation, through the controller's own callback.
    private func endOfFile(_ rig: Rig) -> ContinuousClock.Instant {
        let completion = rig.backend.completionHandler
        let generation = rig.backend.loadedGeneration
        rig.backend.pause()
        let reachedEnd = ContinuousClock.now
        completion?(generation, true)
        return reachedEnd
    }

    /// The instant of the first `play()` after `count`, or nil after `timeout`.
    private func waitForStart(
        _ rig: Rig, after count: Int, timeout: Duration
    ) async -> ContinuousClock.Instant? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if rig.backend.starts.count > count { return rig.backend.starts[count] }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return rig.backend.starts.count > count ? rig.backend.starts[count] : nil
    }

    private func settle(iterations: Int = 60) async throws {
        for _ in 0..<iterations {
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// The scripted fixture backend, with the instant of every `play()` recorded.
@MainActor
final class WiltedMacStartRecordingBackend: PlaybackBackend {
    private let inner = WiltedFixturePlaybackBackend()
    private(set) var starts: [ContinuousClock.Instant] = []

    var duration: TimeInterval { inner.duration }
    var currentTime: TimeInterval {
        get { inner.currentTime }
        set { inner.currentTime = newValue }
    }
    var isPlaying: Bool { inner.isPlaying }
    var rate: Float {
        get { inner.rate }
        set { inner.rate = newValue }
    }
    var volume: Float {
        get { inner.volume }
        set { inner.volume = newValue }
    }
    var loadedGeneration: UInt64 { inner.loadedGeneration }
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)? {
        get { inner.completionHandler }
        set { inner.completionHandler = newValue }
    }

    func load(url: URL) throws { try inner.load(url: url) }
    @discardableResult func play() -> Bool {
        starts.append(.now)
        return inner.play()
    }
    func pause() { inner.pause() }
    func stop() { inner.stop() }
}

/// Whether a quit drain running in its own task has returned.
@MainActor
private final class QuitProbe {
    var finished = false
}

/// Holds every library reload (or follow-up job) until released, and records when each arrived.
private actor ReloadGate {
    private var arrivals: [ContinuousClock.Instant] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func hold() async {
        arrivals.append(.now)
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Reloads that arrived before `instant`; every arrival when it is nil.
    func arrivalsBefore(_ instant: ContinuousClock.Instant?) -> Int {
        guard let instant else { return arrivals.count }
        return arrivals.filter { $0 < instant }.count
    }

    func releaseAll() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
