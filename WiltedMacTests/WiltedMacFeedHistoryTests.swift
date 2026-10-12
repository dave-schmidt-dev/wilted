import XCTest
import WiltedProducer
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
                kind: .retired,
                status: index.isMultiple(of: 2) ? .skipped : .played,
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
        query.statusFilter = .played
        let filtered = query.filtered(records)
        XCTAssertEqual(filtered.count, 140)
        XCTAssertTrue(filtered.allSatisfy { $0.feedID == "feed-b" && $0.status == .played })
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

    // MARK: Played and Skipped labels (B7c-1.2)

    /// A finished episode leaves the list through the same retirement a skip
    /// writes; its completion record is what makes History call it Played.
    func testCompletedRetiredEpisodeReadsPlayed() throws {
        let records = WiltedMacFeedHistoryRecord.history(retired: [retired("finished", played: true, at: 30)], dismissed: [])
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, .played)
        XCTAssertEqual(record.status.rawValue, "Played")
        XCTAssertEqual(record.kind, .retired, "Restore still runs the retirement reversal")
    }

    func testUncompletedRetiredEpisodeReadsSkipped() throws {
        let records = WiltedMacFeedHistoryRecord.history(retired: [retired("passed", played: false, at: 20)], dismissed: [])
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, .skipped)
        XCTAssertEqual(record.status.rawValue, "Skipped")
        XCTAssertEqual(record.kind, .retired)
    }

    /// Nothing writes a dismissal now, so an old one reads Skipped, but its
    /// Restore and identifier still follow the dismissal it really is.
    func testLegacyDismissedRowReadsSkippedAndKeepsItsDismissalRestorePath() throws {
        let records = WiltedMacFeedHistoryRecord.history(retired: [], dismissed: [dismissed("legacy", at: 10)])
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, .skipped)
        XCTAssertEqual(record.kind, .dismissed)
        XCTAssertFalse(WiltedMacFeedHistoryStatus.allCases.map(\.rawValue).contains("Removed"))
        XCTAssertEqual(WiltedMacFeedHistoryAccessibilityID.restoreRemoved(record.id), "wilted-feeds-restore-removed-legacy")

        let overlap = WiltedMacFeedHistoryRecord.history(
            retired: [retired("legacy", played: false, at: 20)], dismissed: [dismissed("legacy", at: 10)]
        )
        XCTAssertEqual(overlap.map(\.kind), [.retired], "a row both retired and dismissed shows once, as retired")

        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedHistoryView.swift")
        XCTAssertTrue(source.contains("let restoreIdentifier = record.kind == .retired"),
                      "the restore identifier follows the stored removal, not the label")
        let dispatch = try XCTUnwrap(source.range(of: "switch record.kind {"), "Restore dispatches on the stored removal")
        let body = source[dispatch.lowerBound...]
        let order = try [
            "case .retired:", "model.restoreSkippedFeedEpisode(episode)",
            "case .dismissed:", "model.restoreEpisode(dismissal)",
        ].map { try XCTUnwrap(body.range(of: $0), $0).lowerBound }
        XCTAssertEqual(order, order.sorted(), "each removal kind keeps its own restore call")
    }

    func testStatusFilterSeparatesPlayedFromSkippedRows() {
        let records = WiltedMacFeedHistoryRecord.history(
            retired: [retired("finished", played: true, at: 30), retired("passed", played: false, at: 20)],
            dismissed: [dismissed("legacy", at: 10)]
        )
        XCTAssertEqual(WiltedMacFeedHistoryQuery.StatusFilter.allCases.map(\.rawValue), ["All statuses", "Played", "Skipped"])
        var query = WiltedMacFeedHistoryQuery()
        XCTAssertEqual(query.filtered(records).map(\.id), ["finished", "passed", "legacy"])
        query.statusFilter = .played
        XCTAssertEqual(query.filtered(records).map(\.id), ["finished"])
        query.statusFilter = .skipped
        XCTAssertEqual(query.filtered(records).map(\.id), ["passed", "legacy"])
        query.statusFilter = .all
        query.searchText = "played"
        XCTAssertEqual(query.filtered(records).map(\.id), ["finished"], "search matches the label a person reads")
    }

    /// Feed details embeds this same history, so its rows carry the same two labels.
    func testFeedDetailsHistoryRendersPlayedAndSkippedLabels() throws {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("history-labels"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.installEpisodeForTesting(retired("finished", played: true, at: 30))
        model.installEpisodeForTesting(retired("passed", played: false, at: 20))
        model.dismissedEpisodes = [dismissed("legacy", at: 10)]
        XCTAssertEqual(Set(model.skippedFeedEpisodes.map(\.id)), ["finished", "passed"])

        let drawn = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedHistoryView(model: model, feedID: "feed-a"), size: CGSize(width: 900, height: 1_000)
        )
        let text = drawn.joined(separator: " ")
        XCTAssertTrue(text.contains("Played"), text)
        XCTAssertTrue(text.contains("Skipped"), text)
        XCTAssertFalse(text.contains("Removed"), text)
        XCTAssertEqual(drawn.filter { $0 == "Restore" }.count, 3, text)
        let details = try WiltedMacHeadless.viewSource("WiltedMacFeedDetailsView.swift")
        XCTAssertTrue(details.contains("WiltedMacFeedHistoryView(model: model, feedID: subscription.id)"))
    }

    private func retired(_ id: String, played: Bool, at seconds: TimeInterval) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "Episode \(id)", feedTitle: "History show", summary: "", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: seconds), durationSeconds: 60,
            playbackSeconds: played ? 60 : 0, isPlayed: played,
            retiredAt: Date(timeIntervalSince1970: seconds + 100), removalKind: .retired,
            downloadState: .completed, feedID: "feed-a"
        )
    }

    private func dismissed(_ id: String, at seconds: TimeInterval) -> WiltedMacDismissedEpisode {
        WiltedMacDismissedEpisode(
            id: id, feedID: "feed-a", title: "Episode \(id)", feedTitle: "History show",
            dismissedAt: Date(timeIntervalSince1970: seconds), hasPreparationHistory: false
        )
    }
}
