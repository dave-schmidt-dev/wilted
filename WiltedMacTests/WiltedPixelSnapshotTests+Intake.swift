import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

extension WiltedPixelSnapshotTests {
    func testShippingMacProducerPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: [
                    "--wilted-ui-fixture-article-flow",
                    "--wilted-ui-fixture-podcasts",
                    "--wilted-ui-fixture-ready",
                    "--wilted-ui-fixture-prepared"
                ], stateDirectoryOverride: wiltedTemporaryDirectory("fixture"), preferences: WiltedMacTestPreferences.ephemeral()
            )
            model.podcastQueueIDs = model.episodes.map(\.id)
            XCTAssertFalse(model.podcastQueueIDs.isEmpty, "the producer capture must show queued podcasts")
            XCTAssertFalse(model.larderVisibleEpisodes.isEmpty, "the Larder capture must contain podcast rows")
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(WiltedMacRootView(model: model), variant: variant, size: windowCanvas),
                named: WiltedSnapshotContract.shellName(kind: "producer-library", appearance: appearance),
                testName: "testShippingMacProducerPixelBaselines"
            )
        }
    }

    func testShippingMacURLFocusPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(
                    WiltedMacLinkField(
                        text: .constant("https://example.com/article"),
                        focusedOverride: true
                    ),
                    variant: variant
                ),
                named: WiltedSnapshotContract.shellName(kind: "producer-url-focus", appearance: appearance),
                testName: "testShippingMacURLFocusPixelBaselines"
            )
        }
    }

    /// The Add sheet's reading and book-import states, rendered as the sheet's own content.
    func testMacAddSheetPixelBaselines() async throws {
        let feed = try XCTUnwrap(URL(string: "https://feeds.example.test/followed.xml"))
        let shows = [
            PodcastCatalogShow(collectionID: 1, title: "The Followed Hour", feedURL: feed, author: "Example Audio"),
            PodcastCatalogShow(
                collectionID: 2, title: "Field Notes",
                feedURL: try XCTUnwrap(URL(string: "https://feeds.example.test/field-notes.xml")),
                author: "Example Studio"),
            PodcastCatalogShow(
                collectionID: 3, title: "Slow Radio",
                feedURL: try XCTUnwrap(URL(string: "https://feeds.example.test/slow.xml")), author: nil),
        ]
        let page = try XCTUnwrap(URL(string: "https://blog.example.test/posts/one"))
        let advertised = try XCTUnwrap(URL(string: "https://blog.example.test/feed.xml"))
        let cases: [(kind: String, text: String, followed: Bool, intake: String?,
                     search: WiltedMacAddSession.Search, classify: WiltedMacAddSession.Classify,
                     importState: WiltedMacAddSession.ImportState?)] = [
            ("add-sheet-link", page.absoluteString, false, nil, { _ in [] }, { _ in .articleAdvertisingFeed(advertised) }, nil),
            ("add-sheet-results", "slow", false, nil, { _ in shows }, { _ in .article }, nil),
            ("add-sheet-followed", "hour", true, nil, { _ in shows }, { _ in .article }, nil),
            ("add-sheet-error", feed.absoluteString, false, WiltedMacModel.PodcastFeedHasNoAudio.message,
             { _ in [] }, { _ in .podcastFeed }, nil),
            ("add-sheet-import-progress", "", false, nil, { _ in [] }, { _ in .article },
             .working(fraction: 0.4, detail: "Converting chapter 2 of 5: The Whale")),
            ("add-sheet-import-refusal", "", false, nil, { _ in [] }, { _ in .article },
             .refused("Moby Dick.epub is copy-protected and cannot be imported.")),
        ]
        for testCase in cases {
            for appearance in WiltedAppearance.allCases {
                let model = WiltedMacModel(
                    arguments: ["--wilted-ui-fixture-ready"],
                    stateDirectoryOverride: wiltedTemporaryDirectory(testCase.kind),
                    preferences: WiltedMacTestPreferences.ephemeral())
                if testCase.followed {
                    model.subscriptions = [WiltedMacSubscription(
                        id: try ItemID.derivePodcastFeed(from: feed).rawValue, title: "The Followed Hour",
                        feedURL: feed, episodeCount: 5, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        enabled: true)]
                }
                let session = model.makeAddSession(
                    search: testCase.search, classify: testCase.classify, linkDebounce: .zero, searchDebounce: .zero)
                session.text = testCase.text
                await session.settle()
                model.podcastFeedDraftStatus = testCase.intake
                if let state = testCase.importState { session.showImportForPreview(state) }
                let content = WiltedMacAddSheetContent(session: session)
                    .environment(\.wiltedTextScale, model.textScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(WiltedTheme.color(.card, scheme: appearance == .dark ? .dark : .light))
                let image = render(
                    content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                    size: CGSize(width: 520, height: 420))
                let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "\(testCase.kind) drew")
                assertSnapshot(
                    image, named: WiltedSnapshotContract.shellName(kind: testCase.kind, appearance: appearance),
                    testName: "testMacAddSheetPixelBaselines")
            }
        }
    }

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
