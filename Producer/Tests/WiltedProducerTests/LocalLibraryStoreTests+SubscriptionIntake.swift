import Foundation
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    /// A retry is a second delivery of the same intake response, not permission
    /// to fill the initial window with the remaining back catalogue.
    func testInitialMetadataRetryKeepsTheOriginalBoundedAdmission() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/intake-retry/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: Array(1...26))
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let first = try await store.savePodcastEpisodes(
            all, admission: .backfill, initialMetadataLimit: 5
        )
        let retry = try await store.savePodcastEpisodes(
            all, admission: .backfill, initialMetadataLimit: 5
        )
        let stored = try await store.podcastEpisodes(for: feed.itemID)

        XCTAssertEqual(first.newlyAdmitted.count, 5)
        XCTAssertEqual(retry.newlyAdmitted, [])
        XCTAssertEqual(stored.count, 5)
    }

    func testDuplicateAdmissionPreservesTheCapButRefreshesKnownAndNewEpisodes() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/intake-duplicate/feed.xml")!
        let (feed, offered) = try episodes(feedURL: feedURL, origin: origin, daysAgo: Array(1...26))
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        _ = try await store.savePodcastEpisodes(offered, admission: .backfill, initialMetadataLimit: 5)

        let corrected = try PodcastEpisode(
            itemID: offered[0].itemID, feedID: feed.itemID, feedURL: feedURL,
            rssGUID: offered[0].rssGUID, title: "Corrected newest", publishedTime: offered[0].publishedTime,
            enclosureURL: offered[0].enclosureURL, enclosureMediaType: offered[0].enclosureMediaType,
            createdAt: offered[0].createdAt
        )
        let future = try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "future", enclosureURL: URL(string: "https://media.example.test/future.mp3")!),
            feedID: feed.itemID, feedURL: feedURL, rssGUID: "future", title: "Future",
            publishedTime: Timestamp(origin.addingTimeInterval(60)), enclosureURL: URL(string: "https://media.example.test/future.mp3")!,
            enclosureMediaType: "audio/mpeg", createdAt: Timestamp(origin)
        )
        let refresh = try await store.savePodcastEpisodes(
            [corrected] + Array(offered.dropFirst()) + [future], admission: .incremental
        )
        let stored = try await store.podcastEpisodes(for: feed.itemID)

        XCTAssertEqual(refresh.newlyAdmitted, [future.itemID])
        XCTAssertEqual(stored.count, 6, "a duplicate may not widen its initial backfill cap")
        XCTAssertEqual(stored.first(where: { $0.itemID == corrected.itemID })?.title, "Corrected newest")
    }
}
