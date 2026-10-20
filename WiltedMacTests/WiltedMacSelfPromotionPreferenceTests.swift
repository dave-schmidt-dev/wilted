import Foundation
import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The per-feed "Remove the show's own promotion" choice: where it is kept,
/// how it reaches the snapshot an episode is admitted with, and the toggle
/// that sets it.
@MainActor
final class WiltedMacSelfPromotionPreferenceTests: XCTestCase {
    // MARK: Preference

    func testStartsWithNoFeedAndNoStoredKey() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let preference = WiltedMacSelfPromotionPreference(preferences: preferences)

        XCTAssertEqual(preference.feedIDs, [])
        XCTAssertFalse(preference.isEnabled(feedID: "feed-a"))
        XCTAssertNil(preferences.object(forKey: WiltedMacSelfPromotionPreference.preferenceKey))
    }

    func testSetStoresASortedArrayAndKeepsEachFeedsChoiceSeparate() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let preference = WiltedMacSelfPromotionPreference(preferences: preferences)

        preference.set(feedID: "feed-c", enabled: true)
        preference.set(feedID: "feed-a", enabled: true)
        preference.set(feedID: "feed-a", enabled: true)

        XCTAssertEqual(WiltedMacSelfPromotionPreference.preferenceKey, "wilted.feeds.removeSelfPromotion")
        XCTAssertEqual(preferences.stringArray(forKey: WiltedMacSelfPromotionPreference.preferenceKey), ["feed-a", "feed-c"])
        XCTAssertTrue(preference.isEnabled(feedID: "feed-a"))
        XCTAssertTrue(preference.isEnabled(feedID: "feed-c"))
        XCTAssertFalse(preference.isEnabled(feedID: "feed-b"), "a feed never set stays off")
    }

    func testClearingOneFeedLeavesTheOthersAndTheLastRemovesTheKey() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let preference = WiltedMacSelfPromotionPreference(preferences: preferences)
        preference.set(feedID: "feed-a", enabled: true)
        preference.set(feedID: "feed-b", enabled: true)

        preference.set(feedID: "feed-a", enabled: false)
        XCTAssertEqual(preference.feedIDs, ["feed-b"])

        preference.set(feedID: "feed-b", enabled: false)
        XCTAssertEqual(preference.feedIDs, [])
        XCTAssertNil(preferences.object(forKey: WiltedMacSelfPromotionPreference.preferenceKey))
    }

    func testReadIgnoresBlanksRepeatsAndAMissingFeed() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set(["feed-b", "", "feed-a", "feed-b"], forKey: WiltedMacSelfPromotionPreference.preferenceKey)
        let preference = WiltedMacSelfPromotionPreference(preferences: preferences)

        XCTAssertEqual(preference.feedIDs, ["feed-a", "feed-b"])
        XCTAssertFalse(preference.isEnabled(feedID: nil), "an episode with no feed never has the option")
        XCTAssertFalse(preference.isEnabled(feedID: ""))
        preference.set(feedID: "", enabled: true)
        XCTAssertEqual(preference.feedIDs, ["feed-a", "feed-b"], "a blank feed ID is never stored")
    }

    // MARK: Snapshot

    func testSnapshotCarriesTheOptionOnlyForAnOptedInFeed() throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        WiltedMacSelfPromotionPreference(preferences: preferences).set(feedID: "feed-a", enabled: true)
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .alwaysTranscribe, removeAds: true
        )

        let optedIn = WiltedMacModel.preparationPolicySnapshot(from: settings, feedID: "feed-a", preferences: preferences)
        let other = WiltedMacModel.preparationPolicySnapshot(from: settings, feedID: "feed-b", preferences: preferences)
        let noFeed = WiltedMacModel.preparationPolicySnapshot(from: settings, feedID: nil, preferences: preferences)

        XCTAssertEqual(optedIn, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: true, removeSelfPromotion: true
        ))
        XCTAssertEqual(other, WiltedMacModel.preparationPolicySnapshot(from: settings))
        XCTAssertFalse(other.removeSelfPromotion)
        XCTAssertFalse(noFeed.removeSelfPromotion)
    }

    func testEpisodeOfAnOptedInFeedIsAdmittedWithTheOption() throws {
        let model = makeModel("self-promotion-admission")
        WiltedMacSelfPromotionPreference(preferences: model.preferences).set(feedID: "feed-a", enabled: true)
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(try windowExcludingNow()),
            transcriptPolicy: .bestAvailable, removeAds: true
        ))
        let optedIn = episode("episode-a", feedID: "feed-a")
        let other = episode("episode-b", feedID: "feed-b")

        XCTAssertTrue(model.preparationPolicySnapshot(for: optedIn).removeSelfPromotion)
        XCTAssertFalse(model.preparationPolicySnapshot(for: other).removeSelfPromotion)

        // Off-peak processing holds the admitted snapshot, so the automatic path can be read back.
        model.admitAutomaticPreparation(for: optedIn, at: Date())
        model.admitAutomaticPreparation(for: other, at: Date())
        let admitted = Dictionary(uniqueKeysWithValues: model.deferredAutomaticPreparations.map {
            ($0.episodeID, $0.policySnapshot.removeSelfPromotion)
        })
        XCTAssertEqual(admitted, ["episode-a": true, "episode-b": false])
        let persisted = WiltedMacModel.loadDeferredAutomaticPreparations(from: model.preferences)
        XCTAssertEqual(persisted.first { $0.episodeID == "episode-a" }?.policySnapshot.removeSelfPromotion, true,
                       "the queued job keeps the option across a relaunch")
    }

    // MARK: Board and toggle

    func testBoardSavesTheChoiceForAPodcastFeedAndRefusesAnArticleFeed() {
        let model = makeModel("self-promotion-board")
        let board = WiltedMacFeedPolicyBoard(model: model)
        board.loadForPreview(feedID: "feed-a", isArticleFeed: false, isNews: false)
        board.loadForPreview(feedID: "articles", isArticleFeed: true, isNews: false)

        XCTAssertFalse(board.setRemoveSelfPromotion(true, for: "unloaded"), "a feed not loaded is refused")
        XCTAssertFalse(board.setRemoveSelfPromotion(true, for: "articles"), "an article feed has no audio to cut")
        XCTAssertTrue(board.setRemoveSelfPromotion(true, for: "feed-a"))

        XCTAssertTrue(board.removesSelfPromotion("feed-a"))
        XCTAssertEqual(WiltedMacSelfPromotionPreference(preferences: model.preferences).feedIDs, ["feed-a"])
        XCTAssertTrue(WiltedMacFeedPolicyBoard(model: model).removesSelfPromotion("feed-a"),
                      "a new board reads the saved choice")

        XCTAssertTrue(board.setRemoveSelfPromotion(false, for: "feed-a"))
        XCTAssertFalse(board.removesSelfPromotion("feed-a"))
        XCTAssertEqual(WiltedMacSelfPromotionPreference(preferences: model.preferences).feedIDs, [])
    }

    func testToggleAndCaptionShowOnlyForAPodcastFeed() throws {
        let podcastText = try popoverText(isArticleFeed: false, suffix: "self-promotion-podcast")
        XCTAssertTrue(podcastText.contains("own promotion"), podcastText)
        XCTAssertTrue(podcastText.contains("sponsor roll call"), podcastText)

        let articleText = try popoverText(isArticleFeed: true, suffix: "self-promotion-article")
        XCTAssertFalse(articleText.contains("own promotion"), articleText)
        XCTAssertFalse(articleText.contains("sponsor roll call"), articleText)
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

    private func episode(_ id: String, feedID: String) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "\(id) title", feedTitle: "Show", summary: "Summary",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed, feedID: feedID
        )
    }

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

    /// A window that starts two hours from now, so the current time is outside it.
    private func windowExcludingNow() throws -> WiltedAutomationOffPeakWindow {
        let hour = Calendar.current.component(.hour, from: Date())
        let start = try XCTUnwrap(WiltedAutomationLocalTime(hour: (hour + 2) % 24, minute: 0))
        let end = try XCTUnwrap(WiltedAutomationLocalTime(hour: (hour + 3) % 24, minute: 0))
        return try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end))
    }
}
