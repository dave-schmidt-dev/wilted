import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// Shared render, record and bitmap comparisons for the Mac pixel cases.
@MainActor
extension WiltedPixelSnapshotTests {
    func render<V: View>(
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

    func assertSnapshot(_ actual: NSImage, named name: String, testName: String, file: StaticString = #filePath, line: UInt = #line) {
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

    enum SnapshotBaselineReplacementAction {
        case replaceExisting
        case keepExisting
    }

    func snapshotBaselineReplacementAction(
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

    func applySnapshotRecordModeUpdate(
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

    func baselineTestURL(for testName: String) throws -> URL {
        let tempDir = wiltedTemporaryDirectory("pixel-baseline-test")
        let snapshotURL = tempDir.appendingPathComponent("\(UUID().uuidString)-\(testName).png")
        return snapshotURL
    }

    func makeSolidBitmap(
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

    func pixelPrecision(expected: NSBitmapImageRep, actual: NSBitmapImageRep) -> Double {
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

    func rgbaPixels(in bitmap: NSBitmapImageRep) -> [UInt8]? {
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

    func baselineBitmap(testName: String, name: String) throws -> NSBitmapImageRep {
        let file = URL(fileURLWithPath: #filePath)
        let baseline = file
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/WiltedPixelSnapshotTests/\(testName).\(name).png")
        return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: baseline)))
    }

    func distinctColorCount(
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

    func maximumGreen(in bitmap: NSBitmapImageRep, region: NSRect) -> CGFloat {
        var maximum: CGFloat = 0
        for y in Int(region.minY)..<min(Int(region.maxY), bitmap.pixelsHigh) {
            for x in Int(region.minX)..<min(Int(region.maxX), bitmap.pixelsWide) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    maximum = max(maximum, color.greenComponent)
                }
            }
        }
        return maximum
    }

}
