import XCTest

/// Exercises the production `LibraryRoot` over a local-only fixture.
@MainActor
final class WiltediOSMVPFlowUITests: XCTestCase {
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

    /// PLAY-DELAY on the production root: while the held cache lookup runs, the mini-player already
    /// says the start is pending, and nothing is loaded; then the episode plays.
    func testLibraryRootDelayedStartShowsStartingPlaybackUntilTheLookupReturns() {
        let app = launchLibraryRoot(.delayedStart)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        // Every cache lookup is held three seconds, the one that lists the audio as on the phone too.
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        let mini = app.descendants(matching: .any)["wilted-player-mini"]
        XCTAssertFalse(mini.exists)
        let tappedAt = Date()
        play.tap()

        // The held lookup begins only after the tap. The pending start is checked only while the hold is
        // certainly still running (a loaded host can reach this line late), and the engine (the Pause label)
        // can never be reached sooner than the hold, however loaded the host is.
        let expand = app.buttons["wilted-player-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 2))
        // Read first, then time the read: the query itself can be slow, so only a value observed inside
        // the window is judged.
        let pendingValue = expand.value as? String
        if Date().timeIntervalSince(tappedAt) < Self.pendingCheckWindow {
            XCTAssertEqual(pendingValue, Self.starting, "the pending start is shown while the file is looked up")
        }
        XCTAssertTrue(waitForLabel("Pause", on: app.buttons["wilted-player-mini-toggle"], timeout: 15))
        let startedAfter = Date().timeIntervalSince(tappedAt)
        XCTAssertGreaterThanOrEqual(startedAfter, Self.delayedStartHold, "the start did not wait for the held lookup")
        XCTAssertEqual(fullPlayerStatus(in: app), "Playing")
        assertNoLiveTransport(in: app)
    }

    /// RACE phone on the production root: a second press while the start is pending joins it. Before
    /// Task 3.2 the second press made its own lookup and toggled the fresh start back to paused.
    func testLibraryRootDuplicatePressWhileStartingMakesOneStart() {
        let app = launchLibraryRoot(.delayedStart)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        play.tap()

        let toggle = app.buttons["wilted-player-mini-toggle"]
        XCTAssertTrue(waitForLabel("Pause", on: toggle, timeout: 15))
        // Past any second lookup the old code would have made, it never flips to paused.
        XCTAssertFalse(waitForLabel("Play", on: toggle, timeout: 4), "a duplicate start toggled the episode off")
        XCTAssertEqual(fullPlayerStatus(in: app), "Playing")
        assertNoLiveTransport(in: app)
    }

    /// PLAY-FAIL / FAIL phone on the production root: a refused engine reads as the canonical failure
    /// with Retry, and a refused Retry keeps it.
    func testLibraryRootRejectedEngineStartShowsTheFailure() {
        let app = launchLibraryRoot(.startError)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let expand = app.buttons["wilted-player-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(Self.refused, on: expand), String(describing: expand.value))
        let retry = app.buttons["wilted-player-mini-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(retry.label, "Retry playback")
        retry.tap()
        XCTAssertTrue(waitForValue(Self.refused, on: expand), "the fixture engine refuses every play")
        XCTAssertEqual(fullPlayerStatus(in: app), Self.refused)
        XCTAssertTrue(app.buttons["wilted-player-retry"].waitForExistence(timeout: 5))
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
        // A paused sync is not an error, so its detail sits in the Diagnostics disclosure (CI-7). The
        // disclosure starts collapsed; scroll to it, expand it, then find the detail inside.
        let disclosure = app.descendants(matching: .any)["wilted-library-settings-diagnostics-disclosure"]
        for _ in 0..<6 where !disclosure.exists { app.swipeUp() }
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), app.debugDescription)
        disclosure.tap()
        let detail = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "iCloud is rate limiting sync.")).firstMatch
        for _ in 0..<6 where !detail.exists { app.swipeUp() }
        XCTAssertTrue(detail.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(detail.label.hasPrefix("iCloud is rate limiting sync."), detail.label)
        assertNoLiveTransport(in: app)
    }

    /// Sort and Group are display only: choosing them says playback still follows the play order, groups
    /// the list under its feed, and an episode still plays from the changed list. Every menu step comes
    /// before the play tap: while audio plays the UI never goes idle, and each later step waits out
    /// XCUITest's 60 s animation timeout.
    func testLibraryRootSortAndGroupAreDisplayOnly() {
        let app = launchLibraryRoot(.normal)
        let organize = app.buttons["wilted-library-organize"]
        XCTAssertTrue(organize.waitForExistence(timeout: 10))
        let note = app.descendants(matching: .any)["wilted-library-order-note"].firstMatch
        let group = app.descendants(matching: .any)["wilted-library-group-Fixture Show"].firstMatch
        let count = app.descendants(matching: .any)["wilted-library-count"].firstMatch
        XCTAssertFalse(note.exists, "the default is the play order, with nothing to explain")

        organize.tap()
        app.buttons["Newest"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("Sorted by Newest"), note.label)
        XCTAssertTrue(note.label.contains("play order"), note.label)
        organize.tap()
        app.buttons["Play order"].tap()
        XCTAssertTrue(waitForDisappearance(of: note))

        organize.tap()
        app.buttons["Feed"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        organize.tap()
        app.buttons["No Grouping"].tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertFalse(group.exists)

        organize.tap()
        app.buttons["Newest"].tap()
        organize.tap()
        app.buttons["Feed"].tap()
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(note.exists)

        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let toggle = app.buttons["wilted-player-mini-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel("Pause", on: toggle))
        assertNoLiveTransport(in: app)
    }

    func testLibraryRootSyncStatusNamesThePhoneFetchAfterTheFixtureFetch() {
        let app = launchLibraryRoot(.normal)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library-throttle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library-error"].exists)
        let status = settingsSyncStatus(in: app)
        XCTAssertTrue(waitForPrefix("Fetched · ", on: status), status.label)
        assertNoLiveTransport(in: app)
    }

    private static let firstEpisode = "fixture-episode-1"
    /// `LibraryUITestFixture.startDelay` (3 s) less a margin for the two processes' clocks.
    private static let delayedStartHold: TimeInterval = 2.5
    /// How soon after the tap the pending label is still certainly showing inside the 3 s hold.
    private static let pendingCheckWindow: TimeInterval = 1.5
    private static let starting = "Starting playback…"
    private static let refused = "Playback refused. Your position is kept."

    private enum RootScenario: String {
        case normal
        case delayedStart = "delayed-start"
        case startError = "start-error"
        case throttled
    }

    /// Launches the production `LibraryRoot` over the fixture and checks it is that root.
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

        // The retired listener root's status line and tab bar are absent.
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

    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
