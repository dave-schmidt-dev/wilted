import UIKit
import Vision
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

    func testLibraryAddSearchLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addSearch, dark: false), named: "library-add-search-light")
    }

    func testLibraryAddSearchDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addSearch, dark: true), named: "library-add-search-dark")
    }

    func testLibraryAddSentLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addSent, dark: false), named: "library-add-sent-light")
    }

    func testLibraryAddSentDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addSent, dark: true), named: "library-add-sent-dark")
    }

    func testLibraryAddRejectedLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addRejected, dark: false), named: "library-add-rejected-light")
    }

    func testLibraryAddRejectedDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addRejected, dark: true), named: "library-add-rejected-dark")
    }

    func testLibraryAddUpdateMacLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addUpdateMac, dark: false), named: "library-add-update-mac-light")
    }

    func testLibraryAddUpdateMacDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.addUpdateMac, dark: true), named: "library-add-update-mac-dark")
    }

    private enum LibraryScreen {
        case larder, larderGrouped, episodeDetail, settings
        // The Add sheet's four states (Task 4.1): results, sent and waiting, refused, and an old Mac.
        case addSearch, addSent, addRejected, addUpdateMac

        /// What the DEBUG fixture's stand-in Mac does for this screen (`LibraryAddUITestSeam`); nil for the rest.
        var addMac: String? {
            switch self {
            case .addSearch, .addSent: "ready"
            case .addRejected: "rejects-no-audio"
            case .addUpdateMac: "old"
            default: nil
            }
        }
    }

    /// Launches the production `LibraryRoot` over the fixed-clock `pixel` fixture and drives it to `screen`.
    private func launchLibraryRoot(_ screen: LibraryScreen, dark: Bool) -> UIImage {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--wilted-library-root-fixture", "--wilted-library-root-scenario=pixel",
            "--wilted-library-root-appearance=\(dark ? "dark" : "light")"
        ]
        if let mac = screen.addMac { app.launchArguments.append("--wilted-library-add-mac=\(mac)") }
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
        case .addSearch, .addSent, .addRejected, .addUpdateMac:
            driveAddSheet(screen, app: app)
        case .settings:
            app.buttons["wilted-library-settings-button"].tap()
            XCTAssertTrue(any["wilted-library-settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["wilted-library-settings-sync-status"].waitForExistence(timeout: 5))
        }
        // Let the menu dismissal, sheet presentation and list layout finish before the capture.
        Thread.sleep(forTimeInterval: 1.5)
        let screenshot = app.screenshot().image
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "shipping-\(screen)-\(dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        assertShippingFacts(screen, app: app, image: screenshot)
        return normalized(screenshot)
    }

    /// Opens the Add sheet and types into it, as a listener would, until `screen`'s state shows. Search
    /// answers come from the DEBUG fixture, never from Apple.
    private func driveAddSheet(_ screen: LibraryScreen, app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        app.buttons["wilted-library-add-button"].tap()
        let field = app.textFields["wilted-add-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The Add sheet did not open.")
        field.tap()
        switch screen {
        case .addSearch:
            field.typeText("garden\n")
            XCTAssertTrue(any["wilted-add-result-show-9001"].waitForExistence(timeout: 10))
        case .addRejected:
            field.typeText("garden\n")
            XCTAssertTrue(any["wilted-add-result-show-9001"].waitForExistence(timeout: 10))
            app.buttons["wilted-add-subscribe-show-9001"].tap()
            // The refusal lands in the requests list and the row offers Subscribe again.
            XCTAssertTrue(app.staticTexts["That feed has no audio episodes, so your Mac did not add it."].waitForExistence(timeout: 10))
        case .addSent:
            field.typeText("https://example.com/podcast\n")
            XCTAssertTrue(any["wilted-add-result-link"].waitForExistence(timeout: 10))
            app.buttons["wilted-add-feed-link"].tap()
            XCTAssertTrue(app.staticTexts["Sent to your Mac"].waitForExistence(timeout: 10))
        case .addUpdateMac:
            field.typeText("https://example.com/podcast\n")
            XCTAssertTrue(any["wilted-add-result-link"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Update Wilted on your Mac to add from iPhone"].waitForExistence(timeout: 10))
        default:
            XCTFail("Not an Add sheet screen")
        }
    }

    /// Reads the actual rendered pixels: accessibility labels alone can conceal clipped text.
    private func assertShippingFacts(_ screen: LibraryScreen, app: XCUIApplication, image: UIImage) {
        guard screen == .larder || screen == .settings else { return }
        do {
            func assertPaintedLine(_ expected: String, frame: CGRect) throws {
                let bounds = CGRect(origin: .zero, size: image.size)
                XCTAssertTrue(bounds.contains(frame), "Factual text stays inside the shipping screen")
                let region = frame.insetBy(dx: -2, dy: -3).intersection(bounds)
                let scale = CGFloat(try XCTUnwrap(image.cgImage).width) / image.size.width
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                    x: region.minX * scale, y: region.minY * scale,
                    width: region.width * scale, height: region.height * scale).integral))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                let lines = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                let text = lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                func compact(_ text: String) -> String {
                    text.lowercased().filter { $0.isLetter || $0.isNumber }
                }
                XCTAssertTrue(compact(text).contains(compact(expected)),
                    "The complete factual text must be painted: expected \(expected), pixels \(text)")
                let centers = lines.map { $0.boundingBox.midY * region.height }
                XCTAssertLessThanOrEqual((centers.max() ?? 0) - (centers.min() ?? 0), 6,
                    "Recognized tokens belong to one painted line, including a separately recognized year")
            }
            if screen == .larder {
                // Frame-bound pixels prove each date, including the longer second show's row.
                for episode in 1...3 {
                    let metadata = app.descendants(matching: .any)["wilted-library-meta-fixture-episode-\(episode)"].firstMatch
                    XCTAssertTrue(metadata.exists)
                    try assertPaintedLine("Nov 14, 2023", frame: metadata.frame)
                }
            } else {
                let value = app.staticTexts["wilted-library-settings-cache-size"]
                XCTAssertTrue(value.exists)
                let label = app.staticTexts["Downloaded audio"].firstMatch
                XCTAssertTrue(label.exists)
                XCTAssertGreaterThanOrEqual(value.frame.minY, label.frame.maxY,
                    "Storage paints its value below the label in its own full-width line")
                try assertPaintedLine("Downloaded audio", frame: label.frame)
                try assertPaintedLine(value.label, frame: value.frame)
            }
        } catch {
            XCTFail("Shipping factual layout could not be verified: \(error)")
        }
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
