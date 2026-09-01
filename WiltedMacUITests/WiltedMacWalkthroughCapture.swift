import AppKit
import XCTest

/// Records the content-viewport frames embedded in the dated Mac walkthrough.
///
/// This is capture tooling, not a gate. It runs only when
/// `WILTED_WALKTHROUGH_CAPTURE_DIR` names a directory, so the shipping suite
/// is unaffected. Pixels come from `XCUIElement.screenshot()` on the app's own
/// window -- never the screen and never another application's window -- and
/// each frame is inset by 8pt per edge because the window's rounded corners are
/// partly transparent and an uncropped frame can contain fragments of whatever
/// is behind it.
@MainActor
final class WiltedMacWalkthroughCapture: XCTestCase {
    func testCaptureWalkthroughFrames() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE"] == "1",
            "capture tooling; set WILTED_WALKTHROUGH_CAPTURE=1 to record walkthrough frames"
        )
        let root = try Self.captureRoot()
        print("walkthrough.capture.root=\(root.path)")

        try captureLarder(into: root)
        try captureFeeds(into: root)
        try capturePlayback(into: root)
        try captureRoutes(into: root)
        try captureRecovery(into: root)
    }

    /// Where the frames land.
    ///
    /// `WILTED_WALKTHROUGH_CAPTURE_DIR` is honoured when the runner can
    /// actually write there; the signed runner often cannot reach an arbitrary
    /// path, so the fallback is its own temporary directory and the resolved
    /// root is printed rather than assumed.
    private static func captureRoot() throws -> URL {
        var candidates: [URL] = []
        if let requested = ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE_DIR"] {
            candidates.append(URL(fileURLWithPath: requested, isDirectory: true))
        }
        candidates.append(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("wilted-walkthrough-captures", isDirectory: true)
        )
        for candidate in candidates {
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                let probe = candidate.appendingPathComponent(".probe")
                try Data("ok".utf8).write(to: probe)
                try FileManager.default.removeItem(at: probe)
                try purge(candidate)
                return candidate
            } catch { continue }
        }
        throw XCTSkip("no writable capture directory")
    }

    // MARK: - Scenarios

    private func captureLarder(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        XCTAssertTrue(element(app, "wilted-library-order").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "wilted-player-idle").waitForExistence(timeout: 10))
        try write(app, "4.1-larder-idle", into: root)
        app.terminate()
    }

    private func captureFeeds(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        let navigate = element(app, "wilted-navigation-feeds")
        XCTAssertTrue(navigate.waitForExistence(timeout: 15))
        navigate.click()
        let card = element(app, "wilted-podcast-feeds")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        try write(app, "5.1-feeds-page", into: root)
        // The page frame above shows the feeds as found. This one records what
        // the switch actually does, so the report is not left asserting an
        // effect it never captured.
        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-enabled-'")
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        let count = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-count-'")
        ).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        try write(app, "5.2-feeds-feed-hidden", into: root)
        app.terminate()
    }

    private func capturePlayback(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts"])
        XCTAssertTrue(element(app, "wilted-player-play-pause").waitForExistence(timeout: 15))
        try write(app, "6.1-playback-rail", into: root)

        let transcript = element(app, "wilted-player-transcript")
        if transcript.exists {
            transcript.click()
            XCTAssertTrue(element(app, "wilted-player-transcript-expanded").waitForExistence(timeout: 10))
            try write(app, "6.2-transcript-expanded", into: root)
            transcript.click()
        }

        let upNext = element(app, "wilted-player-up-next")
        if upNext.exists {
            upNext.click()
            XCTAssertTrue(element(app, "wilted-player-up-next-expanded").waitForExistence(timeout: 10))
            try write(app, "6.3-up-next-expanded", into: root)
            upNext.click()
        }

        // Notes exist only for an episode, so this frame comes from the
        // podcast fixture's episode rather than the playing article.
        let playEpisode = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-play-'")
        ).firstMatch
        if playEpisode.waitForExistence(timeout: 5) {
            playEpisode.click()
            let notes = element(app, "wilted-player-notes")
            XCTAssertTrue(notes.waitForExistence(timeout: 10))
            notes.click()
            XCTAssertTrue(element(app, "wilted-player-notes-expanded").waitForExistence(timeout: 10))
            try write(app, "6.4-notes-expanded", into: root)
            notes.click()
        }
        app.terminate()
    }

    private func captureRoutes(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts"])
        XCTAssertTrue(element(app, "wilted-player-play-pause").waitForExistence(timeout: 15))

        element(app, "wilted-navigation-processor").click()
        XCTAssertTrue(element(app, "wilted-mac-processor-detail").waitForExistence(timeout: 10))
        try write(app, "7.1-prep-with-playback", into: root)

        element(app, "wilted-navigation-settings").click()
        XCTAssertTrue(element(app, "wilted-sync-controls").waitForExistence(timeout: 10))
        try write(app, "8.1-settings-with-playback", into: root)
        app.terminate()
    }

    private func captureRecovery(into root: URL) throws {
        let failure = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                              "--wilted-ui-fixture-download-failure"])
        let download = failure.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-download-'")
        ).firstMatch
        if download.waitForExistence(timeout: 15) {
            download.click()
            let retry = failure.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-retry-'")
            ).firstMatch
            _ = retry.waitForExistence(timeout: 20)
        }
        try write(failure, "9.1-download-failure-retry", into: root)
        failure.terminate()

        let quarantined = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-quarantined"])
        let settings = element(quarantined, "wilted-navigation-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.click()
        XCTAssertTrue(element(quarantined, "wilted-sync-controls").waitForExistence(timeout: 10))
        try write(quarantined, "9.2-sync-quarantine", into: root)
        quarantined.terminate()
    }

    // MARK: - Capture

    /// Writes one inset PNG of the app's own window plus a geometry sidecar, so
    /// the report can state what region each frame covers instead of asserting
    /// it.
    private func write(_ app: XCUIApplication, _ name: String, into root: URL) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let shot = window.screenshot()
        let source = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
        let scale = source.pixelsWide > 0 ? CGFloat(source.pixelsWide) / max(window.frame.width, 1) : 2
        let inset = Int((8 * scale).rounded())
        let cropped = try XCTUnwrap(crop(source, by: inset))
        let png = try XCTUnwrap(cropped.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("\(name).png"))
        let sidecar = """
        {"name":"\(name)","window":{"x":\(window.frame.origin.x),"y":\(window.frame.origin.y),\
        "width":\(window.frame.width),"height":\(window.frame.height)},\
        "capturedPixels":{"width":\(source.pixelsWide),"height":\(source.pixelsHigh)},\
        "embeddedPixels":{"width":\(cropped.pixelsWide),"height":\(cropped.pixelsHigh)},\
        "insetPixelsPerEdge":\(inset)}
        """
        try Data(sidecar.utf8).write(to: root.appendingPathComponent("\(name).json"))
    }

    /// Empties the capture directory before recording.
    ///
    /// The runner's fallback directory lives in its container and survives
    /// between runs, so a frame this run does not write would otherwise be
    /// served by whatever an earlier run left under the same name -- and a
    /// renamed frame would leave its predecessor behind for the generator's
    /// geometry pass to read. Stale evidence is the one thing this report
    /// cannot contain.
    private static func purge(_ directory: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where ["png", "json"].contains(file.pathExtension.lowercased()) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func crop(_ source: NSBitmapImageRep, by inset: Int) -> NSBitmapImageRep? {
        let width = source.pixelsWide - inset * 2
        let height = source.pixelsHigh - inset * 2
        guard width > 0, height > 0, let cgImage = source.cgImage,
              let cropped = cgImage.cropping(to: CGRect(x: inset, y: inset, width: width, height: height))
        else { return nil }
        return NSBitmapImageRep(cgImage: cropped)
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
