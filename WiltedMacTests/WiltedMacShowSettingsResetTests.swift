import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacShowSettingsResetTests: XCTestCase {
    func testPodcastResetExplainsItsScopeAndUndoRestoresChoices() async throws {
        let fixture = try makeFixture(isArticle: false)
        XCTAssertTrue(fixture.board.update(
            fixture.feedID, autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(3)
        ))
        XCTAssertTrue(fixture.board.setAdFree(true, for: fixture.feedID))
        XCTAssertTrue(fixture.board.setRemoveSelfPromotion(true, for: fixture.feedID))
        XCTAssertTrue(fixture.board.setSendForAdFinding(true, for: fixture.feedID))
        fixture.model.preferences.set(["kept-local"], forKey: "wilted.adLabeller.localOnlyFeedIDs")
        XCTAssertEqual(fixture.board.customizedSettingNames(for: fixture.feedID), [
            "Auto keep", "Auto download", "Auto prepare", "Kept limit", "Remove ads",
            "Remove the show's own promotion", "Send this show for ad finding",
        ])

        let view = WiltedMacShowSettingsResetControl(board: fixture.board, feedID: fixture.feedID)
        let text = try WiltedMacHeadless.recognizedText(
            view, size: CGSize(width: 1_000, height: 360)
        ).joined(separator: " ")
        for label in ["Auto keep", "Auto download", "Auto prepare", "Kept limit", "Remove ads",
                      "own promotion", "Send this show for ad finding", "Reset all"] {
            XCTAssertTrue(text.contains(label), "Reset summary should show \(label): \(text)")
        }

        let undo = try XCTUnwrap(fixture.board.resetAllOverrides(for: fixture.feedID))

        XCTAssertEqual(fixture.board.explicitOverrideCount(for: fixture.feedID), 0)
        let restored = await fixture.board.undoResetAllOverrides(undo)
        XCTAssertTrue(restored)

        XCTAssertEqual(fixture.board.policy(for: fixture.feedID), FeedAutomationPolicy(
            autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(3)
        ))
        XCTAssertTrue(fixture.board.isAdFree(fixture.feedID))
        XCTAssertTrue(fixture.board.removesSelfPromotion(fixture.feedID))
        XCTAssertTrue(fixture.board.sendsForAdFinding(fixture.feedID))
        XCTAssertEqual(
            fixture.model.preferences.stringArray(forKey: "wilted.adLabeller.localOnlyFeedIDs"), ["kept-local"]
        )
    }

    func testResetUndoRestoresHeadlinesOnlyForArticleFeeds() async throws {
        let fixture = try makeFixture(isArticle: true)
        XCTAssertTrue(fixture.board.setNews(true, for: fixture.feedID))
        XCTAssertEqual(fixture.board.customizedSettingNames(for: fixture.feedID), ["Headlines only"])

        let undo = try XCTUnwrap(fixture.board.resetAllOverrides(for: fixture.feedID))

        XCTAssertFalse(fixture.board.isNews(fixture.feedID))
        let restored = await fixture.board.undoResetAllOverrides(undo)
        XCTAssertTrue(restored)
        XCTAssertTrue(fixture.board.isNews(fixture.feedID))
    }

    func testResetControlStaysQuietWhenNoSettingsAreCustomized() throws {
        let fixture = try makeFixture(isArticle: false)
        let view = WiltedMacShowSettingsResetControl(board: fixture.board, feedID: fixture.feedID)
        let text = try WiltedMacHeadless.recognizedText(
            view, size: CGSize(width: 1_000, height: 240)
        ).joined(separator: " ")
        XCTAssertFalse(text.contains("Customized:"), text)
        XCTAssertFalse(text.contains("Reset all"), text)
    }

    func testResetCapturesTheSavedAdFreeChoiceWhenBoardCacheIsStale() async throws {
        let fixture = try makeFixture(isArticle: false)
        WiltedMacAdFreeFeedPreference(preferences: fixture.model.preferences)
            .set(feedID: fixture.feedID, adFree: true)
        XCTAssertFalse(fixture.board.isAdFree(fixture.feedID))

        let undo = try XCTUnwrap(fixture.board.resetAllOverrides(for: fixture.feedID))
        XCTAssertFalse(fixture.board.isAdFree(fixture.feedID))
        let restored = await fixture.board.undoResetAllOverrides(undo)

        XCTAssertTrue(restored)
        XCTAssertTrue(fixture.board.isAdFree(fixture.feedID))
    }

    func testUndoKeepsChoicesMadeAfterReset() async throws {
        let fixture = try makeFixture(isArticle: false)
        XCTAssertTrue(fixture.board.update(fixture.feedID, autoKeep: .on))
        XCTAssertTrue(fixture.board.setSendForAdFinding(true, for: fixture.feedID))
        let undo = try XCTUnwrap(fixture.board.resetAllOverrides(for: fixture.feedID))
        XCTAssertTrue(fixture.board.update(fixture.feedID, autoDownload: .on))
        XCTAssertTrue(fixture.board.setSendForAdFinding(false, for: fixture.feedID))

        let restored = await fixture.board.undoResetAllOverrides(undo)

        XCTAssertTrue(restored)
        XCTAssertEqual(fixture.board.policy(for: fixture.feedID), FeedAutomationPolicy(
            autoKeep: .on, autoDownload: .on, autoPrepare: .useGlobal, keptLimit: .useGlobal
        ))
        XCTAssertFalse(fixture.board.sendsForAdFinding(fixture.feedID))
    }

    func testRestoreConfirmationNamesTheConfirmedEpisodeCount() {
        XCTAssertEqual(WiltedMacRestoreCutEpisodesControl.confirmationTitle(count: 1), "Restore 1 cut episode?")
        XCTAssertEqual(WiltedMacRestoreCutEpisodesControl.confirmationActionTitle(count: 1), "Restore 1 Episode")
        XCTAssertEqual(WiltedMacRestoreCutEpisodesControl.confirmationTitle(count: 3), "Restore 3 cut episodes?")
        XCTAssertEqual(WiltedMacRestoreCutEpisodesControl.confirmationActionTitle(count: 3), "Restore 3 Episodes")
    }

    private struct Fixture {
        let model: WiltedMacModel
        let board: WiltedMacFeedPolicyBoard
        let subscription: WiltedMacSubscription
        var feedID: String { subscription.id }
    }

    private func makeFixture(isArticle: Bool) throws -> Fixture {
        let feedURL = URL(string: isArticle
            ? "https://feeds.example.test/settings-articles.xml"
            : "https://feeds.example.test/settings-show.xml")!
        let feedID = try (isArticle
            ? ItemID.articleFeed(canonicalFeedURL: feedURL)
            : ItemID.derivePodcastFeed(from: feedURL)).rawValue
        let subscription = WiltedMacSubscription(
            id: feedID, title: "Settings Show", feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("show-settings-reset"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.subscriptions = [subscription]
        let board = WiltedMacFeedPolicyBoard(model: model)
        board.loadForPreview(feedID: feedID, isArticleFeed: isArticle, isNews: false)
        return Fixture(model: model, board: board, subscription: subscription)
    }
}
