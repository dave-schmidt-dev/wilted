import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// Spoken-interruption surfaces: the player's bulletin banner and a morning report's Larder row.
extension WiltedPixelSnapshotTests {
    private func interruptionVariant(_ appearance: WiltedAppearance) -> WiltedVisualVariant {
        .init(appearance: appearance, dynamicType: .standard, reduceMotion: false)
    }

    /// The banner for a weather alert and for a headline, one above the other.
    func testBulletinBannerPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let content = VStack(spacing: WiltedTheme.Spacing.small) {
                WiltedMacBulletinBanner(
                    text: "Severe Thunderstorm Warning issued October 10 at 3:00PM CDT until 4:00PM CDT by NWS Topeka KS",
                    isAlert: true, onSkip: {})
                WiltedMacBulletinBanner(text: "Wire. City council approves the new transit plan.", isAlert: false, onSkip: {})
            }
            .padding(WiltedTheme.Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WiltedTheme.color(.card, scheme: appearance == .dark ? .dark : .light))
            let image = render(content, variant: interruptionVariant(appearance), size: CGSize(width: 760, height: 150))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the banner drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "player-bulletin-banner", appearance: appearance),
                testName: "testBulletinBannerPixelBaselines")
        }
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacBulletinBanner(text: "Wire. City council approves the new transit plan.", isAlert: false, onSkip: {}),
            size: CGSize(width: 760, height: 80)).joined(separator: " ")
        XCTAssertTrue(shown.contains("City council"), shown)
    }

    private func fixtureReport() -> WiltedMacEpisode {
        var report = WiltedMacEpisode(
            id: "report-2026-10-10", title: "Morning report, Saturday October 10", feedTitle: "Morning report",
            summary: "Weather and headlines", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_900), durationSeconds: 6 * 60,
            playbackSeconds: 0, downloadState: .completed, preparationState: .prepared(summary: "Report"))
        report.audiobook = WiltedMacAudiobookDetails(
            author: nil, chapters: [], sourceFormat: "report", volumeIndex: 0, volumeCount: 1)
        return report
    }

    /// A morning report's row: its own tile, and "Morning report" with the length instead of author and chapters.
    func testLarderReportRowPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("larder-report-row"),
                preferences: WiltedMacTestPreferences.ephemeral())
            let report = fixtureReport()
            model.installEpisodeForTesting(report)
            model.podcastQueueIDs.append(report.id)
            let content = WiltedMacLarderView(model: model, paneMode: .side)
                .larderRow(report, position: 1, count: 1, showsGroupName: false)
                .padding(WiltedTheme.Spacing.large)
                .environment(\.wiltedTextScale, model.textScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WiltedTheme.color(.card, scheme: appearance == .dark ? .dark : .light))
            let image = render(content, variant: interruptionVariant(appearance), size: CGSize(width: 760, height: 110))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the report row drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "larder-report-row", appearance: appearance),
                testName: "testLarderReportRowPixelBaselines")
        }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("larder-report-row-text"),
            preferences: WiltedMacTestPreferences.ephemeral())
        let report = fixtureReport()
        model.installEpisodeForTesting(report)
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacLarderView(model: model, paneMode: .side).larderRow(report, position: 1, count: 1, showsGroupName: false),
            size: CGSize(width: 760, height: 110)).joined(separator: " ")
        XCTAssertTrue(shown.contains("Morning report"), shown)
        XCTAssertFalse(shown.contains("chapter"), shown)
    }
}
