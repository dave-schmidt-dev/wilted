import AppKit
import XCTest
@testable import WiltedMac

/// Headless form of the owner-feedback journeys that used to launch the app under XCUITest. Each drives
/// `WiltedMacModel` with the same `--wilted-ui-fixture-*` arguments the launch used and asserts the
/// state the rows rendered. A row's metadata label is `episode.presentation.accessibilityFactsLabel`
/// on every surface, so label equality is that property compared on the same episode.
@MainActor
final class WiltedMacOwnerFeedbackJourneyTests: XCTestCase {
    private let intake = ["--wilted-ui-fixture-subscription-intake-26"]

    /// NAV-001, DECISION-001, LARDER-001, RESTORE-001. Was `testCanonicalEpisodePresentationJourney`.
    func testCanonicalEpisodePresentationJourney() async throws {
        let model = await WiltedMacHeadless.model(self, [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared",
        ])
        let episode = try XCTUnwrap(model.feedsEpisodes.first, "NAV-001: Feeds shows the fixture episode")
        let facts = episode.presentation.accessibilityFactsLabel
        XCTAssertFalse(facts.isEmpty, "NAV-001: Feeds exposes factual show, publication, and source duration")

        model.decideFeedEpisodes(.skip, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertFalse(model.feedsEpisodes.contains { $0.id == episode.id })
        let skipped = try XCTUnwrap(model.skippedFeedEpisodes.first { $0.id == episode.id },
                                    "RESTORE-001: Skip exposes Off the list")
        XCTAssertEqual(skipped.presentation.accessibilityFactsLabel, facts,
                       "RESTORE-001: Skip keeps the same factual metadata for the same episode")

        model.restoreSkippedFeedEpisode(skipped)
        await WiltedMacHeadless.drainDecisions(model)
        let restored = try XCTUnwrap(model.feedsEpisodes.first { $0.id == episode.id },
                                     "RESTORE-001: Restore returns the canonical row")
        XCTAssertEqual(restored.presentation.accessibilityFactsLabel, facts,
                       "RESTORE-001: Restore returns the same factual metadata")
        XCTAssertTrue(model.skippedFeedEpisodes.isEmpty)

        model.decideFeedEpisodes(.keep, episodes: [restored])
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertEqual(model.podcastQueueIDs, [episode.id])
        XCTAssertFalse(model.feedsEpisodes.contains { $0.id == episode.id })
        let kept = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        XCTAssertEqual(kept.presentation.accessibilityFactsLabel, facts,
                       "LARDER-001: Keep preserves show, publication, and source facts")
        XCTAssertEqual(kept.downloadState, .completed)
        guard case .prepared = kept.preparationState else {
            return XCTFail("LARDER-001: only the ready fixture receives Play")
        }
    }

    /// The rendered half of the journey above: Feeds draws, and the rows share one metadata view with
    /// the Larder and Off the list. Was the UI test's `wilted-feeds-metadata` / `frame.minY` checks.
    func testFeedsRendersCanonicalMetadataAndPlacesOffTheListAfterFeedManagement() async throws {
        let model = await WiltedMacHeadless.model(self, [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared",
        ])
        XCTAssertFalse(model.feedsEpisodes.isEmpty)
        let bitmap = try WiltedMacHeadless.render(WiltedMacFeedsView(model: model))
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap), 8, "Feeds rendered blank")

        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertNotNil(feeds.range(of: "inbox.id(\"feeds-inbox\")\n            feedManagement.id(\"feeds-subscriptions\")\n            restorableEpisodes.id(\"feeds-off-list\")"),
                        "Off the list remains after the feed-management card")
        for identifier in ["wilted-feeds-metadata-", "wilted-feeds-keep-", "wilted-feeds-skip-"] {
            let sources = try ["WiltedMacFeedsComponents.swift", "WiltedMacFeedsView.swift"]
                .map { try WiltedMacHeadless.viewSource($0) }.joined()
            XCTAssertTrue(sources.contains(identifier), identifier)
        }
        let menuRows = try WiltedMacHeadless.viewSource("WiltedMacMenuView+Rows.swift")
        XCTAssertTrue(menuRows.contains("identifier: \"wilted-menu-metadata-\\(episode.id)\""))
        XCTAssertTrue(menuRows.contains("wilted-menu-play-\\(episode.id)"))
    }

    /// Was `testSubscriptionIntakeFixtureAdmitsFiveMetadataRowsThenBulkKeepPreservesTheirFacts`.
    func testSubscriptionIntakeFixtureAdmitsFiveMetadataRowsThenBulkKeepPreservesTheirFacts() async throws {
        let model = await WiltedMacHeadless.model(self, intake)
        await subscribe(model, "https://feeds.example.test/fixture-26.xml", expectedAdded: 5)

        let rows = model.feedsEpisodes
        XCTAssertEqual(rows.count, 5)
        let facts = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.presentation.accessibilityFactsLabel) })
        XCTAssertTrue(facts.values.allSatisfy { !$0.isEmpty })

        // Select all, then Keep selected: the view passes the selected visible rows to this one call.
        model.decideFeedEpisodes(.keep, episodes: rows)
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertEqual(Set(model.podcastQueueIDs), Set(rows.map(\.id)))
        XCTAssertEqual(model.podcastQueueIDs.count, 5, "bulk Keep moves each episode exactly once")
        XCTAssertTrue(model.feedsEpisodes.isEmpty)
        for episode in model.episodes where facts[episode.id] != nil {
            XCTAssertEqual(episode.presentation.accessibilityFactsLabel, facts[episode.id],
                           "bulk Keep does not reshape canonical facts")
        }

        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(feeds.contains("selectedFeedEpisodeIDs = selected.count == visible.count ? [] : visibleIDs"),
                      "select all selects every visible row")
        XCTAssertTrue(feeds.contains(".disabled(selected.isEmpty ||"),
                      "Keep selected is enabled whenever something is selected")
    }

    /// Was `testSubscriptionIntakeFixtureHonorsRequestLocalTenMetadataOverride`.
    func testSubscriptionIntakeFixtureHonorsRequestLocalTenMetadataOverride() async throws {
        let model = await WiltedMacHeadless.model(self, intake)
        await subscribe(
            model, "https://feeds.example.test/fixture-26.xml", expectedAdded: 10, metadataOverride: 10)
        XCTAssertEqual(model.feedsEpisodes.count, 10)
    }

    /// Was `testSubscriptionOverrideResetsForTheNextFeed`. The model takes the override per call; the
    /// view clears its own copy after each Subscribe, which the source check pins.
    func testSubscriptionOverrideResetsForTheNextFeed() async throws {
        let model = await WiltedMacHeadless.model(self, intake)
        await subscribe(
            model, "https://feeds.example.test/fixture-ten.xml", expectedAdded: 10, metadataOverride: 10)
        XCTAssertEqual(model.feedsEpisodes.count, 10)
        await subscribe(model, "https://feeds.example.test/fixture-default.xml", expectedAdded: 5)
        XCTAssertEqual(model.feedsEpisodes.count, 15)

        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        let subscribe = try XCTUnwrap(feeds.range(of: "private func subscribe() {"))
        let tail = String(feeds[subscribe.upperBound...].prefix(260))
        XCTAssertTrue(tail.contains("model.addPodcastFeedDraft(initialMetadataCount: initialMetadataCount)"))
        XCTAssertTrue(tail.contains("subscriptionInitialMetadataOverride = nil"),
                      "the override resets for the next feed")
    }

    /// Was `testBulkSkipDoesNotReselectAnEpisodeAfterRestore`. Selection is view state, so the headless
    /// half proves the model leaves nothing selected-worthy behind and the view's pruning is in place.
    func testBulkSkipDoesNotReselectAnEpisodeAfterRestore() async throws {
        let model = await WiltedMacHeadless.model(self, intake)
        await subscribe(model, "https://feeds.example.test/fixture-default.xml", expectedAdded: 5)
        let rows = model.feedsEpisodes
        let first = try XCTUnwrap(rows.first)

        model.decideFeedEpisodes(.skip, episodes: rows)
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertTrue(model.feedsEpisodes.isEmpty)
        XCTAssertEqual(Set(model.skippedFeedEpisodes.map(\.id)), Set(rows.map(\.id)))

        model.restoreSkippedFeedEpisode(try XCTUnwrap(model.skippedFeedEpisodes.first { $0.id == first.id }))
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertEqual(model.feedsEpisodes.map(\.id), [first.id], "Restore returns exactly the restored row")

        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(feeds.contains(".onChange(of: visibleIDs)"))
        XCTAssertTrue(feeds.contains("selectedFeedEpisodeIDs.formIntersection(currentVisibleIDs)"),
                      "rows that left the list leave the selection, so a restored row returns unselected")
        XCTAssertTrue(feeds.contains("Button(\"Keep selected\")"))
        XCTAssertTrue(feeds.contains(".disabled(selected.isEmpty ||"),
                      "with nothing selected Keep selected is disabled")
    }

    private func subscribe(
        _ model: WiltedMacModel, _ url: String, expectedAdded: Int, metadataOverride: Int? = nil
    ) async {
        model.podcastFeedDraft = url
        model.addPodcastFeedDraft(initialMetadataCount: metadataOverride)
        await model.waitForPodcastOperations()
        XCTAssertTrue(
            model.podcastFeedDraftStatus?.contains("added with \(expectedAdded) episodes") == true,
            "status was \(model.podcastFeedDraftStatus ?? "nil")")
    }
}
