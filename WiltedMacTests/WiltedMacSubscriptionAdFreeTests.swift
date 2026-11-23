import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacSubscriptionAdFreeTests: XCTestCase {
    func testSubscriptionUsesRemoveAdsRegardlessOfTitleOrAddress() async throws {
        let cases = [
            ("Garden Hour Plus", "https://feeds.example.test/garden.xml"),
            ("Members", "https://feeds.example.test/members.xml"),
            ("Garden Hour", "https://feeds.example.test/feed.xml?token=fixture"),
        ]
        for (index, entry) in cases.enumerated() {
            let (title, address) = entry
            let url = try XCTUnwrap(URL(string: address))
            let feedID = try ItemID.derivePodcastFeed(from: url).rawValue
            let preferences = WiltedMacTestPreferences.ephemeral()
            let model = await makeModel(directory: wiltedTemporaryDirectory("ad-free-intake-\(index)"),
                                        title: title, preferences: preferences)
            model.startPodcastSubscriptionIntake(url)
            guard await WiltedMacHeadless.eventually("subscription saved for \(title)", {
                model.subscriptions.contains { $0.id == feedID }
            }) else {
                model.cancelPodcastSubscriptionCheck()
                return
            }
            await model.waitForPodcastOperations()

            let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true })
            board.loadForPreview(feedID: feedID, isArticleFeed: false, isNews: false)
            XCTAssertFalse(board.isAdFree(feedID))
            XCTAssertEqual(WiltedMacModel.preparationPolicySnapshot(
                from: model.automationSettings, feedID: feedID, preferences: preferences
            ).removeAds, model.automationSettings.removeAds)
            AdLabellerPreferences(preferences: model.preferences).isEnabled = true
            XCTAssertTrue(board.setSendForAdFinding(true, for: feedID))
            XCTAssertEqual(board.adRoute(for: feedID), .remote)
            XCTAssertTrue(board.setAdFree(true, for: feedID))
            XCTAssertEqual(board.adRoute(for: feedID), .notSent(.adRemovalOff))
        }
    }

    func testPhoneSubscriptionWithAPlusTitleFollowsTheSameDefault() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/phone-intent-plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let body = Data(Self.feedXML(title: "Garden Hour Plus", guid: "phone-intent-1").utf8)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("ad-free-phone-intent"),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: body)),
            pastedLinkClassifier: PastedLinkClassifier(loader: FixedBodyLoader(body: body)),
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let result = await model.subscribeFeed(feedURL)

        XCTAssertEqual(result, .added)
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        let store = try XCTUnwrap(model.store)
        let subscription = try await store.subscription(for: feedID)
        XCTAssertNotNil(subscription)
    }

    private func makeModel(
        directory: URL, title: String, preferences: UserDefaults
    ) async -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(Self.feedXML(
                title: title, guid: "fixture-1"
            ).utf8))),
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    private static func feedXML(title: String, guid: String) -> String {
        "<rss version=\"2.0\"><channel><title>\(title)</title>"
            + "<item><guid>\(guid)</guid><title>\(title) 1</title>"
            + "<pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>"
            + "<enclosure url=\"https://media.example.test/\(guid).mp3\" type=\"audio/mpeg\" /></item>"
            + "</channel></rss>"
    }
}
