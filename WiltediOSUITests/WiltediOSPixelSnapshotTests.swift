import UIKit
import XCTest

/// Pixel coverage for the production `LibraryRoot`. Captures normalize simulator density while keeping the rendered
/// screen geometry deterministic across the supported iPhone simulators.
@MainActor
final class WiltediOSPixelSnapshotTests: XCTestCase {
    private let canvas = CGSize(width: 390, height: 844)

    // IOS-CLEAR-001, CI-4

    func testLibraryLarderLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.larder, dark: false), named: "library-larder-light")
    }

    func testLibraryLarderDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.larder, dark: true), named: "library-larder-dark")
    }

    func testLibraryLarderGroupedLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.larderGrouped, dark: false), named: "library-larder-grouped-light")
    }

    func testLibraryLarderGroupedDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.larderGrouped, dark: true), named: "library-larder-grouped-dark")
    }

    func testLibraryEpisodeDetailLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.episodeDetail, dark: false), named: "library-episode-detail-light")
    }

    func testLibraryEpisodeDetailDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.episodeDetail, dark: true), named: "library-episode-detail-dark")
    }

    func testLibrarySettingsLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.settings, dark: false), named: "library-settings-light")
    }

    func testLibrarySettingsDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.settings, dark: true), named: "library-settings-dark")
    }

    private enum LibraryScreen {
        case larder, larderGrouped, episodeDetail, settings
    }

    /// Launches the production `LibraryRoot` over the fixed-clock `pixel` fixture and drives it to `screen`.
    private func launchLibraryRoot(_ screen: LibraryScreen, dark: Bool) -> UIImage {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--wilted-library-root-fixture", "--wilted-library-root-scenario=pixel",
            "--wilted-library-root-appearance=\(dark ? "dark" : "light")"
        ]
        // Probe hook: WILTED_PIXEL_PROBE_TZ (as TEST_RUNNER_WILTED_PIXEL_PROBE_TZ) launches the app in another
        // zone; the fixture pins its own, so the captures must not move.
        if let zone = ProcessInfo.processInfo.environment["WILTED_PIXEL_PROBE_TZ"] { app.launchEnvironment["TZ"] = zone }
        app.launch()
        let any = app.descendants(matching: .any)
        let firstRow = any["wilted-library-row-fixture-episode-1"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "LibraryRoot fixture did not list its episodes.")
        XCTAssertTrue(any["wilted-library-row-fixture-episode-3"].waitForExistence(timeout: 10))
        switch screen {
        case .larder:
            break
        case .larderGrouped:
            app.buttons["wilted-library-organize"].tap()
            app.buttons["Feed"].tap()
            XCTAssertTrue(any["wilted-library-group-Fixture Show"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(any["wilted-library-group-Second Fixture Show"].firstMatch.waitForExistence(timeout: 5))
        case .episodeDetail:
            // The title, not the row's centre: the row centre can land on its own Play control.
            let title = any["wilted-library-title-fixture-episode-1"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.tap()
            XCTAssertTrue(any["wilted-library-detail"].waitForExistence(timeout: 5))
        case .settings:
            app.buttons["wilted-library-settings-button"].tap()
            XCTAssertTrue(any["wilted-library-settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["wilted-library-settings-sync-status"].waitForExistence(timeout: 5))
        }
        // Let the menu dismissal, sheet presentation and list layout finish before the capture.
        Thread.sleep(forTimeInterval: 1.5)
        return normalized(app.screenshot().image)
    }

    private func normalized(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: canvas))
        }
    }

    private func assertSnapshot(_ image: UIImage, named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let baseline = URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/WiltediOSPixelSnapshotTests/\(name).png")
        guard let actualData = image.pngData(), let actual = UIImage(data: actualData) else {
            XCTFail("Unable to encode screenshot", file: file, line: line)
            return
        }
        #if WILTED_RECORD_SNAPSHOTS
        let shouldRecord = true
        #else
        let shouldRecord = ProcessInfo.processInfo.environment["WILTED_RECORD_SNAPSHOTS"] == "1"
        #endif
        if shouldRecord {
            do {
                try actualData.write(to: baseline)
            } catch {
                XCTFail("Unable to record snapshot: \(error.localizedDescription)", file: file, line: line)
            }
            return
        }
        guard let expectedData = try? Data(contentsOf: baseline),
              let expected = UIImage(data: expectedData) else {
            XCTFail("Missing or unreadable baseline: \(baseline.lastPathComponent)", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(pixelPrecision(expected: expected, actual: actual), 0.99)
    }

    private func pixelPrecision(expected: UIImage, actual: UIImage) -> Double {
        guard let expectedPixels = rgbaPixels(expected),
              let actualPixels = rgbaPixels(actual),
              expectedPixels.count == actualPixels.count else { return 0 }
        let total = expectedPixels.count / 4
        let matching = stride(from: 0, to: expectedPixels.count, by: 4).reduce(into: 0) { count, index in
            let difference = max(
                abs(Int(expectedPixels[index]) - Int(actualPixels[index])),
                abs(Int(expectedPixels[index + 1]) - Int(actualPixels[index + 1])),
                abs(Int(expectedPixels[index + 2]) - Int(actualPixels[index + 2])),
                abs(Int(expectedPixels[index + 3]) - Int(actualPixels[index + 3]))
            )
            if difference <= 3 { count += 1 }
        }
        return Double(matching) / Double(total)
    }

    private func rgbaPixels(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }
}
