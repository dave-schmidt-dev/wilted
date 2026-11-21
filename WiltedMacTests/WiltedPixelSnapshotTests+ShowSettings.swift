import AppKit
import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedPixelSnapshotTests {
    func testShowSettingsPagePixelBaselines() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/show-settings.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL).rawValue
        let subscription = WiltedMacSubscription(
            id: feedID, title: "Show Settings Example", feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: wiltedTemporaryDirectory("show-settings-pixel"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.subscriptions = [subscription]
        let board = WiltedMacFeedPolicyBoard(model: model)
        board.loadForPreview(feedID: feedID, isArticleFeed: false, isNews: false)

        let unchanged = showSettingsImage(model: model, board: board, subscription: subscription, appearance: .light)
        assertSnapshot(
            unchanged,
            named: WiltedSnapshotContract.shellName(kind: "show-settings", appearance: .light),
            testName: "testShowSettingsPagePixelBaselines"
        )

        board.loadForPreview(feedID: feedID, policy: FeedAutomationPolicy(autoKeep: .on),
                             isArticleFeed: false, isNews: false)
        let changed = showSettingsImage(model: model, board: board, subscription: subscription, appearance: .light)
        assertSnapshot(
            changed,
            named: WiltedSnapshotContract.shellName(kind: "show-settings-changed", appearance: .light),
            testName: "testShowSettingsPagePixelBaselines"
        )
    }

    func testArticleShowSettingsPixelBaselines() throws {
        let feedURL = try XCTUnwrap(URL(string: "https://blog.example.test/feed.xml"))
        let feedID = try ItemID.articleFeed(canonicalFeedURL: feedURL).rawValue
        let subscription = WiltedMacSubscription(
            id: feedID, title: "The Example Blog", feedURL: feedURL, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: [],
                stateDirectoryOverride: wiltedTemporaryDirectory("show-settings-article-pixel"),
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            addTeardownBlock { await model.close() }
            model.subscriptions = [subscription]
            let board = WiltedMacFeedPolicyBoard(model: model)
            board.loadForPreview(feedID: feedID, isArticleFeed: true, isNews: true)
            let image = showSettingsImage(
                model: model, board: board, subscription: subscription, appearance: appearance
            )
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the article Show settings page drew")
            assertSnapshot(
                image,
                named: WiltedSnapshotContract.shellName(kind: "show-settings-article", appearance: appearance),
                testName: "testArticleShowSettingsPixelBaselines"
            )
        }
    }

    private func showSettingsImage(
        model: WiltedMacModel,
        board: WiltedMacFeedPolicyBoard,
        subscription: WiltedMacSubscription,
        appearance: WiltedAppearance
    ) -> NSImage {
        let content = WiltedMacShowSettingsView(model: model, board: board, subscription: subscription)
            .environment(\.wiltedTextScale, model.textScale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WiltedTheme.color(.page, scheme: appearance == .dark ? .dark : .light))
        return render(
            content,
            variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
            size: windowCanvas
        )
    }
}
