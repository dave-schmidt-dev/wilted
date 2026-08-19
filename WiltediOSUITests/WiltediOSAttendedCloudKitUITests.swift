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

        let player = app.descendants(matching: .any)[WiltedAttendedIdentifiers.player]
        if !player.waitForExistence(timeout: 30) {
            attachScreenshot(app, named: "play-failed")
            XCTFail("now playing never appeared; status: \(statusText(app))")
        }

        let started = try XCTUnwrap(position(app), "no position readout")
        let advanced = try XCTUnwrap(waitForPosition(app, above: started, timeout: 30),
                                     "playback position never advanced past \(started)s")

        // Background playback: the position must keep moving while the app is not frontmost,
        // which is the only way to tell real background audio from a UI timer.
        XCUIDevice.shared.press(.home)
        let backgrounded = try XCTUnwrap(waitForWallClock(seconds: 8), "could not hold in background")
        app.activate()
        XCTAssertTrue(player.waitForExistence(timeout: 30))
        let afterBackground = try XCTUnwrap(position(app), "no position readout after foregrounding")
        XCTAssertGreaterThan(afterBackground, advanced + 4,
                             "position moved \(afterBackground - advanced)s across \(backgrounded)s in the background")

        let send = app.descendants(matching: .any)["wilted-listener-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        if send.isEnabled { send.tap() }
        // Only a completed send reaches "Library ready". A queue held by conflicts reports
        // "Nothing was sent…", which a settled-looking status check would have accepted as
        // success: that is precisely the failure this journey has to be able to see.
        XCTAssertTrue(waitForStatus(app, equalTo: "Library ready", timeout: 120),
                      "playback send never completed; status: \(statusText(app))")

        // Reconciliation across relaunch: the restored position must not rewind.
        let beforeRelaunch = try XCTUnwrap(position(app), "no position readout before relaunch")
        app.terminate()
        app.launch()
        XCTAssertTrue(player.waitForExistence(timeout: 60), "playback was not restored after relaunch")
        let restored = try XCTUnwrap(position(app), "no position readout after relaunch")
        XCTAssertGreaterThanOrEqual(restored, beforeRelaunch - 2,
                                    "restored position \(restored)s rewound from \(beforeRelaunch)s")
    }

    // MARK: - Helpers

    private enum WiltedAttendedIdentifiers {
        static let player = "wilted-player"
        static let status = "wilted-listener-status"
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
        return status.exists ? status.label : "<no status>"
    }

    /// The now-playing readout is `"<position> / <duration> seconds"`.
    private func position(_ app: XCUIApplication) -> Double? {
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
