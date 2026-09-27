import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    /// In production, `PlaybackController`'s own `podcastCompletionHandler`
    /// retires the finished episode before `handlePodcastPlaybackFinished`
    /// ever runs its successor search -- the two fire from separate places in
    /// `handleBackendCompletion`, and the retirement's single store hop wins
    /// the race against the handler's own multi-hop reload. This test forces
    /// that ordering directly (retiring the episode between "reached end" and
    /// "finished") so the successor search has to find its anchor even though
    /// the anchor is already hidden and retired by the time it looks.
    func testFinishedEpisodeAdvancesEvenWhenItIsAlreadyRetiredBeforeTheSearchRuns() async throws {
        let directory = temporaryDirectory("continue-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-race.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-race-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-race-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-race-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-race-2", enclosureURL: secondEnclosure
        )

        let storeCapture = StoreCapture()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Racing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-race-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-race-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                await storeCapture.capture(store)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        let capturedStore = await storeCapture.store
        let store = try XCTUnwrap(capturedStore)
        _ = try await store.retireEpisode(firstID)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue,
                       "the search has to find its own anchor even though retirement already ran first")
    }

    /// The undownloaded middle episode is never a candidate; the search has
    /// to keep going past it rather than stopping at the first row after the
    /// one that finished.
    func testNaturalCompletionSkipsAnUndownloadedEpisodeToReachTheNextReadyOne() async throws {
        let directory = temporaryDirectory("continue-skip")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-skip.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Skipping", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-skip-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addUndownloadedEpisode(
                    secondID, guid: "continue-skip-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "continue-skip-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: thirdEnclosure, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "an undownloaded episode in between has to be skipped, not offered")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue },
                                     "retirement is not dismissal -- the finished episode's row survives")
        XCTAssertNotNil(finished.retiredAt)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == firstID.rawValue },
                       "the episode that finished is taken off the shelf")
        let skipped = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertNil(skipped.retiredAt, "the one merely passed over is not -- it was never listened to")
    }

    /// The downloaded but unprepared middle episode must also be skipped
    /// in natural-completion continuation.
    func testNaturalCompletionSkipsAnUnpreparedEpisodeToReachTheNextReadyOne() async throws {
        let directory = temporaryDirectory("continue-skip-unprepared")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-skip-unprepared.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-unprepared-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-unprepared-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-unprepared-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-unprepared-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-unprepared-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-unprepared-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Skipping Unprepared", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-skip-unprepared-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addDownloadedUnpreparedEpisode(
                    secondID, guid: "continue-skip-unprepared-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "continue-skip-unprepared-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: thirdEnclosure, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "an unprepared episode in between has to be skipped in favor of the next ready one")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue },
                                     "retirement is not dismissal -- the finished episode's row survives")
        XCTAssertNotNil(finished.retiredAt)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == firstID.rawValue },
                       "the episode that finished is taken off the shelf")
        let skipped = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertNil(skipped.retiredAt, "the one merely passed over is not -- it was never listened to")
    }

    /// Nothing else in the Larder is ready, so playback has to stop and the
    /// operation message has to say why -- silence with no explanation reads
    /// as a stall, not as "nothing to play."
    func testNaturalCompletionWithNoReadyEpisodeLeftStopsAndSaysSo() async throws {
        let directory = temporaryDirectory("continue-none")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-none.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let onlyEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-none-1.mp3"))
        let onlyID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-none-1", enclosureURL: onlyEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Alone", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    onlyID, guid: "continue-none-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: onlyEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let only = try XCTUnwrap(model.episodes.first { $0.id == onlyID.rawValue })
        model.playEpisode(only)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        // Retiring what was playing empties the player, the same as taking it off
        // the shelf by hand does; there is no episode left to show.
        XCTAssertNil(model.currentEpisode, "the finished episode was retired and nothing replaced it")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == onlyID.rawValue },
                                     "retirement is not dismissal -- the row survives")
        XCTAssertNotNil(finished.retiredAt)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == onlyID.rawValue })
        XCTAssertEqual(model.podcastOperationMessage,
                       "Finished \(only.title). No other downloaded, prepared episode is ready to play next.")
    }

    /// The handler is podcast-specific; an article running out must not go
    /// looking through the Larder at all.
    func testArticleCompletionDoesNotSearchForANextPodcastEpisode() {
        let directory = temporaryDirectory("continue-article")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let article = WiltedMacArticle(
            id: "article-1", title: "A Long Read", source: "example.com",
            url: URL(string: "https://example.com/read")!, isReady: true,
            durationSeconds: 300, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        model.installPlaybackStateForTesting(article: article, isPlaying: true, position: 300, duration: 300)

        model.simulatePodcastPlaybackFinishedForTesting()

        XCTAssertNil(model.podcastOperationMessage, "an article finishing has nothing to do with the podcast queue")
    }

    /// `applyPodcastPlaybackObservation` also covers `PlaybackController`'s
    /// own within-queue advance, which already wrote the outgoing episode's
    /// completed record before this fires; the in-memory Larder rows would
    /// otherwise not know until something else happened to reload them.
    func testMovingToAnotherPodcastEpisodeRefreshesTheLibraryRows() async throws {
        let directory = temporaryDirectory("continue-move-reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-move.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-move-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-move-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-move-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-move-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Moving", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-move-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-move-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        try await settle(model)

        let phantom = WiltedMacEpisode(
            id: "phantom-episode", title: "Not really in the store", feedTitle: "Moving",
            summary: "", artworkURL: nil, releasedAt: created.date, durationSeconds: 60,
            playbackSeconds: 0, downloadState: .completed
        )
        model.installEpisodeForTesting(phantom)
        XCTAssertTrue(model.episodes.contains { $0.id == phantom.id })

        model.applyPodcastPlaybackObservationForTesting(itemID: secondID, fault: nil)
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue)
        XCTAssertFalse(model.episodes.contains { $0.id == phantom.id },
                       "moving to another episode has to reload the Larder from the store, not keep stale rows")
    }

    /// Pure enumeration logic, but it is the one line that decides whether an
    /// episode still preparing or one that failed can be handed to
    /// continuous playback, so it earns its own direct check.
    func testEpisodePreparationStateReportsWhetherItIsPrepared() {
        XCTAssertTrue(WiltedMacEpisodePreparationState.prepared(summary: "Ready").isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.notPrepared.isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.preparing(stage: "Preparing…").isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.failed("Failed").isPrepared)
    }

}
