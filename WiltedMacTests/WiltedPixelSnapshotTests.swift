import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

/// Offscreen snapshot contract for the canonical Mac renderer. The fixed
/// canvas and explicit environment keep these baselines independent of the
/// host window and user accessibility settings.
@MainActor
final class WiltedPixelSnapshotTests: XCTestCase {
    /// Single surfaces and state cards render at card scale.
    let canvas = CGSize(width: 520, height: 260)
    /// Whole-window compositions render at window scale.
    ///
    /// The split-view shells were previously captured on the 520x260 card
    /// canvas, where the sidebar collapses and renders as a blank rectangle —
    /// so the pixel suite never actually saw the navigation it was meant to
    /// verify, and a composition whose sidebar did nothing cleared the gate.
    private let windowCanvas = CGSize(width: 1100, height: 700)

    fileprivate static let visualFixtures = WiltedPreviewFixture.matrix
    fileprivate static let visualVariants = WiltedVisualVariant.matrix

    func testEveryPreviewStateHasLightAndDarkPixelBaselines() {
        for fixture in Self.visualFixtures {
            for variant in Self.visualVariants {
                assertSnapshot(
                    render(WiltedStateCard(fixture: fixture), variant: variant),
                    named: WiltedSnapshotContract.stateName(state: fixture.state, variant: variant),
                    testName: "testEveryPreviewStateHasLightAndDarkPixelBaselines"
                )
            }
        }
    }

