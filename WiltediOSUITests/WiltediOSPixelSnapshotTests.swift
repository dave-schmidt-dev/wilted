import UIKit
import XCTest

/// Pixel coverage for the shipping listener Library, including its toolbar
/// wordmark. Captures normalize simulator density while keeping the rendered
/// screen geometry deterministic across the supported iPhone simulators.
@MainActor
final class WiltediOSPixelSnapshotTests: XCTestCase {
    private let canvas = CGSize(width: 390, height: 844)

    func testListenerLibraryDarkPixelBaseline() {
        assertSnapshot(launch(screen: .library, dark: true), named: "listener-library-dark")
    }

    func testListenerLibraryLightPixelBaseline() {
        assertSnapshot(launch(screen: .library, dark: false), named: "listener-library-light")
    }

    func testListenerSettingsDarkPixelBaseline() {
        assertSnapshot(launch(screen: .settings, dark: true), named: "listener-settings-dark")
    }

    func testListenerSettingsLightPixelBaseline() {
        assertSnapshot(launch(screen: .settings, dark: false), named: "listener-settings-light")
    }

    func testListenerNowPlayingDarkPixelBaseline() {
        assertSnapshot(launch(screen: .nowPlaying, dark: true), named: "listener-now-playing-dark")
    }

    func testListenerNowPlayingLightPixelBaseline() {
        assertSnapshot(launch(screen: .nowPlaying, dark: false), named: "listener-now-playing-light")
    }

    func testListenerEmptyNowPlayingDarkPixelBaseline() {
        assertSnapshot(launch(screen: .emptyNowPlaying, dark: true), named: "listener-now-playing-empty-dark")
    }

    func testListenerEmptyNowPlayingLightPixelBaseline() {
        assertSnapshot(launch(screen: .emptyNowPlaying, dark: false), named: "listener-now-playing-empty-light")
    }

    func testListenerTerminalFailureDarkPixelBaseline() {
        assertSnapshot(launch(screen: .terminalFailure, dark: true), named: "listener-terminal-failure-dark")
    }

    func testListenerTerminalFailureLightPixelBaseline() {
        assertSnapshot(launch(screen: .terminalFailure, dark: false), named: "listener-terminal-failure-light")
    }

    // MARK: Production LibraryRoot (IOS-CLEAR-001, CI-4)

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

    private enum Screen: String {
        case library
        case settings
        case nowPlaying
        case emptyNowPlaying = "empty-now-playing"
        case terminalFailure = "terminal-failure"

        var fixtureState: String {
            switch self {
            case .nowPlaying: "nowPlaying"
            case .emptyNowPlaying: "emptyNowPlaying"
            case .terminalFailure: "terminalFailure"
            case .library, .settings: "library"
            }
        }

        var readyIdentifier: String {
            switch self {
            case .settings: "wilted-settings"
            case .nowPlaying: "wilted-player"
            case .emptyNowPlaying: "wilted-player-empty"
            case .library, .terminalFailure: "wilted-listener-status"
            }
        }
    }

    private func launch(screen: Screen, dark: Bool) -> UIImage {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--wilted-listener-pixel-fixture",
            "--wilted-listener-pixel-state=\(screen.fixtureState)"
        ]
            + (screen == .settings ? ["--wilted-listener-pixel-settings"] : [])
            + ([.nowPlaying, .emptyNowPlaying].contains(screen) ? ["--wilted-listener-pixel-now-playing"] : [])
            + ["--wilted-listener-pixel-appearance=\(dark ? "dark" : "light")"]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)[screen.readyIdentifier].waitForExistence(timeout: 5),
            "Listener fixture did not reach \(screen.rawValue)."
        )
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
            XCTFail("Unable to encode listener screenshot", file: file, line: line)
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
                XCTFail("Unable to record listener snapshot: \(error.localizedDescription)", file: file, line: line)
            }
            return
        }
        guard let expectedData = try? Data(contentsOf: baseline),
              let expected = UIImage(data: expectedData) else {
            XCTFail("Missing or unreadable listener baseline: \(baseline.lastPathComponent)", file: file, line: line)
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
