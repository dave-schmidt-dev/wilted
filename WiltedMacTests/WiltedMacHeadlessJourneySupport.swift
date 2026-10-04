import AppKit
import SwiftUI
import Vision
import XCTest
@testable import WiltedMac

/// Shared pieces of the headless journeys that replaced the Mac XCUITest launches: a model built from
/// the same `--wilted-ui-fixture-*` arguments, a polling wait, offscreen rendering, and view source.
@MainActor
enum WiltedMacHeadless {
    static let windowCanvas = CGSize(width: 1100, height: 700)

    /// A model on a fresh state directory, started the way the fixture launch starts it. A podcast
    /// fixture saves its rows in the background, so this waits for that before a test acts on them.
    static func model(
        _ test: XCTestCase, _ arguments: [String], suffix: String = "headless-journey"
    ) async -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: arguments, stateDirectoryOverride: test.wiltedTemporaryDirectory(suffix),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        await model.waitForFixturePodcastInstallForTesting()
        return model
    }

    /// Polls `condition` until it holds; fails the test with `what` after `timeout`.
    @discardableResult
    static func eventually(
        _ what: String, timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if condition() { return true }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
        return false
    }

    /// Settles every in-flight Keep / Skip / Restore writer.
    static func drainDecisions(_ model: WiltedMacModel) async {
        for writer in Array(model.subscriptionWriteTasks.values) { await writer.value }
    }

    /// The Mac app's source root, from this file's location.
    static func sourceRoot(_ file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func viewSource(_ name: String, file: String = #filePath) throws -> String {
        try String(
            contentsOf: sourceRoot(file).appendingPathComponent("WiltedMac/Views/\(name)"), encoding: .utf8)
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Renders `view` offscreen in light mode and returns its bitmap.
    static func render<V: View>(_ view: V, size: CGSize = windowCanvas) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(
            rootView: view.environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    static func distinctColorCount(in bitmap: NSBitmapImageRep, region: NSRect? = nil) -> Int {
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
    /// The text a hosted view draws, read back from its rendered pixels with Vision, one string per
    /// recognized line. SwiftUI vends no accessibility tree to a view that no assistive technology is
    /// attached to, so a headless test cannot read identifiers; what it can read is what a person sees.
    static func recognizedText<V: View>(_ view: V, size: CGSize = windowCanvas) throws -> [String] {
        try recognizedLines(view, size: size).map(\.text)
    }

    /// The same lines with their vertical position, top of the view first.
    static func recognizedLines<V: View>(
        _ view: V, size: CGSize = windowCanvas
    ) throws -> [(text: String, top: CGFloat)] {
        let scale = 2
        // Vision misses text that touches the image edge, so the view sits inside a margin.
        let hostingView = NSHostingView(
            rootView: view.environment(\.colorScheme, .light).padding(24)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // The default skips text shorter than 1/32 of the image, which drops body copy in a tall render.
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, 1 - observation.boundingBox.maxY) }
        }.sorted { $0.1 < $1.1 }
    }
}
