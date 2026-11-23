import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacArticleShowSettingsTests: XCTestCase {
    func testArticleResetAllPersistsDefaultsAndPreservesHiddenPolicyAndName() async throws {
        let at = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feed = try ArticleFeed(canonicalURL: URL(string: "https://journal.example.test/feed")!,
                                   title: "Journal", createdAt: at)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("article-show-reset"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(articleFeed: feed)
                try await store.save(subscription: PodcastSubscription(
                    feedID: feed.itemID, subscribedAt: at, displayName: "My journal"
                ))
                try await store.save(feedAutomationPolicy: FeedAutomationPolicy(
                    autoKeep: .off, autoDownload: .on, autoPrepare: .on, keptLimit: .explicit(4)
                ), for: feed.itemID)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let id = feed.itemID.rawValue
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        XCTAssertTrue(board.setNews(true, for: id))
        await board.settle()
        XCTAssertEqual(board.explicitOverrideCount(for: id), 4)
        board.reset(.autoPrepare, for: id)
        await board.settle()
        XCTAssertEqual(board.explicitOverrideCount(for: id), 3)
        let undo = try XCTUnwrap(board.resetAllOverrides(for: id))
        await board.settle()

        let fresh = WiltedMacFeedPolicyBoard(model: model)
        await fresh.reload()
        XCTAssertTrue(fresh.isLoaded(id))
        XCTAssertEqual(fresh.policy(for: id), FeedAutomationPolicy(autoDownload: .on))
        XCTAssertFalse(fresh.isNews(id))
        XCTAssertEqual(fresh.explicitOverrideCount(for: id), 0)
        let store = try XCTUnwrap(model.store)
        let saved = try await store.subscription(for: feed.itemID)
        XCTAssertEqual(saved?.displayName, "My journal")

        board.beforeFeedPolicySaveHookForTesting = { _ in throw CocoaError(.fileWriteNoPermission) }
        let firstAttempt = await board.undoResetAllOverrides(undo)
        XCTAssertFalse(firstAttempt, "a partial Undo remains available for retry")
        board.beforeFeedPolicySaveHookForTesting = nil
        let retry = await board.undoResetAllOverrides(undo)
        XCTAssertTrue(retry)
        let restored = try await store.feedAutomationPolicy(for: feed.itemID)
        XCTAssertEqual(restored, FeedAutomationPolicy(autoKeep: .off, autoDownload: .on, keptLimit: .explicit(4)))
        let headlinesOnly = try await store.isNews(feedID: feed.itemID)
        XCTAssertTrue(headlinesOnly)
    }

    func testLarderArticleSettingsUseSavedFeedRelationEvenWhenSourcesMatch() async throws {
        let at = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feed = try ArticleFeed(canonicalURL: URL(string: "https://journal.example.test/feed")!,
                                   title: "Journal", createdAt: at)
        func article(_ path: String) throws -> Article {
            let url = URL(string: "https://journal.example.test/\(path)")!
            return try Article(itemID: ItemID.derive(from: url), canonicalURL: url,
                               title: "Journal", source: "Journal", createdAt: at)
        }
        let subscribed = try article("from-feed")
        let byHand = try article("from-link")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("article-show-settings"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(articleFeed: feed)
                try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: at))
                try await store.save(article: subscribed)
                try await store.save(article: byHand)
                _ = try await store.assign(articleID: subscribed.itemID, toFeed: feed.itemID)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let fromFeed = try XCTUnwrap(model.articles.first { $0.id == subscribed.itemID.rawValue })
        let standalone = try XCTUnwrap(model.articles.first { $0.id == byHand.itemID.rawValue })
        XCTAssertEqual(fromFeed.feedID, feed.itemID.rawValue)
        XCTAssertNil(standalone.feedID)
        let view = try WiltedMacHeadless.viewSource("WiltedMacLarderView+Sections.swift")
        XCTAssertTrue(view.contains("showSettingsAction(feedID: article.feedID)"))
    }
}
