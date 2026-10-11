import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Article feeds in the Feeds inbox: offered posts, Keep and Skip, and surviving a reload.
@MainActor
final class WiltedMacArticleFeedInboxTests: XCTestCase {
    private static let feedURL = URL(string: "https://feeds.example.test/articles.xml")!
    private static let xml = "<rss version=\"2.0\"><channel><title>Articles only</title>"
        + "<item><guid>a1</guid><title>Post one</title><link>https://feeds.example.test/post-1</link></item>"
        + "<item><guid>a2</guid><title>Post two</title><link>https://feeds.example.test/post-2</link></item>"
        + "</channel></rss>"

    private func followedModel(_ name: String) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(Self.xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.startPodcastSubscriptionIntake(Self.feedURL)
        await model.waitForPodcastOperations()
        return model
    }

    func testArticleFeedIsStillListedAfterAModelReload() async throws {
        let model = try await followedModel("article-feed-reload")
        XCTAssertEqual(model.subscriptions.map(\.feedURL), [Self.feedURL])

        await model.reloadLibraryRowsForTesting()
        XCTAssertEqual(model.subscriptions.map(\.feedURL), [Self.feedURL], "reloadLibraryRows keeps article feeds")

        model.subscriptions = []
        model.refresh()
        let deadline = Date().addingTimeInterval(5)
        while model.subscriptions.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.subscriptions.map(\.feedURL), [Self.feedURL], "loadLibrary keeps article feeds")
        XCTAssertEqual(model.subscriptions.count, 1, "an article feed is listed once")
    }

    func testOfferedArticlesAreListedInTheInboxAndSkipRemovesOneForGood() async throws {
        let model = try await followedModel("article-feed-inbox-skip")
        XCTAssertEqual(Set(model.feedsOfferedArticles.map(\.title)), ["Post one", "Post two"])

        let skipped = try XCTUnwrap(model.feedsOfferedArticles.first { $0.title == "Post one" })
        model.skipOfferedArticle(skipped)
        XCTAssertEqual(model.feedsOfferedArticles.map(\.title), ["Post two"], "article Skip answers before its writer starts")
        XCTAssertEqual(model.offeredArticles.count, 2, "the canonical offers remain until commit")
        XCTAssertEqual(model.pendingFeedDecisionIDs, [skipped.id])
        let writers = model.subscriptionWriteTasks.count
        model.skipOfferedArticle(skipped)
        XCTAssertEqual(model.subscriptionWriteTasks.count, writers, "repeated Skip does not admit another writer")
        await waitForFeedDecisionWriters(model)
        XCTAssertEqual(model.feedsOfferedArticles.map(\.title), ["Post two"])
        XCTAssertTrue(model.pendingFeedDecisionIDs.isEmpty)

        let store = try XCTUnwrap(model.store)
        let decision = try await store.episodeDecision(for: ItemID(rawValue: skipped.id))
        XCTAssertEqual(decision?.decision, .skip)
        XCTAssertEqual(decision?.source, .manual)
    }

    func testKeepThatCannotPrepareLeavesThePostOfferedAndMarksItFailed() async throws {
        let model = try await followedModel("article-feed-inbox-keep-fails")
        model.coordinator = nil
        let offered = try XCTUnwrap(model.feedsOfferedArticles.first)

        model.keepOfferedArticle(offered)
        XCTAssertEqual(model.feedsOfferedArticles.count, 1, "article Keep answers before preparation begins")
        XCTAssertFalse(model.feedsOfferedArticles.contains { $0.id == offered.id })
        XCTAssertEqual(model.offeredArticles.count, 2)
        XCTAssertEqual(model.pendingFeedDecisionIDs, [offered.id])
        let writers = model.subscriptionWriteTasks.count
        model.keepOfferedArticle(offered)
        XCTAssertEqual(model.subscriptionWriteTasks.count, writers)
        await waitForFeedDecisionWriters(model)
        XCTAssertTrue(model.failedFeedDecisionIDs.contains(offered.id))
        XCTAssertTrue(model.pendingFeedDecisionIDs.isEmpty)
        XCTAssertTrue(model.feedsOfferedArticles.contains { $0.id == offered.id }, "the failed article returns for retry")
        XCTAssertEqual(model.feedsOfferedArticles.count, 2)
        let store = try XCTUnwrap(model.store)
        let decision = try await store.episodeDecision(for: ItemID(rawValue: offered.id))
        XCTAssertNil(decision, "a failed keep decides nothing, so the next refresh offers the post again")
    }
}
