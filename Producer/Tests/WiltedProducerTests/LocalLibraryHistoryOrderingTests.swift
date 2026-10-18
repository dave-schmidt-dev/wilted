import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

/// Calculated History sorts are global across the matching set before a page
/// is selected; full rows and page-only facts are then hydrated in that order.
final class LocalLibraryHistoryOrderingTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testCalculatedOrdersPageGloballyAcrossAllFeedsAndOneFeed() async throws {
        let store = try makeStore()
        let firstFeed = try Feed("ordering-first")
        let secondFeed = try Feed("ordering-second")
        let first = try firstFeed.episodes(count: 134, name: "first")
        let second = try secondFeed.episodes(count: 129, name: "second")
        let episodes = first + second
        XCTAssertGreaterThan(episodes.count, 256, "the fixture spans multiple scalar-key batches")
        try await store.savePodcastEpisodes(episodes, admission: .backfill)
        let removedAt = Timestamp(Date(timeIntervalSince1970: 1_900_000_000))
        let result = try await store.retireEpisodes(episodes.map(\.itemID), at: removedAt)
        XCTAssertEqual(result.committed.count, episodes.count)

        for sort in [LibraryEpisodeOrdering.Sort.length, .age, .alphabetical] {
            for direction in LibraryEpisodeOrdering.Direction.allCases {
                let everyFeed = try await collectPages(
                    store, feed: nil, sort: sort, direction: direction, expectedTotal: episodes.count
                )
                let allKeys = episodes.map(Self.key)
                let expected = LibraryEpisodeOrdering.ordered(allKeys, sort: sort, direction: direction).map(\.id)
                XCTAssertEqual(everyFeed.map { $0.episodeID.rawValue }, expected, "all feeds: \(sort), \(direction)")
                XCTAssertEqual(Set(everyFeed.map(\.episodeID)).count, episodes.count, "all-feed pages overlap")
                XCTAssertTrue(everyFeed.allSatisfy { $0.retiredAt == removedAt })

                let firstFeedRows = try await collectPages(
                    store, feed: firstFeed.id, sort: sort, direction: direction, expectedTotal: first.count
                )
                let expectedFirst = LibraryEpisodeOrdering.ordered(
                    first.map(Self.key), sort: sort, direction: direction
                ).map(\.id)
                XCTAssertEqual(firstFeedRows.map { $0.episodeID.rawValue }, expectedFirst,
                               "one feed: \(sort), \(direction)")
                XCTAssertTrue(firstFeedRows.allSatisfy { $0.feedID == firstFeed.id })
            }
        }

