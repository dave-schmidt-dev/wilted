import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    func testManualNextWithABCSkipsUnpreparedBAndFailsDeterministicallyWhenCMediaMissing() async throws {
        let directory = temporaryDirectory("manual-skip-abc-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-skip-abc-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-missing-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-missing-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-missing-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-missing-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-missing-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-missing-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Skip Missing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "manual-skip-abc-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addDownloadedUnpreparedEpisode(
                    secondID, guid: "manual-skip-abc-missing-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "manual-skip-abc-missing-3", feedID: feedID, feedURL: feedURL,
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

        let second = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        let third = try XCTUnwrap(model.episodes.first { $0.id == thirdID.rawValue })
        model.addEpisodeToUpNext(second)
        model.addEpisodeToUpNext(third)
        try await settle(model)

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manual-skip-abc-missing-3.m4a")
        )

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let repaired = try XCTUnwrap(model.episodes.first { $0.id == thirdID.rawValue })
        XCTAssertFalse(repaired.isReadyMediaAvailable,
                       "failing to load C due to missing media must flip C's flag immediately")
        XCTAssertFalse(model.canPlayEpisode(repaired))
        XCTAssertNotNil(model.playbackError)
    }

    func testCanSelectPreviousEpisodeIsFalseWhenQueuedPredecessorsMediaIsMissing() {
        let root = temporaryDirectory("can-select-previous-media-missing")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingID = "item-" + String(repeating: "1", count: 64)
        let currentID = "item-" + String(repeating: "2", count: 64)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: root,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let missing = WiltedMacEpisode(
            id: missingID, title: "Missing", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 100), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced"),
            isReadyMediaAvailable: false
        )
        let current = WiltedMacEpisode(
            id: currentID, title: "Current", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 200), durationSeconds: 600,
            playbackSeconds: 12, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced")
        )
        model.installEpisodeForTesting(missing)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [missingID, currentID]
        )

        XCTAssertFalse(model.canSelectPreviousEpisode,
                       "the queued predecessor's media is missing, so selecting it must be disallowed")
    }

    func testManualPreviousWithABCSkipsUnpreparedBAndAdvancesToA() async throws {
        let directory = temporaryDirectory("manual-skip-abc-previous")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-skip-abc-prev.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-prev-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-prev-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-prev-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-prev-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-prev-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-prev-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Skip ABC Prev", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "manual-skip-abc-prev-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addDownloadedUnpreparedEpisode(
                    secondID, guid: "manual-skip-abc-prev-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "manual-skip-abc-prev-3", feedID: feedID, feedURL: feedURL,
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
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        let second = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        let third = try XCTUnwrap(model.episodes.first { $0.id == thirdID.rawValue })
        model.addEpisodeToUpNext(second)
        model.addEpisodeToUpNext(third)
        try await settle(model)

        XCTAssertTrue(model.canSelectNextEpisode)
        XCTAssertFalse(model.canSelectPreviousEpisode, "no predecessor before first episode")

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "Next must skip unprepared B and advance to C")
        XCTAssertTrue(model.canSelectPreviousEpisode,
                      "first is ready and queued before unprepared B, so Previous must be enabled")

        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue,
                       "manual Previous must skip unprepared B and select A")
        XCTAssertNil(model.playbackError)
        XCTAssertFalse(model.canSelectPreviousEpisode, "back at first episode, Previous must be disabled")

        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)
        XCTAssertNil(model.playbackError)
    }

    func testManualAndRemotePreviousWithABCSkipsRetiredReadyBAndAdvancesToA() async throws {
        let directory = temporaryDirectory("manual-skip-abc-retired-prev")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-skip-abc-retired-prev.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-retired-prev-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-retired-prev-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-retired-prev-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-retired-prev-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-retired-prev-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-retired-prev-3", enclosureURL: thirdEnclosure
        )

        let sink = ModelTestNowPlayingSink()
        let commands = ModelTestRemoteCommandSource()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Skip ABC Retired Prev", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "manual-skip-abc-retired-prev-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "manual-skip-abc-retired-prev-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                _ = try await store.retireEpisode(secondID)
                try await Self.addReadyEpisode(
                    thirdID, guid: "manual-skip-abc-retired-prev-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: thirdEnclosure, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                return store
            }, nowPlayingSink: sink, remoteCommandSource: commands,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        let second = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        let third = try XCTUnwrap(model.episodes.first { $0.id == thirdID.rawValue })

        XCTAssertTrue(model.canPlayEpisode(first))
        XCTAssertFalse(model.canPlayEpisode(second), "retired ready B must not be playable")
        XCTAssertTrue(model.canPlayEpisode(third))

        model.playEpisode(first)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        model.addEpisodeToUpNext(second)
        model.addEpisodeToUpNext(third)
        try await settle(model)

        // Advance to third
        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue)

        XCTAssertTrue(model.canSelectPreviousEpisode,
                      "first is ready and queued before retired B, so Previous must be enabled")
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasPrevious, true)

        // Remote Previous command must skip retired ready B and select first
        commands.send(.previousTrack)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue,
                       "remote Previous must skip retired B and select first")
        XCTAssertNil(model.playbackError)

        // B must remain retired: Previous must not silently unretire it
        let retiredSecond = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertNotNil(retiredSecond.retiredAt, "Previous must not silently unretire B")

        // When only retired B is queued before current, Previous must be disabled
        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue)

        model.removeEpisodeFromUpNext(first.id)
        try await settle(model)
        XCTAssertEqual(model.podcastQueueIDs, [second.id, third.id])
        XCTAssertFalse(model.canSelectPreviousEpisode,
                       "only retired B is before current, so Previous must be disabled")
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasPrevious, false)

        commands.send(.previousTrack)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue)

        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue)

        // Restoring B must make it eligible again
        model.restoreSkippedFeedEpisode(second)
        await waitForFeedDecisionWriters(model)

        let restoredSecond = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertNil(restoredSecond.retiredAt)
        XCTAssertNil(restoredSecond.removalKind)
        // W-INV-025: retiring B reclaimed its audio, so a restored B is back on
        // the shelf but must be downloaded again before it is playable.
        XCTAssertFalse(model.canPlayEpisode(restoredSecond), "restored B has no audio until it is downloaded again")
        let redownloadStore = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await Self.addReadyEpisode(
            secondID, guid: "manual-skip-abc-retired-prev-2", feedID: feedID, feedURL: feedURL,
            enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
            directory: directory, store: redownloadStore, created: Timestamp(Date())
        )
        // Preparing again is what proves the new audio; the outcome row went
        // with the revision it described.
        let redownloadedRevision = try await redownloadStore.readyRevision(for: secondID)
        try await redownloadStore.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: secondID, revisionID: try XCTUnwrap(redownloadedRevision?.revision.revisionID),
            policyDigest: "d", pipelineFingerprint: "f", semanticVersion: "v", producedAt: Timestamp(Date())
        ))
        await model.reloadLibraryRowsForTesting()
        let redownloadedSecond = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertTrue(model.canPlayEpisode(redownloadedSecond), "re-downloaded B must be playable again")
        XCTAssertTrue(model.canSelectPreviousEpisode, "restoring B makes Previous enabled again")
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasPrevious, true)

        model.previousPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue, "manual Previous now selects restored B")
    }

}
