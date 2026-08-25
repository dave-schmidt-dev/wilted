import SwiftUI
import XCTest
@testable import WiltediOS

final class WiltedVisualSystemTests: XCTestCase {
    func testPreviewMatrixCoversEveryRequiredState() {
        XCTAssertEqual(WiltedPreviewFixture.matrix.count, WiltedPreviewState.allCases.count)
        XCTAssertEqual(Set(WiltedPreviewFixture.matrix.map(\.id)).count, WiltedPreviewFixture.matrix.count)
        XCTAssertEqual(WiltedVisualVariant.matrix.count, 8)
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.preparing(.synthesizing)))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.offlineCached))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.deletedRemotely))
    }

    func testStatesHaveStableAccessibilityMetadata() {
        for state in WiltedPreviewState.allCases {
            XCTAssertFalse(state.id.isEmpty)
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertFalse(state.symbolName.isEmpty)
            XCTAssertTrue(state.accessibilityStatus.contains(state.title))
        }
    }

    func testLightAndDarkPaletteContrast() {
        XCTAssertEqual(WiltedTheme.lightHex[.wiltedLeaf], 0x4D6B22)
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            let card = WiltedTheme.hex(for: .card, scheme: scheme)
            let leaf = WiltedTheme.hex(for: .wiltedLeaf, scheme: scheme)
            let primary = WiltedTheme.hex(for: .primaryText, scheme: scheme)
            let secondary = WiltedTheme.hex(for: .secondaryText, scheme: scheme)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, card), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(primary, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(secondary, page), 4.5)
        }
    }

    func testLiteralNavigationAndTouchTargetContract() {
        XCTAssertEqual(WiltedNavigation.allCases.map(\.title), ["Library", "Now Playing", "Downloads", "Settings"])
        XCTAssertEqual(WiltedScreenCopy.libraryEmpty, "Your library is empty")
        XCTAssertEqual(WiltedScreenCopy.noArticles, "No articles yet")
        XCTAssertEqual(WiltedScreenCopy.addArticle, "Add Article")
        XCTAssertEqual(WiltedScreenCopy.addArticleIdentifier, "wilted-add-article")
        XCTAssertEqual(WiltedScreenCopy.stateActionIdentifier, "wilted-state-action")
        XCTAssertEqual(WiltedScreenCopy.libraryIdentifier, "wilted-library")
        XCTAssertEqual(
            WiltedPreviewState.emptyLibrary.accessibilityIdentifier,
            "wilted-state-emptyLibrary"
        )
        XCTAssertEqual(WiltedScreenCopy.downloads, "Downloads")
        XCTAssertEqual(WiltedScreenCopy.noDownloads, "No Downloads")
        XCTAssertEqual(WiltedScreenCopy.downloadsEmptyIdentifier, "wilted-no-downloads")
        XCTAssertEqual(WiltedScreenCopy.nowPlaying, "Now Playing")
        XCTAssertEqual(WiltedScreenCopy.nowPlayingEmptyIdentifier, "wilted-player-empty")
        XCTAssertEqual(WiltedScreenCopy.downloadsIdentifier, "wilted-downloads")
        XCTAssertEqual(WiltedScreenCopy.settings, "Settings")
        XCTAssertEqual(WiltedScreenCopy.settingsIdentifier, "wilted-settings")
        XCTAssertEqual(WiltedScreenCopy.audio, "Audio")
        XCTAssertEqual(WiltedScreenCopy.audioRowIdentifier, "wilted-audio-setting")
        XCTAssertFalse(WiltedScreenCopy.audioValue.isEmpty)
        XCTAssertEqual(WiltedTheme.Spacing.minimumTouchTarget, 44)
        XCTAssertEqual(WiltedMark.geometrySignature, "single-stroke-w:balanced-d6:v2")
        XCTAssertEqual(
            WiltedVisualVariant.matrix.map(\.id),
            [
                "light-standard-motion-full", "light-standard-motion-reduced",
                "light-xxxLarge-motion-full", "light-xxxLarge-motion-reduced",
                "dark-standard-motion-full", "dark-standard-motion-reduced",
                "dark-xxxLarge-motion-full", "dark-xxxLarge-motion-reduced"
            ]
        )
    }

    func testDeterministicRenderArtifactDoesNotDrift() {
        let variant = WiltedVisualVariant(
            appearance: .light,
            dynamicType: .xxxLarge,
            reduceMotion: true
        )
        XCTAssertEqual(
            WiltedPreviewState.emptyLibrary.renderSignature(variant: variant),
            "1d1e7e2ce1d523c3"
        )
        let signatures = Set(
            WiltedPreviewState.allCases.flatMap { state in
                WiltedVisualVariant.matrix.map { state.renderSignature(variant: $0) }
            }
        )
        XCTAssertEqual(signatures.count, WiltedPreviewState.allCases.count * WiltedVisualVariant.matrix.count)
    }

    /// The reported defect: a 29-minute article read "1743 seconds" on both
    /// platforms. These lock the format, not just the fix.
    func testDurationsReadAsClockTimeRatherThanRawSeconds() {
        XCTAssertEqual(WiltedDuration.clock(1743), "29:03")
        XCTAssertEqual(WiltedDuration.clock(120), "2:00")
        XCTAssertEqual(WiltedDuration.clock(0), "0:00")
        XCTAssertEqual(WiltedDuration.clock(9), "0:09")
        XCTAssertEqual(WiltedDuration.clock(3600), "1:00:00")
        XCTAssertEqual(WiltedDuration.clock(3661), "1:01:01")
        // Nothing may print a negative or non-finite clock.
        XCTAssertEqual(WiltedDuration.clock(-90), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.infinity), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.nan), "0:00")
        XCTAssertEqual(WiltedDuration.progress(position: 31, duration: 1743), "0:31 of 29:03")
    }

    /// VoiceOver cannot infer units from a colon, so the spoken form must carry
    /// the words. Reading "twenty-nine oh three" is the same defect as printing
    /// "1743".
    func testSpokenDurationsCarryUnitsRatherThanColons() {
        for value in [WiltedDuration.spoken(1743), WiltedDuration.spokenProgress(position: 31, duration: 1743)] {
            XCTAssertFalse(value.contains(":"), "spoken duration must not rely on a colon: \(value)")
            XCTAssertTrue(value.lowercased().contains("minute"), "spoken duration must name its units: \(value)")
        }
    }
}
