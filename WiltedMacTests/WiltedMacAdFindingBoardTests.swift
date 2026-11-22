import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The per-feed "Send this show for ad finding" choice: where it is kept, how it changes
/// the route the policy picks, and the board accessors the popover's switch uses.
@MainActor
final class WiltedMacAdFindingBoardTests: XCTestCase {
    private let legacyKey = AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"
    private let confirmedKey = AdLabellerPreferences.keyPrefix + "confirmedFeedIDs"

    // MARK: Preference and policy

    func testShowStoredInBothListsRendersSwitchOffAndTurningOnRemovesFromLegacyList() throws {
        let model = makeModel("stored-in-both-lists")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/both.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL).rawValue
        model.subscriptions = [WiltedMacSubscription(
            id: feedID, title: "Dual Stored Show", feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )]

        // Store the show in both confirmed list and legacy "Mac only" list.
        model.preferences.set([feedID], forKey: confirmedKey)
        model.preferences.set([feedID], forKey: legacyKey)

        let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true })
        board.loadForPreview(feedID: feedID, isArticleFeed: false, isNews: false)

        // Stored in both lists renders the switch off.
        XCTAssertFalse(board.sendsForAdFinding(feedID), "a show in both lists renders the switch off")

        // Turning it on removes the show from the stored legacy list and sets confirmed.
        XCTAssertTrue(board.setSendForAdFinding(true, for: feedID))
        XCTAssertTrue(board.sendsForAdFinding(feedID), "turning it on renders the switch on")
        XCTAssertNil(model.preferences.object(forKey: legacyKey), "turning it on removes the legacy key when empty")
        XCTAssertEqual(model.preferences.stringArray(forKey: confirmedKey), [feedID], "the confirmed key holds the feed")
    }

    // MARK: Board

    func testBoardSavesForAPodcastFeedOnlyAndReportsTheRoute() throws {
        let model = makeModel("send-for-ad-finding-board")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/ledger.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL).rawValue
        model.subscriptions = [WiltedMacSubscription(
            id: feedID, title: "The Night Ledger", feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )]
        let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true })
        board.loadForPreview(feedID: feedID, isArticleFeed: false, isNews: false)
        board.loadForPreview(feedID: "articles", isArticleFeed: true, isNews: false)
        let labeller = AdLabellerPreferences(preferences: model.preferences)

        XCTAssertFalse(board.setSendForAdFinding(true, for: "unloaded"), "a feed not loaded is refused")
        XCTAssertFalse(board.setSendForAdFinding(true, for: "articles"), "an article feed offers no ad finding")
        XCTAssertEqual(board.adRoute(for: feedID), .notSent(.switchOff), "the global switch starts off")

        labeller.isEnabled = true
        XCTAssertFalse(board.sendsForAdFinding(feedID))
        XCTAssertEqual(board.adRoute(for: feedID), .notSent(.notConfirmed))

        XCTAssertTrue(board.setSendForAdFinding(true, for: feedID))
        XCTAssertTrue(board.sendsForAdFinding(feedID))
        XCTAssertEqual(board.adRoute(for: feedID), .remote)
        XCTAssertTrue(WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true }).sendsForAdFinding(feedID),
                      "a new board reads the saved choice")
        XCTAssertEqual(WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { false }).adRoute(for: feedID),
                       .notSent(.noKey), "the injected key decides noKey")

        XCTAssertTrue(board.setSendForAdFinding(false, for: feedID))
        XCTAssertFalse(board.sendsForAdFinding(feedID))
        XCTAssertEqual(board.adRoute(for: feedID), .notSent(.notConfirmed))
        XCTAssertEqual(labeller.keptBackFeedIDs, [feedID],
                       "switching a show off is remembered, so no confirm sheet offers it as sent")

        XCTAssertTrue(board.setSendForAdFinding(true, for: feedID))
        XCTAssertEqual(labeller.keptBackFeedIDs, [], "switching it on clears the record")
        XCTAssertEqual(board.adRoute(for: feedID), .remote)
    }

    // MARK: Helpers

    private func makeModel(_ suffix: String) -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory(suffix),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        return model
    }
}
