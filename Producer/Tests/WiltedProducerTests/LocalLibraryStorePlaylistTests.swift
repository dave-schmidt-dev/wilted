import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

final class LocalLibraryStorePlaylistTests: XCTestCase {
    private func makeStore() throws -> (LocalLibraryStore, URL) {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-playlist-\(UUID().uuidString)")
        return (try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite")), directory)
    }

    func testReorderingManualPlaylistLeavesLarderQueueOrderUnchanged() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["e1", "e2", "e3"] { try await store.addPodcastQueueEpisode(ItemID(rawValue: id)) }
        let queueBefore = try await store.podcastQueueState()

        let playlist = try await store.createPlaylist(name: "Mine", kind: .manual)
        for id in ["e3", "e1", "e2"] { try await store.addPlaylistEntry(playlistID: playlist.id, entryID: id) }
        try await store.movePlaylistEntry(playlistID: playlist.id, entryID: "e2", to: 0)
        var order = try await store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(order, ["e2", "e3", "e1"])
        try await store.movePlaylistEntry(playlistID: playlist.id, entryID: "e2", to: 2)
        order = try await store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(order, ["e3", "e1", "e2"])

        let queueAfter = try await store.podcastQueueState()
        XCTAssertEqual(queueAfter, queueBefore)
        XCTAssertEqual(queueAfter.episodeIDs.map(\.rawValue), ["e1", "e2", "e3"])
    }

    func testRepeatedMovesRebalanceKeysAndKeepOrder() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlist = try await store.createPlaylist(name: "Tight", kind: .manual)
        for id in ["a", "b", "c"] { try await store.addPlaylistEntry(playlistID: playlist.id, entryID: id) }
        // Each move squeezes a key between "a" and the previous neighbour until
        // doubles run out and the playlist rebalances.
        var expected = ["a", "b", "c"]
        for step in 0..<120 {
            let mover = step.isMultiple(of: 2) ? "c" : "b"
            let other = mover == "c" ? "b" : "c"
            try await store.movePlaylistEntry(playlistID: playlist.id, entryID: mover, to: 1)
            expected = ["a", mover, other]
            let order = try await store.playlistEntryIDs(playlistID: playlist.id)
            XCTAssertEqual(order, expected, "step \(step)")
        }
    }

    func testRemovedEntryDisappearsFromManualPlaylists() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await store.createPlaylist(name: "One", kind: .manual)
        let second = try await store.createPlaylist(name: "Two", kind: .manual)
        for id in ["x", "y"] { try await store.addPlaylistEntry(playlistID: first.id, entryID: id) }
        for id in ["y", "z"] { try await store.addPlaylistEntry(playlistID: second.id, entryID: id) }

        try await store.removeEntryFromAllPlaylists(entryID: "y")

        let firstEntries = try await store.playlistEntryIDs(playlistID: first.id)
        let secondEntries = try await store.playlistEntryIDs(playlistID: second.id)
        XCTAssertEqual(firstEntries, ["x"])
        XCTAssertEqual(secondEntries, ["z"])
    }

    func testPlaylistCrudRulesAndDeleteSurviveReopen() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manual = try await store.createPlaylist(name: "Manual", kind: .manual)
        let auto = try await store.createPlaylist(name: "Auto", kind: .automatic, matchAll: false)
        try await store.addPlaylistEntry(playlistID: manual.id, entryID: "x")
        try await store.addPlaylistEntry(playlistID: manual.id, entryID: "x")
        let entries = try await store.playlistEntryIDs(playlistID: manual.id)
        XCTAssertEqual(entries, ["x"], "adding twice keeps one row")

        let rules = [try PlaylistRule(field: .kind, comparator: .is, value: "article"),
                     try PlaylistRule(field: .length, comparator: .shorterThan, value: "10")]
        try await store.setPlaylistRules(playlistID: auto.id, rules: rules)
        try await store.updatePlaylist(id: auto.id, name: "Auto 2")

        let reopened = try LocalLibraryStore(url: await store.url)
        let stored = try await reopened.playlists()
        XCTAssertEqual(stored.map(\.name), ["Manual", "Auto 2"])
        XCTAssertEqual(stored.map(\.sortIndex), [0, 1])
        XCTAssertEqual(stored[1].matchAll, false)
        let storedRules = try await reopened.playlistRules(playlistID: auto.id)
        XCTAssertEqual(storedRules, rules)

        do { try await store.addPlaylistEntry(playlistID: auto.id, entryID: "x"); XCTFail("automatic takes no entries") } catch {}
        do { try await store.setPlaylistRules(playlistID: manual.id, rules: rules); XCTFail("manual takes no rules") } catch {}

        try await store.deletePlaylist(id: manual.id)
        try await store.deletePlaylist(id: auto.id)
        let remaining = try await store.playlists()
        let leftoverEntries = try await store.playlistEntryIDs(playlistID: manual.id)
        let leftoverRules = try await store.playlistRules(playlistID: auto.id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(leftoverEntries.isEmpty)
        XCTAssertTrue(leftoverRules.isEmpty)
    }

    // MARK: - Library removal

    private func podcast(_ origin: Date) throws -> (feed: PodcastFeed, episodes: [PodcastEpisode]) {
        let feedURL = URL(string: "https://podcasts.example.test/show/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", author: nil,
                                   artworkURL: nil, createdAt: Timestamp(origin))
        let episodes = try ["g1", "g2"].map { guid -> PodcastEpisode in
            let enclosure = URL(string: "https://podcasts.example.test/show/\(guid).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure),
                feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid, publishedTime: nil,
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: Timestamp(origin))
        }
        return (feed, episodes)
    }

    func testDismissingAnEpisodeRemovesItFromManualPlaylists() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (feed, episodes) = try podcast(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: feed)
        for episode in episodes { try await store.save(episode: episode) }
        let playlist = try await store.createPlaylist(name: "Mine", kind: .manual)
        for episode in episodes { try await store.addPlaylistEntry(playlistID: playlist.id, entryID: episode.itemID.rawValue) }

        let dismissed = try await store.dismissPodcastEpisode(episodes[0].itemID)

        XCTAssertTrue(dismissed)
        let entries = try await store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(entries, [episodes[1].itemID.rawValue])
    }

    func testUnsubscribingRemovesItsEpisodesFromManualPlaylists() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let (feed, episodes) = try podcast(origin)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        for episode in episodes { try await store.save(episode: episode) }
        let playlist = try await store.createPlaylist(name: "Mine", kind: .manual)
        for id in episodes.map(\.itemID.rawValue) + ["other"] {
            try await store.addPlaylistEntry(playlistID: playlist.id, entryID: id)
        }

        let removed = try await store.unsubscribeFromPodcast(feedID: feed.itemID)

        XCTAssertEqual(removed, 2)
        let entries = try await store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(entries, ["other"])
    }

    func testRemovingAnArticleRemovesItFromManualPlaylists() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://example.test/library/playlist-article")!
        let article = try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: "A", source: "example.test",
                                  createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        try await store.save(article: article)
        let playlist = try await store.createPlaylist(name: "Mine", kind: .manual)
        for id in [article.itemID.rawValue, "keep"] { try await store.addPlaylistEntry(playlistID: playlist.id, entryID: id) }

        let removed = try await store.removeArticle(itemID: article.itemID)

        XCTAssertTrue(removed)
        let entries = try await store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(entries, ["keep"])
    }
}
