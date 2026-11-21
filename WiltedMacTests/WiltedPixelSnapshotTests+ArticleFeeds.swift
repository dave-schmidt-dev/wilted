import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

extension WiltedPixelSnapshotTests {
    /// The feed settings popover of an article feed: no download choice, and the "News" row.
    func testArticleFeedPolicyPopoverPixelBaselines() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://blog.example.test/feed.xml"))
        let feedID = try ItemID.articleFeed(canonicalFeedURL: feedURL).rawValue
        let subscription = WiltedMacSubscription(
            id: feedID, title: "The Example Blog", feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true)
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("feed-policy-article"),
                preferences: WiltedMacTestPreferences.ephemeral())
            model.subscriptions = [subscription]
            let board = WiltedMacFeedPolicyBoard(model: model)
            board.loadForPreview(feedID: feedID, isArticleFeed: true, isNews: true)
            let content = WiltedMacFeedPolicyContent(board: board, subscription: subscription)
                .padding(WiltedTheme.Spacing.large)
                .environment(\.wiltedTextScale, model.textScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WiltedTheme.color(.card, scheme: appearance == .dark ? .dark : .light))
            let image = render(
                content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 520, height: 460))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the article feed popover drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "feed-policy-article", appearance: appearance),
                testName: "testArticleFeedPolicyPopoverPixelBaselines")
        }
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedPolicyContent(board: {
                let model = WiltedMacModel(
                    arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("feed-policy-article-text"),
                    preferences: WiltedMacTestPreferences.ephemeral())
                model.subscriptions = [subscription]
                let board = WiltedMacFeedPolicyBoard(model: model)
                board.loadForPreview(feedID: feedID, isArticleFeed: true, isNews: true)
                return board
            }(), subscription: subscription),
            size: CGSize(width: WiltedMacFeedPolicyContent.width, height: 800)
        ).joined(separator: " ")
        XCTAssertTrue(shown.contains("News"), shown)
        XCTAssertFalse(shown.contains("Auto download"), "an article has nothing to download: \(shown)")
    }

    /// An offered post of an article feed in the Feeds inbox, with Keep and Skip.
    func testArticleFeedInboxRowPixelBaselines() throws {
        let article = WiltedMacOfferedArticle(
            id: "article-row-fixture", feedID: "feed", feedTitle: "The Example Blog",
            title: "Why small tools last longer than big ones",
            link: try XCTUnwrap(URL(string: "https://blog.example.test/post")),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            item: ArticleFeedItem(
                guid: "g", title: "Why small tools last longer than big ones",
                link: try XCTUnwrap(URL(string: "https://blog.example.test/post")),
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("feeds-article-row"),
                preferences: WiltedMacTestPreferences.ephemeral())
            let content = WiltedMacFeedsArticleRow(model: model, article: article)
                .padding(WiltedTheme.Spacing.large)
                .environment(\.wiltedTextScale, model.textScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WiltedTheme.color(.card, scheme: appearance == .dark ? .dark : .light))
            let image = render(
                content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 520, height: 90))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the article row drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "feeds-article-row", appearance: appearance),
                testName: "testArticleFeedInboxRowPixelBaselines")
        }
    }
}
