import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Removing an episode from the Larder by mistake: the toast's Undo puts the episode back exactly
/// as it was, the toast lets go at five seconds while the removal stands, and an offer that can no
/// longer work is withdrawn.
extension WiltedMacCompletionOptimisticTests {
    struct Shelf {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let clock: CompletionClock
        /// Three episodes in Larder order; the tests remove the middle one.
        let ids: [ItemID]
        let directory: URL
        var middle: ItemID { ids[1] }
        var middleMedia: URL { directory.appendingPathComponent("shelf-1.m4a") }
    }

    /// One feed with three prepared episodes queued in a known order, on a clock the test moves.
    func shelf(_ suffix: String) async throws -> Shelf {
        let directory = wiltedTemporaryDirectory("undo-toast-\(suffix)")
        let feedURL = URL(string: "https://feeds.example.test/undo-toast-\(suffix).xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        var ids: [ItemID] = []
        for index in 0..<3 {
            ids.append(try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "shelf-\(index)",
                enclosureURL: URL(string: "https://media.example.test/undo-toast-\(suffix)-\(index).mp3")!))
        }
        let episodeIDs = ids
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { root in
                let store = try LocalLibraryStore(url: root)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Undo Show", createdAt: created))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, id) in episodeIDs.enumerated() {
                    try await WiltedMacModelTests.addReadyEpisode(
                        id, guid: "shelf-\(index)", feedID: feedID, feedURL: feedURL,
                        enclosureURL: URL(string: "https://media.example.test/undo-toast-\(suffix)-\(index).mp3")!,
                        publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400),
                        directory: directory, store: store, created: created)
                }
                try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: episodeIDs))
                return store
            },
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader()),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        let clock = CompletionClock()
        model.manualCompletionNow = { clock.now }
        model.manualCompletionSleep = { try await clock.sleep($0) }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        await model.refreshPodcastQueueState()
        await model.reloadLibraryRowsForTesting()
        return Shelf(model: model, store: store, clock: clock, ids: ids, directory: directory)
    }

    func testUndoFromTheToastPutsARemovedEpisodeBackExactlyAsItWas() async throws {
        let shelf = try await shelf("restore")
        let model = shelf.model
        let id = shelf.middle
        let revisions = try await shelf.store.revisions(for: id)
        let revision = try XCTUnwrap(revisions.first).revision.revisionID
        try await shelf.store.save(playback: PlaybackState(
            itemID: id, revisionID: revision, sessionID: "undo-toast-session", sequence: 1,
            positionSeconds: 4, durationSeconds: 10, completed: false, intent: .progress,
            deviceID: "undo-toast-test", updatedAt: Timestamp(shelf.clock.now)))
        let created = await model.createPlaylist(kind: .manual, name: "Keepers", adding: id.rawValue)
        let playlist = try XCTUnwrap(created)
        await model.refreshPodcastQueueState()
        await model.reloadLibraryRowsForTesting()

        let larderBefore = model.larderVisibleEpisodes.map(\.id)
        let queueBefore = model.podcastQueueIDs
        let rowBefore = try XCTUnwrap(model.episodes.first { $0.id == id.rawValue })
        XCTAssertEqual(queueBefore, shelf.ids.map(\.rawValue))
        XCTAssertEqual(larderBefore.count, 3)
        XCTAssertEqual(rowBefore.playbackSeconds, 4)
        XCTAssertTrue(rowBefore.preparationState.isPrepared)

        model.removeEpisodeFromUpNext(id.rawValue)
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == id.rawValue }, "the removal happens at once")
        let removedKind = try await shelf.store.removalKind(for: id)
        XCTAssertNotNil(removedKind, "and is saved, not held back for the five seconds")
        XCTAssertEqual(model.undoToast.current?.message, "Marked \(rowBefore.title) completed.")
        XCTAssertEqual(model.undoToast.current?.subjects, [id.rawValue])

        shelf.clock.advance(4)
        model.undoToast.undoCurrent()
        XCTAssertNil(model.undoToast.current, "Undo closes the toast")
        await WiltedMacHeadless.drainDecisions(model)

        let restoredKind = try await shelf.store.removalKind(for: id)
        XCTAssertNil(restoredKind)
        XCTAssertEqual(model.larderVisibleEpisodes.map(\.id), larderBefore, "back in the same place on the Larder")
        XCTAssertEqual(model.podcastQueueIDs, queueBefore, "and in the same place in the play order")
        let rowAfter = try XCTUnwrap(model.episodes.first { $0.id == id.rawValue })
        XCTAssertFalse(rowAfter.isPlayed)
        XCTAssertNil(rowAfter.retiredAt)
        XCTAssertEqual(rowAfter.playbackSeconds, 4, "the listening position is kept")
        XCTAssertTrue(rowAfter.preparationState.isPrepared, "the prepared audio is kept")
        XCTAssertTrue(rowAfter.isReadyMediaAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelf.middleMedia.path))
        let entries = try await shelf.store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(entries, [id.rawValue], "playlist membership is kept")
        XCTAssertNil(model.undoableSkip)
    }

    func testTheToastLetsGoAtFiveSecondsAndTheRemovalStands() async throws {
        let shelf = try await shelf("expire")
        let model = shelf.model
        let id = shelf.middle

        model.removeEpisodeFromUpNext(id.rawValue)
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertNotNil(model.undoToast.current)

        shelf.clock.advance(5)
        await WiltedMacHeadless.eventually("the toast lets go at five seconds") { model.undoToast.current == nil }
        model.undoToast.undoCurrent()
        await WiltedMacHeadless.drainDecisions(model)
        let kind = try await shelf.store.removalKind(for: id)
        XCTAssertNotNil(kind, "an offer that ran out restores nothing")
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == id.rawValue })
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelf.middleMedia.path),
                      "the audio is kept for Restore in Feeds")
    }

    func testTwoQuickRemovalsCanBothBeUndoneNewestFirst() async throws {
        let shelf = try await shelf("stack")
        let model = shelf.model
        let larderBefore = model.larderVisibleEpisodes.map(\.id)
        let queueBefore = model.podcastQueueIDs

        model.removeEpisodeFromUpNext(shelf.ids[0].rawValue)
        await WiltedMacHeadless.drainDecisions(model)
        shelf.clock.advance(1)
        model.removeEpisodeFromUpNext(shelf.ids[2].rawValue)
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertEqual(model.undoToast.offers.map(\.subjects), [[shelf.ids[0].rawValue], [shelf.ids[2].rawValue]])
        XCTAssertEqual(model.larderVisibleEpisodes.map(\.id), [shelf.middle.rawValue])

        model.undoToast.undoCurrent()
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertEqual(model.undoToast.current?.subjects, [shelf.ids[0].rawValue], "the earlier removal is offered next")
        model.undoToast.undoCurrent()
        await WiltedMacHeadless.drainDecisions(model)

        XCTAssertEqual(model.larderVisibleEpisodes.map(\.id), larderBefore)
        XCTAssertEqual(model.podcastQueueIDs, queueBefore)
        for id in shelf.ids {
            let kind = try await shelf.store.removalKind(for: id)
            XCTAssertNil(kind)
        }
    }

    func testUnsubscribingWithdrawsTheOfferForThatFeedsEpisode() async throws {
        let shelf = try await shelf("unsubscribe")
        let model = shelf.model
        model.removeEpisodeFromUpNext(shelf.middle.rawValue)
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertNotNil(model.undoToast.current)

        let subscription = try XCTUnwrap(model.subscriptions.first)
        try await model.commitUnsubscribe(subscription)
        XCTAssertNil(model.undoToast.current, "Undo cannot put back an episode whose feed is gone")
    }

    func testClosingTheLibraryWithdrawsEveryOffer() async throws {
        let shelf = try await shelf("close")
        let model = shelf.model
        model.removeEpisodeFromUpNext(shelf.middle.rawValue)
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertNotNil(model.undoToast.current)

        await model.close()
        XCTAssertNil(model.undoToast.current)
        let kind = try await shelf.store.removalKind(for: shelf.middle)
        XCTAssertNotNil(kind, "quitting inside the five seconds leaves the removal in place")
    }
}
