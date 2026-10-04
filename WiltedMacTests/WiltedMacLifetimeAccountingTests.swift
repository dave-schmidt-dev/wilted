import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac

/// The Producer's lifetime measures (Task 8.1a) driven from real Mac flows:
/// played time on a fake listening clock, manual skips from the Mac's own
/// seek and Next commands, and received bytes from an intake download.
@MainActor
final class WiltedMacLifetimeAccountingTests: XCTestCase {
    // MARK: Played time

    /// Play, pause, replay after a rewind and a rate change measure elapsed
    /// listening exactly; the quit drain admits it once, and neither a repeat
    /// drain nor a relaunch counts it again.
    func testPlayPauseReplayRateAndQuitDrainCountPlayedTimeOnceAcrossRelaunch() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("accounting-played"))
        let model = library.model
        let (backend, clock) = library.installScriptedPlayback(on: model)
        let episode = library.episodes[0]

        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(backend.isPlaying)
        clock.now += 5
        backend.currentTime = 120  // the audio advanced while playing
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        clock.now += 60  // paused time is not listening

        model.rewind()  // replayed audio counts again
        await model.waitForPlaybackOperationForTesting()
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(backend.isPlaying)
        clock.now += 3
        model.setPlaybackRate(2)  // played time is elapsed time, not media time
        await model.waitForPlaybackOperationForTesting()
        clock.now += 2

        try await model.drainLocalWorkForTermination()
        XCTAssertFalse(backend.isPlaying)
        try await library.assertTotals(played: 10_000, skipped: 0, "after the quit drain")
        clock.now += 30
        try await model.drainLocalWorkForTermination()
        try await library.assertTotals(played: 10_000, skipped: 0, "a repeat drain adds nothing")

        await model.close()
        let relaunched = library.relaunch()
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        try await library.assertTotals(played: 10_000, skipped: 0, "a relaunch counts nothing")
        try await relaunched.drainLocalWorkForTermination()
        try await library.assertTotals(played: 10_000, skipped: 0, "nor does the relaunched drain")
        await relaunched.close()
    }

    // MARK: Manual skips

    /// A Mac skip-forward counts its jump and a Mac Next counts the outgoing
    /// remainder, each once.
    func testMacForwardSeekAndNextCountAsManualSkips() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("accounting-skips"))
        let model = library.model
        let (backend, _) = library.installScriptedPlayback(on: model)
        try await library.loadPaused(library.episodes[0], at: 100, backend: backend)

        model.forward()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playback?.livePositionSeconds ?? 0, 130, accuracy: 0.001)
        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playback?.itemID?.rawValue, library.episodes[1].id, "Next moved on")

        try await model.drainLocalWorkForTermination()
        // 30 s forward, then the 600 - 130 s Next remainder.
        try await library.assertTotals(played: nil, skipped: 500_000, "forward seek plus Next")
        try await model.drainLocalWorkForTermination()
        try await library.assertTotals(played: nil, skipped: 500_000, "admitted once")
        await model.close()
    }

    /// A handoff position, a Feeds Skip of the loaded episode and an automatic
    /// advance move the player without counting; a manual seek afterwards
    /// still counts exactly, so the meter was live throughout. A handoff
    /// relinquish and a completion keep their played time exact.
    func testHandoffFeedsSkipAndAutoAdvanceNeverCountAsManualSkips() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("accounting-exclusions"))
        let model = library.model
        let (backend, clock) = library.installScriptedPlayback(on: model)
        try await library.loadPaused(library.episodes[0], at: 50, backend: backend)
        let playback = try XCTUnwrap(model.playback)

        // Handoff: the phone's newer position, applied to the loaded episode.
        let request = RemotePositionRequest(
            itemID: try XCTUnwrap(playback.itemID), revisionID: try XCTUnwrap(playback.revisionID),
            positionSeconds: 400, durationSeconds: 600, observedAt: Date().addingTimeInterval(5)
        )
        let outcome = await WiltedMacModelPositionImportHost(model: model).applyRemotePosition(request)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(playback.livePositionSeconds, 400, accuracy: 0.001, "the handoff moved the player")
        try await model.drainLocalWorkForTermination()
        try await library.assertTotals(played: 0, skipped: 0, "a handoff position is not a skip")
        model.resumeAfterCancelledTermination()

        // Another device takes over: the relinquish pause ends the played run.
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        clock.now += 4
        let audio = WiltedMacLocalReadyAudioSource(store: try XCTUnwrap(model.store))
        await WiltedMacModelHandoffPlayer(model: model, audio: audio).pauseAndCheckpoint()
        XCTAssertFalse(backend.isPlaying, "the relinquish paused")
        clock.now += 100

        // Automatic advance at the end of the first episode.
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        clock.now += 6
        backend.currentTime = 600
        backend.finish(successfully: true)
        try await waitFor { model.playback?.itemID?.rawValue == library.episodes[1].id }
        await model.waitForPlaybackOperationForTesting()
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()

        // Feeds Skip of the loaded, mid-position episode, a successor queued.
        backend.currentTime = 200
        let loaded = try XCTUnwrap(model.episodes.first { $0.id == library.episodes[1].id })
        model.decideFeedEpisodes(.skip, episodes: [loaded])
        await model.waitForPodcastOperations()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertNotNil(model.episodes.first { $0.id == loaded.id }?.retiredAt, "the Feeds Skip took effect")
        try await model.drainLocalWorkForTermination()
        try await library.assertTotals(played: 10_000, skipped: 0, "auto-advance and Feeds Skip are not skips")
        model.resumeAfterCancelledTermination()

        // The meter was live: a manual skip-forward still counts exactly.
        try await library.loadPaused(library.episodes[2], at: 10, backend: backend)
        model.forward()
        await model.waitForPlaybackOperationForTesting()
        try await model.drainLocalWorkForTermination()
        try await library.assertTotals(played: 10_000, skipped: 30_000, "the following manual seek counts")
        await model.close()
    }

    /// A restore resumes at the saved position without counting a skip, and
    /// the restored attempt still counts a manual seek. The saved position sits
    /// inside the 10 s fixture file, because the bootstrap's restore runs on the
    /// real backend, which clamps, and its drain checkpoints what it holds.
    func testRestoredPositionIsNotASkipAndTheRestoredAttemptStillCounts() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("accounting-restore"))
        let (backend, _) = library.installScriptedPlayback(on: library.model)
        try await library.loadPaused(library.episodes[0], at: 5, backend: backend)
        try await library.model.drainLocalWorkForTermination()
        await library.model.close()

        let relaunched = library.relaunch()
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        await relaunched.waitForPlaybackOperationForTesting()
        // The bootstrap's own restore loaded the saved episode; draining that
        // controller admits whatever its load metered.
        XCTAssertEqual(relaunched.playback?.itemID?.rawValue, library.episodes[0].id, "the bootstrap restored it")
        try await relaunched.drainLocalWorkForTermination()
        try await library.assertTotals(played: 0, skipped: 0, "the bootstrap restore is not a skip")
        relaunched.resumeAfterCancelledTermination()

        // The same resume through the owner, on a scripted backend.
        let (restoredBackend, _) = library.installScriptedPlayback(on: relaunched)
        let episode = try XCTUnwrap(relaunched.episodes.first { $0.id == library.episodes[0].id })
        relaunched.playEpisode(episode)
        await relaunched.waitForPlaybackOperationForTesting()
        relaunched.pausePlayback()
        await relaunched.waitForPlaybackOperationForTesting()
        XCTAssertEqual(restoredBackend.currentTime, 5, accuracy: 0.001, "resumed at the saved position")
        try await relaunched.drainLocalWorkForTermination()
        try await library.assertTotals(played: nil, skipped: 0, "resuming is not a skip")
        relaunched.resumeAfterCancelledTermination()

        relaunched.forward()
        await relaunched.waitForPlaybackOperationForTesting()
        try await relaunched.drainLocalWorkForTermination()
        try await library.assertTotals(played: nil, skipped: 30_000, "the restored attempt still counts")
        await relaunched.close()
    }

    // MARK: Received bytes

    /// An intake download's bytes land once per transfer, and a relaunch and
    /// its drain add nothing. A repeat Download request may or may not
    /// transfer again (today the Mac's `.notInFlight` claim clears the
    /// completed record), so the total is pinned to what the transport
    /// actually delivered. Cache reuse receiving zero bytes is covered at the
    /// coordinator in `PodcastDownloadCoordinatorTests`.
    func testIntakeDownloadBytesLandOncePerTransferAcrossRelaunch() async throws {
        let transport = AccountingDownloadTransport(chunks: [3_000, 4_000])
        let library = try await AccountingLibrary.make(
            in: wiltedTemporaryDirectory("accounting-bytes"), downloads: transport, readyCount: 0
        )
        let model = library.model
        let episode = try XCTUnwrap(model.episodes.first)

        model.downloadEpisode(episode)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.episodes.first { $0.id == episode.id }?.downloadState, .completed)
        try await library.assertBytes(7_000, "the transfer's bytes")

        let downloaded = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        model.downloadEpisode(downloaded)
        await model.waitForPodcastOperations()
        let transfers = Int64(transport.startCount)
        XCTAssertGreaterThanOrEqual(transfers, 1)
        try await library.assertBytes(7_000 * transfers, "each transfer's bytes, once")

        await model.close()
        let relaunched = library.relaunch()
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        try await relaunched.drainLocalWorkForTermination()
        try await library.assertBytes(7_000 * transfers, "a relaunch counts nothing")
        await relaunched.close()
    }

    private func waitFor(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition never held") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
final class FakeListeningClock {
    var now: TimeInterval = 1_000
}

/// One seeded library directory and the models launched over it. Only the
/// first launch seeds; a relaunch opens the same store as it is.
@MainActor
final class AccountingLibrary {
    let directory: URL
    let preferences: UserDefaults
    let downloads: AccountingDownloadTransport?
    private(set) var model: WiltedMacModel
    private(set) var episodes: [WiltedMacEpisode] = []

    private init(directory: URL, preferences: UserDefaults, downloads: AccountingDownloadTransport?, model: WiltedMacModel) {
        self.directory = directory
        self.preferences = preferences
        self.downloads = downloads
        self.model = model
    }

    static func make(
        in directory: URL, downloads: AccountingDownloadTransport? = nil, readyCount: Int = 3
    ) async throws -> AccountingLibrary {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/accounting.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let count = max(readyCount, 1)
        let enclosures = try (0..<count).map { try XCTUnwrap(URL(string: "https://media.example.test/accounting-\($0).mp3")) }
        let ids = try enclosures.enumerated().map { index, url in
            try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "accounting-\(index)", enclosureURL: url)
        }
        let preferences = WiltedMacTestPreferences.ephemeral()
        let library = AccountingLibrary(directory: directory, preferences: preferences, downloads: downloads, model: WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Accounting", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for index in 0..<count {
                    if index < readyCount {
                        try await WiltedMacModelTests.addReadyEpisode(
                            ids[index], guid: "accounting-\(index)", feedID: feedID, feedURL: feedURL,
                            enclosureURL: enclosures[index], publishedAt: created.date.addingTimeInterval(Double(index) * 60),
                            directory: directory, store: store, created: created
                        )
                    } else {
                        try await store.save(episode: try PodcastEpisode(
                            itemID: ids[index], feedID: feedID, feedURL: feedURL, rssGUID: "accounting-\(index)",
                            title: "Episode \(index)", publishedTime: created, enclosureURL: enclosures[index],
                            enclosureMediaType: "audio/mpeg", createdAt: created
                        ))
                    }
                }
                if readyCount > 0 {
                    try await store.replacePodcastQueue(try PodcastQueueState(
                        episodeIDs: Array(ids.prefix(readyCount)), currentEpisodeID: ids[0]
                    ))
                }
                return store
            },
            podcastDownloadTransportFactory: Self.factory(for: downloads),
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: preferences
        ))
        library.model.startStoreBootstrap()
        await library.model.waitForStoreBootstrap()
        library.episodes = try ids.map { id in try XCTUnwrap(library.model.episodes.first { $0.id == id.rawValue }) }
        return library
    }

    private static func factory(for downloads: AccountingDownloadTransport?) -> WiltedMacPodcastDownloadTransportFactory? {
        guard let downloads else { return nil }
        return { downloads }
    }

    func relaunch() -> WiltedMacModel {
        let downloads = self.downloads
        model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { try LocalLibraryStore(url: $0) },
            podcastDownloadTransportFactory: Self.factory(for: downloads),
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: preferences
        )
        return model
    }

    /// A scripted backend (600 s, no clock of its own) and a fake listening
    /// clock, installed on the model's current controller.
    func installScriptedPlayback(on model: WiltedMacModel) -> (WiltedMacScriptedBackend, FakeListeningClock) {
        let backend = WiltedMacScriptedBackend()
        let clock = FakeListeningClock()
        model.installPlaybackBackendForTesting(backend)
        model.playback?.listeningClock = { clock.now }
        return (backend, clock)
    }

    /// Plays `episode` through the owner, pauses it, then parks the audio at
    /// `position` as if it had played there.
    func loadPaused(_ episode: WiltedMacEpisode, at position: TimeInterval, backend: WiltedMacScriptedBackend) async throws {
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playback?.itemID?.rawValue, episode.id)
        backend.currentTime = position
    }

    func assertTotals(played: Int64?, skipped: Int64?, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let totals = try await measuredTotals()
        if let played { XCTAssertEqual(totals.playedMilliseconds, played, "played: \(message)", file: file, line: line) }
        if let skipped {
            XCTAssertEqual(totals.manuallySkippedMilliseconds, skipped, "skipped: \(message)", file: file, line: line)
        }
    }

    func assertBytes(_ bytes: Int64, _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let totals = try await measuredTotals()
        XCTAssertEqual(totals.receivedBytes, bytes, message, file: file, line: line)
    }

    private func measuredTotals() async throws -> LifetimeMeasuredTotals {
        let store = try XCTUnwrap(model.store, "the model's store is open")
        return try await store.lifetimeStatisticsSummary().measured
    }
}

/// Delivers fixed chunks and finishes, counting transfers started.
final class AccountingDownloadTransport: PodcastDownloadTransporting, @unchecked Sendable {
    private let chunks: [Int]
    private let lock = NSLock()
    private var starts = 0

    init(chunks: [Int]) { self.chunks = chunks }

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        lock.lock(); starts += 1; lock.unlock()
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: url, statusCode: 200, mediaType: "audio/mpeg",
                                               expectedByteCount: Int64(chunks.reduce(0, +)))))
            for size in chunks { continuation.yield(.data(Data(repeating: 0x41, count: size))) }
            continuation.finish()
        }
    }
}
