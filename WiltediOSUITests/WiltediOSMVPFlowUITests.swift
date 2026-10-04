import XCTest

/// Exercises the listener's shipping SwiftUI views with a local-only fixture.
@MainActor
final class WiltediOSMVPFlowUITests: XCTestCase {
    func testAccountFreeListenerJourneyDownloadsPlaysResumesAndRecovers() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--wilted-listener-mvp-fixture"]
        app.launch()

        let library = app.descendants(matching: .any)["wilted-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        for title in ["Larder", "Now Playing", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.tabBars.buttons["Downloads"].exists)

        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertEqual(download.elementType, .button)
        download.tap()

        // Remove Download moved into the row's actions menu when the row
        // became two lines. It is still reachable from the list, not only
        // from a screen the listener has to navigate to first.
        let actions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "wilted-listener-item-actions-"))
            .firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["wilted-settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-settings-producer"].label.contains("Unavailable"))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-settings-download-count"].label.contains("1 file"))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-settings-download-bytes"].exists)

        app.tabBars.buttons["Larder"].tap()
        // Downloads is a filter on Larder now. The row is not itself a play
        // action; the explicit Play button owns the interaction.
        let downloadedItem = app.buttons
            .matching(NSPredicate(format: "label == %@", "Play"))
            .firstMatch
        XCTAssertTrue(downloadedItem.waitForExistence(timeout: 5))
        XCTAssertEqual(downloadedItem.elementType, .button)
        downloadedItem.tap()

        let nowPlayingTab = app.tabBars.buttons["Now Playing"]
        nowPlayingTab.tap()
        let player = app.descendants(matching: .any)["wilted-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        XCTAssertTrue((player.value as? String ?? "").contains("12 seconds"), player.value as? String ?? "")

        // The transcript panel is persistent in Now Playing.
        let transcript = app.descendants(matching: .any)["wilted-now-playing-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This local fixture transcript is available without contacting iCloud."].waitForExistence(timeout: 5))

        let nowPlayingControl = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertTrue(nowPlayingControl.waitForExistence(timeout: 5))
        XCTAssertEqual(nowPlayingControl.elementType, .button)
        XCTAssertEqual(nowPlayingControl.label, "Pause")
        nowPlayingControl.tap()
        let status = app.descendants(matching: .any)["wilted-now-playing-status"]
        XCTAssertTrue(waitForLabel("Playback paused", on: status))

        let resumeControl = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertTrue(resumeControl.waitForExistence(timeout: 5))
        XCTAssertEqual(resumeControl.label, "Play")
        resumeControl.tap()
        XCTAssertTrue(waitForLabel("Playing offline", on: status))

        let quarantine = app.descendants(matching: .any)["wilted-listener-fixture-quarantine"]
        XCTAssertTrue(quarantine.waitForExistence(timeout: 5))
        quarantine.tap()

        let recover = app.descendants(matching: .any)["wilted-listener-fixture-recover"]
        XCTAssertTrue(recover.waitForExistence(timeout: 5))
        recover.tap()
        app.tabBars.buttons["Larder"].tap()
        XCTAssertTrue(app.staticTexts["Larder ready"].waitForExistence(timeout: 5))
    }

    // MARK: - Production LibraryRoot over the deterministic fixture

    func testLibraryRootFixtureRendersProductionRootAndPlaysWithoutLiveTransport() {
        let app = launchLibraryRoot(.normal)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let toggle = app.buttons["wilted-player-mini-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel("Pause", on: toggle))
        XCTAssertEqual(fullPlayerStatus(in: app), "Playing")
        assertNoLiveTransport(in: app)
    }

    func testLibraryRootDelayedStartPlaysOnlyAfterTheCacheLookupReturns() {
        let app = launchLibraryRoot(.delayedStart)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        // Every cache lookup is held three seconds, the one that lists the audio as on the phone too.
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        let mini = app.descendants(matching: .any)["wilted-player-mini"]
        XCTAssertFalse(mini.exists)
        let tappedAt = Date()
        play.tap()

        // The start waits on the held lookup, which begins only after the tap, so the engine (and with it
        // the mini player) cannot be reached sooner than the hold. A loaded host only makes this later, so
        // the bound holds where an immediate "not there yet" check would race the hold.
        XCTAssertTrue(mini.waitForExistence(timeout: 15))
        let startedAfter = Date().timeIntervalSince(tappedAt)
        XCTAssertGreaterThanOrEqual(startedAfter, Self.delayedStartHold, "the start did not wait for the held lookup")
        XCTAssertTrue(waitForLabel("Pause", on: app.buttons["wilted-player-mini-toggle"], timeout: 5))
        XCTAssertEqual(fullPlayerStatus(in: app), "Playing")
        assertNoLiveTransport(in: app)
    }

    func testLibraryRootRejectedEngineStartShowsTheFailure() {
        let app = launchLibraryRoot(.startError)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let mini = app.descendants(matching: .any)["wilted-player-mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        let toggle = app.buttons["wilted-player-mini-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Play")
        XCTAssertEqual(fullPlayerStatus(in: app), "Could not play: The audio engine refused to play")
        assertNoLiveTransport(in: app)
    }

    func testLibraryRootThrottledFetchShowsRateLimitBannerAndPausedSync() {
        let app = launchLibraryRoot(.throttled)
        // The first fetch landed before iCloud pushed back, so the Larder still lists the episodes.
        let throttle = app.descendants(matching: .any)["wilted-library-throttle"]
        XCTAssertTrue(throttle.waitForExistence(timeout: 10))
        XCTAssertTrue(throttle.label.hasPrefix("iCloud is rate limiting sync."), throttle.label)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library-error"].exists)

        let status = settingsSyncStatus(in: app)
        XCTAssertTrue(status.label.hasPrefix("Paused"), status.label)
        let detail = app.descendants(matching: .any)["wilted-library-settings-sync-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(detail.label.hasPrefix("iCloud is rate limiting sync."), detail.label)
        assertNoLiveTransport(in: app)
    }

    func testLibraryRootSyncStatusReportsUpToDateAfterTheFixtureFetch() {
        let app = launchLibraryRoot(.normal)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library-throttle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library-error"].exists)
        let status = settingsSyncStatus(in: app)
        XCTAssertTrue(waitForPrefix("Up to date", on: status), status.label)
        assertNoLiveTransport(in: app)
    }

    private static let firstEpisode = "fixture-episode-1"
    /// `LibraryUITestFixture.startDelay` (3 s) less a margin for the two processes' clocks.
    private static let delayedStartHold: TimeInterval = 2.5

    private enum RootScenario: String {
        case normal
        case delayedStart = "delayed-start"
        case startError = "start-error"
        case throttled
    }

    /// Launches the production `LibraryRoot` over the fixture and checks it is that root, not the legacy one.
    private func launchLibraryRoot(_ scenario: RootScenario) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--wilted-library-root-fixture", "--wilted-library-root-scenario=\(scenario.rawValue)",
        ]
        app.launch()

        let marker = app.descendants(matching: .any)["wilted-library-root-fixture"]
        XCTAssertTrue(marker.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(marker.label, "Library root fixture \(scenario.rawValue)")
        for identifier in ["wilted-library-list", "wilted-library-settings-button", "wilted-library-filter"] {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 10), identifier)
        }
        let row = app.descendants(matching: .any)["wilted-library-row-\(Self.firstEpisode)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-library-title-\(Self.firstEpisode)"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-library-count"].exists)

        // No legacy listener root: its library, status line and tab bar are all absent.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-listener-status"].exists)
        XCTAssertFalse(app.tabBars.buttons["Larder"].exists)
        XCTAssertFalse(app.tabBars.buttons["Now Playing"].exists)
        assertNoLiveTransport(in: app)
        return app
    }

    /// The fixture's spy: zero means `LibraryEnvironment.makeModel` never built a live transport.
    private func assertNoLiveTransport(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let marker = app.descendants(matching: .any)["wilted-library-root-fixture"]
        XCTAssertEqual(marker.value as? String, "0", "live transport constructions", file: file, line: line)
    }

    /// Opens the full player from the mini-player and returns its status line.
    private func fullPlayerStatus(in app: XCUIApplication) -> String {
        let expand = app.buttons["wilted-player-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        let status = app.staticTexts["wilted-player-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        return status.label
    }

    /// Opens Settings and scrolls to the sync status line.
    private func settingsSyncStatus(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["wilted-library-settings-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let settings = app.descendants(matching: .any)["wilted-library-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let status = app.staticTexts["wilted-library-settings-sync-status"]
        for _ in 0..<6 where !status.exists { app.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        return status
    }

    private func waitForPrefix(_ prefix: String, on element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", prefix),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
