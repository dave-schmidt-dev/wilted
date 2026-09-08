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
        try capturePrep(into: root)
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

        // The address box is behind Add article now, and a popover is its
        // own window, so the main window's frame cannot show it: the popover
        // is captured as itself.
        element(app, "wilted-add-article-button").click()
        XCTAssertTrue(element(app, "wilted-link-url").waitForExistence(timeout: 10))
        try write(popover: app.popovers.firstMatch, "4.3-larder-add-article", into: root)
        app.typeKey(.escape, modifierFlags: [])

        // Skip is one press, and the message it leaves offers Undo; Removed
        // then appears in the list header and opens the removed list.
        let skip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-skip-'")
        ).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.click()
        XCTAssertTrue(element(app, "wilted-podcast-undo-removal").waitForExistence(timeout: 10))
        try write(app, "4.4-larder-skipped-undo", into: root)

        let removed = element(app, "wilted-podcast-removed-title")
        XCTAssertTrue(removed.waitForExistence(timeout: 10))
        removed.click()
        let removedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-removed-row-'")
        ).firstMatch
        if !removedRow.waitForExistence(timeout: 3) { removed.click() }
        XCTAssertTrue(removedRow.waitForExistence(timeout: 10))
        try write(popover: app.popovers.firstMatch, "4.5-larder-removed", into: root)
        app.typeKey(.escape, modifierFlags: [])
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

        app.terminate()

        // Notes exist only for an episode, so this frame comes from the
        // podcast fixture's episode rather than the playing article -- and from
        // a launch of its own. Starting an episode from the Larder rows after
        // the panels above have been expanded and collapsed does not work:
        // the row's play button reports hittable, the geometry is unchanged,
        // and the click lands on nothing. That is tracked as its own defect;
        // relaunching keeps the capture measuring what it is for, which is what
        // the rail looks like, rather than failing on an unrelated bug.
        let episodeApp = launch(["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts"])
        XCTAssertTrue(element(episodeApp, "wilted-player-play-pause").waitForExistence(timeout: 15))
        let playEpisode = episodeApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-play-'")
        ).firstMatch
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 10))
        playEpisode.click()
        let notes = element(episodeApp, "wilted-player-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.click()
        XCTAssertTrue(element(episodeApp, "wilted-player-notes-expanded").waitForExistence(timeout: 10))
        try write(episodeApp, "6.4-notes-expanded", into: root)
        notes.click()
        episodeApp.terminate()
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

        // The one settings state that refuses work. Ad removal is timed from
        // an aligned local pass, so pairing it with No local speech-to-text
        // makes every preparation fail before any model time is spent, and
        // neither control is disabled or rewritten -- the notice is all the
        // owner gets, which is why the walkthrough shows it rather than
        // describing it. A fixture launch has its own defaults domain, so
        // driving the picker here cannot reach the owner's own choice.
        let transcriptPolicy = element(app, "wilted-automation-transcript-policy")
        XCTAssertTrue(transcriptPolicy.waitForExistence(timeout: 10))
        transcriptPolicy.click()
        let noLocalSTT = app.menuItems["No local speech-to-text"]
        XCTAssertTrue(noLocalSTT.waitForExistence(timeout: 10))
        noLocalSTT.click()
        XCTAssertTrue(element(app, "wilted-automation-transcript-conflict").waitForExistence(timeout: 10))
        try write(app, "8.2-settings-transcript-conflict", into: root)
        app.terminate()
    }

    /// The prepared fixture journals a finished run, so this is the Larder row
    /// and the Prep page as they read after preparation, and the run's log
    /// once asked for.
    private func capturePrep(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"])
        XCTAssertTrue(element(app, "wilted-library-order").waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-row-'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready · 5 ads removed (7:22) · transcript synced"].exists)
        try write(app, "4.2-larder-prepared-episode", into: root)

        element(app, "wilted-navigation-processor").click()
        let run = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-run-podcast-prepare|'")
        ).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        try write(app, "7.2-prep-recorded-run", into: root)

        let showLog = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-log-toggle-'")
        ).firstMatch
        XCTAssertTrue(showLog.waitForExistence(timeout: 5))
        showLog.click()
        XCTAssertTrue(app.staticTexts["ads.detect.calls · 50 requests, 0 failed"].waitForExistence(timeout: 5))
        try write(app, "7.3-prep-run-log", into: root)
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

    /// Writes one PNG of a popover plus its sidecar.
    ///
    /// A popover is a window of its own, so the main window's screenshot
    /// never contains it. The frame is the popover element's, uninset, and
    /// the sidecar says so with `"kind":"popover"`, which is how the report
    /// keeps these out of the one-geometry claim it makes for window frames.
    private func write(popover: XCUIElement, _ name: String, into root: URL) throws {
        XCTAssertTrue(popover.waitForExistence(timeout: 10))
        let shot = popover.screenshot()
        let source = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
        try shot.pngRepresentation.write(to: root.appendingPathComponent("\(name).png"))
        let sidecar = """
        {"name":"\(name)","kind":"popover","window":{"x":\(popover.frame.origin.x),"y":\(popover.frame.origin.y),\
        "width":\(popover.frame.width),"height":\(popover.frame.height)},\
        "capturedPixels":{"width":\(source.pixelsWide),"height":\(source.pixelsHigh)},\
        "embeddedPixels":{"width":\(source.pixelsWide),"height":\(source.pixelsHigh)},\
        "insetPixelsPerEdge":0}
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
