import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// The optional figures beside the Larder and Feeds sidebar rows.
@MainActor
final class WiltedMacSidebarCountsTests: XCTestCase {
    func testCountsAreOffByDefaultAndTheChoicePersistsAcrossAFreshModel() {
        // A fixture launch replaces the preferences with its own, so this uses a plain launch.
        let preferences = WiltedMacTestPreferences.ephemeral()
        let first = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertFalse(first.showsSidebarCounts, "off by default")
        first.showsSidebarCounts = true
        XCTAssertTrue(WiltedMacModel(arguments: [], preferences: preferences).showsSidebarCounts)
        first.showsSidebarCounts = false
        XCTAssertFalse(WiltedMacModel(arguments: [], preferences: preferences).showsSidebarCounts)
    }

    func testRowsCarryTheReadyAndToDecideCountsOnlyWhenTurnedOn() {
        let model = seededModel()
        XCTAssertNil(model.sidebarCount(for: .larder))
        XCTAssertNil(model.sidebarCount(for: .feeds))

        model.showsSidebarCounts = true
        XCTAssertEqual(model.sidebarCount(for: .larder), 2, "the two prepared episodes, not the one needing prep")
        XCTAssertEqual(model.sidebarCount(for: .feeds), 1, "the one episode that is not on the Larder")
        XCTAssertEqual(model.sidebarCount(for: .feeds), model.feedsEpisodeCandidates.count + model.feedsOfferedArticles.count)
        XCTAssertNil(model.sidebarCount(for: .settings))
        XCTAssertNil(model.sidebarCount(for: .playlist("any")))
    }

    func testAnEmptyRowCarriesNoFigure() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        model.showsSidebarCounts = true
        XCTAssertNil(model.sidebarCount(for: .larder))
        XCTAssertNil(model.sidebarCount(for: .feeds))
    }

    func testTheRailNamesTheCountInWords() {
        XCTAssertEqual(WiltedMacModel.sidebarCountPhrase(3, for: .larder), "3 ready")
        XCTAssertEqual(WiltedMacModel.sidebarCountPhrase(5, for: .feeds), "5 to decide")
    }

    func testACountedRowDrawsItsFigure() throws {
        let plain = try rowBitmap(count: nil)
        let counted = try rowBitmap(count: 12)
        XCTAssertNotEqual(plain.tiffRepresentation, counted.tiffRepresentation, "the figure is drawn")
        let attachment = XCTAttachment(data: counted.representation(using: .png, properties: [:]) ?? Data(),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "sidebar-row-counted"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Two ready and one needing prep on the Larder, and one new episode in Feeds.
    private func seededModel() -> WiltedMacModel {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func episode(_ id: String, download: WiltedMacEpisodeDownloadState,
                     preparation: WiltedMacEpisodePreparationState) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600, playbackSeconds: 0, downloadState: download, preparationState: preparation)
        }
        let queued = [
            episode("counts-ready-1", download: .completed, preparation: .prepared(summary: "Ready")),
            episode("counts-ready-2", download: .completed, preparation: .prepared(summary: "Ready")),
            episode("counts-needs-prep", download: .completed, preparation: .notPrepared),
        ]
        for value in queued {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }
        model.installEpisodeForTesting(episode("counts-new", download: .notDownloaded, preparation: .notPrepared))
        return model
    }

    private func rowBitmap(count: Int?) throws -> NSBitmapImageRep {
        try WiltedMacHeadless.render(
            WiltedMacSidebarRow(destination: .larder, count: count, mode: .full, isSelected: true, textScale: .large) {},
            size: CGSize(width: 240, height: 44))
    }
}
