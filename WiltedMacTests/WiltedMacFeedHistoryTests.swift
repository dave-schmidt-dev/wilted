import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacFeedHistoryTests: XCTestCase {
    func testStoreRowBecomesARecordWithFactsKindAndRestoreIdentifier() async throws {
        let labelled = try await labelledHistory(feedTitle: "History show")
        let passed = try XCTUnwrap(labelled.records["passed"])
        XCTAssertEqual(passed.presentation.title, "Episode passed")
        XCTAssertEqual(passed.presentation.showTitle, "History show")
        XCTAssertEqual(passed.presentation.publishedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(passed.presentation.sourceDurationSeconds, 1_800)
        XCTAssertNil(passed.presentation.playableDurationSeconds, "History never claims a playable cut")
        XCTAssertEqual(passed.feedTitle, "History show")
        XCTAssertEqual(passed.changedAt, Date(timeIntervalSince1970: 1_900_000_020))
        XCTAssertEqual(WiltedMacFeedHistoryAccessibilityID.restoreSkipped(passed.id), "wilted-feeds-restore-skipped-\(passed.id)")
        XCTAssertEqual(labelled.records.values.map(\.feedID), Array(repeating: Optional(labelled.feedID), count: 4))
        XCTAssertEqual(labelled.loader.rows.map(\.episodeID.rawValue),
                       ["rule", "finished", "passed", "legacy"].map { labelled.ids[$0]! }, "newest removal first")
    }

    func testHistoryPagePreservesRestorePathsAndAccessibleSearchFiltersAndPaging() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedHistoryView.swift")
        let loader = try WiltedMacHeadless.viewSource("WiltedMacFeedHistoryLoader.swift")
        XCTAssertTrue(source.contains("model.restoreSkippedFeedEpisode(episode)"))
        XCTAssertTrue(source.contains("model.restoreEpisode(dismissal)"))
        XCTAssertTrue(loader.contains("record.requestRestore(through: model)"))
        XCTAssertTrue(loader.contains("static let pageSize = 25"))
        XCTAssertTrue(loader.contains("static let searchDebounce: Duration = .milliseconds(300)"))
        for identifier in [
            "wilted-feed-history-search", "wilted-feed-history-feed-filter", "wilted-feed-history-status-filter",
            "wilted-feed-history-previous", "wilted-feed-history-next", "wilted-feed-history-range",
        ] {
            XCTAssertTrue(source.contains(identifier), identifier)
        }
        XCTAssertTrue(source.contains("WiltedMacFeedHistoryAccessibilityID.restoreSkipped(record.id)"))
        XCTAssertTrue(source.contains("WiltedMacFeedHistoryAccessibilityID.restoreRemoved(record.id)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(restoreIdentifier)"))
        XCTAssertTrue(source.contains("Button(\"Restore\") { restore(record) }"))
        XCTAssertTrue(source.contains("loader.restore(record, model: model)"))
        for retired in ["model.skippedFeedEpisodes", "history(retired:", "WiltedMacFeedHistoryQuery"] {
            XCTAssertFalse(source.contains(retired), "History renders the store page, not \(retired)")
        }
        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(feeds.contains(".sheet(item: $presentedSheet)"))
        XCTAssertTrue(feeds.contains("Button(\"Done\") { presentedSheet = nil }"))
        XCTAssertTrue(feeds.contains("wilted-feeds-restore-skipped-\\(episodeID)"))
        XCTAssertTrue(feeds.contains("wilted-feeds-restore-removed-\\(episodeID)"))
    }

    // MARK: Played and Skipped labels (B7c-1.2)

    /// A finished episode leaves the list through the same retirement a skip
    /// writes; its completion record is what makes History call it Played.
    func testCompletedRetiredEpisodeReadsPlayed() async throws {
        let records = try await labelledHistory().records
        let record = try XCTUnwrap(records["finished"])
        XCTAssertEqual(record.status, .played)
        XCTAssertEqual(record.status.rawValue, "Played")
        XCTAssertEqual(record.kind, .retired, "Restore still runs the retirement reversal")
    }

    func testUncompletedRetiredEpisodeReadsSkipped() async throws {
        let records = try await labelledHistory().records
        let record = try XCTUnwrap(records["passed"])
        XCTAssertEqual(record.status, .skipped)
        XCTAssertEqual(record.status.rawValue, "Skipped")
        XCTAssertEqual(record.kind, .retired)
    }

    /// A feed rule's skip names itself, and restores like any retirement.
    func testRuleSkippedEpisodeReadsSkippedByRule() async throws {
        let records = try await labelledHistory().records
        let record = try XCTUnwrap(records["rule"])
        XCTAssertEqual(record.status, .skippedByRule)
        XCTAssertEqual(record.status.rawValue, "Skipped by rule")
        XCTAssertEqual(record.kind, .retired)
    }

    /// Nothing writes a dismissal now, so an old one reads Skipped, but its
    /// Restore and identifier still follow the dismissal it really is.
    func testLegacyDismissedRowReadsSkippedAndKeepsItsDismissalRestorePath() async throws {
        let labelled = try await labelledHistory()
        let record = try XCTUnwrap(labelled.records["legacy"])
        XCTAssertEqual(record.status, .skipped)
        XCTAssertEqual(record.kind, .dismissed)
        XCTAssertFalse(WiltedMacFeedHistoryStatus.allCases.map(\.rawValue).contains("Removed"))
        XCTAssertEqual(WiltedMacFeedHistoryAccessibilityID.restoreRemoved(record.id), "wilted-feeds-restore-removed-\(record.id)")
        XCTAssertEqual(record.storeRestoreDismissal.id, record.id, "an unloaded row still restores by its own identity")

        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedHistoryView.swift")
        XCTAssertTrue(source.contains("let restoreIdentifier = record.kind == .retired"),
                      "the restore identifier follows the stored removal, not the label")
        let dispatch = try XCTUnwrap(source.range(of: "switch kind {"), "Restore dispatches on the stored removal")
        let body = source[dispatch.lowerBound...]
        let order = try [
            "case .retired:", "model.restoreSkippedFeedEpisode(episode)",
            "case .dismissed:", "model.restoreEpisode(dismissal)",
        ].map { try XCTUnwrap(body.range(of: $0), $0).lowerBound }
        XCTAssertEqual(order, order.sorted(), "each removal kind keeps its own restore call")
    }

    func testStatusFilterSeparatesPlayedFromSkippedRows() async throws {
        typealias Filter = WiltedMacFeedHistoryLoader.StatusFilter
        XCTAssertEqual(Filter.allCases.map(\.rawValue), ["All statuses", "Played", "Skipped"])
        XCTAssertEqual(Filter.allCases.map(\.storeFilter), [nil, .played, .skipped])
        let labelled = try await labelledHistory()
        let loader = labelled.loader
        let ids = labelled.ids
        loader.setStatusFilter(.played)
        await loader.settle()
        XCTAssertEqual(loader.rows.map(\.episodeID.rawValue), [ids["finished"]!])
        loader.setStatusFilter(.skipped)
        await loader.settle()
        XCTAssertEqual(loader.rows.map(\.episodeID.rawValue), ["rule", "passed", "legacy"].map { ids[$0]! },
                       "Skipped includes rule skips and legacy dismissals")
        loader.setStatusFilter(.all)
        loader.setSearchText("passed")
        await loader.settle()
        XCTAssertEqual(loader.rows.map(\.episodeID.rawValue), [ids["passed"]!], "search matches the episode title")
    }

    /// Feed details embeds this same history, so its rows carry the same labels.
    func testFeedDetailsHistoryRendersPlayedSkippedAndRuleLabels() async throws {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("history-labels"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        let labelled = try await labelledHistory()
        XCTAssertEqual(labelled.loader.rows.count, 4)

        let drawn = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedHistoryView(model: model, feedID: labelled.feedID, loader: labelled.loader),
            size: CGSize(width: 900, height: 1_000)
        )
        let text = drawn.joined(separator: " ")
        XCTAssertTrue(text.contains("Played"), text)
        XCTAssertTrue(text.contains("Skipped"), text)
        XCTAssertTrue(text.contains("Skipped by rule"), text)
        XCTAssertFalse(text.contains("Removed"), text)
        XCTAssertEqual(drawn.filter { $0 == "Restore" }.count, 4, text)
        let details = try WiltedMacHeadless.viewSource("WiltedMacFeedDetailsView.swift")
        XCTAssertTrue(details.contains("WiltedMacFeedHistoryView(model: model, feedID: subscription.id)"))
    }

    /// One feed's History in a fresh store, loaded: a finished episode, a hand
    /// skip, a feed rule's skip and a legacy dismissal. `ids` maps each
    /// fixture name to its episode identifier, and `records` is keyed by name.
    private func labelledHistory(feedTitle: String? = nil) async throws -> (
        loader: WiltedMacFeedHistoryLoader, records: [String: WiltedMacFeedHistoryRecord],
        ids: [String: String], feedID: String
    ) {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let feed = try WiltedMacHistoryStoreFixture.Feed("labels")
        let names = ["finished", "passed", "rule", "legacy"]
        let episodes = try names.map { try feed.episode($0, title: "Episode \($0)") }
        let byName = Dictionary(uniqueKeysWithValues: zip(names, episodes))
        try await fixture.store.savePodcastEpisodes(episodes, admission: .backfill)
        let finished = try XCTUnwrap(byName["finished"]).itemID
        _ = try await fixture.store.completeAndRetireEpisode(listening: PodcastListeningState(
            episodeID: finished, completedAt: fixture.at(29), lastRevisionID: nil, updatedAt: fixture.at(29)
        ), at: fixture.at(30))
        _ = try await fixture.store.retireEpisode(try XCTUnwrap(byName["passed"]).itemID, at: fixture.at(20))
        try await fixture.seedRuleSkip(try XCTUnwrap(byName["rule"]).itemID, at: 40)
        _ = try await fixture.store.dismissPodcastEpisode(try XCTUnwrap(byName["legacy"]).itemID, at: fixture.at(10))

        let loader = WiltedMacFeedHistoryLoader(fetch: fixture.fetch)
        await loader.start(feedID: feed.id.rawValue)
        let ids = byName.mapValues(\.itemID.rawValue)
        let nameByID = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        let records = Dictionary(uniqueKeysWithValues: loader.rows.compactMap { row in
            nameByID[row.episodeID.rawValue].map { ($0, WiltedMacFeedHistoryRecord(row: row, feedTitle: feedTitle)) }
        })
        return (loader, records, ids, feed.id.rawValue)
    }
}
