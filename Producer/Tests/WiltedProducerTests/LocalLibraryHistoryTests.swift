import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// Store-side paged History: ordering, paging bounds, totals, and filters,
/// for one feed and for every feed at once.
final class LocalLibraryHistoryTests: XCTestCase {
    private typealias Store = LocalLibraryStore
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    // MARK: - Scale: 5,000 removed rows across two feeds, per feed and all together

    func testFiveThousandRemovedRowsPageNewestFirstWithoutOverlapAndExactTotals() async throws {
        let store = try makeStore()
        let feedA = try Feed("history-a"), feedB = try Feed("history-b")
        let removedA = try (0..<3_000).map { try feedA.episode("a-\($0)", title: "Alpha \($0)") }
        let removedB = try (0..<2_000).map { try feedB.episode("b-\($0)", title: "Beta \($0)") }
        let kept = try (0..<50).map { try feedA.episode("a-kept-\($0)", title: "Alpha kept \($0)") }
            + (0..<50).map { try feedB.episode("b-kept-\($0)", title: "Beta kept \($0)") }
        try await store.savePodcastEpisodes(removedA + removedB + kept, admission: .backfill)

        // Interleave the feeds and retire in batches that share a timestamp,
        // so ordering exercises both the time key and the identifier tie-break.
        var retiredAt: [String: Date] = [:]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let dismissedIDs = Array(removedA.prefix(10).map(\.itemID)) + Array(removedB.prefix(5).map(\.itemID))
        let dismissedSet = Set(dismissedIDs)
        let interleaved = zip(removedA.dropFirst(10), removedB.dropFirst(5)).flatMap { [$0, $1] }
            + removedA.dropFirst(10 + 1_995)
        XCTAssertEqual(interleaved.count + dismissedIDs.count, 5_000)
        for (batch, start) in stride(from: 0, to: interleaved.count, by: 100).enumerated() {
            let ids = interleaved[start..<min(start + 100, interleaved.count)].map(\.itemID)
            let at = base.addingTimeInterval(Double(batch))
            let result = try await store.retireEpisodes(ids, at: Timestamp(at))
            XCTAssertEqual(result.committed.count, ids.count)
            for id in ids { retiredAt[id.rawValue] = at }
        }
        for (index, id) in dismissedIDs.enumerated() {
            let at = base.addingTimeInterval(10_000 + Double(index % 3))
            let dismissed = try await store.dismissPodcastEpisode(id, at: Timestamp(at))
            XCTAssertTrue(dismissed)
            retiredAt[id.rawValue] = at
        }

        // Every third removed row in both feeds, plus kept rows, is completed:
        // well over 999 identifiers reach the status predicate.
        let completedIDs = Set(
            removedA.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.itemID.rawValue)
                + removedB.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.itemID.rawValue)
        )
        XCTAssertGreaterThan(completedIDs.count, 1_500)
        let ruleID = UUID()
        let ruleSkipped = Set(removedA.enumerated().filter { $0.offset % 7 == 1 }.map(\.element.itemID.rawValue))
        let playedRuleSkip = removedA[21].itemID.rawValue // offset 21: completed and rule-skipped
        try seed(store, completed: completedIDs.union(kept.map(\.itemID.rawValue)),
                 ruleSkips: ruleSkipped.union([playedRuleSkip]), ruleID: ruleID)

        let expectedA = Self.newestFirst(removedA.map(\.itemID.rawValue), retiredAt: retiredAt)
        let expectedB = Self.newestFirst(removedB.map(\.itemID.rawValue), retiredAt: retiredAt)

        let allA = try await collectPages(store, feed: feedA.id, status: nil, limit: 37, expectedTotal: 3_000)
        XCTAssertEqual(allA.map(\.episodeID.rawValue), expectedA)
        XCTAssertEqual(Set(allA.map(\.episodeID.rawValue)).count, 3_000, "pages overlap")
        XCTAssertTrue(allA.allSatisfy { $0.feedID == feedA.id })
        XCTAssertEqual(Set(allA.filter { $0.removalKind == .dismissed }.map(\.episodeID)),
                       Set(removedA.prefix(10).map(\.itemID)))
        XCTAssertTrue(allA.filter { dismissedSet.contains($0.episodeID) }.allSatisfy { $0.removalKind == .dismissed })
        XCTAssertEqual(allA.first?.retiredAt?.date, base.addingTimeInterval(10_002))

        let allB = try await collectPages(store, feed: feedB.id, status: nil, limit: 250, expectedTotal: 2_000)
        XCTAssertEqual(allB.map(\.episodeID.rawValue), expectedB)

        // Every feed at once: one newest-first order across both feeds, and
        // the status split still exact with well over 999 completed identifiers.
        let expectedAll = Self.newestFirst((removedA + removedB).map(\.itemID.rawValue), retiredAt: retiredAt)
        let everyFeed = try await collectPages(store, feed: nil, status: nil, limit: 250, expectedTotal: 5_000)
        XCTAssertEqual(everyFeed.map(\.episodeID.rawValue), expectedAll)
        let expectedEverySkipped = expectedAll.filter { !completedIDs.contains($0) }
        let everySkipped = try await collectPages(
            store, feed: nil, status: .skipped, limit: 400, expectedTotal: expectedEverySkipped.count)
        XCTAssertEqual(everySkipped.map(\.episodeID.rawValue), expectedEverySkipped)
        let expectedEveryPlayed = expectedAll.filter { completedIDs.contains($0) }
        let everyPlayed = try await collectPages(
            store, feed: nil, status: .played, limit: 400, expectedTotal: expectedEveryPlayed.count)
        XCTAssertEqual(everyPlayed.map(\.episodeID.rawValue), expectedEveryPlayed)

        let keptIDs = Set(kept.map(\.itemID.rawValue))
        XCTAssertTrue((allA + allB).allSatisfy { !keptIDs.contains($0.episodeID.rawValue) })

        // Status filters page with exact totals and agree with per-row status.
        let playedA = try await collectPages(store, feed: feedA.id, status: .played, limit: 101, expectedTotal: 1_000)
        XCTAssertEqual(playedA.map(\.episodeID.rawValue), expectedA.filter { completedIDs.contains($0) })
        XCTAssertTrue(playedA.allSatisfy { $0.status == .played && $0.ruleID == nil })
        XCTAssertTrue(playedA.contains { $0.episodeID.rawValue == playedRuleSkip }, "played wins over a rule skip")

        let skippedA = try await collectPages(store, feed: feedA.id, status: .skipped, limit: 101, expectedTotal: 2_000)
        XCTAssertEqual(skippedA.map(\.episodeID.rawValue), expectedA.filter { !completedIDs.contains($0) })
        XCTAssertTrue(skippedA.allSatisfy { $0.status == .skipped || $0.status == .skippedByRule })
        let byRule = skippedA.filter { $0.status == .skippedByRule }
        XCTAssertEqual(Set(byRule.map(\.episodeID.rawValue)), ruleSkipped.subtracting(completedIDs))
        XCTAssertTrue(byRule.allSatisfy { $0.ruleID == ruleID })
        XCTAssertTrue(skippedA.filter { $0.status == .skipped }.allSatisfy { $0.ruleID == nil })

        // Paging bounds: past the end, zero limit, and a negative offset.
        let pastEnd = try await store.historyPage(feedID: feedA.id, offset: 3_005, limit: 37)
        XCTAssertEqual(pastEnd.rows, [])
        XCTAssertEqual(pastEnd.total, 3_000)
        let zeroLimit = try await store.historyPage(feedID: feedA.id, status: .skipped, offset: 0, limit: 0)
        XCTAssertEqual(zeroLimit.rows, [])
        XCTAssertEqual(zeroLimit.total, 2_000)
        let negative = try await store.historyPage(feedID: feedB.id, offset: -4, limit: 3)
        XCTAssertEqual(negative.offset, 0)
        XCTAssertEqual(negative.rows.map(\.episodeID.rawValue), Array(expectedB.prefix(3)))
    }

    // MARK: - Filters

    func testFiltersIsolateFeedsSearchTitlesAndSplitPlayedFromSkipped() async throws {
        let store = try makeStore()
        let feed = try Feed("history-filters"), other = try Feed("history-other")
        let morning = try feed.episode("morning", title: "Morning News", duration: 1_234)
        let evening = try feed.episode("evening", title: "Evening NEWS Special")
        let weather = try feed.episode("weather", title: "Weather")
        let sports = try feed.episode("sports", title: "Sports Roundup")
        let keptByRule = try feed.episode("kept-rule", title: "Kept by rule, retired by hand")
        let playedRule = try feed.episode("played-rule", title: "Rule skip later played")
        let shelf = try feed.episode("shelf", title: "Shelf news")
        let elsewhere = try other.episode("elsewhere", title: "Other News")
        try await store.savePodcastEpisodes(
            [morning, evening, weather, sports, keptByRule, playedRule, shelf, elsewhere], admission: .backfill
        )

        let skipRule = UUID(), keepRule = UUID()
        func at(_ seconds: Double) -> Timestamp { Timestamp(Date(timeIntervalSince1970: 1_900_000_000 + seconds)) }
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: weather.itemID, decision: .skip, source: .rule, ruleID: skipRule, decidedAt: at(0)))
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: keptByRule.itemID, decision: .keep, source: .rule, ruleID: keepRule, decidedAt: at(0)))
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: playedRule.itemID, decision: .skip, source: .rule, ruleID: skipRule, decidedAt: at(0)))
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: shelf.itemID, decision: .skip, source: .rule, ruleID: skipRule, decidedAt: at(0)))

        var wrote: [Bool] = []
        wrote.append(try await store.retireEpisode(morning.itemID, at: at(10)))
        wrote.append(try await store.completeAndRetireEpisode(listening: PodcastListeningState(
            episodeID: evening.itemID, completedAt: at(19), lastRevisionID: nil, updatedAt: at(19)), at: at(20)))
        wrote.append(try await store.retireEpisode(weather.itemID, at: at(30)))
        wrote.append(try await store.dismissPodcastEpisode(sports.itemID, at: at(40)))
        wrote.append(try await store.retireEpisode(keptByRule.itemID, at: at(50)))
        wrote.append(try await store.completeAndRetireEpisode(listening: PodcastListeningState(
            episodeID: playedRule.itemID, completedAt: at(59), lastRevisionID: nil, updatedAt: at(59)), at: at(60)))
        wrote.append(try await store.retireEpisode(elsewhere.itemID, at: at(70)))
        XCTAssertEqual(wrote, Array(repeating: true, count: 7))
        // `shelf` stays on the shelf, even though it is completed and carries a rule skip.
        try await store.saveListening(PodcastListeningState(
            episodeID: shelf.itemID, completedAt: at(5), lastRevisionID: nil, updatedAt: at(5)))

        let all = try await store.historyPage(feedID: feed.id, limit: 50)
        XCTAssertEqual(all.total, 6)
        XCTAssertEqual(all.rows.map(\.episodeID), [playedRule, keptByRule, sports, weather, evening, morning].map(\.itemID))
        let byID = Dictionary(uniqueKeysWithValues: all.rows.map { ($0.episodeID, $0) })
        XCTAssertEqual(byID[morning.itemID]?.status, .skipped)
        XCTAssertEqual(byID[evening.itemID]?.status, .played)
        XCTAssertEqual(byID[weather.itemID]?.status, .skippedByRule)
        XCTAssertEqual(byID[weather.itemID]?.ruleID, skipRule)
        XCTAssertEqual(byID[sports.itemID]?.status, .skipped)
        XCTAssertEqual(byID[sports.itemID]?.removalKind, .dismissed)
        XCTAssertEqual(byID[keptByRule.itemID]?.status, .skipped)
        XCTAssertNil(byID[keptByRule.itemID]?.ruleID, "a rule keep is not a rule skip")
        XCTAssertEqual(byID[playedRule.itemID]?.status, .played)
        XCTAssertNil(byID[playedRule.itemID]?.ruleID)
        XCTAssertEqual(byID[morning.itemID], Store.HistoryRow(
            episodeID: morning.itemID, title: "Morning News", feedID: feed.id,
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)), durationSeconds: 1_234,
            retiredAt: at(10), removalKind: .retired, status: .skipped, ruleID: nil))
        XCTAssertNil(byID[evening.itemID]?.durationSeconds, "a feed that published no duration has none")
        XCTAssertFalse(all.rows.contains { $0.episodeID == shelf.itemID || $0.episodeID == elsewhere.itemID })

        let otherFeed = try await store.historyPage(feedID: other.id, limit: 50)
        XCTAssertEqual(otherFeed.rows.map(\.episodeID), [elsewhere.itemID])
        XCTAssertEqual(otherFeed.total, 1)

        for query in ["news", "  NEWS  ", "nEwS"] {
            let found = try await store.historyPage(feedID: feed.id, search: query, limit: 50)
            XCTAssertEqual(found.rows.map(\.episodeID), [evening.itemID, morning.itemID], query)
            XCTAssertEqual(found.total, 2, query)
        }
        let blank = try await store.historyPage(feedID: feed.id, search: "   ", limit: 50)
        XCTAssertEqual(blank.total, 6)
        let none = try await store.historyPage(feedID: feed.id, search: "podcast", limit: 50)
        XCTAssertEqual(none.rows, [])
        XCTAssertEqual(none.total, 0)

        let played = try await store.historyPage(feedID: feed.id, status: .played, limit: 50)
        XCTAssertEqual(played.rows.map(\.episodeID), [playedRule.itemID, evening.itemID])
        XCTAssertEqual(played.total, 2)
        let skipped = try await store.historyPage(feedID: feed.id, status: .skipped, limit: 50)
        XCTAssertEqual(skipped.rows.map(\.episodeID), [keptByRule, sports, weather, morning].map(\.itemID))
        XCTAssertEqual(skipped.rows.map(\.status), [.skipped, .skipped, .skippedByRule, .skipped])
        XCTAssertEqual(skipped.total, 4)
        let skippedNews = try await store.historyPage(feedID: feed.id, search: "news", status: .skipped, limit: 50)
        XCTAssertEqual(skippedNews.rows.map(\.episodeID), [morning.itemID])
        let playedNews = try await store.historyPage(feedID: feed.id, search: "news", status: .played, limit: 50)
        XCTAssertEqual(playedNews.rows.map(\.episodeID), [evening.itemID])

        let pageTwo = try await store.historyPage(feedID: feed.id, status: .skipped, offset: 2, limit: 1)
        XCTAssertEqual(pageTwo.rows.map(\.episodeID), [weather.itemID])
        XCTAssertEqual(pageTwo.rows.first?.status, .skippedByRule)
        XCTAssertEqual(pageTwo.total, 4)

        // A nil feed reads every feed's History through each predicate variant.
        let everyFeed = try await store.historyPage(feedID: nil, limit: 50)
        XCTAssertEqual(everyFeed.total, 7)
        XCTAssertEqual(everyFeed.rows.map(\.episodeID),
                       [elsewhere, playedRule, keptByRule, sports, weather, evening, morning].map(\.itemID))
        XCTAssertEqual(everyFeed.rows.first?.feedID, other.id)
        let everyNews = try await store.historyPage(feedID: nil, search: " news ", limit: 50)
        XCTAssertEqual(everyNews.rows.map(\.episodeID), [elsewhere, evening, morning].map(\.itemID))
        XCTAssertEqual(everyNews.total, 3)
        let everyPlayed = try await store.historyPage(feedID: nil, status: .played, limit: 50)
        XCTAssertEqual(everyPlayed.rows.map(\.episodeID), [playedRule.itemID, evening.itemID])
        let everySkipped = try await store.historyPage(feedID: nil, status: .skipped, limit: 50)
        XCTAssertEqual(everySkipped.rows.map(\.episodeID), [elsewhere, keptByRule, sports, weather, morning].map(\.itemID))
        XCTAssertEqual(everySkipped.rows.map(\.status), [.skipped, .skipped, .skipped, .skippedByRule, .skipped])
        XCTAssertEqual(everySkipped.total, 5)
        let everyPlayedNews = try await store.historyPage(feedID: nil, search: "news", status: .played, limit: 50)
        XCTAssertEqual(everyPlayedNews.rows.map(\.episodeID), [evening.itemID])
        let everySkippedNews = try await store.historyPage(feedID: nil, search: "news", status: .skipped, limit: 50)
        XCTAssertEqual(everySkippedNews.rows.map(\.episodeID), [elsewhere.itemID, morning.itemID])
        XCTAssertEqual(everySkippedNews.total, 2)
        let everyRuleSkip = try await store.historyPage(feedID: nil, status: .skipped, offset: 3, limit: 1)
        XCTAssertEqual(everyRuleSkip.rows.map(\.episodeID), [weather.itemID])
        XCTAssertEqual(everyRuleSkip.rows.first?.ruleID, skipRule)
        XCTAssertEqual(everyRuleSkip.total, 5)
    }

    func testKeptEpisodesNeverAppearAndStatusFiltersWorkWithoutAnyCompletion() async throws {
        let store = try makeStore()
        let feed = try Feed("history-kept")
        let episodes = try (0..<6).map { try feed.episode("kept-\($0)", title: "Kept \($0)") }
        try await store.savePodcastEpisodes(episodes, admission: .backfill)

        let empty = try await store.historyPage(feedID: feed.id, limit: 10)
        XCTAssertEqual(empty.rows, [])
        XCTAssertEqual(empty.total, 0)

        let retired = episodes[4]
        var wrote: [Bool] = []
        wrote.append(try await store.retireEpisode(retired.itemID, at: Timestamp(Date(timeIntervalSince1970: 1_950_000_000))))
        // A restored episode is back on the shelf and leaves History.
        wrote.append(try await store.retireEpisode(episodes[1].itemID))
        wrote.append(try await store.restoreEpisode(episodes[1].itemID))
        XCTAssertEqual(wrote, [true, true, true])

        let page = try await store.historyPage(feedID: feed.id, limit: 10)
        XCTAssertEqual(page.rows.map(\.episodeID), [retired.itemID])
        XCTAssertEqual(page.total, 1)
        let played = try await store.historyPage(feedID: feed.id, status: .played, limit: 10)
        XCTAssertEqual(played.rows, [])
        XCTAssertEqual(played.total, 0)
        let skipped = try await store.historyPage(feedID: feed.id, status: .skipped, limit: 10)
        XCTAssertEqual(skipped.rows.map(\.episodeID), [retired.itemID])
        XCTAssertEqual(skipped.total, 1)
    }

    // MARK: - Helpers

    private struct Feed {
        let url: URL
        let id: ItemID

        init(_ slug: String) throws {
            url = URL(string: "https://podcasts.example.test/\(slug).xml")!
            id = try ItemID.derivePodcastFeed(from: url)
        }

        func episode(_ guid: String, title: String, duration: Double? = nil) throws -> PodcastEpisode {
            let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: url, rssGUID: guid, enclosureURL: enclosure),
                feedID: id, feedURL: url, rssGUID: guid, title: title,
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", durationSeconds: duration,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            )
        }
    }

    /// A fresh on-disk store with no subscription, so admission saves every episode.
    private func makeStore() throws -> LocalLibraryStore {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
    }

    /// Bulk-inserts completion and rule-skip records in one save; the public
    /// one-at-a-time writers re-read their whole table per call.
    private func seed(_ store: LocalLibraryStore, completed: Set<String>, ruleSkips: Set<String>, ruleID: UUID) throws {
        let context = ModelContext(store.container)
        let when = Timestamp(Date(timeIntervalSince1970: 1_800_000_000))
        for raw in completed.sorted() {
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(PodcastListeningState(
                episodeID: try ItemID(rawValue: raw), completedAt: when, lastRevisionID: nil, updatedAt: when)))
        }
        for raw in ruleSkips.sorted() {
            context.insert(LocalLibrarySchemaV16Models.EpisodeDecisionRecord(
                episodeID: raw, decision: EpisodeDecision.skip.rawValue,
                source: EpisodeDecisionSource.rule.rawValue, ruleID: ruleID, decidedAt: when.date))
        }
        try context.save()
    }

    /// Reads every page at `limit`, checking each page's bound and total.
    private func collectPages(
        _ store: LocalLibraryStore, feed: ItemID?, status: Store.HistoryStatusFilter?,
        limit: Int, expectedTotal: Int
    ) async throws -> [Store.HistoryRow] {
        var rows: [Store.HistoryRow] = []
        var offset = 0
        while offset < expectedTotal {
            let page = try await store.historyPage(feedID: feed, status: status, offset: offset, limit: limit)
            XCTAssertEqual(page.total, expectedTotal, "offset \(offset)")
            XCTAssertEqual(page.offset, offset)
            XCTAssertEqual(page.rows.count, min(limit, expectedTotal - offset), "offset \(offset)")
            XCTAssertLessThanOrEqual(page.rows.count, limit)
            guard !page.rows.isEmpty else { break }
            rows += page.rows
            offset += page.rows.count
        }
        return rows
    }

    /// The independent expected order: newest removal first, identifier ascending on ties.
    private static func newestFirst(_ ids: [String], retiredAt: [String: Date]) -> [String] {
        ids.sorted { left, right in
            let leftDate = retiredAt[left]!, rightDate = retiredAt[right]!
            return leftDate != rightDate ? leftDate > rightDate : left < right
        }
    }
}
