import XCTest

/// The attended Development listener journey against the real private database.
///
/// This is the listener half of the Task 6 round trip, and it deliberately does not
/// run in the ordinary gate: it needs a Development-signed build carrying the live
/// CloudKit entitlement, a physical device, a signed-in iCloud account, and an item
/// the Mac producer has already published. The gate runs it on a simulator with no
/// such environment, where every test here skips rather than reporting a false pass.
///
/// The item identifier is supplied by the run, not pinned here, because it is account
/// data. `xcodebuild` forwards any `TEST_RUNNER_`-prefixed variable to the runner
/// process on the device with the prefix stripped, which is how it arrives:
///
///     TEST_RUNNER_WILTED_ATTENDED_ITEM_ID=item-… xcodebuild test …
@MainActor
final class WiltediOSAttendedCloudKitUITests: XCTestCase {
    private var itemID: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let id = ProcessInfo.processInfo.environment["WILTED_ATTENDED_ITEM_ID"], !id.isEmpty else {
            throw XCTSkip("attended run only; set TEST_RUNNER_WILTED_ATTENDED_ITEM_ID to a published item")
        }
        itemID = id
    }

    func testAPublishedRevisionDownloadsPlaysInBackgroundAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let refresh = app.descendants(matching: .any)["wilted-listener-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 30), "listener library never appeared")
        if refresh.isEnabled { refresh.tap() }

        // The fetch pulls a real asset over the network, so the wait is long but bounded.
        let download = app.descendants(matching: .any)["wilted-listener-download-action-\(itemID)"]
        let removeDownload = app.descendants(matching: .any)["wilted-listener-remove-download-\(itemID)"]
        XCTAssertTrue(waitForEither(download, removeDownload, timeout: 240),
                      "published item never reached the listener library; status: \(statusText(app))")

        if download.exists {
            download.tap()
            XCTAssertTrue(removeDownload.waitForExistence(timeout: 300),
                          "download never completed; status: \(statusText(app))")
        }

        let play = app.descendants(matching: .any)["wilted-listener-play-\(itemID)"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        XCTAssertTrue(play.isEnabled, "play stayed disabled after the download reported complete")
        play.tap()

        if !waitForPlayer(app, timeout: 30) {
            attachScreenshot(app, named: "play-failed")
            XCTFail("now playing never became reachable; status: \(statusText(app))\n"
                    + playerTree(app))
        }

        // Zero the position before backgrounding. Play resumes from the persisted record, and
        // on a wiped container that record is whatever the server last held -- roughly 9s in
        // practice. A threshold below that resume value is satisfied the instant the readout
        // renders, so the assertion would pass identically whether or not any audio advanced
        // while backgrounded. Restarting makes the hold the only thing that can move the clock.
        let restart = app.descendants(matching: .any)["wilted-listener-restart"]
        XCTAssertTrue(reveal(app, restart, swipingUp: true), "restart control never became reachable")
        restart.tap()

        // Wait for the restart to actually take hold before backgrounding. The tap starts async
        // work that reloads the asset and reactivates the audio session, and pressing Home into
        // the middle of it leaves the engine stopped: one run in two came back at position 0
        // for exactly this reason, which reads identically to background audio being broken.
        // `.playing` is published only after `play(asset:)` returns, so the status is the signal
        // that there is playing audio to background in the first place.
        XCTAssertTrue(waitForStatus(app, equalTo: "Playing offline", timeout: 30),
                      "playback never restarted; status: \(statusText(app))")

        // The readout renders the recorded `PlaybackState`, which only changes at explicit
        // commands, so it stays at the start position for as long as audio simply plays.
        // Background playback is therefore proven through `pause()`, the one path that reads
        // the live engine clock: a position near the wall-clock hold cannot be produced by
        // anything except audio that actually advanced while the app was not frontmost.
        // Holding in the foreground instead isolates which half is broken. A position of zero
        // after a background hold has two explanations -- audio that stops when the app leaves
        // the screen, or an engine clock that never advances anywhere -- and they call for
        // completely different fixes. The same hold with the app frontmost tells them apart.
        let foregroundOnly = Self.holdsInForeground
        if !foregroundOnly { XCUIDevice.shared.press(.home) }
        let backgrounded = try XCTUnwrap(waitForWallClock(seconds: Self.backgroundHold),
                                         "could not hold\(foregroundOnly ? "" : " in background")")
        if !foregroundOnly { app.activate() }

        // Read only after pausing. Foregrounding runs `resumeForeground` -> `refresh`, whose
        // rebuild republishes the persisted start-position record over the display, so a read
        // taken before the pause would report that stale value no matter what the engine did.
        XCTAssertTrue(waitForPlayer(app, timeout: 30),
                      "player controls never became reachable; status: \(statusText(app))")
        playPause(app).tap()
        // Scaled to the hold rather than fixed, so the threshold cannot be met by a resume
        // value that predates the background period: from zero, only real elapsed playback
        // reaches it. The margin absorbs the tap-to-tap overhead either side of the hold.
        let floor = backgrounded * 0.6
        let held = position(app) ?? -1
        let message = "position reached \(held)s across \(backgrounded)s of background audio, "
            + "needed \(floor)s; status: \(statusText(app))"
        let paused = try XCTUnwrap(waitForPosition(app, above: floor, timeout: 30), message)
        // Attached on success too. A position is only evidence of background playback if it
        // tracks the hold, and comparing runs needs the number from the passing run, not just
        // from a failing one. `WILTED_ATTENDED_BACKGROUND_HOLD` varies the hold so the two can
        // be checked against each other; a position that ignores the hold is not a live clock.
        record("held=\(backgrounded)s paused=\(paused)s")

        // Send sits above the player in the same scrolling stack, so reaching it means
        // scrolling back up; revealing the player pushed it off the top of the screen.
        let send = app.descendants(matching: .any)["wilted-listener-send"]
        XCTAssertTrue(reveal(app, send, swipingUp: false), "send control never became reachable")
        if send.isEnabled { send.tap() }
        // Only a completed send reaches "Larder ready". A queue held by conflicts reports
        // "Nothing was sent…", which a settled-looking status check would have accepted as
        // success: that is precisely the failure this journey has to be able to see.
        XCTAssertTrue(waitForStatus(app, equalTo: "Larder ready", timeout: 120),
                      "playback send never completed; status: \(statusText(app))")

        // Reconciliation across relaunch: the restored position must not rewind. The baseline
        // is re-read rather than reused so a send that clobbered the display would be caught.
        let beforeRelaunch = try XCTUnwrap(position(app), "no position readout before relaunch")
        XCTAssertGreaterThanOrEqual(beforeRelaunch, paused - 2,
                                    "sending rewound the displayed position from \(paused)s to \(beforeRelaunch)s")
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForPlayer(app, timeout: 60), "playback was not restored after relaunch")
        let restored = try XCTUnwrap(position(app), "no position readout after relaunch")
        record("beforeRelaunch=\(beforeRelaunch)s restored=\(restored)s")
        XCTAssertGreaterThanOrEqual(restored, beforeRelaunch - 2,
                                    "restored position \(restored)s rewound from \(beforeRelaunch)s")
    }

    // MARK: - Helpers

    /// How long to hold in the background, overridable per run.
    ///
    /// Two runs that hold for the same time cannot distinguish a live engine clock from a
    /// value echoed back off the server record, because both produce the same number. Varying
    /// the hold makes the two hypotheses predict different positions.
    private static var backgroundHold: TimeInterval {
        ProcessInfo.processInfo.environment["WILTED_ATTENDED_BACKGROUND_HOLD"]
            .flatMap(TimeInterval.init) ?? 8
    }

    /// Diagnostic only: holds with the app frontmost so the engine clock can be measured
    /// without the background transition in the way. Never the shipping assertion.
    private static var holdsInForeground: Bool {
        ProcessInfo.processInfo.environment["WILTED_ATTENDED_FOREGROUND_HOLD"] == "1"
    }

    /// Emits a measurement into the run log and the result bundle.
    private func record(_ measurement: String) {
        let note = "wilted.measure \(measurement)"
        print(note)
        let attachment = XCTAttachment(string: note)
        attachment.name = "measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum WiltedAttendedIdentifiers {
        static let player = "wilted-player"
        static let playPause = "wilted-player-play-pause"
        static let status = "wilted-listener-status"
    }

    /// The Now Playing subtree as the accessibility hierarchy actually reports it.
    ///
    /// A device journey that fails with "control not found" and nothing else costs a full
    /// rebuild-and-rerun cycle per guess about why, and the guesses are cheap to get wrong:
    /// off-screen content, a collapsed container, and a control that was never rendered all
    /// present identically. The tree distinguishes them in one run.
    private func playerTree(_ app: XCUIApplication) -> String {
        let player = app.descendants(matching: .any)[WiltedAttendedIdentifiers.player]
        guard player.exists else { return "player element absent; app tree:\n" + app.debugDescription }
        return "player subtree:\n" + player.debugDescription
    }

    private func playPause(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[WiltedAttendedIdentifiers.playPause]
    }

    /// Scrolls `element` into view, reporting whether it got there.
    ///
    /// The library and the Now Playing panel share one scrolling stack, so on a long library
    /// a control can be present but not hittable. A bounded swipe count keeps a genuinely
    /// absent control a failure rather than an endless scroll, and swiping past the end of
    /// the content is a no-op, so an already-visible element costs one existence check.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, swipingUp: Bool, swipes: Int = 8) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            if swipingUp { app.swipeUp() } else { app.swipeDown() }
        }
        return element.exists && element.isHittable
    }

    /// Waits on the transport control rather than the panel, because the panel identifier
    /// alone is not evidence the controls are addressable: before the container was declared
    /// an accessibility element, `wilted-player` resolved to a bare "Now Playing" label while
    /// every button underneath had had its own identifier overwritten by the same string.
    private func waitForPlayer(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { self.reveal(app, self.playPause(app), swipingUp: true, swipes: 2) }
    }

    /// Failure messages carry the on-screen status, because a device journey that fails
    /// without it costs a full rebuild-and-rerun cycle to learn what the app reported.
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func statusText(_ app: XCUIApplication) -> String {
        let status = app.descendants(matching: .any)[WiltedAttendedIdentifiers.status]
        reveal(app, status, swipingUp: false, swipes: 2)
        return status.exists ? status.label : "<no status>"
    }

    /// The now-playing readout is `"<position> / <duration> seconds"`.
    private func position(_ app: XCUIApplication) -> Double? {
        reveal(app, playPause(app), swipingUp: true, swipes: 2)
        let readout = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@ AND label CONTAINS %@", " seconds", " / ")).firstMatch
        guard readout.exists else { return nil }
        return Double(readout.label.components(separatedBy: " / ").first ?? "")
    }

    private func waitForEither(_ a: XCUIElement, _ b: XCUIElement, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { a.exists || b.exists }
    }

    private func waitForPosition(_ app: XCUIApplication, above value: Double, timeout: TimeInterval) -> Double? {
        var latest: Double?
        _ = poll(timeout: timeout) {
            guard let current = self.position(app), current > value else { return false }
            latest = current
            return true
        }
        return latest
    }

    private func waitForStatus(_ app: XCUIApplication, equalTo expected: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { self.statusText(app) == expected }
    }

    /// Holds for real time without a silent wait: it reports how long it actually held.
    private func waitForWallClock(seconds: TimeInterval) -> TimeInterval? {
        let start = Date()
        _ = poll(timeout: seconds + 5) { Date().timeIntervalSince(start) >= seconds }
        let held = Date().timeIntervalSince(start)
        return held >= seconds ? held : nil
    }

    private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }
}