        let artworkID = try XCTUnwrap(episodes.first(where: { $0.rssGUID == "first-00" })?.itemID)
        let artworkPage = try await store.historyPage(
            feedID: nil, sort: .alphabetical, direction: .ascending, limit: 25
        )
        XCTAssertEqual(artworkPage.total, episodes.count)
        XCTAssertEqual(artworkPage.rows.first?.episodeID, artworkID,
                       "article-stripped title puts this row on the selected page")
        // The selected page preserves the store's original episode facts,
        // including artwork, instead of rebuilding a partial row from keys.
        XCTAssertEqual(artworkPage.rows.first?.artworkURL, URL(string: "https://cdn.example.test/history-cover.jpg"))
    }

    func testKnownFactsAndNaturalAlphabeticalTitlesOutrankUnknownsInBothDirections() async throws {
        let store = try makeStore()
        let feed = try Feed("ordering-edge-cases")
        let knownShort = try feed.episode("short", title: "The Alpha", duration: 60, published: 1_700_000_000)
        let naturalTwo = try feed.episode("natural-two", title: "Episode 2", duration: 120, published: 1_700_000_100)
        let naturalTen = try feed.episode("natural-ten", title: "Episode 10", duration: 240, published: 1_700_000_200)
        let unknownLength = try feed.episode("unknown-length", title: "Unknown Length", duration: nil, published: 1_700_000_300)
        let unknownAge = try feed.episode("unknown-age", title: "Unknown Age", duration: 480, published: nil)
        let episodes = [unknownAge, naturalTen, unknownLength, knownShort, naturalTwo]
        try await store.savePodcastEpisodes(episodes, admission: .backfill)
        _ = try await store.retireEpisodes(episodes.map(\.itemID), at: Timestamp(Date()))

        for direction in LibraryEpisodeOrdering.Direction.allCases {
            let length = try await store.historyPage(
                feedID: feed.id, sort: .length, direction: direction, limit: 20
            )
            XCTAssertEqual(length.rows.last?.episodeID, unknownLength.itemID,
                           "unknown duration remains last for \(direction)")

            let age = try await store.historyPage(feedID: feed.id, sort: .age, direction: direction, limit: 20)
            XCTAssertEqual(age.rows.last?.episodeID, unknownAge.itemID,
                           "unknown publication date remains last for \(direction)")
        }

        try await store.saveListening(PodcastListeningState(
            episodeID: naturalTwo.itemID,
            completedAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)),
            lastRevisionID: nil,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000))
        ))
        let filtered = try await store.historyPage(
            feedID: feed.id, search: "Episode", status: .skipped,
            sort: .alphabetical, direction: .descending, limit: 1
        )
        XCTAssertEqual(filtered.total, 1, "search and status filter the set before calculated paging")
        XCTAssertEqual(filtered.rows.map(\.episodeID), [naturalTen.itemID])
        XCTAssertEqual(filtered.rows.first?.status, .skipped)

        let alphabetical = try await store.historyPage(
            feedID: feed.id, sort: .alphabetical, direction: .ascending, limit: 20
        )
        let alphabeticalIDs = alphabetical.rows.map(\.episodeID)
        XCTAssertLessThan(try XCTUnwrap(alphabeticalIDs.firstIndex(of: knownShort.itemID)),
                          try XCTUnwrap(alphabeticalIDs.firstIndex(of: naturalTwo.itemID)),
                          "leading The is ignored for the title key")
        XCTAssertLessThan(try XCTUnwrap(alphabeticalIDs.firstIndex(of: naturalTwo.itemID)),
                          try XCTUnwrap(alphabeticalIDs.firstIndex(of: naturalTen.itemID)),
                          "numeric title portions compare naturally")
    }

    private func makeStore() throws -> LocalLibraryStore {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-history-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
    }

    private func collectPages(
        _ store: LocalLibraryStore,
        feed: ItemID?,
        sort: LibraryEpisodeOrdering.Sort,
        direction: LibraryEpisodeOrdering.Direction,
        expectedTotal: Int
    ) async throws -> [LocalLibraryStore.HistoryRow] {
        var rows: [LocalLibraryStore.HistoryRow] = []
        var offset = 0
        while offset < expectedTotal {
            let page = try await store.historyPage(
                feedID: feed, sort: sort, direction: direction, offset: offset, limit: 25
            )
            XCTAssertEqual(page.total, expectedTotal)
            XCTAssertEqual(page.offset, offset)
            XCTAssertLessThanOrEqual(page.rows.count, 25)
            rows.append(contentsOf: page.rows)
            offset += page.rows.count
            XCTAssertGreaterThan(page.rows.count, 0, "a calculated page cannot stop before the total")
        }
        return rows
    }

    private static func key(_ episode: PodcastEpisode) -> LibraryEpisodeOrdering.Key {
        LibraryEpisodeOrdering.Key(
            id: episode.itemID.rawValue,
            title: episode.title,
            durationSeconds: episode.durationSeconds,
            publishedAt: episode.publishedTime?.date
        )
    }

    private struct Feed {
        let url: URL
        let id: ItemID

        init(_ slug: String) throws {
            url = URL(string: "https://podcasts.example.test/\(slug).xml")!
            id = try ItemID.derivePodcastFeed(from: url)
        }

        func episodes(count: Int, name: String) throws -> [PodcastEpisode] {
            try (0..<count).map { index in
                try episode(
                    "\(name)-\(String(format: "%02d", index))",
                    title: index == 0 ? "The Alpha \(name)" : "Episode \(index) \(name)",
                    duration: index.isMultiple(of: 9) ? nil : Double(60 + index * 17),
                    published: index.isMultiple(of: 11) ? nil : 1_700_000_000 + Double(index * 1_000),
                    artwork: index == 0 ? URL(string: "https://cdn.example.test/history-cover.jpg") : nil
                )
            }
        }

        func episode(
            _ guid: String,
            title: String,
            duration: Double?,
            published: Double?,
            artwork: URL? = nil
        ) throws -> PodcastEpisode {
            let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: url, rssGUID: guid, enclosureURL: enclosure),
                feedID: id, feedURL: url, rssGUID: guid, title: title,
                publishedTime: published.map { Timestamp(Date(timeIntervalSince1970: $0)) },
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", durationSeconds: duration,
                artworkURL: artwork, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            )
        }
    }
}
