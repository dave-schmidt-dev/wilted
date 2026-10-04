import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// The episode page the feed published reaches the Mac's episode rows, so Share can use it.
@MainActor
final class WiltedMacEpisodeLinkTests: XCTestCase {
    func testLoadedEpisodesCarryTheirStoredPageAndLinklessOnesCarryNone() async throws {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("episode-link"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        let feedURL = URL(string: "https://feeds.example.test/links.xml")!
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        let page = URL(string: "https://show.example.test/episodes/one")!
        var ids: [String: String] = [:]
        for (guid, link) in [("linked", page as URL?), ("linkless", nil)] {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid,
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
                episodeLink: link, createdAt: created))
            ids[guid] = id.rawValue
        }
        await model.reloadLibraryRowsForTesting()

        XCTAssertEqual(model.episodes.first { $0.id == ids["linked"] }?.episodeLink, page)
        XCTAssertNil(model.episodes.first { $0.id == ids["linkless"] }?.episodeLink)
        XCTAssertEqual(model.episodes.count, 2)
    }
}
