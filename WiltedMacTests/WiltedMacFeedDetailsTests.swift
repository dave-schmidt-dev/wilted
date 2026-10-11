import SwiftUI
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacFeedDetailsTests: XCTestCase {
    func testFeedNameOpensDetailsAndPencilStartsRenameAsSeparateActions() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(source.contains("Button { presentedSheet = .details(subscription.id) }"))
        XCTAssertTrue(source.contains("Button { beginFeedName(subscription) }"))
        XCTAssertTrue(source.contains("wilted-podcast-feed-name-\\(subscription.id)"))
        XCTAssertTrue(source.contains("wilted-podcast-feed-rename-\\(subscription.id)"))
        XCTAssertFalse(source.contains("Text(subscription.feedURL.host ?? subscription.feedURL.absoluteString)"))
    }

    func testBothFeedSheetsShareVisibleDoneCancelAction() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        let start = try XCTUnwrap(source.range(of: ".sheet(item: $presentedSheet) {"))
        let sheetSource = source[start.upperBound...]
        let end = try XCTUnwrap(sheetSource.range(of: "/// The count keeps the established Off the list"))
        let sheet = String(sheetSource[..<end.lowerBound])

        XCTAssertEqual(sheet.components(separatedBy: "wilted-feed-sheet-done").count - 1, 1)
        XCTAssertTrue(sheet.contains("Button(\"Done\") { presentedSheet = nil }"))
        XCTAssertTrue(sheet.contains(".keyboardShortcut(.cancelAction)"))
        let done = try XCTUnwrap(sheet.range(of: "Button(\"Done\")")).lowerBound
        let destinationSwitch = try XCTUnwrap(sheet.range(of: "switch sheet")).lowerBound
        XCTAssertLessThan(done, destinationSwitch, "one shared Done action wraps both sheet destinations")
        XCTAssertTrue(sheet.contains("case let .details(feedID):"))
        XCTAssertTrue(sheet.contains("case .history:"))
    }

    func testDetailsRenderStoredSourcePublisherFollowedRefreshSettingsAndHistory() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "feed-details"
        )
        addTeardownBlock { await model.close() }
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()

        let recognizedText = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedDetailsView(model: model, board: board, subscription: subscription),
            size: CGSize(width: 900, height: 2_000)
        ).joined(separator: "\n")
        let text = recognizedText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(text.contains(subscription.title), text)
        XCTAssertTrue(text.contains(subscription.feedURL.absoluteString), text)
        XCTAssertTrue(text.contains(subscription.publisherTitle ?? "Publisher not provided"), text)
        XCTAssertTrue(text.contains("Followed"), text)
        XCTAssertTrue(text.contains("Global podcast refresh"), text)
        let globalRefresh = model.lastPodcastRefreshAt?.formatted(date: .complete, time: .standard) ?? "Never"
        XCTAssertTrue(text.contains(globalRefresh), text)
        XCTAssertFalse(text.contains("Last refreshed: Last refreshed"), text)
        XCTAssertTrue(text.contains("Current settings"), text)
        XCTAssertTrue(text.contains("Episode history"), text)
    }

    func testRenameSubmissionClosesImmediatelyAndFailureRestoresDraftAndError() throws {
        let subscription = WiltedMacSubscription(
            id: "fixture-feed", title: "Fixture feed",
            feedURL: URL(string: "https://feeds.example.test/show.xml")!, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        var interaction = WiltedMacFeedRenameInteraction()
        interaction.begin(subscription)
        interaction.update(subscription.id, text: "A new name")

        let submitted = interaction.submit(subscription.id)
        XCTAssertEqual(submitted, "A new name")
        XCTAssertNil(interaction.drafts[subscription.id], "the editor closes before asynchronous persistence starts")

        let submittedName = try XCTUnwrap(submitted)
        interaction.restoreFailure(subscription, text: submittedName, error: "Could not save. Try again.")
        XCTAssertEqual(interaction.drafts[subscription.id]?.text, "A new name")
        XCTAssertEqual(interaction.drafts[subscription.id]?.error, "Could not save. Try again.")
        XCTAssertFalse(interaction.drafts[subscription.id]?.isSaving ?? true)

        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        let submitRange = try XCTUnwrap(source.range(of: "private func submitFeedName"))
        let submitBody = source[submitRange.lowerBound...]
        XCTAssertLessThan(
            try XCTUnwrap(submitBody.range(of: "feedRenameInteraction.submit")).lowerBound,
            try XCTUnwrap(submitBody.range(of: "Task {")).lowerBound
        )
    }

    func testCapacityFailureIsVisibleAndRetryDoesNotLeaveTheBoardLoading() async throws {
        enum ExpectedFailure: LocalizedError {
            case open
            var errorDescription: String? { "Fixture store failure" }
        }

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("feed-capacity-failure"),
            storeBootstrap: { _ in throw ExpectedFailure.open },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        XCTAssertFalse(board.isLoading)
        XCTAssertNotNil(board.loadFailureMessage)
        XCTAssertFalse(board.isLoaded("missing-feed"), "a read failure must not resolve to default capacity")
        let subscription = WiltedMacSubscription(
            id: "missing-feed", title: "Missing feed", feedURL: URL(string: "https://example.test/feed.xml")!,
            episodeCount: 0, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        let capacity = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedCapacityLabel(board: board, subscription: subscription),
            size: CGSize(width: 360, height: 80)
        )
        XCTAssertTrue(capacity.contains("Capacity unavailable"), "the failure is visible instead of a default count")

        await board.retryReload()
        XCTAssertFalse(board.isLoading)
        let failure = try XCTUnwrap(board.loadFailureMessage, "the failed retry stays visible")
        let details = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedDetailsView(model: model, board: board, subscription: subscription),
            size: CGSize(width: 900, height: 1_000)
        ).joined(separator: " ")
        XCTAssertTrue(details.contains(failure), "actual safe startup error should be visible: \(details)")
        XCTAssertTrue(details.contains("Retry settings"), details)
    }
}
