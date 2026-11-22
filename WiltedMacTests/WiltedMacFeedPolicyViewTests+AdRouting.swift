import SwiftUI
import XCTest
import WiltedProducer
import WiltedDomain
@testable import WiltedMac

extension WiltedMacFeedPolicyViewTests {
    /// A podcast feed on a fresh model, with its Show settings page built. The labeller's
    /// global switch, confirmation and key are the test's to set up on the returned model.
    private func sendForAdFindingFixture(
        feedURL: URL, title: String, suffix: String, hasKey: Bool
    ) throws -> (model: WiltedMacModel, board: WiltedMacFeedPolicyBoard,
                 content: WiltedMacShowSettingsView, feedID: String) {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL).rawValue
        let subscription = WiltedMacSubscription(
            id: feedID, title: title, feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory(suffix),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.subscriptions = [subscription]
        let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { hasKey })
        board.loadForPreview(feedID: feedID, isArticleFeed: false, isNews: false)
        return (model, board, WiltedMacShowSettingsView(model: model, board: board, subscription: subscription), feedID)
    }

    func testPremiumShowWithTokenAddressCanBeSentWhenConfirmed() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/ledger.xml?feed=a1b2c3d4e5f6g7h8i9j0k1l2"))
        let fixture = try sendForAdFindingFixture(
            feedURL: feedURL, title: "The Night Ledger Premium", suffix: "premium-confirmed", hasKey: true
        )
        let labeller = AdLabellerPreferences(preferences: fixture.model.preferences)
        labeller.isEnabled = true
        labeller.setConfirmed(feedID: fixture.feedID, true)

        XCTAssertEqual(fixture.board.adRoute(for: fixture.feedID), .remote)
        XCTAssertTrue(fixture.board.sendsForAdFinding(fixture.feedID))

        let shown = try WiltedMacHeadless.showSectionText(fixture.content, .ads).joined(separator: " ")
        XCTAssertTrue(shown.contains("Send this show for ad finding"), shown)
        XCTAssertTrue(shown.contains("Transcripts are sent to the labelling provider"), shown)
        XCTAssertFalse(shown.contains("Not sent"), shown)
        let header = try WiltedMacHeadless.recognizedText(fixture.content, size: CGSize(width: 800, height: 620))
        XCTAssertTrue(header.joined(separator: " ").contains("The Night Ledger Premium"), "\(header)")
    }

    func testUnconfirmedShowRendersTheWaitingLineBesideTheOrdinaryCaption() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/unconfirmed.xml"))
        let fixture = try sendForAdFindingFixture(
            feedURL: feedURL, title: "The Morning Ledger", suffix: "local-only-unconfirmed", hasKey: true
        )
        let labeller = AdLabellerPreferences(preferences: fixture.model.preferences)
        labeller.isEnabled = true

        XCTAssertEqual(fixture.board.adRoute(for: fixture.feedID), .notSent(.notConfirmed))
        XCTAssertFalse(fixture.board.sendsForAdFinding(fixture.feedID))

        let shown = try WiltedMacHeadless.showSectionText(fixture.content, .ads).joined(separator: " ")
        XCTAssertTrue(shown.contains("Send this show for ad finding"), shown)
        XCTAssertTrue(shown.contains("When on, this show's transcripts go to the labelling provider and its ads are removed. When off, nothing is sent and its ads stay in."), shown)
        XCTAssertTrue(shown.contains("Not sent"), shown)
        XCTAssertFalse(shown.contains("Needs your confirmation"), shown)
    }

    func testConfirmedShowRendersTheSwitchOnAndRemoteRouteLine() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/confirmed.xml"))
        let fixture = try sendForAdFindingFixture(
            feedURL: feedURL, title: "The Evening Ledger", suffix: "local-only-confirmed", hasKey: true
        )
        let labeller = AdLabellerPreferences(preferences: fixture.model.preferences)
        labeller.isEnabled = true
        XCTAssertTrue(fixture.board.setSendForAdFinding(true, for: fixture.feedID))

        XCTAssertEqual(fixture.board.adRoute(for: fixture.feedID), .remote)
        XCTAssertTrue(fixture.board.sendsForAdFinding(fixture.feedID))

        let shown = try WiltedMacHeadless.showSectionText(fixture.content, .ads).joined(separator: " ")
        XCTAssertTrue(shown.contains("Send this show for ad finding"), shown)
        XCTAssertTrue(shown.contains("Transcripts are sent to the labelling provider"), shown)
        XCTAssertFalse(shown.contains("Not sent"), shown)
        let header = try WiltedMacHeadless.recognizedText(fixture.content, size: CGSize(width: 800, height: 620))
        XCTAssertTrue(header.joined(separator: " ").contains("The Evening Ledger"), "\(header)")
    }

    /// Regression: a confirmed show at the daily limit names the limit and keeps the prior route line.
    func testConfirmedShowAtTheDailyLimitNamesTheLimitNotNotSent() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/capped.xml"))
        let fixture = try sendForAdFindingFixture(
            feedURL: feedURL, title: "The Capped Ledger", suffix: "send-capped", hasKey: true
        )
        let labeller = AdLabellerPreferences(preferences: fixture.model.preferences)
        labeller.isEnabled = true
        XCTAssertTrue(fixture.board.setSendForAdFinding(true, for: fixture.feedID))
        let counter = LabellerRequestCounter(preferences: fixture.model.preferences)
        for _ in 0..<counter.cap { counter.record() }

        XCTAssertEqual(fixture.board.adRoute(for: fixture.feedID), .notSent(.dailyCapReached))
        let shown = try WiltedMacHeadless.showSectionText(fixture.content, .ads).joined(separator: " ")
        XCTAssertTrue(shown.contains("limit for online labelling is reached"), shown)
        XCTAssertFalse(shown.contains("Not sent"), shown)
        XCTAssertTrue(shown.contains("Transcripts are sent to the labelling provider"), shown)
    }

    // MARK: Fixture
}
