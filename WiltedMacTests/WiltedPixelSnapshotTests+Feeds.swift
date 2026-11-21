import AppKit
import SwiftUI
import WiltedDomain
import XCTest
@testable import WiltedMac

extension WiltedPixelSnapshotTests {
    func testFeedsRowPixelBaselines() async throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("feeds-pixels"),
                preferences: WiltedMacTestPreferences.ephemeral())
            // One feed of each kind, so the Podcasts, Articles and Headlines groups all show.
            let longReads = URL(string: "https://feeds.example.test/long-reads.xml")!
            let news = URL(string: "https://feeds.example.test/news.xml")!
            let longReadsID = try ItemID.articleFeed(canonicalFeedURL: longReads).rawValue
            let newsID = try ItemID.articleFeed(canonicalFeedURL: news).rawValue
            let subscribedAt = Date(timeIntervalSince1970: 1_700_000_000)
            model.subscriptions = [
                WiltedMacSubscription(
                    id: "feed-pixel-fixture", title: "Morning listening",
                    feedURL: URL(string: "https://feeds.example.test/morning.xml")!,
                    episodeCount: 3, subscribedAt: subscribedAt,
                    enabled: true, publisherTitle: "Publisher title", displayName: "Morning listening"),
                WiltedMacSubscription(id: longReadsID, title: "Long reads", feedURL: longReads, episodeCount: 0,
                                      subscribedAt: subscribedAt, enabled: true),
                WiltedMacSubscription(id: newsID, title: "World news", feedURL: news, episodeCount: 0,
                                      subscribedAt: subscribedAt, enabled: true),
            ]
            let board = WiltedMacFeedPolicyBoard(model: model)
            board.loadForPreview(feedID: "feed-pixel-fixture", isArticleFeed: false, isNews: false)
            board.loadForPreview(feedID: longReadsID, isArticleFeed: true, isNews: false)
            board.loadForPreview(feedID: newsID, isArticleFeed: true, isNews: true)
            let variant = WiltedVisualVariant(
                appearance: appearance, dynamicType: .standard, reduceMotion: false)
            let image = render(
                WiltedMacFeedsView(model: model, policyBoard: board), variant: variant,
                size: CGSize(width: 760, height: 560))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8)
            assertSnapshot(image,
                named: WiltedSnapshotContract.shellName(kind: "feeds-row", appearance: appearance),
                testName: "testFeedsRowPixelBaselines")
            await model.close()
        }
    }
}
