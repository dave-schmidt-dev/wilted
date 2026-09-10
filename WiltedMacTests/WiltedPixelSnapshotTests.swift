import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// Offscreen snapshot contract for the canonical Mac renderer. The fixed
/// canvas and explicit environment keep these baselines independent of the
/// host window and user accessibility settings.
@MainActor
final class WiltedPixelSnapshotTests: XCTestCase {
    /// Single surfaces and state cards render at card scale.
    private let canvas = CGSize(width: 520, height: 260)
    /// Whole-window compositions render at window scale.
    ///
    /// The split-view shells were previously captured on the 520x260 card
    /// canvas, where the sidebar collapses and renders as a blank rectangle —
    /// so the pixel suite never actually saw the navigation it was meant to
    /// verify, and a composition whose sidebar did nothing cleared the gate.
    private let windowCanvas = CGSize(width: 1100, height: 700)

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

    /// Window baselines are captured at window scale and their detail region
    /// is genuinely rendered.
    ///
    /// **These baselines do not cover the sidebar, and cannot.** A
    /// `NavigationSplitView`'s navigation column is hosted in a separate
    /// AppKit split-view hierarchy that `NSHostingView.cacheDisplay` does not
    /// draw, so it records as a flat rectangle at any canvas size. That is
    /// precisely why a composition whose sidebar selection did nothing cleared
    /// this suite and was only caught in attended acceptance.
    ///
    /// Sidebar behavior is therefore owned by the Mac XCUITest suite, which
    /// drives the real app: `testEachDestinationExclusivelyOccupiesTheDetailRegion`
    /// and `testSidebarListsDestinationsOnlyAndNotTheArticleList`. This test
    /// asserts only what the pixel path can honestly see, and pins the
    /// detail-region origin so a future change cannot quietly shrink these
    /// back to the card canvas where even the detail region was cropped.
    func testWindowBaselinesCaptureTheDetailRegionAtWindowScale() throws {
        for appearance in ["light", "dark"] {
            let bitmap = try baselineBitmap(
                testName: "testMacPlayerShellPixelBaselines",
                name: "mac-shell-player-\(appearance)"
            )
            XCTAssertEqual(bitmap.pixelsWide, Int(canvas.width))
            XCTAssertEqual(bitmap.pixelsHigh, Int(canvas.height))
        }

        for appearance in ["light", "dark"] {
            for shell in ["producer-library", "navigation-selection"] {
                let testName = shell == "producer-library"
                    ? "testShippingMacProducerPixelBaselines"
                    : "testMacNavigationSelectionPixelBaselines"
                let bitmap = try baselineBitmap(testName: testName, name: "mac-shell-\(shell)-\(appearance)")

                XCTAssertEqual(bitmap.pixelsWide, Int(windowCanvas.width),
                               "\(shell)-\(appearance) must be captured at window scale")
                XCTAssertEqual(bitmap.pixelsHigh, Int(windowCanvas.height),
                               "\(shell)-\(appearance) must be captured at window scale")

                // Sample past the sidebar column into the detail region.
                let detail = NSRect(
                    x: 260, y: 0,
                    width: bitmap.pixelsWide - 260,
                    height: bitmap.pixelsHigh
                )
                XCTAssertGreaterThan(
                    distinctColorCount(in: bitmap, region: detail), 8,
                    "\(shell)-\(appearance) detail region is blank; the destination did not render."
                )
            }
        }
    }