    func testPixelSnapshotSelectorsAreUniqueAndComplete() {
        let names = Self.visualFixtures.flatMap { fixture in
            Self.visualVariants.map { variant in
                WiltedSnapshotContract.stateName(state: fixture.state, variant: variant)
            }
        } + WiltedAppearance.allCases.flatMap { appearance in
            [
                WiltedSnapshotContract.shellName(kind: "library", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "player", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "navigation-selection", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "producer-library", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "producer-url-focus", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "sidebar-full", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "sidebar-rail", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "toolbar", appearance: appearance)
            ] + ["add-sheet-link", "add-sheet-results", "add-sheet-followed", "add-sheet-error", "feed-policy-article", "feeds-article-row",
                "larder-kind-filter", "larder-book-row", "player-chapters"].map {
                WiltedSnapshotContract.shellName(kind: $0, appearance: appearance)
            }
        }
        XCTAssertEqual(names.count, WiltedSnapshotContract.expectedPixelBaselineCount)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("state-") || $0.hasPrefix("mac-shell-") })
    }

    func testLibraryAndPreparingBaselinesContainRenderedControls() throws {
        let lightLibrary = try baselineBitmap(
            testName: "testMacLibraryShellPixelBaselines",
            name: "mac-shell-library-light"
        )
        let darkLibrary = try baselineBitmap(
            testName: "testMacLibraryShellPixelBaselines",
            name: "mac-shell-library-dark"
        )
        XCTAssertGreaterThan(distinctColorCount(in: lightLibrary), 1)
        XCTAssertGreaterThan(distinctColorCount(in: darkLibrary), 1)

        let preparing = try baselineBitmap(
            testName: "testEveryPreviewStateHasLightAndDarkPixelBaselines",
            name: "state-preparing-fetching-light-standard-motion-full"
        )
        XCTAssertGreaterThan(distinctColorCount(in: preparing), 1,
                             "Preparing baseline must contain rendered progress content.")
    }

    /// Window baselines are captured at window scale and their detail region
    /// is genuinely rendered.
    ///
    /// **These baselines do not cover the sidebar, and cannot.** A
    /// `NavigationSplitView`'s navigation column is hosted in a separate
    /// AppKit split-view hierarchy that `NSHostingView.cacheDisplay` does not
    /// draw, so it records as a flat rectangle at any canvas size. That is
    /// precisely why a composition whose sidebar selection did nothing cleared
    /// this suite and was only caught in attended acceptance.
    ///
    /// Sidebar behavior is therefore owned by the Mac XCUITest suite, which
    /// drives the real app: `testIntakeJourneyAcrossLarderFeedsAndSettings`. This test
    /// asserts only what the pixel path can honestly see, and pins the
    /// detail-region origin so a future change cannot quietly shrink these
    /// back to the card canvas where even the detail region was cropped.
    func testWindowBaselinesCaptureTheDetailRegionAtWindowScale() throws {
        for appearance in ["light", "dark"] {
            let bitmap = try baselineBitmap(
                testName: "testMacPlayerShellPixelBaselines",
                name: "mac-shell-player-\(appearance)"
            )
            XCTAssertEqual(bitmap.pixelsWide, Int(canvas.width))
            XCTAssertEqual(bitmap.pixelsHigh, Int(canvas.height))
        }

        for appearance in ["light", "dark"] {
            for shell in ["producer-library", "navigation-selection"] {
                let testName = shell == "producer-library"
                    ? "testShippingMacProducerPixelBaselines"
                    : "testMacNavigationSelectionPixelBaselines"
                let bitmap = try baselineBitmap(testName: testName, name: "mac-shell-\(shell)-\(appearance)")

                XCTAssertEqual(bitmap.pixelsWide, Int(windowCanvas.width),
                               "\(shell)-\(appearance) must be captured at window scale")
                XCTAssertEqual(bitmap.pixelsHigh, Int(windowCanvas.height),
                               "\(shell)-\(appearance) must be captured at window scale")

                // Sample past the sidebar column into the detail region.
                let detail = NSRect(
                    x: 260, y: 0,
                    width: bitmap.pixelsWide - 260,
                    height: bitmap.pixelsHigh
                )
                XCTAssertGreaterThan(
                    distinctColorCount(in: bitmap, region: detail), 8,
                    "\(shell)-\(appearance) detail region is blank; the destination did not render."
                )
            }
        }
    }

    /// Settings is scrollable at window scale, so this focused render check
    /// guards against the automation card collapsing the destination to a
    /// blank surface without requiring a new unreviewed pixel baseline.
    func testSettingsAutomationSurfaceRendersAtWindowScale() throws {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"],
                stateDirectoryOverride: wiltedTemporaryDirectory("fixture"),
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            model.selectedNavigation = .settings
            let image = render(WiltedMacRootView(model: model), variant: variant, size: windowCanvas)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let detail = NSRect(x: 260, y: 0, width: bitmap.pixelsWide - 260, height: bitmap.pixelsHigh)
            XCTAssertGreaterThan(
                distinctColorCount(in: bitmap, region: detail), 8,
                "Settings automation surface is blank in \(appearance.rawValue) mode."
            )
        }
    }

    /// Captures shipping row contents; native List selection chrome is outside this renderer.
    func testMacSidebarFullPixelBaselines() throws {
        try captureSidebar(mode: .full, kind: "sidebar-full", testName: "testMacSidebarFullPixelBaselines")
    }

    func testMacSidebarRailPixelBaselines() throws {
        try captureSidebar(mode: .rail, kind: "sidebar-rail", testName: "testMacSidebarRailPixelBaselines")
    }

    /// The same controls used by ToolbarItems, without claiming AppKit toolbar chrome.
    func testMacToolbarPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"],
                stateDirectoryOverride: wiltedTemporaryDirectory("toolbar-pixel"),
                preferences: WiltedMacTestPreferences.ephemeral())
            let root = WiltedMacRootView(model: model)
            let content = HStack(spacing: WiltedTheme.Spacing.medium) {
                root.wordmarkContent
                root.sidebarToggleContent
            }
            .padding(WiltedTheme.Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(WiltedTheme.color(.page, scheme: appearance == .dark ? .dark : .light))
            .environment(\.wiltedTextScale, model.textScale)
            let image = render(content,
                variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: WiltedMacShellLayout.sidebarIdealWidth + WiltedMacShellLayout.railWidth,
                             height: WiltedMacShellLayout.railWidth))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the wordmark and sidebar control drew")
            assertSnapshot(image, named: WiltedSnapshotContract.shellName(kind: "toolbar", appearance: appearance),
                           testName: "testMacToolbarPixelBaselines")
        }
    }

    private func captureSidebar(mode: WiltedMacSidebarMode, kind: String, testName: String) throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"],
                stateDirectoryOverride: wiltedTemporaryDirectory("sidebar-pixel"),
                preferences: WiltedMacTestPreferences.ephemeral())
            model.selectedNavigation = .larder
            let sidebar = WiltedMacSidebar(model: model, mode: mode) { model.selectedNavigation = $0 }
            let width = mode == .full
                ? WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: model.textScale)
                : WiltedMacShellLayout.railWidth
            let content = VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                ForEach(WiltedMacNavigation.allCases) { sidebar.row($0) }
                Spacer(minLength: 0)
            }
            .padding(WiltedTheme.Spacing.small)
            .background(WiltedTheme.color(.page, scheme: appearance == .dark ? .dark : .light))
            .environment(\.wiltedTextScale, model.textScale)
            let image = render(content,
                variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: width, height: canvas.height))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "shipping navigation contents drew")
            if appearance == .dark {
                XCTAssertGreaterThan(maximumGreen(in: bitmap, region: NSRect(x: 0, y: 0, width: width, height: 28)),
                                     0.65, "selected shipping row resolves dark appearance inside its view body")
            }
            assertSnapshot(image, named: WiltedSnapshotContract.shellName(kind: kind, appearance: appearance),
                           testName: testName)
        }
    }

    func testMacLibraryShellPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(WiltedLibraryShell(fixture: WiltedPreviewFixture(state: .emptyLibrary)), variant: variant),
                named: WiltedSnapshotContract.shellName(kind: "library", appearance: appearance),
                testName: "testMacLibraryShellPixelBaselines"
            )
        }
    }

    func testMacPlayerShellPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("fixture"), preferences: WiltedMacTestPreferences.ephemeral())
            if let article = model.articles.first { model.openNowPlaying(for: article) }
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            let rendered = render(WiltedMacCompactPlayer(model: model), variant: variant)
            let bitmap = try XCTUnwrap(rendered.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "mac-player-current-\(appearance.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            assertSnapshot(
                rendered,
                named: WiltedSnapshotContract.shellName(kind: "player", appearance: appearance),
                testName: "testMacPlayerShellPixelBaselines"
            )
        }
    }

    /// The selected pane is rendered as a detail-sized surface, not a taller
    /// version of the old rail. A colour check is deliberate here: there is no
    /// new bitmap baseline until the attended visual review records one.
    func testMacFullWindowPlayerRendersAtDetailHeight() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("fixture"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        if let article = model.articles.first { model.openNowPlaying(for: article) }
        let image = render(
            WiltedMacFullWindowPlayer(
                model: model,
                presentation: .constant(.transcript),
                onSelect: { _ in },
                onCollapse: { _ in }
            ),
            variant: WiltedVisualVariant(appearance: .dark, dynamicType: .standard, reduceMotion: false),
            size: windowCanvas
        )
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(bitmap.pixelsHigh, Int(windowCanvas.height))
        XCTAssertGreaterThan(
            distinctColorCount(
                in: bitmap,
                region: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            ),
            8
        )
    }

    func testMacNavigationSelectionPixelBaselines() async {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"],
                stateDirectoryOverride: wiltedTemporaryDirectory("fixture"),
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            model.selectedNavigation = .settings
            // Settings shows lifetime totals once the background load lands.
            await model.waitForLifetimeStatisticsForTesting()
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(
                    WiltedMacRootView(model: model),
                    variant: variant,
                    size: windowCanvas
                ),
                named: WiltedSnapshotContract.shellName(kind: "navigation-selection", appearance: appearance),
                testName: "testMacNavigationSelectionPixelBaselines"
            )
        }
    }

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
            size: CGSize(width: WiltedMacFeedRulesView.width, height: 800)
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

    // MARK: Larder kinds and audiobooks

    /// A book as the Larder queues it: one single-file volume with chapter marks.
    private func fixtureBook() -> WiltedMacEpisode {
        var book = WiltedMacEpisode(
            id: "book-dune-0", title: "Dune", feedTitle: "Audiobook", summary: "Frank Herbert", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_900), durationSeconds: 21 * 3_600 + 35 * 60,
            playbackSeconds: 5_400, downloadState: .completed, preparationState: .prepared(summary: "Audiobook"))
        book.audiobook = WiltedMacAudiobookDetails(
            author: "Frank Herbert",
            chapters: [
                WiltedMacChapter(title: "Book One: Dune", startSeconds: 0),
                WiltedMacChapter(title: "Book Two: Muad'Dib", startSeconds: 4_800),
                WiltedMacChapter(title: "Book Three: The Prophet", startSeconds: 9_600),
            ],
            sourceFormat: "audio", volumeIndex: 0, volumeCount: 1)
        return book
    }

    private func larderModel(_ name: String) -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            preferences: WiltedMacTestPreferences.ephemeral())
        let book = fixtureBook()
        model.installEpisodeForTesting(book)
        model.podcastQueueIDs.append(book.id)
        return model
    }

    /// The whole Larder under the All filter: the kind menu beside Group and Sort, and articles,
    /// episodes and a book as rows in the one grouped list.
    func testLarderKindFilterPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = larderModel("larder-kind-filter")
            XCTAssertEqual(model.larderKind, .all)
            let image = render(
                WiltedMacLarderView(model: model, paneMode: .side),
                variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 760, height: 560))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the Larder drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "larder-kind-filter", appearance: appearance),
                testName: "testLarderKindFilterPixelBaselines")
        }
    }

    /// A book row: author, length and chapter count under the title.
    func testLarderBookRowPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = larderModel("larder-book-row")
            let book = try XCTUnwrap(model.episodes.first { $0.id == "book-dune-0" })
            let larder = WiltedMacLarderView(model: model, paneMode: .side)
            let content = larder.larderRow(book, position: 1, count: 1, showsGroupName: false)
                .padding(WiltedTheme.Spacing.large)
                .environment(\.wiltedTextScale, model.textScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WiltedTheme.color(.card, scheme: appearance == .dark ? .dark : .light))
            let image = render(
                content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 760, height: 110))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the book row drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "larder-book-row", appearance: appearance),
                testName: "testLarderBookRowPixelBaselines")
        }
        let model = larderModel("larder-book-row-text")
        let book = try XCTUnwrap(model.episodes.first { $0.id == "book-dune-0" })
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacLarderView(model: model, paneMode: .side).larderRow(book, position: 1, count: 1, showsGroupName: false),
            size: CGSize(width: 760, height: 110)).joined(separator: " ")
        XCTAssertTrue(shown.contains("Frank Herbert"), shown)
        XCTAssertTrue(shown.contains("3 chapters"), shown)
    }

    /// The player while a book plays: the chapter under the playhead and the previous and next steps.
    func testPlayerChaptersPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = larderModel("player-chapters")
            let book = try XCTUnwrap(model.episodes.first { $0.id == "book-dune-0" })
            model.installPlaybackStateForTesting(
                episode: book, isPlaying: false, position: 5_400, duration: book.durationSeconds ?? 0,
                queue: model.podcastQueueIDs)
            XCTAssertEqual(model.currentChapterTitle, "Book Two: Muad'Dib")
            let image = render(
                WiltedMacFullWindowPlayer(
                    model: model, presentation: .constant(nil), onSelect: { _ in }, onCollapse: { _ in }),
                variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 900, height: 480))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the player drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "player-chapters", appearance: appearance),
                testName: "testPlayerChaptersPixelBaselines")
        }
    }

    func testSnapshotBaselinePreservesExistingBytesWhenMatchingInRecordMode() throws {
        let baseline = try baselineTestURL(for: "matching-baseline")
        let existingBitmap = makeSolidBitmap(width: 4, height: 2, red: 17, green: 34, blue: 51, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 4, height: 2, red: 17, green: 34, blue: 51, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: false
        )

        XCTAssertFalse(mutation)
        XCTAssertEqual(try Data(contentsOf: baseline), existingBytes)
    }

    func testSnapshotBaselineReplacesWhenBaselineIsMissingOrUnreadableOrDifferentInRecordMode() throws {
        let missingBaseline = try baselineTestURL(for: "missing-baseline")
        let replacement = makeSolidBitmap(width: 3, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let replacementBytes = try XCTUnwrap(replacement.representation(using: .png, properties: [:]))
        let missing = try applySnapshotRecordModeUpdate(
            baseline: missingBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingBaseline.path))

        let unreadableBaseline = try baselineTestURL(for: "unreadable-baseline")
        try Data("not-an-image".utf8).write(to: unreadableBaseline, options: .atomic)
        let unreadable = try applySnapshotRecordModeUpdate(
            baseline: unreadableBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(unreadable)

        let dimensionMismatchBaseline = try baselineTestURL(for: "dimension-mismatch-baseline")
        let smallBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let smallBytes = try XCTUnwrap(smallBitmap.representation(using: .png, properties: [:]))
        try smallBytes.write(to: dimensionMismatchBaseline, options: .atomic)
        let dimensionMismatch = try applySnapshotRecordModeUpdate(
            baseline: dimensionMismatchBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(dimensionMismatch)

        let materialMismatchBaseline = try baselineTestURL(for: "material-mismatch-baseline")
        let oldBitmap = makeSolidBitmap(width: 3, height: 2, red: 1, green: 2, blue: 3, alpha: 255)
        let oldBytes = try XCTUnwrap(oldBitmap.representation(using: .png, properties: [:]))
        try oldBytes.write(to: materialMismatchBaseline, options: .atomic)
        let materialMismatch = try applySnapshotRecordModeUpdate(
            baseline: materialMismatchBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(materialMismatch)
    }

    func testSnapshotBaselineReplacesWhenForceRecordEnabled() throws {
        let baseline = try baselineTestURL(for: "force-record-baseline")
        let existingBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 2, height: 2, red: 13, green: 26, blue: 39, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: true
        )
        XCTAssertTrue(mutation)
        XCTAssertNotEqual(try Data(contentsOf: baseline), existingBytes)
    }

    func testForceRecordHasNoEffectWhenRecordModeIsDisabled() throws {
        let baseline = try baselineTestURL(for: "force-without-record")
        let existingBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 2, height: 2, red: 13, green: 26, blue: 39, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: true,
            recordMode: false
        )
        XCTAssertFalse(mutation)
        XCTAssertEqual(try Data(contentsOf: baseline), existingBytes)
    }


}

enum WiltedSnapshotContract {
    static let stateCount = WiltedPreviewState.allCases.count
    static let variantCount = WiltedVisualVariant.matrix.count
    static let shellCount = 34
    static let expectedPixelBaselineCount = stateCount * variantCount + shellCount

    static var recordMode: Bool {
        ProcessInfo.processInfo.environment["WILTED_RECORD_SNAPSHOTS"] == "1"
    }

    static var forceRecordMode: Bool {
        ProcessInfo.processInfo.environment["WILTED_FORCE_RECORD_SNAPSHOTS"] == "1"
    }

    static func stateName(state: WiltedPreviewState, variant: WiltedVisualVariant) -> String {
        "state-\(state.id)-\(variant.id)"
    }

    static func shellName(kind: String, appearance: WiltedAppearance) -> String {
        "mac-shell-\(kind)-\(appearance.rawValue)"
    }
}
