import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacEpisodeAliasTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(_ id: String, prepared: Bool) -> WiltedMacEpisode {
        var value = WiltedMacEpisode(id: id, title: "Episode \(id)", feedTitle: "Alias show", summary: "",
            artworkURL: nil, releasedAt: created, durationSeconds: 120,
            playbackSeconds: id == "backing-B" ? 73 : 0, downloadState: prepared ? .completed : .notDownloaded)
        value.preparationState = prepared ? .prepared(summary: "Prepared") : .notPrepared
        value.feedID = "alias-feed"
        return value
    }

    private func model() throws -> WiltedMacModel {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("alias-projection"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) }, preferences: WiltedMacTestPreferences.ephemeral())
        let first = try ItemID(rawValue: "backing-A"), second = try ItemID(rawValue: "backing-B")
        let group = LibraryEpisodeAssociation(groupID: UUID(), representativeID: first,
            memberIDs: [first, second], associationVersion: 1, isTerminal: false)
        model.episodeAssociations = [first.rawValue: group, second.rawValue: group]
        model.episodes = [row(first.rawValue, prepared: false), row(second.rawValue, prepared: true)]
        model.podcastQueueIDs = [second.rawValue, first.rawValue]
        return model
    }

    func testDisplayFoldsWithoutReplacingRawLoadedMemberQueueOrBackingSelection() async throws {
        let model = try model()
        model.currentPodcastEpisodeID = "backing-B"
        model.isPodcastPlayback = true
        let queue = model.podcastQueueIDs
        let visible = model.larderVisibleEpisodes
        XCTAssertEqual(visible.map(\.id), ["backing-A"])
        XCTAssertTrue(try XCTUnwrap(visible.first).preparationState.isPrepared)
        XCTAssertEqual(visible.first?.playbackSeconds, 73)
        XCTAssertEqual(model.backingEpisode(for: try XCTUnwrap(visible.first))?.id, "backing-B")
        XCTAssertTrue(model.larderPresentationEpisodes.isEmpty, "The loaded raw B owns the logical Now Playing slot")
        XCTAssertEqual(model.currentEpisode?.id, "backing-B")
        XCTAssertEqual(model.currentPodcastEpisodeID, "backing-B")
        XCTAssertEqual(model.podcastQueueIDs, queue)
        XCTAssertTrue(model.feedsEpisodes.isEmpty)
        model.isPodcastPlayback = false
        model.podcastQueueIDs = ["backing-B"]
        XCTAssertEqual(model.larderWaitingEpisodes.map(\.id), ["backing-A"], "A need not hold a raw queue slot")
        XCTAssertEqual(model.podcastQueueIDs, ["backing-B"])
        await model.close()
    }

    func testAssociatedSelectionWithoutEligibleBackingExplainsFailureAndPreservesRawCurrent() async throws {
        let model = try model()
        let display = try XCTUnwrap(model.episodes.first)
        model.currentPodcastEpisodeID = "backing-B"
        model.isPodcastPlayback = true
        model.hiddenEpisodeIDs = ["backing-A", "backing-B"]
        model.playEpisode(display)
        XCTAssertEqual(model.playbackError, "This episode's saved audio is unavailable.")
        XCTAssertEqual(model.currentPodcastEpisodeID, "backing-B")
        XCTAssertEqual(model.podcastQueueIDs, ["backing-B", "backing-A"])
        await model.close()
    }

    func testRawPlaylistReferencesFoldOnceAndRetainTheirStoredMembership() async throws {
        let model = try model()
        let playlist = Playlist(id: "alias-list", name: "Aliases", kind: .manual, matchAll: true, sortIndex: 0)
        model.playlists.entryIDs[playlist.id] = ["backing-B", "backing-A"]
        XCTAssertEqual(model.playlistItems(playlist).map(\.id), ["backing-A"])
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], ["backing-B", "backing-A"])
        model.podcastQueueIDs = []
        XCTAssertEqual(model.feedsEpisodes.map(\.id), ["backing-A"])
        await model.close()
    }

    func testSnapshotExportsEveryRawSlotAndOldIntentKeepsItsOriginalTime() async throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("alias-intent"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap(); await model.waitForStoreBootstrap()
        await model.manualCompletionRecoveryTask?.value
        let store = try XCTUnwrap(model.store)
        let feedURL = URL(string: "https://feeds.example.test/alias.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Alias", createdAt: Timestamp(created)))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(created)))
        var ids: [ItemID] = []
        for guid in ["A", "B"] {
            let enclosure = URL(string: "https://media.example.test/alias-\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: PodcastEpisode(itemID: id, feedID: feedID, feedURL: feedURL,
                rssGUID: guid, title: "Alias \(guid)", enclosureURL: enclosure,
                enclosureMediaType: "audio/mpeg", createdAt: Timestamp(created)))
            try await store.addPodcastQueueEpisode(id); ids.append(id)
        }
        let confirmation = PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: feedID,
            first: ids[0], second: ids[1], confirmedAt: Timestamp(created))
        let preview = try await store.previewEpisodeAssociation(confirming: confirmation, representativeID: ids[0])
        _ = try await store.applyEpisodeAssociation(preview, at: Timestamp(created))
        await model.reloadLibraryRows(); await model.refreshPodcastQueueState()
        let source = WiltedMacLocalLibraryStateSource(store: store, deviceID: "fixture") { nil }
        let snapshot = try await source.currentState()
        XCTAssertEqual(snapshot.queue, ids)
        XCTAssertEqual(try snapshot.replicatedContent().queue.map(\.entryID), ids)
        XCTAssertEqual(LibraryEpisodeAssociation.coherentGroups(in: snapshot.episodes).count, 1)
        let choiceAt = created.addingTimeInterval(30)
        let restore = try LibraryIntent.restore(entryID: ids[1], deviceID: "old-phone", createdAt: choiceAt)
        let restored = await model.applyOwnerIntent(restore)
        if case .applied? = restored {} else { XCTFail("Expected dated group Restore") }
        for id in ids {
            let choice = try await store.episodeDecision(for: id)
            XCTAssertEqual(choice?.decidedAt.date, choiceAt)
            XCTAssertEqual(choice?.decision, .keep)
        }
        let stale = try LibraryIntent.skip(entryID: ids[0], deviceID: "old-phone", createdAt: created.addingTimeInterval(10))
        if case .superseded? = await model.applyOwnerIntent(stale) {} else { XCTFail("Old Skip must be superseded") }
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs, ids)
        let otherURL = URL(string: "https://media.example.test/other.mp3")!
        let other = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "other", enclosureURL: otherURL)
        try await store.save(episode: PodcastEpisode(itemID: other, feedID: feedID, feedURL: feedURL,
            rssGUID: "other", title: "Other", enclosureURL: otherURL, enclosureMediaType: "audio/mpeg", createdAt: Timestamp(created)))
        try await store.addPodcastQueueEpisode(other)
        let controller = PlaybackController(store: store, backend: WiltedFixturePlaybackBackend(), deviceID: "fixture")
        controller.episodeEligibilityPredicate = { _ in true }
        try await store.setCurrentPodcastQueueEpisode(ids[0])
        let next = try await controller.nextEligibleEpisodeID()
        XCTAssertEqual(next, other, "Next skips the same logical episode's retained raw twin")
        try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: [other, ids[0], ids[1]], currentEpisodeID: ids[1]))
        let previous = try await controller.previousEligibleEpisodeID()
        XCTAssertEqual(previous, other)
        let retained = try await store.podcastQueueState()
        XCTAssertEqual(retained.episodeIDs, [other, ids[0], ids[1]])
        await model.close()
    }
}
