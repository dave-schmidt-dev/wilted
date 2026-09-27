import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    /// A manual "Play" throws out of `loadQueuedEpisode` before
    /// `podcastStateHandler` ever runs, so the auto-advance fault repair never
    /// fires on this path -- it needs its own repair in `playEpisode`'s catch.
    func testManuallyPlayingAnEpisodeWithMissingMediaDisablesItImmediately() async throws {
        let directory = temporaryDirectory("manual-play-media-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-play-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/manual-play-missing-1.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-play-missing-1", enclosureURL: enclosureURL
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Play", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "manual-play-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manual-play-missing-1.m4a")
        )

        let episode = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let repaired = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertFalse(repaired.isReadyMediaAvailable,
                       "a manual play that throws podcastMediaUnavailable must flip the flag without a reload")
        XCTAssertFalse(model.canPlayEpisode(repaired))
        XCTAssertNotNil(model.playbackError)
    }

    /// Symmetric to the manual-play test above: pressing Next also throws out of
    /// `loadQueuedEpisode` before `podcastStateHandler` ever runs, so
    /// `navigatePodcastQueue`'s own catch block is the only place that can repair
    /// the flag for this path.
    func testManuallySkippingToAnEpisodeWithMissingMediaDisablesItImmediately() async throws {
        let directory = temporaryDirectory("manual-skip-media-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-skip-missing.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-missing-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-missing-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-missing-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-missing-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Skip", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "manual-skip-missing-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "manual-skip-missing-2", feedID: feedID, feedURL: feedURL,
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

        // `playEpisode` only enqueues the episode it plays -- the controller's
        // own queue, not the Larder-wide search `simulatePodcastPlaybackReachedEndForTesting`
        // uses -- so `second` must be enqueued explicitly for `nextPlayback` to reach it.
        let second = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        model.addEpisodeToUpNext(second)
        try await settle(model)
        XCTAssertTrue(model.canSelectNextEpisode,
                      "second's media is still on disk and queued, so Next must be enabled going in")

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manual-skip-missing-2.m4a")
        )

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let repaired = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertFalse(repaired.isReadyMediaAvailable,
                       "a manual skip that throws podcastMediaUnavailable must flip the flag without a reload")
        XCTAssertFalse(model.canPlayEpisode(repaired))
        XCTAssertNotNil(model.playbackError)
    }

    /// `canSelectNextEpisode`'s third gate, added alongside the other two media
    /// availability checks in this phase, had no direct coverage: this puts a
    /// missing-media episode at exactly the queue slot the property inspects.
    func testCanSelectNextEpisodeIsFalseWhenTheQueuedSuccessorsMediaIsMissing() {
        let root = temporaryDirectory("can-select-next-media-missing")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentID = "item-" + String(repeating: "1", count: 64)
        let missingID = "item-" + String(repeating: "2", count: 64)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: root,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let current = WiltedMacEpisode(
            id: currentID, title: "Current", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 100), durationSeconds: 600,
            playbackSeconds: 12, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced")
        )
        let missing = WiltedMacEpisode(
            id: missingID, title: "Missing", feedTitle: "Fixtures", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 200), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready · transcript synced"),
            isReadyMediaAvailable: false
        )
        model.installEpisodeForTesting(missing)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [currentID, missingID]
        )

        XCTAssertFalse(model.canSelectNextEpisode,
                       "the queued successor's media is missing, so advancing to it must be disallowed")
    }

    func testManualNextWithABCSkipsUnpreparedBAndAdvancesToC() async throws {
        let directory = temporaryDirectory("manual-skip-abc")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-skip-abc.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Skip ABC", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "manual-skip-abc-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addDownloadedUnpreparedEpisode(
                    secondID, guid: "manual-skip-abc-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "manual-skip-abc-3", feedID: feedID, feedURL: feedURL,
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
        XCTAssertTrue(model.canSelectNextEpisode,
                      "C is ready and queued after unprepared B, so Next must be enabled")

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "manual Next must skip unprepared B and advance directly to C")
        XCTAssertNil(model.playbackError)
    }

    func testManualAndRemoteNextWithABCSkipsRetiredReadyBAndAdvancesToC() async throws {
        let directory = temporaryDirectory("manual-skip-abc-retired")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-skip-abc-retired.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-retired-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-retired-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/manual-skip-abc-retired-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-retired-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-retired-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "manual-skip-abc-retired-3", enclosureURL: thirdEnclosure
        )

        let sink = ModelTestNowPlayingSink()
        let commands = ModelTestRemoteCommandSource()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Manual Skip ABC Retired", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "manual-skip-abc-retired-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "manual-skip-abc-retired-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                _ = try await store.retireEpisode(secondID)
                try await Self.addReadyEpisode(
                    thirdID, guid: "manual-skip-abc-retired-3", feedID: feedID, feedURL: feedURL,
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

        XCTAssertTrue(model.canSelectNextEpisode,
                      "C is ready and queued after retired B, so Next must be enabled")
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasNext, true)

        // Remote Next command must skip retired ready B and advance directly to C
        commands.send(.nextTrack)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "remote Next must skip retired B and advance directly to C")
        XCTAssertNil(model.playbackError)

        // When only retired B is queued after current, Next must be disabled
        model.removeEpisodeFromUpNext(second.id)
        try await settle(model)
        model.addEpisodeToUpNext(second)
        try await settle(model)
        XCTAssertEqual(model.podcastQueueIDs.last, second.id,
                       "B must be after current C to exercise retired Next eligibility")
        XCTAssertFalse(model.canSelectNextEpisode,
                       "only retired B is after current, so Next must be disabled")
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasNext, false)

        commands.send(.nextTrack)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue)

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue)

        // Restoring B must make it eligible again
        model.restoreSkippedFeedEpisode(second)
        for _ in 0..<50 {
            if model.episodes.first(where: { $0.id == secondID.rawValue })?.retiredAt == nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await settle(model)

        let restoredSecond = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        XCTAssertNil(restoredSecond.retiredAt)
        XCTAssertNil(restoredSecond.removalKind)
        XCTAssertTrue(model.canPlayEpisode(restoredSecond), "restored B must be playable again")
        XCTAssertTrue(model.canSelectNextEpisode, "restoring B makes Next enabled again")
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasNext, true)

        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue, "manual Next now advances to restored B")
    }

}
