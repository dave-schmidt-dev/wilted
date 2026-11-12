import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The per-feed "Find ads on this Mac only" choice: where it is kept, how it changes
/// the route the policy picks, and the board accessors the popover's switch uses.
@MainActor
final class WiltedMacLocalOnlyAdsPreferenceTests: XCTestCase {
    private let localOnlyKey = AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"

    // MARK: Preference and policy

    func testSwitchingOneFeedLocalKeepsTheOtherConfirmedFeedRemote() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let labeller = AdLabellerPreferences(preferences: preferences)
        labeller.isEnabled = true
        labeller.setConfirmed(feedID: "feed-a", true)
        labeller.setConfirmed(feedID: "feed-b", true)
        let preference = WiltedMacLocalOnlyAdsPreference(preferences: preferences)
        XCTAssertFalse(preference.isLocalOnly(feedID: "feed-a"))

        preference.set(feedID: "feed-a", localOnly: true)

        XCTAssertEqual(preference.feedIDs, ["feed-a"])
        XCTAssertTrue(preference.isLocalOnly(feedID: "feed-a"))
        XCTAssertFalse(preference.isLocalOnly(feedID: "feed-b"), "another feed keeps its route")
        XCTAssertFalse(preference.isLocalOnly(feedID: nil), "an episode with no feed is never local-only")
        let context = RemoteLabellingContext(
            preferences: labeller, hasKey: true, counter: LabellerRequestCounter(preferences: preferences)
        )
        XCTAssertEqual(RemoteLabellingPolicy.route(
            for: RemoteLabellingInput(
                feedID: "feed-a", feedURL: URL(string: "https://feeds.example.test/show-a.xml"),
                feedTitle: "Show A", audioURL: nil
            ), context: context), .local(.ownerLocalOnly))
        XCTAssertEqual(RemoteLabellingPolicy.route(
            for: RemoteLabellingInput(
                feedID: "feed-b", feedURL: URL(string: "https://feeds.example.test/show-b.xml"),
                feedTitle: "Show B", audioURL: nil
            ), context: context), .remote)
    }

    func testSwitchingOffRemovesTheIDAndTheKeyWhenEmpty() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let preference = WiltedMacLocalOnlyAdsPreference(preferences: preferences)
        XCTAssertNil(preferences.object(forKey: localOnlyKey))

        preference.set(feedID: "feed-a", localOnly: true)
        preference.set(feedID: "feed-b", localOnly: true)
        XCTAssertEqual(preferences.stringArray(forKey: localOnlyKey), ["feed-a", "feed-b"])

        preference.set(feedID: "feed-a", localOnly: false)
        XCTAssertEqual(preference.feedIDs, ["feed-b"])

        preference.set(feedID: "feed-b", localOnly: false)
        XCTAssertEqual(preference.feedIDs, [])
        XCTAssertNil(preferences.object(forKey: localOnlyKey), "the key is removed once no feed is local-only")
    }

    // MARK: Board

    func testBoardSavesForAPodcastFeedOnlyAndReportsTheRoute() throws {
        let model = makeModel("local-only-board")
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

        XCTAssertFalse(board.setFindAdsLocallyOnly(true, for: "unloaded"), "a feed not loaded is refused")
        XCTAssertFalse(board.setFindAdsLocallyOnly(true, for: "articles"), "an article feed offers no ad finding")
        XCTAssertEqual(board.adRoute(for: feedID), .local(.switchOff), "the global switch starts off")

        labeller.isEnabled = true
        labeller.setConfirmed(feedID: feedID, true)
        XCTAssertEqual(board.adRoute(for: feedID), .remote)

        XCTAssertTrue(board.setFindAdsLocallyOnly(true, for: feedID))
        XCTAssertTrue(board.findsAdsLocallyOnly(feedID))
        XCTAssertEqual(board.adRoute(for: feedID), .local(.ownerLocalOnly))
        XCTAssertEqual(WiltedMacLocalOnlyAdsPreference(preferences: model.preferences).feedIDs, [feedID])
        XCTAssertTrue(WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true }).findsAdsLocallyOnly(feedID),
                      "a new board reads the saved choice")
        XCTAssertEqual(WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { false }).adRoute(for: feedID),
                       .local(.noKey), "the injected key decides noKey")

        XCTAssertTrue(board.setFindAdsLocallyOnly(false, for: feedID))
        XCTAssertFalse(board.findsAdsLocallyOnly(feedID))
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
