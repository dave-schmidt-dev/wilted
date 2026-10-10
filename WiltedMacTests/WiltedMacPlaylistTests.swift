import Foundation
import WiltedDomain
import WiltedProducer
import WiltedSync
import XCTest
@testable import WiltedMac

/// Serves the queued fetch batches in order, then empty ones. Records how many fetches happened.
private actor SequencedFetchTransport: SyncTransport {
    nonisolated let statuses: AsyncStream<SyncStatus>
    private var batches: [SyncFetchBatch]
    private(set) var fetchCount = 0

    init(batches: [SyncFetchBatch]) {
        self.batches = batches
        statuses = AsyncStream<SyncStatus>.makeStream().stream
    }

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchCount += 1
        return batches.isEmpty ? try SyncFetchBatch(generationID: "idle-\(fetchCount)", records: []) : batches.removeFirst()
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        try SyncSendResult(engineState: Data([8]), acknowledgedRecordIDs: changes.map(\.recordID), serverEnvelopes: [])
    }
}

@MainActor
private final class LoadHold {
    var entered = 0
    var release: CheckedContinuation<Void, Never>?
}

/// Playlists play in their own order on the Mac and never change the Larder: the durable queue, the
/// finished entry's place on the shelf and the queue's current episode all stay as they were.
@MainActor
final class WiltedMacPlaylistTests: XCTestCase {
    struct Fixture {
        let model: WiltedMacModel
        let ids: [ItemID]
    }

    private func created(_ model: WiltedMacModel, _ kind: PlaylistKind, _ name: String? = nil) async throws -> Playlist {
        let made = await model.createPlaylist(kind: kind, name: name)
        return try XCTUnwrap(made)
    }

