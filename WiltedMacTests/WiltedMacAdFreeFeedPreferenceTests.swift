import Foundation
import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The per-feed "This show has no ads" choice: where it is kept, how it reaches
/// the snapshot an episode is admitted with, and the toggle that sets it.
@MainActor
final class WiltedMacAdFreeFeedPreferenceTests: XCTestCase {
    // MARK: Preference

    func testStartsWithNoFeedAndNoStoredKey() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let preference = WiltedMacAdFreeFeedPreference(preferences: preferences)

        XCTAssertEqual(preference.feedIDs, [])
        XCTAssertFalse(preference.isAdFree(feedID: "feed-a"))
        XCTAssertNil(preferences.object(forKey: WiltedMacAdFreeFeedPreference.preferenceKey))
    }

    func testSetStoresASortedArrayAndKeepsEachFeedsChoiceSeparate() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let preference = WiltedMacAdFreeFeedPreference(preferences: preferences)

        preference.set(feedID: "feed-c", adFree: true)
        preference.set(feedID: "feed-a", adFree: true)
        preference.set(feedID: "feed-a", adFree: true)

        XCTAssertEqual(WiltedMacAdFreeFeedPreference.preferenceKey, "wilted.feeds.adFree")
        XCTAssertEqual(preferences.stringArray(forKey: WiltedMacAdFreeFeedPreference.preferenceKey), ["feed-a", "feed-c"])
        XCTAssertTrue(preference.isAdFree(feedID: "feed-a"))
        XCTAssertTrue(preference.isAdFree(feedID: "feed-c"))
        XCTAssertFalse(preference.isAdFree(feedID: "feed-b"), "a feed never set stays off")
    }

    func testClearingOneFeedLeavesTheOthersAndTheLastRemovesTheKey() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let preference = WiltedMacAdFreeFeedPreference(preferences: preferences)
        preference.set(feedID: "feed-a", adFree: true)
        preference.set(feedID: "feed-b", adFree: true)

        preference.set(feedID: "feed-a", adFree: false)
        XCTAssertEqual(preference.feedIDs, ["feed-b"])

        preference.set(feedID: "feed-b", adFree: false)
        XCTAssertEqual(preference.feedIDs, [])
        XCTAssertNil(preferences.object(forKey: WiltedMacAdFreeFeedPreference.preferenceKey))
    }

    func testNilOrEmptyFeedIDIsNeverAdFreeAndABlankIsNeverStored() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set(["feed-b", "", "feed-a", "feed-b"], forKey: WiltedMacAdFreeFeedPreference.preferenceKey)
        let preference = WiltedMacAdFreeFeedPreference(preferences: preferences)

        XCTAssertEqual(preference.feedIDs, ["feed-a", "feed-b"])
        XCTAssertFalse(preference.isAdFree(feedID: nil), "an episode with no feed is never ad-free")
        XCTAssertFalse(preference.isAdFree(feedID: ""))
        preference.set(feedID: "", adFree: true)
        XCTAssertEqual(preference.feedIDs, ["feed-a", "feed-b"], "a blank feed ID is never stored")
    }

    // MARK: Snapshot

    func testAdFreeFeedTurnsOffAdRemovalAndSelfPromotionEvenWhenAlsoOptedIn() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        WiltedMacAdFreeFeedPreference(preferences: preferences).set(feedID: "feed-a", adFree: true)
        WiltedMacSelfPromotionPreference(preferences: preferences).set(feedID: "feed-a", enabled: true)
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .alwaysTranscribe, removeAds: true
        )

        let adFree = WiltedMacModel.preparationPolicySnapshot(from: settings, feedID: "feed-a", preferences: preferences)
        let other = WiltedMacModel.preparationPolicySnapshot(from: settings, feedID: "feed-b", preferences: preferences)

        XCTAssertEqual(adFree, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false, removeSelfPromotion: false
        ))
        XCTAssertEqual(other, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: true, removeSelfPromotion: false
        ))
        XCTAssertEqual(other, WiltedMacModel.preparationPolicySnapshot(from: settings))
    }

    func testGlobalAdRemovalOffKeepsEveryFeedUncut() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        WiltedMacAdFreeFeedPreference(preferences: preferences).set(feedID: "feed-a", adFree: true)
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .bestAvailable, removeAds: false
        )

        let adFree = WiltedMacModel.preparationPolicySnapshot(from: settings, feedID: "feed-a", preferences: preferences)
        let other = WiltedMacModel.preparationPolicySnapshot(from: settings, feedID: "feed-b", preferences: preferences)

        XCTAssertFalse(adFree.removeAds)
        XCTAssertFalse(other.removeAds)
        XCTAssertFalse(adFree.removeSelfPromotion)
        XCTAssertFalse(other.removeSelfPromotion)
    }

    // MARK: Board and toggle

    func testBoardSavesTheChoiceForAPodcastFeedAndRefusesAnArticleFeed() {
        let model = makeModel("ad-free-board")
        let board = WiltedMacFeedPolicyBoard(model: model)
        board.loadForPreview(feedID: "feed-a", isArticleFeed: false, isNews: false)
        board.loadForPreview(feedID: "articles", isArticleFeed: true, isNews: false)

        XCTAssertFalse(board.setAdFree(true, for: "unloaded"), "a feed not loaded is refused")
        XCTAssertFalse(board.setAdFree(true, for: "articles"), "an article feed has no audio to leave uncut")
        XCTAssertTrue(board.setAdFree(true, for: "feed-a"))

        XCTAssertTrue(board.isAdFree("feed-a"))
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: model.preferences).feedIDs, ["feed-a"])
        XCTAssertTrue(WiltedMacFeedPolicyBoard(model: model).isAdFree("feed-a"),
                      "a new board reads the saved choice")

        XCTAssertTrue(board.setAdFree(false, for: "feed-a"))
        XCTAssertFalse(board.isAdFree("feed-a"))
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: model.preferences).feedIDs, [])
    }

    func testTitleAppearsOnceForAPodcastFeedAndNeverForAnArticleFeed() throws {
        let podcastText = try popoverText(isArticleFeed: false, suffix: "ad-free-podcast")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "This show has no ads", in: podcastText), 1, podcastText)
        XCTAssertTrue(podcastText.contains("without ad removal"), podcastText)

        let articleText = try popoverText(isArticleFeed: true, suffix: "ad-free-article")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "This show has no ads", in: articleText), 0, articleText)
        XCTAssertFalse(articleText.contains("without ad removal"), articleText)
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

    /// Same headless OCR path the feed-policy rendering tests use for the popover canvas.
    private func popoverText(isArticleFeed: Bool, suffix: String) throws -> String {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/\(suffix).xml"))
        let feedID = isArticleFeed
            ? try ItemID.articleFeed(canonicalFeedURL: feedURL).rawValue
            : try ItemID.derivePodcastFeed(from: feedURL).rawValue
        let subscription = WiltedMacSubscription(
            id: feedID, title: "The Daily Show", feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true)
        let model = makeModel(suffix)
        model.subscriptions = [subscription]
        let board = WiltedMacFeedPolicyBoard(model: model)
        board.loadForPreview(feedID: feedID, isArticleFeed: isArticleFeed, isNews: false)
        return try WiltedMacHeadless.recognizedText(
            WiltedMacFeedPolicyContent(board: board, subscription: subscription),
            size: CGSize(width: WiltedMacFeedPolicyContent.width, height: 800)
        ).joined(separator: " ")
    }
}
