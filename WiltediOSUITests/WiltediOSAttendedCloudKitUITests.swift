import XCTest

/// The attended Development journey of the production `LibraryRoot` against the real private database.
///
/// This is the phone half of the Task 6 round trip, and it deliberately does not
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

        // `LibraryRoot` syncs on its own; there is no refresh control to press. The row appears
        // once the published revision has been fetched and queued.
        let row = app.descendants(matching: .any)["wilted-library-row-\(itemID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 240),
                      "published item never reached the library; status: \(statusText(app))")

        // The download pulls a real asset over the network, so the wait is long but bounded.
        let get = app.descendants(matching: .any)["wilted-library-media-get-\(itemID)"]
        let removeDownload = app.descendants(matching: .any)["wilted-library-media-remove-\(itemID)"]
        XCTAssertTrue(waitForEither(get, removeDownload, timeout: 60),
                      "no download control appeared; status: \(statusText(app))")
        if get.exists {
            get.tap()
            XCTAssertTrue(removeDownload.waitForExistence(timeout: 300),
                          "download never completed; status: \(statusText(app))")
        }

        let play = app.descendants(matching: .any)["wilted-library-play-\(itemID)"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        XCTAssertTrue(play.isEnabled, "play stayed disabled after the download reported complete")
        play.tap()

        guard let started = waitForPlaying(app, timeout: 30) else {
            attachScreenshot(app, named: "play-failed")
            XCTFail("playback never started; player: \(playerSummary(app) ?? "<none>")")
            return
        }

        // The start position is read after playback starts, and the assertion below is the
        // advance beyond it. Play resumes from the persisted record, so a threshold on the
        // absolute position could be met by the resume value alone; only audio that really
        // advanced while backgrounded can move the clock past it.
        let foregroundOnly = Self.holdsInForeground
        if !foregroundOnly { XCUIDevice.shared.press(.home) }
        let backgrounded = try XCTUnwrap(waitForWallClock(seconds: Self.backgroundHold),
                                         "could not hold\(foregroundOnly ? "" : " in background")")
        if !foregroundOnly { app.activate() }

        // Pause first, then read: the readout of a playing item moves while it is read.
        let toggle = app.descendants(matching: .any)["wilted-player-mini-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "player controls never became reachable")
        toggle.tap()
        // Scaled to the hold, so the threshold cannot be met by a resume value that predates the
        // background period. The margin absorbs the tap-to-tap overhead either side of the hold.
        let floor = backgrounded * 0.6
        let paused = try XCTUnwrap(
            waitForPosition(app, above: started + floor, timeout: 30),
            "position stayed at \(position(app) ?? -1)s after \(backgrounded)s of background audio from \(started)s, "
                + "needed \(floor)s more; player: \(playerSummary(app) ?? "<none>")")
        // Attached on success too: a position only counts as evidence if it tracks the hold.
        record("held=\(backgrounded)s started=\(started)s paused=\(paused)s")

        // The restored position must not rewind: play again after a relaunch resumes from the
        // persisted record, and that record must be at least where the pause left it.
        app.terminate()
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the library did not return after relaunch")
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        play.tap()
        let resumed = try XCTUnwrap(waitForPlaying(app, timeout: 30), "playback did not resume after relaunch")
        record("pausedBeforeRelaunch=\(paused)s resumedAt=\(resumed)s")
        XCTAssertGreaterThanOrEqual(resumed, paused - 2,
                                    "resumed position \(resumed)s rewound from \(paused)s")
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

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The mini player's value, `"<status> · <position> of <duration>"` (for example
    /// "Playing · 12:03 of 40:00"). Nil while no item is loaded.
    private func playerSummary(_ app: XCUIApplication) -> String? {
        let expand = app.descendants(matching: .any)["wilted-player-expand"]
        guard expand.exists else { return nil }
        return expand.value as? String
    }

    /// Failure messages carry what the app reported, because a device journey that fails
    /// without it costs a full rebuild-and-rerun cycle to learn why.
    private func statusText(_ app: XCUIApplication) -> String {
        let banner = app.descendants(matching: .any)["wilted-library-error"]
        if banner.exists { return banner.label }
        return playerSummary(app) ?? "<no status>"
    }

    /// The position in seconds from the summary's `mm:ss` or `h:mm:ss` clock, nil when absent.
    private func position(_ app: XCUIApplication) -> Double? {
        guard let summary = playerSummary(app),
              let clock = summary.components(separatedBy: " · ").last?.components(separatedBy: " of ").first
        else { return nil }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Waits until the mini player reports Playing, then returns the position it reports.
    private func waitForPlaying(_ app: XCUIApplication, timeout: TimeInterval) -> Double? {
        var latest: Double?
        _ = poll(timeout: timeout) {
            guard self.playerSummary(app)?.hasPrefix("Playing") == true, let current = self.position(app) else { return false }
            latest = current
            return true
        }
        return latest
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
