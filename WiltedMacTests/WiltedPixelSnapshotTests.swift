import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// Offscreen snapshot contract for the canonical Mac renderer. The fixed
/// canvas and explicit environment keep these baselines independent of the
/// host window and user accessibility settings.
@MainActor
final class WiltedPixelSnapshotTests: XCTestCase {
    private let canvas = CGSize(width: 520, height: 260)

    fileprivate static let visualFixtures = WiltedPreviewFixture.matrix
    fileprivate static let visualVariants = WiltedVisualVariant.matrix

    func testEveryPreviewStateHasLightAndDarkPixelBaselines() {
        for fixture in Self.visualFixtures {
            for variant in Self.visualVariants {
                assertSnapshot(
                    render(WiltedStateCard(fixture: fixture), variant: variant),
                    named: WiltedSnapshotContract.stateName(state: fixture.state, variant: variant),
                    testName: "testEveryPreviewStateHasLightAndDarkPixelBaselines"
                )
            }
        }
    }

    func testPixelSnapshotSelectorsAreUniqueAndComplete() {
        let names = Self.visualFixtures.flatMap { fixture in
            Self.visualVariants.map { variant in
                WiltedSnapshotContract.stateName(state: fixture.state, variant: variant)
            }
        } + WiltedAppearance.allCases.flatMap { appearance in
            [
                WiltedSnapshotContract.shellName(kind: "library", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "player", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "navigation-selection", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "producer-library", appearance: appearance),
                WiltedSnapshotContract.shellName(kind: "producer-url-focus", appearance: appearance)
            ]
        }
        XCTAssertEqual(names.count, WiltedSnapshotContract.expectedPixelBaselineCount)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("state-") || $0.hasPrefix("mac-shell-") })
    }

    func testLibraryAndPreparingBaselinesContainRenderedControls() throws {
        let lightLibrary = try baselineBitmap(
            testName: "testMacLibraryShellPixelBaselines",
            name: "mac-shell-library-light"
        )
        let darkLibrary = try baselineBitmap(
            testName: "testMacLibraryShellPixelBaselines",
            name: "mac-shell-library-dark"
        )
        XCTAssertGreaterThan(distinctColorCount(in: lightLibrary), 1)
        XCTAssertGreaterThan(distinctColorCount(in: darkLibrary), 1)

        let preparing = try baselineBitmap(
            testName: "testEveryPreviewStateHasLightAndDarkPixelBaselines",
            name: "state-preparing-fetching-light-standard-motion-full"
        )
        XCTAssertGreaterThan(distinctColorCount(in: preparing), 1,
                             "Preparing baseline must contain rendered progress content.")
    }

    func testMacLibraryShellPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(WiltedLibraryShell(fixture: WiltedPreviewFixture(state: .emptyLibrary)), variant: variant),
                named: WiltedSnapshotContract.shellName(kind: "library", appearance: appearance),
                testName: "testMacLibraryShellPixelBaselines"
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
                render(WiltedPlayerShell(fixture: WiltedPreviewFixture(state: .playing)), variant: variant),
                named: WiltedSnapshotContract.shellName(kind: "player", appearance: appearance),
                testName: "testMacPlayerShellPixelBaselines"
            )
        }
    }

    func testMacNavigationSelectionPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(
                    WiltedRootView(
                        initialSelection: .downloads,
                        fixture: WiltedPreviewFixture(state: .ready)
                    ),
                    variant: variant
                ),
                named: WiltedSnapshotContract.shellName(kind: "navigation-selection", appearance: appearance),
                testName: "testMacNavigationSelectionPixelBaselines"
            )
        }
    }

    func testShippingMacProducerPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-article-flow", "--wilted-ui-fixture-ready"]
            )
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(WiltedMacRootView(model: model), variant: variant),
                named: WiltedSnapshotContract.shellName(kind: "producer-library", appearance: appearance),
                testName: "testShippingMacProducerPixelBaselines"
            )
        }
    }

    func testShippingMacURLFocusPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(
                    WiltedMacArticleURLField(
                        text: .constant("https://example.com/article"),
                        focusedOverride: true
                    ),
                    variant: variant
                ),
                named: WiltedSnapshotContract.shellName(kind: "producer-url-focus", appearance: appearance),
                testName: "testShippingMacURLFocusPixelBaselines"
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

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: canvas)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width),
            pixelsHigh: Int(canvas.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            // AppKit rejects non-premultiplied alpha for this display-backed
            // cache on current macOS. The default RGBA representation is
            // stable and is what the PNG comparator reads below.
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fatalError("Unable to allocate snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let image = NSImage(size: canvas)
        image.addRepresentation(bitmap)
        return image
    }

    private func assertSnapshot(_ actual: NSImage, named name: String, testName: String, file: StaticString = #filePath, line: UInt = #line) {
        let baseline = URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/WiltedPixelSnapshotTests/\(testName).\(name).png")
        guard let actualData = actual.tiffRepresentation,
              let actualBitmap = NSBitmapImageRep(data: actualData) else {
            XCTFail("Unable to encode rendered snapshot", file: file, line: line)
            return
        }

        if WiltedSnapshotContract.recordMode {
            guard let png = actualBitmap.representation(using: .png, properties: [:]) else {
                XCTFail("Unable to encode rendered snapshot as PNG", file: file, line: line)
                return
            }
            do {
                try png.write(to: baseline)
            } catch {
                XCTFail("Unable to record snapshot: \(error.localizedDescription)", file: file, line: line)
            }
            return
        }

        guard let expectedData = try? Data(contentsOf: baseline),
              let expectedBitmap = NSBitmapImageRep(data: expectedData) else {
            XCTFail("Missing or unreadable snapshot baseline: \(baseline.lastPathComponent)", file: file, line: line)
            return
        }
        guard expectedBitmap.pixelsWide == actualBitmap.pixelsWide,
              expectedBitmap.pixelsHigh == actualBitmap.pixelsHigh else {
            XCTFail("Snapshot dimensions changed for \(baseline.lastPathComponent)", file: file, line: line)
            return
        }

        let precision = pixelPrecision(expected: expectedBitmap, actual: actualBitmap)
        XCTAssertGreaterThanOrEqual(
            precision,
            0.99,
            "Snapshot differs by more than 1% of pixels: \(baseline.lastPathComponent) (precision \(precision))",
            file: file,
            line: line
        )
    }

    private func pixelPrecision(expected: NSBitmapImageRep, actual: NSBitmapImageRep) -> Double {
        guard let expectedPixels = rgbaPixels(in: expected),
              let actualPixels = rgbaPixels(in: actual),
              expectedPixels.count == actualPixels.count else {
            return 0
        }
        let total = expectedPixels.count / 4
        var matching = 0
        for index in stride(from: 0, to: expectedPixels.count, by: 4) {
            let difference = max(
                abs(Int(expectedPixels[index]) - Int(actualPixels[index])),
                abs(Int(expectedPixels[index + 1]) - Int(actualPixels[index + 1])),
                abs(Int(expectedPixels[index + 2]) - Int(actualPixels[index + 2])),
                abs(Int(expectedPixels[index + 3]) - Int(actualPixels[index + 3]))
            )
            if difference <= 3 {
                matching += 1
            }
        }
        return Double(matching) / Double(total)
    }

    private func rgbaPixels(in bitmap: NSBitmapImageRep) -> [UInt8]? {
        guard let image = bitmap.cgImage else { return nil }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }

    private func baselineBitmap(testName: String, name: String) throws -> NSBitmapImageRep {
        let file = URL(fileURLWithPath: #filePath)
        let baseline = file
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/WiltedPixelSnapshotTests/\(testName).\(name).png")
        return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: baseline)))
    }

    private func distinctColorCount(in bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                colors.insert((red << 16) | (green << 8) | blue)
            }
        }
        return colors.count
    }

}

enum WiltedSnapshotContract {
    static let stateCount = WiltedPreviewState.allCases.count
    static let variantCount = WiltedVisualVariant.matrix.count
    static let shellCount = 10
    static let expectedPixelBaselineCount = stateCount * variantCount + shellCount

    static var recordMode: Bool {
        ProcessInfo.processInfo.environment["WILTED_RECORD_SNAPSHOTS"] == "1"
    }

    static func stateName(state: WiltedPreviewState, variant: WiltedVisualVariant) -> String {
        "state-\(state.id)-\(variant.id)"
    }

    static func shellName(kind: String, appearance: WiltedAppearance) -> String {
        "mac-shell-\(kind)-\(appearance.rawValue)"
    }
}