    private func settle() async throws {
        for _ in 0..<40 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A model over a real store holding `count` ready episodes, the Larder queue set to the first
    /// two with the first current.
    private func fixture(_ name: String, count: Int) async throws -> Fixture {
        try await Self.makeFixture(name, count: count, directory: wiltedTemporaryDirectory(name))
    }

    static func makeFixture(_ name: String, count: Int, directory: URL) async throws -> Fixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/\(name).xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        var ids: [ItemID] = []
        for index in 0..<count {
            let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/\(name)-\(index).mp3"))
            ids.append(try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "\(name)-\(index)", enclosureURL: enclosure))
        }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { [ids] url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Lists", createdAt: created))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, id) in ids.enumerated() {
                    let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/\(name)-\(index).mp3"))
                    try await WiltedMacModelTests.addReadyEpisode(
                        id, guid: "\(name)-\(index)", feedID: feedID, feedURL: feedURL, enclosureURL: enclosure,
                        publishedAt: created.date.addingTimeInterval(Double(index) * 60),
                        directory: directory, store: store, created: created)
                }
                try await store.replacePodcastQueue(try PodcastQueueState(
                    episodeIDs: Array(ids.prefix(2)), currentEpisodeID: ids[0]))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.loadPlaylists()
        return Fixture(model: model, ids: ids)
    }

    func testPlayingAManualPlaylistAdvancesInPlaylistOrderAndLeavesTheLarderQueueUnchanged() async throws {
        let (model, ids) = try await { let f = try await fixture("manual-order", count: 3); return (f.model, f.ids) }()
        let store = try XCTUnwrap(model.store)
        let queueBefore = try await store.podcastQueueState()

        // Playlist order is the reverse of the Larder's: third, then second.
        let playlist = try await created(model, .manual, "Backwards")
        await model.addToPlaylist(playlist.id, entryID: ids[2].rawValue)
        await model.addToPlaylist(playlist.id, entryID: ids[1].rawValue)
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], [ids[2].rawValue, ids[1].rawValue])

        model.playPlaylist(playlist)
        await model.waitForPlaybackOperationForTesting()
        try await settle()
        XCTAssertEqual(model.playback?.itemID, ids[2], "the playlist starts at its own first entry")
        XCTAssertTrue(model.playlistSessionIsCurrent)

        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle()
        model.simulatePodcastPlaybackFinishedForTesting()
        await model.waitForPlaybackOperationForTesting()
        try await settle()
        XCTAssertEqual(model.playback?.itemID, ids[1], "it advances in playlist order")

        let queueAfter = try await store.podcastQueueState()
        XCTAssertEqual(queueAfter.episodeIDs, queueBefore.episodeIDs, "the Larder queue is unchanged")
        XCTAssertEqual(queueAfter.currentEpisodeID, queueBefore.currentEpisodeID)
        XCTAssertEqual(model.podcastQueueIDs, queueBefore.episodeIDs.map(\.rawValue))
        let finished = try XCTUnwrap(model.episodes.first { $0.id == ids[2].rawValue })
        XCTAssertNil(finished.retiredAt, "a finished playlist entry is not retired from the Larder")
    }

    func testARemoteDeletionOfTheSelectedPlaylistReturnsTheSelectionToTheLarder() async throws {
        let f = try await fixture("remote-delete", count: 2)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let playlist = try await created(model, .manual, "Doomed")
        XCTAssertEqual(model.selectedNavigation, .playlist(playlist.id))

        // The playlist disappears under the model, as an inbound sync apply would remove it.
        try await store.deletePlaylist(id: playlist.id)
        await model.reloadLibraryRowsForTesting()

        XCTAssertEqual(model.selectedNavigation, .larder)
        XCTAssertFalse(model.playlists.playlists.contains { $0.id == playlist.id })
    }

    func testTheEndOfAPlaylistStopsItWithoutTouchingTheLarder() async throws {
        let f = try await fixture("manual-end", count: 3)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let queueBefore = try await store.podcastQueueState()
        let playlist = try await created(model, .manual, "One")
        await model.addToPlaylist(playlist.id, entryID: f.ids[2].rawValue)

        model.playPlaylist(playlist)
        await model.waitForPlaybackOperationForTesting()
        try await settle()
        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle()
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle()

        XCTAssertNil(model.playlists.session, "the session ends with the last entry")
        XCTAssertEqual(model.playlists.message, "Finished the playlist.")
        let queueAfter = try await store.podcastQueueState()
        XCTAssertEqual(queueAfter.episodeIDs, queueBefore.episodeIDs)
        XCTAssertEqual(queueAfter.currentEpisodeID, queueBefore.currentEpisodeID)
    }

    func testReorderAndRemoveEditOnlyTheManualPlaylist() async throws {
        let f = try await fixture("manual-edit", count: 3)
        let model = f.model
        let playlist = try await created(model, .manual, "Edit")
        for id in f.ids { await model.addToPlaylist(playlist.id, entryID: id.rawValue) }
        let raw = f.ids.map(\.rawValue)
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], raw)

        await model.movePlaylistEntry(playlist.id, entryID: raw[2], to: 0)
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], [raw[2], raw[0], raw[1]])
        await model.removeFromPlaylist(playlist.id, entryID: raw[0])
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], [raw[2], raw[1]])
        XCTAssertEqual(model.podcastQueueIDs, Array(raw.prefix(2)), "the Larder queue is not edited")
        XCTAssertTrue(model.episodes.contains { $0.id == raw[0] }, "removing from a playlist keeps the item")
    }

    func testAnAutomaticPlaylistShowsWhatItsRulesMatch() async throws {
        let f = try await fixture("automatic", count: 3)
        let model = f.model
        let playlist = try await created(model, .automatic, "Rules")
        XCTAssertTrue(model.playlistItems(playlist).isEmpty, "a new automatic playlist starts empty")

        let rule = try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue)
        let saved = await model.savePlaylistRules(playlist.id, rules: [rule], matchAll: true)
        XCTAssertTrue(saved)
        let updated = try XCTUnwrap(model.playlist(playlist.id))
        XCTAssertEqual(Set(model.playlistItems(updated).map(\.id)), Set(f.ids.map(\.rawValue)))

        let none = try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.played.rawValue)
        _ = await model.savePlaylistRules(playlist.id, rules: [rule, none], matchAll: false)
        XCTAssertEqual(model.playlistItems(try XCTUnwrap(model.playlist(playlist.id))).count, 3, "any-of")
        _ = await model.savePlaylistRules(playlist.id, rules: [rule, none], matchAll: true)
        XCTAssertTrue(model.playlistItems(try XCTUnwrap(model.playlist(playlist.id))).isEmpty, "all-of")
    }

    func testAnInvalidRuleDraftIsRefusedNotDropped() throws {
        var draft = WiltedMacPlaylistRuleDraft()
        draft.setField(.length, firstFeedID: nil)
        draft.value = "soon"
        XCTAssertThrowsError(try draft.makeRule())
        draft.value = "45"
        XCTAssertEqual(try draft.makeRule().value, "45")
    }

    func testNewPlaylistsGetUniqueNamesAndDeletingOneKeepsItsItems() async throws {
        let f = try await fixture("naming", count: 2)
        let model = f.model
        let first = try await created(model, .manual)
        let second = try await created(model, .automatic)
        XCTAssertEqual(first.name, "New Playlist")
        XCTAssertEqual(second.name, "New Playlist 2")
        XCTAssertEqual(model.selectedNavigation, .playlist(second.id), "a new playlist opens")
        await model.addToPlaylist(first.id, entryID: f.ids[0].rawValue)
        await model.renamePlaylist(first.id, to: "Mine")
        XCTAssertEqual(model.playlist(first.id)?.name, "Mine")
        await model.deletePlaylist(first.id)
        XCTAssertNil(model.playlist(first.id))
        XCTAssertTrue(model.episodes.contains { $0.id == f.ids[0].rawValue })
    }

    func testALoadThatFinishesAfterANewerOneNeverRevertsANewPlaylistOrItsSelection() async throws {
        let f = try await fixture("stale-load", count: 1)
        let model = f.model
        let hold = LoadHold()
        WiltedMacModel.afterPlaylistsRead = {
            hold.entered += 1
            // Only the first load (the one started before the playlist exists) is held.
            if hold.entered == 1 { await withCheckedContinuation { hold.release = $0 } }
        }
        defer { WiltedMacModel.afterPlaylistsRead = nil }

        let stale = Task { await model.loadPlaylists() }
        for _ in 0..<400 where hold.release == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(hold.release, "the older load is suspended after its read")

        let fresh = try await created(model, .manual, "Fresh")
        XCTAssertEqual(model.selectedNavigation, .playlist(fresh.id))
        hold.release?.resume()
        await stale.value

        XCTAssertEqual(model.playlists.playlists.map(\.id), [fresh.id], "the stale read did not erase the new playlist")
        XCTAssertEqual(model.selectedNavigation, .playlist(fresh.id), "nor push the selection back to the Larder")
    }

    func testAnInboundSyncDeletionDropsTheItemFromRowsAndPlaylistEntriesThroughTheLifecycle() async throws {
        let root = wiltedTemporaryDirectory("playlist-inbound-delete")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try XCTUnwrap(URL(string: "https://example.test/mac/inbound-delete"))
        let article = try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: "Inbound", source: "example.test",
                                  createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        let record = try WiltedRecordCodec().encode(
            article: article, currentRevisionID: RevisionID(rawValue: "rev-inbound-delete"))
        let transport = SequencedFetchTransport(batches: [
            try SyncFetchBatch(generationID: "g1", records: [record], engineState: Data([1])),
            try SyncFetchBatch(generationID: "g2", records: [], engineState: Data([2]), deletedRecordIDs: [record.id]),
        ])
        let model = WiltedMacModel(
            arguments: [], syncTransportFactory: { WiltedMacSyncTransportHandle(transport: transport) },
            stateDirectoryOverride: root, preferences: WiltedMacTestPreferences.ephemeral())
        defer { try? FileManager.default.removeItem(at: root) }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.loadPlaylists()

        func refresh(toFetchCount count: Int) async throws {
            model.refreshSync()
            for _ in 0..<600 {
                if await transport.fetchCount == count, model.syncStatus.phase == .completed { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("sync did not complete fetch \(count): \(model.syncStatus)")
        }

        try await refresh(toFetchCount: 1)
        XCTAssertTrue(model.articles.contains { $0.id == article.itemID.rawValue }, "the inbound item reached the rows")
        let playlist = try await created(model, .manual, "Reading")
        await model.addToPlaylist(playlist.id, entryID: article.itemID.rawValue)
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], [article.itemID.rawValue])

        try await refresh(toFetchCount: 2)
        XCTAssertEqual(model.playlists.entryIDs[playlist.id], [], "the deleted item left the playlist")
        XCTAssertFalse(model.articles.contains { $0.id == article.itemID.rawValue }, "and the Larder rows")
    }
}