    /// Settings is scrollable at window scale, so this focused render check
    /// guards against the automation card collapsing the destination to a
    /// blank surface without requiring a new unreviewed pixel baseline.
    func testSettingsAutomationSurfaceRendersAtWindowScale() throws {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"],
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            model.selectedNavigation = .settings
            let image = render(WiltedMacRootView(model: model), variant: variant, size: windowCanvas)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let detail = NSRect(x: 260, y: 0, width: bitmap.pixelsWide - 260, height: bitmap.pixelsHigh)
            XCTAssertGreaterThan(
                distinctColorCount(in: bitmap, region: detail), 8,
                "Settings automation surface is blank in \(appearance.rawValue) mode."
            )
        }
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
            let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], preferences: WiltedMacTestPreferences.ephemeral())
            if let article = model.articles.first { model.openNowPlaying(for: article) }
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(WiltedMacCompactPlayer(model: model), variant: variant),
                named: WiltedSnapshotContract.shellName(kind: "player", appearance: appearance),
                testName: "testMacPlayerShellPixelBaselines"
            )
        }
    }

    /// The selected pane is rendered as a detail-sized surface, not a taller
    /// version of the old rail. A colour check is deliberate here: there is no
    /// new bitmap baseline until the attended visual review records one.
    func testMacFullWindowPlayerRendersAtDetailHeight() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        if let article = model.articles.first { model.openNowPlaying(for: article) }
        let image = render(
            WiltedMacFullWindowPlayer(
                model: model,
                presentation: .transcript,
                onSelect: { _ in },
                onCollapse: { _ in }
            ),
            variant: WiltedVisualVariant(appearance: .dark, dynamicType: .standard, reduceMotion: false),
            size: windowCanvas
        )
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(bitmap.pixelsHigh, Int(windowCanvas.height))
        XCTAssertGreaterThan(
            distinctColorCount(
                in: bitmap,
                region: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            ),
            8
        )
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
                    // Settings, not Downloads: Downloads is listener-only and
                    // is no longer offered as a Mac destination.
                    WiltedRootView(
                        initialSelection: .settings,
                        fixture: WiltedPreviewFixture(state: .ready)
                    ),
                    variant: variant,
                    size: windowCanvas
                ),
                named: WiltedSnapshotContract.shellName(kind: "navigation-selection", appearance: appearance),
                testName: "testMacNavigationSelectionPixelBaselines"
            )
        }
    }

    func testShippingMacProducerPixelBaselines() {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: [
                    "--wilted-ui-fixture-article-flow",
                    "--wilted-ui-fixture-podcasts",
                    "--wilted-ui-fixture-ready"
                ], preferences: WiltedMacTestPreferences.ephemeral()
            )
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            assertSnapshot(
                render(WiltedMacRootView(model: model), variant: variant, size: windowCanvas),
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
                    WiltedMacLinkField(
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

    func testSnapshotBaselinePreservesExistingBytesWhenMatchingInRecordMode() throws {
        let baseline = try baselineTestURL(for: "matching-baseline")
        let existingBitmap = makeSolidBitmap(width: 4, height: 2, red: 17, green: 34, blue: 51, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 4, height: 2, red: 17, green: 34, blue: 51, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: false
        )

        XCTAssertFalse(mutation)
        XCTAssertEqual(try Data(contentsOf: baseline), existingBytes)
    }

    func testSnapshotBaselineReplacesWhenBaselineIsMissingOrUnreadableOrDifferentInRecordMode() throws {
        let missingBaseline = try baselineTestURL(for: "missing-baseline")
        let replacement = makeSolidBitmap(width: 3, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let replacementBytes = try XCTUnwrap(replacement.representation(using: .png, properties: [:]))
        let missing = try applySnapshotRecordModeUpdate(
            baseline: missingBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingBaseline.path))

        let unreadableBaseline = try baselineTestURL(for: "unreadable-baseline")
        try Data("not-an-image".utf8).write(to: unreadableBaseline, options: .atomic)
        let unreadable = try applySnapshotRecordModeUpdate(
            baseline: unreadableBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(unreadable)

        let dimensionMismatchBaseline = try baselineTestURL(for: "dimension-mismatch-baseline")
        let smallBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let smallBytes = try XCTUnwrap(smallBitmap.representation(using: .png, properties: [:]))
        try smallBytes.write(to: dimensionMismatchBaseline, options: .atomic)
        let dimensionMismatch = try applySnapshotRecordModeUpdate(
            baseline: dimensionMismatchBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(dimensionMismatch)

        let materialMismatchBaseline = try baselineTestURL(for: "material-mismatch-baseline")
        let oldBitmap = makeSolidBitmap(width: 3, height: 2, red: 1, green: 2, blue: 3, alpha: 255)
        let oldBytes = try XCTUnwrap(oldBitmap.representation(using: .png, properties: [:]))
        try oldBytes.write(to: materialMismatchBaseline, options: .atomic)
        let materialMismatch = try applySnapshotRecordModeUpdate(
            baseline: materialMismatchBaseline,
            actual: replacement,
            actualPNG: replacementBytes,
            forceRecord: false
        )
        XCTAssertTrue(materialMismatch)
    }

    func testSnapshotBaselineReplacesWhenForceRecordEnabled() throws {
        let baseline = try baselineTestURL(for: "force-record-baseline")
        let existingBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 2, height: 2, red: 13, green: 26, blue: 39, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: true
        )
        XCTAssertTrue(mutation)
        XCTAssertNotEqual(try Data(contentsOf: baseline), existingBytes)
    }

    func testForceRecordHasNoEffectWhenRecordModeIsDisabled() throws {
        let baseline = try baselineTestURL(for: "force-without-record")
        let existingBitmap = makeSolidBitmap(width: 2, height: 2, red: 12, green: 25, blue: 38, alpha: 255)
        let existingBytes = try XCTUnwrap(existingBitmap.representation(using: .png, properties: [:]))
        try existingBytes.write(to: baseline, options: .atomic)

        let actualBitmap = makeSolidBitmap(width: 2, height: 2, red: 13, green: 26, blue: 39, alpha: 255)
        let actualBytes = try XCTUnwrap(actualBitmap.representation(using: .png, properties: [:]))
        let mutation = try applySnapshotRecordModeUpdate(
            baseline: baseline,
            actual: actualBitmap,
            actualPNG: actualBytes,
            forceRecord: true,
            recordMode: false
        )
        XCTAssertFalse(mutation)
        XCTAssertEqual(try Data(contentsOf: baseline), existingBytes)
    }

    private func render<V: View>(
        _ view: V,
        variant: WiltedVisualVariant,
        size: CGSize? = nil
    ) -> NSImage {
        let canvas = size ?? self.canvas
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

        guard let png = actualBitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Unable to encode rendered snapshot as PNG", file: file, line: line)
            return
        }

        if WiltedSnapshotContract.recordMode {
            let replacementAction = snapshotBaselineReplacementAction(
                baseline: baseline,
                actualBitmap: actualBitmap,
                forceRecord: WiltedSnapshotContract.forceRecordMode,
                recordMode: true
            )
            if replacementAction == .replaceExisting {
                do {
                    try png.write(to: baseline, options: .atomic)
                } catch {
                    XCTFail("Unable to record snapshot: \(error.localizedDescription)", file: file, line: line)
                }
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

    private enum SnapshotBaselineReplacementAction {
        case replaceExisting
        case keepExisting
    }

    private func snapshotBaselineReplacementAction(
        baseline: URL,
        actualBitmap: NSBitmapImageRep,
        forceRecord: Bool,
        recordMode: Bool = WiltedSnapshotContract.recordMode
    ) -> SnapshotBaselineReplacementAction {
        guard recordMode else { return .keepExisting }
        if forceRecord {
            return .replaceExisting
        }
        guard let expectedData = try? Data(contentsOf: baseline),
              let expectedBitmap = NSBitmapImageRep(data: expectedData),
              expectedBitmap.pixelsWide == actualBitmap.pixelsWide,
              expectedBitmap.pixelsHigh == actualBitmap.pixelsHigh,
              pixelPrecision(expected: expectedBitmap, actual: actualBitmap) >= 0.99 else {
            return .replaceExisting
        }
        return .keepExisting
    }

    private func applySnapshotRecordModeUpdate(
        baseline: URL,
        actual: NSBitmapImageRep,
        actualPNG: Data,
        forceRecord: Bool,
        recordMode: Bool = true
    ) throws -> Bool {
        if snapshotBaselineReplacementAction(
            baseline: baseline,
            actualBitmap: actual,
            forceRecord: forceRecord,
            recordMode: recordMode
        ) == .replaceExisting {
            try actualPNG.write(to: baseline, options: .atomic)
            return true
        }
        return false
    }

    private func baselineTestURL(for testName: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiltedPixelSnapshotTests", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        let snapshotURL = tempDir.appendingPathComponent("\(UUID().uuidString)-\(testName).png")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        return snapshotURL
    }

    private func makeSolidBitmap(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8
    ) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        guard let bitmapData = bitmap.bitmapData else { return bitmap }
        let rowLength = width * 4
        for y in 0..<height {
            for x in 0..<width {
                let index = y * rowLength + x * 4
                bitmapData[index] = red
                bitmapData[index + 1] = green
                bitmapData[index + 2] = blue
                bitmapData[index + 3] = alpha
            }
        }
        return bitmap
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

    private func distinctColorCount(
        in bitmap: NSBitmapImageRep,
        region: NSRect? = nil
    ) -> Int {
        let bounds = region ?? NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        var colors = Set<UInt32>()
        for y in Int(bounds.minY)..<min(Int(bounds.maxY), bitmap.pixelsHigh) {
            for x in Int(bounds.minX)..<min(Int(bounds.maxX), bitmap.pixelsWide) {
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

    static var forceRecordMode: Bool {
        ProcessInfo.processInfo.environment["WILTED_FORCE_RECORD_SNAPSHOTS"] == "1"
    }

    static func stateName(state: WiltedPreviewState, variant: WiltedVisualVariant) -> String {
        "state-\(state.id)-\(variant.id)"
    }

    static func shellName(kind: String, appearance: WiltedAppearance) -> String {
        "mac-shell-\(kind)-\(appearance.rawValue)"
    }
}
