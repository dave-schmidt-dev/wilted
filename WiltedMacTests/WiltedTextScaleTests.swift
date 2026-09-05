import Foundation
import SwiftUI
import XCTest
@testable import WiltedMac

/// The Mac draws its own text size. macOS has no Dynamic Type to inherit --
/// the pixel gate renders every state at `.medium` and at `.xxxLarge` and the
/// two are byte-identical -- so the scale is the app's to carry, and these
/// cover the three ways it could be dropped: a role that does not grow, a
/// measurement that does not keep pace with the words, and a call site that
/// sets a font without going through the modifier that knows the scale.
@MainActor
final class WiltedTextScaleTests: XCTestCase {
    // MARK: - The scale itself

    func testTheStepsGetLargerAndStandardIsThePlatformsOwnSize() {
        let steps = WiltedTheme.TextScale.allCases
        XCTAssertEqual(steps.first, .standard)
        XCTAssertEqual(WiltedTheme.TextScale.standard.multiplier, 1.0)
        for (smaller, larger) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThan(smaller.multiplier, larger.multiplier,
                              "\(larger.rawValue) must draw larger than \(smaller.rawValue)")
        }
    }

    /// `standard` has to return the semantic text styles unchanged, not a
    /// point size that happens to match today. It is the reference the other
    /// steps are measured from, and a platform that moves its own metrics
    /// should carry it rather than leave it frozen at a number written here.
    func testStandardReturnsExactlyWhatTheAppDrewBeforeThereWasAChoice() {
        for role in WiltedTheme.TypographyRole.allCases {
            XCTAssertEqual(WiltedTheme.font(role), WiltedTheme.font(role, scale: .standard),
                           "\(role.rawValue) at standard must be the untouched font")
        }
    }

    func testEveryRoleGrowsWithTheScaleRatherThanOnlyTheLiteralOnes() {
        for role in WiltedTheme.TypographyRole.allCases {
            let base = WiltedTheme.baseSize(role)
            XCTAssertGreaterThan(base, 0, "\(role.rawValue) has no measurable size")
            var previous = WiltedTheme.scaled(base, scale: .standard)
            for scale in [WiltedTheme.TextScale.large, .larger, .largest] {
                let size = WiltedTheme.scaled(base, scale: scale)
                XCTAssertGreaterThan(size, previous,
                                     "\(role.rawValue) did not grow at \(scale.rawValue)")
                previous = size
            }
        }
    }

    /// A half-pixel frame blurs the edge it draws, so measurements round.
    func testAMeasurementCarriesUpWholeAndStandardLeavesItAlone() {
        XCTAssertEqual(WiltedTheme.scaled(56, scale: .standard), 56)
        XCTAssertEqual(WiltedTheme.scaled(56, scale: .large), 67)
        XCTAssertEqual(WiltedTheme.scaled(44, scale: .large), 53)
        XCTAssertEqual(WiltedTheme.scaled(28, scale: .large), 34)
        for base in [CGFloat(28), 44, 56] {
            for scale in WiltedTheme.TextScale.allCases {
                let side = WiltedTheme.scaled(base, scale: scale)
                XCTAssertEqual(side, side.rounded(), "\(base) at \(scale.rawValue) is not whole")
            }
        }
    }

    // MARK: - What the reader's choice survives

    func testAnAbsentOrUnreadableChoiceTakesTheDefaultRatherThanTheSmallestStep() {
        let suite = "com.zerodelta.wilted.mac.textscale-tests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to open a preferences suite for the test")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(WiltedMacModel.loadTextScale(from: defaults), .large,
                       "a library that has never been asked takes the default")

        // A step named by a later version this one cannot read must not
        // silently shrink the window back to the system's own size.
        defaults.set("enormous", forKey: WiltedMacModel.textScalePreferenceKey)
        XCTAssertEqual(WiltedMacModel.loadTextScale(from: defaults), .large)

        for scale in WiltedTheme.TextScale.allCases {
            defaults.set(scale.rawValue, forKey: WiltedMacModel.textScalePreferenceKey)
            XCTAssertEqual(WiltedMacModel.loadTextScale(from: defaults), scale)
        }
    }

    // MARK: - The one place the scale can be missed

    /// A site that writes `.font(WiltedTheme.font(role))` renders at the
    /// platform's size whatever the reader chose, and nothing about it looks
    /// wrong in review -- it is the same call the whole app used to make. The
    /// scale can only be honoured through `wiltedFont`, so the absence of the
    /// direct call is the invariant, asserted over the source rather than over
    /// a rendering that would only catch the states a baseline happens to draw.
    func testNoSurfaceSetsAThemeFontWithoutGoingThroughTheScale() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let searched = ["Shared", "WiltedMac", "WiltediOS"]
        var offenders: [String] = []
        var scanned = 0

        for directory in searched {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(atPath: base.path) else {
                return XCTFail("Unable to read \(directory)")
            }
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                // The theme is where the fonts are built; it is the exception.
                guard !relative.hasSuffix("WiltedTheme.swift") else { continue }
                let source = try String(contentsOf: base.appendingPathComponent(relative), encoding: .utf8)
                scanned += 1
                for (offset, line) in source.components(separatedBy: .newlines).enumerated()
                where line.contains(".font(WiltedTheme.font(") {
                    offenders.append("\(directory)/\(relative):\(offset + 1)")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 5, "the walk found almost nothing, so it proves nothing")
        XCTAssertEqual(offenders, [], "these set a theme font directly; use .wiltedFont(role)")
    }

    /// The root is where the choice enters the window. Without it every
    /// `wiltedFont` reads the default and the setting does nothing.
    func testTheMacRootHandsTheChosenScaleToItsSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".environment(\\.wiltedTextScale, model.textScale)"),
                      "the Mac root must publish the chosen scale")
    }
}
