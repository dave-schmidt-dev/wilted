import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Continuing across the Larder when playback runs out

    /// `.oldest` puts the second episode after the first in the Larder's own
    /// displayed order, matching what "next" means to a listener: forward
    /// through the feed, not `.newest`'s reversal of it.
    func testANaturallyFinishedEpisodeStartsTheNextReadyOneAndRemovesItself() async throws {
        let directory = temporaryDirectory("continue-ready")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-ready.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-ready-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-ready-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-ready-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-ready-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Continuing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-ready-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-ready-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
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
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue,
                       "the next ready episode should start once the current one runs out with nothing queued")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue },
                                     "retirement is not dismissal -- the row survives")
        XCTAssertNotNil(finished.retiredAt,
                         "the episode that was listened to all the way through is retired")
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == firstID.rawValue },
                        "and off the Larder shelf")
        XCTAssertFalse(model.dismissedEpisodes.contains { $0.id == firstID.rawValue })
        XCTAssertEqual(model.podcastOperationMessage, "Finished \(first.title).")
    }

    /// Coverage-table row: "Prepared episode's media disappears" (Phase 6).
    func testMediaMissingAfterPreparationDisablesPlaybackAndSurvivesDurableRecords() async throws {
        let directory = temporaryDirectory("media-missing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/media-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/media-missing-1.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "media-missing-1", enclosureURL: enclosureURL
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Missing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "media-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let prepared = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertTrue(model.canPlayEpisode(prepared))
        model.playEpisode(prepared)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        let verifyStore = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let readyRevision = try await verifyStore.readyRevision(for: episodeID)
        let revisionID = try XCTUnwrap(readyRevision?.revision.revisionID)
        // The listening fact is written directly. Playing to the end instead
        // would start the controller's own completion sequence, which retires
        // the episode and reclaims its audio and revision records (W-INV-025)
        // while this test is deleting the same file by hand.
        try await verifyStore.saveListening(PodcastListeningState(
            episodeID: episodeID, completedAt: created, lastRevisionID: revisionID, updatedAt: created
        ))
        let outcomeBefore = try await verifyStore.preparationOutcome(for: episodeID, revisionID: revisionID)
        let listeningBefore = try await verifyStore.listeningState(for: episodeID)
        XCTAssertNotNil(listeningBefore?.completedAt)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("media-missing-1.m4a"))

        // A fresh launch is what actually rebuilds the snapshot from the store
        // and the filesystem together; nothing short of relaunch reaches
        // `loadLibrary` again from test code.
        let relaunched = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()

        let afterDeletion = try XCTUnwrap(relaunched.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertFalse(afterDeletion.isReadyMediaAvailable)
        XCTAssertFalse(relaunched.canPlayEpisode(afterDeletion))
        XCTAssertEqual(
            afterDeletion.lifecyclePresentation.label,
            "Prepared \u{00B7} Local audio missing — Download again"
        )
        XCTAssertTrue(afterDeletion.lifecyclePresentation.isFailure)

        let outcomeAfter = try await verifyStore.preparationOutcome(for: episodeID, revisionID: revisionID)
        XCTAssertEqual(outcomeAfter, outcomeBefore, "a missing file must not touch the durable preparation outcome")
        let listeningAfter = try await verifyStore.listeningState(for: episodeID)
        XCTAssertEqual(listeningAfter, listeningBefore, "a missing file must not touch the durable listening record")
    }

    /// W-INV-025: natural completion retires the episode, and retiring
    /// reclaims its audio file and revision records; the listening facts stay.
    func testNaturalCompletionRetiresTheEpisodeAndReclaimsItsAudioButKeepsListeningFacts() async throws {
        let directory = temporaryDirectory("natural-completion-reclaim")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/natural-completion.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/natural-completion-1.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "natural-completion-1", enclosureURL: enclosureURL
        )
        let audioURL = directory.appendingPathComponent("natural-completion-1.m4a")

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Natural", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "natural-completion-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let prepared = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        model.playEpisode(prepared)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        let finished = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertTrue(finished.isPlayed, "the listening fact survives the reclaim")
        XCTAssertNotNil(finished.retiredAt, "natural completion retires the episode")

        let verifyStore = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let listening = try await verifyStore.listeningState(for: episodeID)
        XCTAssertNotNil(listening?.completedAt, "the durable listening record survives")
        let reclaimedRevision = try await verifyStore.readyRevision(for: episodeID)
        XCTAssertNil(reclaimedRevision, "retiring deletes the revision records")
        let reclaimedDownload = try await verifyStore.download(for: episodeID)
        XCTAssertNil(reclaimedDownload, "retiring deletes the download record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "retiring deletes the audio file")
    }

    /// W-INV-025 across a relaunch: once natural completion has reclaimed the
    /// audio and its revision records, the snapshot still reads the listening
    /// and retirement facts without any revision row.
    func testARelaunchAfterNaturalCompletionKeepsTheEpisodePlayedAndRetiredWithItsAudioReclaimed() async throws {
        let directory = temporaryDirectory("natural-completion-relaunch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/natural-relaunch.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/natural-relaunch-1.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "natural-relaunch-1", enclosureURL: enclosureURL
        )
        let audioURL = directory.appendingPathComponent("natural-relaunch-1.m4a")

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Relaunch", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "natural-relaunch-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let prepared = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        model.playEpisode(prepared)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "completion reclaimed the audio")

        let relaunched = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()

        let row = try XCTUnwrap(relaunched.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertTrue(row.isPlayed, "the snapshot reads the listening fact without a revision row")
        XCTAssertNotNil(row.retiredAt, "and the retirement")
        XCTAssertEqual(row.downloadState, .notDownloaded, "the audio records went with the audio")
        XCTAssertFalse(row.isReadyMediaAvailable)
    }

    /// Plan gate: "a test asserting no hashing occurs during snapshot
    /// construction (inject a counting file-manager seam)."
    func testLoadingTheLibraryChecksMediaExistenceOnceExactlyPerReadyRevision() async throws {
        let directory = temporaryDirectory("media-availability-seam")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/media-seam.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/media-seam-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/media-seam-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "media-seam-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "media-seam-2", enclosureURL: secondEnclosure
        )
        let checker = CountingMediaAvailabilityChecker()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Seam", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "media-seam-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                // Never downloaded, so there is no ready revision -- proving
                // the seam is not consulted once per episode, only once per
                // ready revision.
                try await store.save(episode: try PodcastEpisode(
                    itemID: secondID, feedID: feedID, feedURL: feedURL, rssGUID: "media-seam-2",
                    title: "Not ready", publishedTime: created, enclosureURL: secondEnclosure,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            mediaAvailabilityChecker: checker,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.episodes.count, 2)
        XCTAssertEqual(checker.fileExistsCallCount, 1,
                       "exactly one stat for the one ready revision, and none for the unprepared episode")
    }

    /// Repeats the Phase 5 HIGH-severity chain (auto-advance skipping the
    /// finished item) for the media-availability gate added on top of it.
    func testNaturalCompletionSkipsASuccessorWhoseMediaWentMissing() async throws {
        let directory = temporaryDirectory("continue-media-missing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-media-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-media-missing-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-media-missing-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-media-missing-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-media-missing-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-media-missing-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-media-missing-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Missing Media", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-media-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-media-missing-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "continue-media-missing-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: thirdEnclosure, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("continue-media-missing-2.m4a")
        )

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "the successor with missing media must be skipped in favor of the next ready one")
        let skipped = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertFalse(skipped.isReadyMediaAvailable)
        XCTAssertFalse(skipped.isPlayed, "skipping past it must not mark it finished")
        XCTAssertNil(skipped.retiredAt, "skipping past it must not retire it")
    }

    /// The fault names the episode that failed to load, not the one that just
    /// finished -- this is the same pair Phase 5's HIGH bug lived in. Uses two
    /// distinct episodes so a repair keyed on `itemID` instead of the fault's
    /// own associated value would fail this test: the just-finished episode
    /// (`itemID`) must stay untouched while the successor named by `fault`
    /// (`.podcastMediaUnavailable`) is the one that flips.
    func testMediaUnavailableFaultImmediatelyDisablesPlaybackForTheSuccessorNotTheFinishedEpisode() async throws {
        let directory = temporaryDirectory("fault-media-unavailable")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/fault-media.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let finishedEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/fault-media-finished.mp3"))
        let successorEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/fault-media-successor.mp3"))
        let finishedID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "fault-media-finished", enclosureURL: finishedEnclosure
        )
        let successorID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "fault-media-successor", enclosureURL: successorEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Fault", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    finishedID, guid: "fault-media-finished", feedID: feedID, feedURL: feedURL,
                    enclosureURL: finishedEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    successorID, guid: "fault-media-successor", feedID: feedID, feedURL: feedURL,
                    enclosureURL: successorEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let finished = try XCTUnwrap(model.episodes.first { $0.id == finishedID.rawValue })
        let successor = try XCTUnwrap(model.episodes.first { $0.id == successorID.rawValue })
        XCTAssertTrue(finished.isReadyMediaAvailable)
        XCTAssertTrue(successor.isReadyMediaAvailable)

        // Mirrors PlaybackController.handleBackendCompletion's successor-load-throws
        // shape: `itemID` is the episode that just finished, `fault`'s associated
        // value is the successor that actually failed to load.
        model.applyPodcastPlaybackObservationForTesting(
            itemID: finishedID, fault: .podcastMediaUnavailable(successorID)
        )

        let repairedSuccessor = try XCTUnwrap(model.episodes.first { $0.id == successorID.rawValue })
        XCTAssertFalse(repairedSuccessor.isReadyMediaAvailable,
                       "a media-unavailable fault must flip the flag immediately, without waiting for a reload")
        XCTAssertFalse(model.canPlayEpisode(repairedSuccessor))

        let untouchedFinished = try XCTUnwrap(model.episodes.first { $0.id == finishedID.rawValue })
        XCTAssertTrue(untouchedFinished.isReadyMediaAvailable,
                      "the episode named by itemID just finished playing fine and must not be flagged")
        XCTAssertTrue(model.canPlayEpisode(untouchedFinished))
    }

}
