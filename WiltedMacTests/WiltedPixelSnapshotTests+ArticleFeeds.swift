import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

extension WiltedPixelSnapshotTests {
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
