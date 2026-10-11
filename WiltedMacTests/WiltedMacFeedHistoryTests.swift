import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacFeedHistoryTests: XCTestCase {
    func testHistoryQueryKeepsAll281RecordsAndFiltersPagesOf25() {
        let records = (0..<281).map { index in
            WiltedMacFeedHistoryRecord(
                id: "episode-\(index)",
                feedID: index.isMultiple(of: 2) ? "feed-a" : "feed-b",
                feedTitle: index.isMultiple(of: 2) ? "Alpha show" : "Beta show",
                presentation: WiltedMacEpisodePresentation(
                    title: "Episode \(index)", showTitle: "Show \(index % 3)", publishedAt: nil,
                    sourceDurationSeconds: nil, playableDurationSeconds: nil
                ),
                status: index.isMultiple(of: 2) ? .skipped : .removed,
                changedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        var query = WiltedMacFeedHistoryQuery()

        XCTAssertEqual(query.filtered(records).count, 281)
        XCTAssertEqual(query.page(in: records).count, 25)
        XCTAssertEqual(query.pageCount(in: records), 12)
        query.pageIndex = 11
        XCTAssertEqual(query.page(in: records).count, 6, "the final page retains every remaining record")

        query.pageIndex = 0
        query.feedID = "feed-b"
        query.statusFilter = .removed
        let filtered = query.filtered(records)
        XCTAssertEqual(filtered.count, 140)
        XCTAssertTrue(filtered.allSatisfy { $0.feedID == "feed-b" && $0.status == .removed })
        query.searchText = "Episode 27"
        XCTAssertFalse(query.filtered(records).isEmpty)
        XCTAssertTrue(query.filtered(records).allSatisfy { $0.presentation.title.localizedCaseInsensitiveContains("Episode 27") })
    }

    func testHistoryPagePreservesRestorePathsAndAccessibleSearchFiltersAndPaging() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedHistoryView.swift")
        XCTAssertTrue(source.contains("model.restoreSkippedFeedEpisode(episode)"))
        XCTAssertTrue(source.contains("model.restoreEpisode(dismissal)"))
        XCTAssertTrue(source.contains("static let pageSize = 25"))
        for identifier in [
            "wilted-feed-history-search", "wilted-feed-history-feed-filter", "wilted-feed-history-status-filter",
            "wilted-feed-history-previous", "wilted-feed-history-next", "wilted-feed-history-range",
        ] {
            XCTAssertTrue(source.contains(identifier), identifier)
        }
        XCTAssertTrue(source.contains("WiltedMacFeedHistoryAccessibilityID.restoreSkipped(record.id)"))
        XCTAssertTrue(source.contains("WiltedMacFeedHistoryAccessibilityID.restoreRemoved(record.id)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(restoreIdentifier)"))
        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(feeds.contains(".sheet(item: $presentedSheet)"))
        XCTAssertTrue(feeds.contains("Button(\"Done\") { presentedSheet = nil }"))
        XCTAssertTrue(feeds.contains("wilted-feeds-restore-skipped-\\(episodeID)"))
        XCTAssertTrue(feeds.contains("wilted-feeds-restore-removed-\\(episodeID)"))
    }
}
