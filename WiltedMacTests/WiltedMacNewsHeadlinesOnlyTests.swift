import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// A feed marked News is a headline source only: its posts are not offered in Feeds, not
/// counted and not kept. Nothing is deleted, and turning News off brings them back.
@MainActor
final class WiltedMacNewsHeadlinesOnlyTests: XCTestCase {
    private static let feedXML = "<rss version=\"2.0\"><channel><title>Wire news</title>"
        + "<item><guid>n1</guid><title>First story</title><link>https://news.example.test/one</link></item>"
        + "<item><guid>n2</guid><title>Second story</title><link>https://news.example.test/two</link></item>"
        + "</channel></rss>"
    private let feedURL = URL(string: "https://news.example.test/rss.xml")!

    private func followedModel(_ name: String) async throws -> (WiltedMacModel, LocalLibraryStore, ItemID) {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(Self.feedXML.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        model.startPodcastSubscriptionIntake(feedURL)
        await model.waitForPodcastOperations()
        return (model, store, try ItemID.articleFeed(canonicalFeedURL: feedURL))
    }

    func testPostsOfAFeedMarkedNewsAreNotOfferedCountedOrKept() async throws {
        let (model, store, feedID) = try await followedModel("news-headlines-only")
        XCTAssertEqual(model.feedsOfferedArticles.count, 2, "an ordinary article feed offers its posts")

        try await store.save(isNews: true, feedID: feedID)
        _ = try await model.refreshArticleFeed(url: feedURL, subscribing: false, store: store)

        XCTAssertTrue(model.feedsOfferedArticles.isEmpty, "a News feed's posts stay out of Feeds")
        XCTAssertEqual(model.feedsDecisionCount, 0, "and out of the Feeds count")
        let kept = try await store.articleIDs(forFeed: feedID)
        XCTAssertTrue(kept.isEmpty, "nothing of a News feed is kept or prepared")
    }

    func testMarkingNewsHidesOfferedPostsAtOnceAndUnmarkingBringsThemBack() async throws {
        let (model, store, feedID) = try await followedModel("news-toggle")
        XCTAssertEqual(model.feedsOfferedArticles.count, 2)

        let board = WiltedMacFeedPolicyBoard(model: model)
        board.loadForPreview(feedID: feedID.rawValue, isArticleFeed: true, isNews: false)
        XCTAssertTrue(board.setNews(true, for: feedID.rawValue))
        XCTAssertTrue(model.feedsOfferedArticles.isEmpty, "hidden as soon as News is switched on")

        XCTAssertTrue(board.setNews(false, for: feedID.rawValue))
        await board.settle()
        _ = try await model.refreshArticleFeed(url: feedURL, subscribing: false, store: store)
        XCTAssertEqual(Set(model.feedsOfferedArticles.map(\.title)), ["First story", "Second story"],
                       "nothing was used up: the posts are offered again")
    }
}
