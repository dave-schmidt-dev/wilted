import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
@testable import WiltedMac

/// Offscreen snapshot contract for the canonical Mac renderer. The fixed
/// canvas and explicit environment keep these baselines independent of the
/// host window and user accessibility settings.
@MainActor
final class WiltedPixelSnapshotTests: XCTestCase {
    private let canvas = CGSize(width: 520, height: 260)

    func testEveryPreviewStateHasLightAndDarkPixelBaselines() {
        for fixture in WiltedPreviewFixture.matrix {
            for variant in WiltedVisualVariant.matrix {
                assertSnapshot(
                    of: render(WiltedStateCard(fixture: fixture), variant: variant),
                    as: .image(precision: 0.99, perceptualPrecision: 0.99),
                    named: WiltedSnapshotContract.stateName(state: fixture.state, variant: variant),
                    record: WiltedSnapshotContract.recordMode
                )
            }
        }
    }

    func testPixelSnapshotSelectorsAreUniqueAndComplete() {
        let names = WiltedPreviewFixture.matrix.flatMap { fixture in
            WiltedVisualVariant.matrix.map { variant in
                WiltedSnapshotContract.stateName(state: fixture.state, variant: variant)
            }
        } + WiltedAppearance.allCases.flatMap { appearance in
            [
                WiltedSnapshotContract.shellName(kind: "library", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "player", appearance: appearance)
            ]
        }
        XCTAssertEqual(names.count, WiltedSnapshotContract.expectedPixelBaselineCount)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("state-") || $0.hasPrefix("mac-shell-") })
    }

    func testMacLibraryShellPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                of: render(WiltedLibraryShell(fixture: WiltedPreviewFixture(state: .emptyLibrary)), variant: variant),
                as: .image(precision: 0.99, perceptualPrecision: 0.99),
                named: WiltedSnapshotContract.shellName(kind: "library", appearance: appearance),
                record: WiltedSnapshotContract.recordMode
            )
        }
    }

    func testMacPlayerShellPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                of: render(WiltedPlayerShell(fixture: WiltedPreviewFixture(state: .playing)), variant: variant),
                as: .image(precision: 0.99, perceptualPrecision: 0.99),
                named: WiltedSnapshotContract.shellName(kind: "player", appearance: appearance),
                record: WiltedSnapshotContract.recordMode
            )
        }
    }

    private func render<V: View>(_ view: V, variant: WiltedVisualVariant) -> NSImage {
        let content = view
            .environment(\.colorScheme, variant.appearance == .dark ? .dark : .light)
            .environment(
                \.dynamicTypeSize,
                variant.dynamicType == .xxxLarge ? .xxxLarge : .medium
            )
            .transaction { transaction in
                if variant.reduceMotion {
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
            }
            .frame(width: canvas.width, height: canvas.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.nsImage else {
            XCTFail("ImageRenderer did not produce an NSImage")
            return NSImage(size: canvas)
        }
        return image
    }
}

enum WiltedSnapshotContract {
    static let stateCount = WiltedPreviewState.allCases.count
    static let variantCount = WiltedVisualVariant.matrix.count
    static let shellCount = 4
    static let expectedPixelBaselineCount = stateCount * variantCount + shellCount

    static var recordMode: SnapshotTestingConfiguration.Record? {
        ProcessInfo.processInfo.environment["WILTED_RECORD_SNAPSHOTS"] == "1" ? .all : nil
    }

    static func stateName(state: WiltedPreviewState, variant: WiltedVisualVariant) -> String {
        "state-\(state.id)-\(variant.id)"
    }

    static func shellName(kind: String, appearance: WiltedAppearance) -> String {
        "mac-shell-\(kind)-\(appearance.rawValue)"
    }
}
