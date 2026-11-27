import AppKit
import SwiftUI
import XCTest
import WiltedLibrary
@testable import WiltedMac

@MainActor
final class WiltedMacReportsDisclosureLatencyTests: XCTestCase {
    func testExpandedReportsFirstFrameWithBusyHeadlineFeeds() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        let now = Date()
        let stories = try (0..<800).map { index in
            try LibraryHeadlineStory(
                id: "report-\(index)", title: "Transit bulletin \(index)", publisherID: "local",
                publisherName: "Local news", link: URL(string: "https://example.test/news/\(index)"),
                publishedAt: now.addingTimeInterval(-Double(index)), firstSeenAt: now, lastSeenAt: now)
        }
        _ = try model.headlineCatalogStore.mergeRecent(stories, at: now)
        model.headlineCatalogState.refresh(at: now)
        let history = WiltedMacHeadlineHistoryDisclosure(model: model, isExpanded: .constant(true), chooseReadingVoice: {})
        try checkFirstFrame("Recent stories", view: history)
        let settings = WiltedMacReportsCard(model: model, location: model.bulletinHub.location, startsExpanded: true)
        try checkFirstFrame("Report settings", view: settings)
    }

    private func checkFirstFrame<V: View>(_ name: String, view: V) throws {
        let clock = ContinuousClock()
        let start = clock.now
        let host = WiltedMacHeadless.hosted(ScrollView { view }, size: CGSize(width: 850, height: 700))
        let bitmap = try WiltedMacHeadless.snapshot(of: host.view)
        let elapsed = start.duration(to: clock.now)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "\(name) first frame in \(elapsed)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(elapsed, .seconds(2), "\(name) blocked first paint for \(elapsed)")
    }
}
