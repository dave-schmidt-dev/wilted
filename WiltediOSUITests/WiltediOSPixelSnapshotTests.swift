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

    // B6.3 Task 4.2: the kind filter (Articles chosen), a book row under the Audiobooks filter, and Now Playing chapters.

    func testLibraryFilterArticlesLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.filterArticles, dark: false), named: "library-filter-articles-light")
    }

    func testLibraryFilterArticlesDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.filterArticles, dark: true), named: "library-filter-articles-dark")
    }

    func testLibraryBookRowLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.bookRow, dark: false), named: "library-book-row-light")
    }

    func testLibraryBookRowDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.bookRow, dark: true), named: "library-book-row-dark")
    }

    func testLibraryNowPlayingChaptersLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.nowPlayingChapters, dark: false), named: "library-now-playing-chapters-light")
    }

    func testLibraryNowPlayingChaptersDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.nowPlayingChapters, dark: true), named: "library-now-playing-chapters-dark")
    }

    // B6.4 Task 4.2b: a Morning report row, and Now Playing while a bulletin is being spoken (stub speaker, silent).

    func testLibraryReportRowLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.reportRow, dark: false), named: "library-report-row-light")
    }

    func testLibraryReportRowDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.reportRow, dark: true), named: "library-report-row-dark")
    }

    func testLibraryNowPlayingBulletinLightPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.nowPlayingBulletin, dark: false), named: "library-now-playing-bulletin-light")
    }

    func testLibraryNowPlayingBulletinDarkPixelBaseline() {
        assertSnapshot(launchLibraryRoot(.nowPlayingBulletin, dark: true), named: "library-now-playing-bulletin-dark")
    }

    private enum LibraryScreen {
        case larder, larderGrouped, episodeDetail, settings
        case filterArticles, bookRow, nowPlayingChapters
        case reportRow, nowPlayingBulletin

        /// The fixture scenario: the three B6.3 screens need the article and the audiobook volume.
        var scenario: String {
            switch self {
            case .filterArticles, .bookRow, .nowPlayingChapters: "pixel-books"
            case .reportRow, .nowPlayingBulletin: "pixel-interruptions"
            default: "pixel"
            }
        }
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
            "--wilted-library-root-fixture", "--wilted-library-root-scenario=\(screen.scenario)",
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
        case .filterArticles:
            XCTAssertTrue(any["wilted-library-row-fixture-book-1"].waitForExistence(timeout: 10))
            app.buttons["wilted-library-filter"].tap()
            XCTAssertTrue(app.buttons["Audiobooks"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Articles"].exists && app.buttons["Podcasts"].exists)
            // The open menu's translucent material is not stable enough to pin, so the capture is the result.
            app.buttons["Articles"].tap()
            XCTAssertTrue(any["wilted-library-row-fixture-article-1"].waitForExistence(timeout: 5))
            XCTAssertFalse(any["wilted-library-row-fixture-book-1"].exists, "The Articles filter lists only articles")
            XCTAssertFalse(any["wilted-library-row-fixture-episode-1"].exists, "The Articles filter lists only articles")
        case .bookRow:
            XCTAssertTrue(any["wilted-library-row-fixture-book-1"].waitForExistence(timeout: 10))
            app.buttons["wilted-library-filter"].tap()
            app.buttons["Audiobooks"].tap()
            XCTAssertTrue(any["wilted-library-meta-fixture-book-1"].waitForExistence(timeout: 5))
            XCTAssertFalse(any["wilted-library-row-fixture-episode-1"].exists, "The Audiobooks filter lists only books")
            XCTAssertFalse(any["wilted-library-row-fixture-article-1"].exists, "The Audiobooks filter lists only books")
        case .nowPlayingChapters:
            let play = app.buttons["wilted-library-play-fixture-book-1"]
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            play.tap()
            let expand = app.buttons["wilted-player-expand"]
            XCTAssertTrue(expand.waitForExistence(timeout: 10))
            expand.tap()
            let next = app.buttons["wilted-player-next-chapter"]
            XCTAssertTrue(next.waitForExistence(timeout: 10))
            next.tap()
            XCTAssertTrue(app.staticTexts["Roots and Rain"].waitForExistence(timeout: 5), "Next chapter moves to chapter 2")
            XCTAssertTrue(app.staticTexts["Chapter 2 of 4"].exists)
        case .reportRow:
            XCTAssertTrue(any["wilted-library-row-fixture-report-1"].waitForExistence(timeout: 10))
            XCTAssertTrue(any["wilted-library-meta-fixture-report-1"].waitForExistence(timeout: 5))
        case .nowPlayingBulletin:
            let play = app.buttons["wilted-library-play-fixture-episode-1"]
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            play.tap()
            // The banner and Skip bulletin live in the mini player, so the capture stays on the Larder.
            XCTAssertTrue(app.buttons["wilted-player-skip-bulletin"].waitForExistence(timeout: 15), "The bulletin banner shows Skip bulletin")
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
        guard screen == .larder || screen == .settings || screen == .bookRow else { return }
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
            if screen == .bookRow {
                // The book row names its author and its length, painted whole.
                let metadata = app.descendants(matching: .any)["wilted-library-meta-fixture-book-1"].firstMatch
                XCTAssertTrue(metadata.exists)
                try assertPaintedLine("Ada Fixture", frame: metadata.frame)
                try assertPaintedLine("10:00", frame: metadata.frame)
            } else if screen == .larder {
                // Frame-bound pixels prove each date, painted whole on its own line below the show and
                // duration, including the longer second show's row.
                for episode in 1...3 {
                    let metadata = app.descendants(matching: .any)["wilted-library-meta-fixture-episode-\(episode)"].firstMatch
                    let date = app.descendants(matching: .any)["wilted-library-date-fixture-episode-\(episode)"].firstMatch
                    XCTAssertTrue(metadata.exists && date.exists)
                    XCTAssertGreaterThanOrEqual(date.frame.minY, metadata.frame.maxY - 1,
                        "The date is its own line under the show and duration")
                    try assertPaintedLine("Nov 14, 2023", frame: date.frame)
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
