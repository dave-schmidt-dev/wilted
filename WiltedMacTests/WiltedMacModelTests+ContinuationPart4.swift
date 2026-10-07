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
                try await store.replacePodcastQueue(PodcastQueueState(
                    episodeIDs: [firstID, secondID], currentEpisodeID: firstID
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        do {
            model.startStoreBootstrap()
            await model.waitForStoreBootstrap()

            let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
            model.playEpisode(first)
            await model.waitForPlaybackOperationForTesting()
            try await settle(model)

            let phantom = WiltedMacEpisode(
                id: "phantom-episode", title: "Not really in the store", feedTitle: "Moving",
                summary: "", artworkURL: nil, releasedAt: created.date, durationSeconds: 60,
                playbackSeconds: 0, downloadState: .completed
            )
            model.installEpisodeForTesting(phantom)
            XCTAssertTrue(model.episodes.contains { $0.id == phantom.id })

            let playback = try XCTUnwrap(model.playback)
            let advanced = try await playback.selectNextPodcastQueueEpisode(autoplay: true)
            XCTAssertTrue(advanced, "the real controller advances through the seeded queue")
            try await settle(model)

            XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue)
            XCTAssertFalse(model.episodes.contains { $0.id == phantom.id },
                           "moving to another episode has to reload the Larder from the store, not keep stale rows")
        } catch {
            await model.close()
            throw error
        }
        await model.close()
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

    /// Manually starting a middle episode in the Larder preserves queue order and
    /// checkpoints the outgoing current episode's position, then natural completions
    /// advance through the remainder of the queue and stop cleanly at the end without
    /// wrapping backwards to restart earlier unfinished episodes.
    func testManualLarderStartAdvancesThroughLaterEpisodesAndStopsWithoutRestartingEarlierUnfinished() async throws {
        let directory = temporaryDirectory("continue-larder-advance")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-larder.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enc18 = try XCTUnwrap(URL(string: "https://media.example.test/continue-larder-18.mp3"))
        let enc19 = try XCTUnwrap(URL(string: "https://media.example.test/continue-larder-19.mp3"))
        let enc20 = try XCTUnwrap(URL(string: "https://media.example.test/continue-larder-20.mp3"))
        let enc21 = try XCTUnwrap(URL(string: "https://media.example.test/continue-larder-21.mp3"))
        let id18 = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "larder-18", enclosureURL: enc18)
        let id19 = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "larder-19", enclosureURL: enc19)
        let id20 = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "larder-20", enclosureURL: enc20)
        let id21 = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "larder-21", enclosureURL: enc21)

        let storeCapture = StoreCapture()
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Larder Advance", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    id18, guid: "larder-18", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enc18, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    id19, guid: "larder-19", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enc19, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    id20, guid: "larder-20", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enc20, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    id21, guid: "larder-21", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enc21, publishedAt: created.date.addingTimeInterval(180),
                    directory: directory, store: store, created: created
                )
                try await store.replacePodcastQueue(PodcastQueueState(
                    episodeIDs: [id18, id19, id20, id21],
                    currentEpisodeID: id18
                ))
                await storeCapture.capture(store)
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        try await settle(model)

        let ep18 = try XCTUnwrap(model.episodes.first { $0.id == id18.rawValue })
        model.playEpisode(ep18)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        await model.seekPlaybackForTesting(to: 4)
        try await settle(model)
        XCTAssertEqual(model.currentPodcastEpisodeID, id18.rawValue)

        let ep19 = try XCTUnwrap(model.episodes.first { $0.id == id19.rawValue })
        model.playLarderEpisode(ep19)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentPodcastEpisodeID, id19.rawValue)
        XCTAssertEqual(model.podcastQueueIDs, [id18.rawValue, id19.rawValue, id20.rawValue, id21.rawValue])
        let capturedStore = await storeCapture.store
        let storedStore = try XCTUnwrap(capturedStore)
        let readyRevision = try await storedStore.readyRevision(for: id18)
        let ep18Rev = try XCTUnwrap(readyRevision)
        let ep18Playback = try await storedStore.playbackState(for: id18, revisionID: ep18Rev.revision.revisionID)
        let storedPlayback = try XCTUnwrap(ep18Playback)
        // The muted real player clock can advance slightly before handoff.
        XCTAssertEqual(storedPlayback.positionSeconds, 4, accuracy: 0.5,
                       "outgoing loaded current position was checkpointed")
        XCTAssertFalse(storedPlayback.completed, "18 was not completed")

        try finishLoadedPodcastSuccessfully(model)
        try await settle(model)
        XCTAssertEqual(model.currentPodcastEpisodeID, id20.rawValue, "natural completion of 19 advances forward to 20")

        try finishLoadedPodcastSuccessfully(model)
        try await settle(model)
        XCTAssertEqual(model.currentPodcastEpisodeID, id21.rawValue, "natural completion of 20 advances forward to 21")

        try finishLoadedPodcastSuccessfully(model)
        try await settle(model)
        XCTAssertFalse(model.isPlaying, "playback stops after the last episode in queue")
        XCTAssertNotEqual(model.currentPodcastEpisodeID, id18.rawValue, "earlier unfinished episode 18 is never restarted")
    }

    /// A Larder-origin session is bounded by its own durable queue. With the
    /// Feeds sort left at its default -- newest-first, the opposite of this
    /// queue's order -- finishing the queue's last episode must stop there
    /// rather than wrap back to the earlier unfinished episodes the default
    /// sort places after it, while a generic Play keeps that Larder-wide
    /// fallback.
    func testLarderQueueEndStopsUnderTheDefaultFeedsSortAndGenericPlayKeepsTheLarderFallback() async throws {
        let directory = temporaryDirectory("continue-larder-default-sort")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-larder-default.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosures = try (17...21).map { number in
            try XCTUnwrap(URL(string: "https://media.example.test/continue-larder-default-\(number).mp3"))
        }
        let ids = try (17...21).map { number in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "larder-default-\(number)",
                enclosureURL: enclosures[number - 17]
            )
        }

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Larder Default", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, id) in ids.enumerated() {
                    try await Self.addReadyEpisode(
                        id, guid: "larder-default-\(index + 17)", feedID: feedID, feedURL: feedURL,
                        enclosureURL: enclosures[index],
                        publishedAt: created.date.addingTimeInterval(Double(index) * 60),
                        directory: directory, store: store, created: created
                    )
                }
                // 17 is ready but never queued: the queue holds 18 through 21.
                try await store.replacePodcastQueue(PodcastQueueState(
                    episodeIDs: [ids[1], ids[2], ids[3], ids[4]],
                    currentEpisodeID: ids[1]
                ))
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        try await settle(model)

        // The Feeds sort stays at its default, and that default orders the
        // shelf opposite to the queue: the earlier unfinished episodes sort
        // after the queue's last one, which is exactly the wrap a
        // queue-origin session must not take.
        XCTAssertEqual(model.feedsSort, .newest, "the Feeds sort is left at its default")
        let shelfOrder = WiltedMacModel.sortedLarderEpisodes(model.episodes, by: model.feedsSort).map(\.id)
        XCTAssertEqual(shelfOrder, [ids[4].rawValue, ids[3].rawValue, ids[2].rawValue, ids[1].rawValue, ids[0].rawValue])
        XCTAssertNotEqual(shelfOrder, model.podcastQueueIDs,
                          "the default Feeds sort and the durable queue disagree about order")

        let ep18 = try XCTUnwrap(model.episodes.first { $0.id == ids[1].rawValue })
        model.playEpisode(ep18)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        await model.seekPlaybackForTesting(to: 4)
        try await settle(model)

        let ep19 = try XCTUnwrap(model.episodes.first { $0.id == ids[2].rawValue })
        model.playLarderEpisode(ep19)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.podcastQueueIDs, [ids[1].rawValue, ids[2].rawValue, ids[3].rawValue, ids[4].rawValue])

        try finishLoadedPodcastSuccessfully(model)
        try await settle(model)
        XCTAssertEqual(model.currentPodcastEpisodeID, ids[3].rawValue, "natural completion of 19 advances forward to 20")
        try finishLoadedPodcastSuccessfully(model)
        try await settle(model)
        XCTAssertEqual(model.currentPodcastEpisodeID, ids[4].rawValue, "natural completion of 20 advances forward to 21")
        try finishLoadedPodcastSuccessfully(model)
        try await settle(model)

        XCTAssertFalse(model.isPlaying, "a queue-origin session stops at the queue's end")
        XCTAssertNil(model.currentPodcastEpisodeID,
                     "the earlier unfinished episodes the default sort places after 21 are never restarted")
        let finished21 = try XCTUnwrap(model.episodes.first { $0.id == ids[4].rawValue })
        XCTAssertTrue(finished21.isPlayed, "the queue's last episode is still durably completed")
        XCTAssertNotNil(finished21.retiredAt, "and still retired off the shelf")
        let unfinished18 = try XCTUnwrap(model.episodes.first { $0.id == ids[1].rawValue })
        XCTAssertFalse(unfinished18.isPlayed, "the earlier episode stays unfinished")
        XCTAssertEqual(unfinished18.playbackSeconds, 4, accuracy: 0.5,
                       "its saved position survives the whole queue session")
        XCTAssertEqual(model.podcastOperationMessage,
                       "Finished Episode larder-default-21. The Larder queue reached its end.")

        // A generic Play keeps the Larder-wide fallback. 17 was never in the
        // queue and the default sort places it after 18, so finishing a
        // generic play of 18 has to reach it -- the same wrap the queue-origin
        // session above correctly refused to take.
        model.playEpisode(unfinished18)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        try finishLoadedPodcastSuccessfully(model)
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, ids[0].rawValue,
                       "a generic play still continues across the Larder when its own queue run ends")
    }

    /// Emulates successful EOF through the loaded backend's controller callback.
    private func finishLoadedPodcastSuccessfully(_ model: WiltedMacModel) throws {
        let backend = try XCTUnwrap(model.playback).backend
        let completion = try XCTUnwrap(backend.completionHandler)
        let generation = backend.loadedGeneration
        XCTAssertGreaterThan(generation, 0, "a media generation must be loaded before EOF")
        backend.pause()
        completion(generation, true)
    }

    func testLegacyGenericQueueRestoreKeepsTheLarderWideFallback() async throws {
        let directory = temporaryDirectory("continue-origin-generic-restore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = WiltedMacTestPreferences.ephemeral()
        let ids = try await seedPlaybackOriginLibrary(directory, numbers: [17, 18], queued: [18])
        var original: WiltedMacModel? = playbackOriginModel(directory, preferences)
        original?.startStoreBootstrap()
        await original?.waitForStoreBootstrap()
        try await settle(try XCTUnwrap(original))
        let episode18 = try XCTUnwrap(original?.episodes.first { $0.id == ids[1].rawValue })
        original?.playEpisode(episode18)
        await original?.waitForPlaybackOperationForTesting()
        try await settle(try XCTUnwrap(original))
        let key = WiltedMacModel.podcastPlaybackOriginPreferenceKey(for: directory.appendingPathComponent("library.sqlite"))
        XCTAssertNotNil(preferences.data(forKey: key), "generic origin is durably recorded")

        try? await original?.playback?.pause()
        await original?.close()
        original = nil
        preferences.removeObject(forKey: key) // simulate a pre-marker installation

        let relaunched = playbackOriginModel(directory, preferences)
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        try await settle(relaunched)
        XCTAssertEqual(relaunched.currentPodcastEpisodeID, ids[1].rawValue)
        XCTAssertFalse(relaunched.isLarderQueuePlayback)
        await relaunched.simulatePodcastPlaybackReachedEndForTesting()
        relaunched.simulatePodcastPlaybackFinishedForTesting()
        try await settle(relaunched)
        XCTAssertEqual(relaunched.currentPodcastEpisodeID, ids[0].rawValue,
                       "a missing legacy marker restores generic continuation")
        await relaunched.close()
    }

    func testLarderQueueOriginSurvivesRelaunchAndStopsAtItsSuffix() async throws {
        let directory = temporaryDirectory("continue-origin-larder-restore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = WiltedMacTestPreferences.ephemeral()
        let ids = try await seedPlaybackOriginLibrary(directory, numbers: [18, 19, 20, 21], queued: [18, 19, 20, 21])
        var original: WiltedMacModel? = playbackOriginModel(directory, preferences)
        original?.startStoreBootstrap()
        await original?.waitForStoreBootstrap()
        try await settle(try XCTUnwrap(original))
        let episode19 = try XCTUnwrap(original?.episodes.first { $0.id == ids[1].rawValue })
        original?.playLarderEpisode(episode19)
        await original?.waitForPlaybackOperationForTesting()
        try await settle(try XCTUnwrap(original))
        try? await original?.playback?.pause()
        await original?.close()
        original = nil

        let relaunched = playbackOriginModel(directory, preferences)
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        try await settle(relaunched)
        XCTAssertEqual(relaunched.currentPodcastEpisodeID, ids[1].rawValue)
        XCTAssertTrue(relaunched.isLarderQueuePlayback)
        let advancedTo20 = try await relaunched.playback?.selectNextPodcastQueueEpisode()
        XCTAssertEqual(advancedTo20, true)
        try await settle(relaunched)
        XCTAssertEqual(relaunched.currentPodcastEpisodeID, ids[2].rawValue)
        let advancedTo21 = try await relaunched.playback?.selectNextPodcastQueueEpisode()
        XCTAssertEqual(advancedTo21, true)
        try await settle(relaunched)
        XCTAssertEqual(relaunched.currentPodcastEpisodeID, ids[3].rawValue)
        await relaunched.simulatePodcastPlaybackReachedEndForTesting()
        relaunched.simulatePodcastPlaybackFinishedForTesting()
        try await settle(relaunched)
        XCTAssertNil(relaunched.currentPodcastEpisodeID, "the Larder-origin session stops after 21")
        XCTAssertFalse(relaunched.isPlaying)
        XCTAssertFalse(try XCTUnwrap(relaunched.episodes.first { $0.id == ids[0].rawValue }).isPlayed,
                       "earlier unfinished 18 is not restarted")
        await relaunched.close()
    }

    private func playbackOriginModel(_ directory: URL, _ preferences: UserDefaults) -> WiltedMacModel {
        WiltedMacModel(arguments: [], stateDirectoryOverride: directory, storeBootstrap: { url in
            try LocalLibraryStore(url: url)
        }, preferences: preferences)
    }

    private func seedPlaybackOriginLibrary(_ directory: URL, numbers: [Int], queued: [Int]) async throws -> [ItemID] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/origin-restore.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Restore", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        let ids = try numbers.map { number in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "origin-\(number)",
                enclosureURL: try XCTUnwrap(URL(string: "https://media.example.test/origin-\(number).mp3"))
            )
        }
        for (index, number) in numbers.enumerated() {
            let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/origin-\(number).mp3"))
            try await Self.addReadyEpisode(
                ids[index], guid: "origin-\(number)", feedID: feedID, feedURL: feedURL,
                enclosureURL: enclosure, publishedAt: created.date.addingTimeInterval(Double(index) * 60),
                directory: directory, store: store, created: created
            )
        }
        let idByNumber = Dictionary(uniqueKeysWithValues: zip(numbers, ids))
        let queue = try queued.map { try XCTUnwrap(idByNumber[$0]) }
        try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: queue, currentEpisodeID: queue.first))
        return ids
    }
}
