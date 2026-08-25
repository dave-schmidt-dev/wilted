import SwiftUI
import XCTest
@testable import WiltedMac

final class WiltedVisualSystemTests: XCTestCase {
    func testPreviewMatrixCoversEveryRequiredState() {
        XCTAssertEqual(WiltedPreviewFixture.matrix.count, WiltedPreviewState.allCases.count)
        XCTAssertEqual(Set(WiltedPreviewFixture.matrix.map(\.id)).count, WiltedPreviewFixture.matrix.count)
        XCTAssertEqual(WiltedVisualVariant.matrix.count, 8)
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.cancelling))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.iCloudUnavailable))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.incompatibleRevision))
    }

    func testStatesHaveStableUserFacingMetadata() {
        for state in WiltedPreviewState.allCases {
            XCTAssertFalse(state.id.isEmpty)
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertFalse(state.symbolName.isEmpty)
            XCTAssertFalse(state.accessibilityStatus.isEmpty)
        }
    }

    func testLightAndDarkLeafPassReadableContrast() {
        XCTAssertEqual(WiltedTheme.lightHex[.wiltedLeaf], 0x4D6B22)
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            let card = WiltedTheme.hex(for: .card, scheme: scheme)
            let leaf = WiltedTheme.hex(for: .wiltedLeaf, scheme: scheme)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, card), 4.5)
        }
    }

    func testPrimaryAndSecondaryTextPassReadableContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            let primary = WiltedTheme.hex(for: .primaryText, scheme: scheme)
            let secondary = WiltedTheme.hex(for: .secondaryText, scheme: scheme)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(primary, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(secondary, page), 4.5)
        }
    }

    /// The producer surfaces put body and status text on `.card`, not just on
    /// `.page`. That pairing shipped untested until the Mac producer screens
    /// adopted the token set, so it is asserted here rather than assumed.
    func testCardTextPairingsPassReadableContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let card = WiltedTheme.hex(for: .card, scheme: scheme)
            for token in [WiltedTheme.ColorToken.primaryText, .secondaryText, .success, .error, .progress] {
                let foreground = WiltedTheme.hex(for: token, scheme: scheme)
                XCTAssertGreaterThanOrEqual(
                    WiltedTheme.contrastRatio(foreground, card), 4.5,
                    "\(token) on card fails readable contrast in \(scheme)"
                )
            }
        }
    }

    func testNativeInteractionContract() {
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

    /// The producer window has no Downloads destination, so its copy must not
    /// send the reader to one. This was shipped: the Mac empty player told the
    /// reader to visit Downloads, and no pixel baseline could catch it because
    /// the Mac baselines always render the player, never the empty state.
    func testProducerCopyNamesOnlyProducerDestinations() {
        let producerDestinations = WiltedNavigation.allCases.filter { $0 != .downloads }
        XCTAssertEqual(producerDestinations.map(\.title), ["Library", "Now Playing", "Settings"])

        XCTAssertFalse(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.downloads),
            "Producer copy must not point at a destination the Mac window does not have."
        )
        XCTAssertTrue(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.library)
        )
        // The listener does have Downloads, so its wording legitimately differs.
        XCTAssertTrue(
            WiltedScreenCopy.nowPlayingEmptyDetailListener.contains(WiltedScreenCopy.downloads)
        )
        XCTAssertFalse(
            WiltedScreenCopy.libraryEmptyDetailProducer.contains(WiltedScreenCopy.downloads)
        )
    }

    /// Emphasis without letting colour carry state alone: every phase still
    /// renders its own name, and only the phases that mean something distinct
    /// get a non-neutral tone.
    func testSyncPhasesCarryTheirOwnToneAndText() {
        let expected: [(WiltedMacSyncPhase, WiltedStatusTone)] = [
            (.disabled, .neutral), (.idle, .neutral), (.cancelled, .neutral),
            (.staging, .active), (.fetching, .active), (.sending, .active),
            (.completed, .positive), (.quarantined, .caution), (.failed, .failure)
        ]
        for (phase, tone) in expected {
            XCTAssertEqual(phase.tone, tone, "wrong tone for \(phase.rawValue)")
            XCTAssertFalse(phase.rawValue.isEmpty)
        }
        XCTAssertEqual(WiltedMacSyncPhase.quarantined.rawValue.capitalized, "Quarantined")
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
}
