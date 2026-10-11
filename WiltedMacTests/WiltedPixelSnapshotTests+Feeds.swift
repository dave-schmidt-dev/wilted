import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

extension WiltedPixelSnapshotTests {
    func testFeedsRowPixelBaselines() async throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("feeds-pixels"),
                preferences: WiltedMacTestPreferences.ephemeral())
            model.subscriptions = [WiltedMacSubscription(
                id: "feed-pixel-fixture", title: "Morning listening",
                feedURL: URL(string: "https://feeds.example.test/morning.xml")!,
                episodeCount: 3, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000),
                enabled: true, publisherTitle: "Publisher title", displayName: "Morning listening")]
            let variant = WiltedVisualVariant(
                appearance: appearance, dynamicType: .standard, reduceMotion: false)
            let image = render(
                WiltedMacFeedsView(model: model), variant: variant, size: CGSize(width: 760, height: 440))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8)
            assertSnapshot(image,
                named: WiltedSnapshotContract.shellName(kind: "feeds-row", appearance: appearance),
                testName: "testFeedsRowPixelBaselines")
            await model.close()
        }
    }
}
