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

    /// The story remains readable in the idle Larder when headline speech is turned off.
    func testLibraryRootShowsHeadlineCardAndReadLinkWhileSpeechIsOff() {
        let app = launchLibraryRoot(.headlines)
        XCTAssertTrue(app.staticTexts["Fixture story with a clear Read link"].waitForExistence(timeout: 10))
        let metadata = app.descendants(matching: .any)["wilted-library-headline-metadata-fixture-headline-story"]
        XCTAssertTrue(metadata.exists)
        XCTAssertTrue(metadata.label.contains("Fixture Daily"), metadata.label)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-library-headline-read-fixture-headline-story"].exists)
        XCTAssertTrue(app.buttons["wilted-library-headline-save-fixture-headline-story"].exists)
        XCTAssertTrue(app.buttons["wilted-library-headline-mute-fixture-headline-story"].exists)
        XCTAssertFalse(app.buttons["wilted-player-mini-toggle"].exists, "the card is visible while the player is idle")
        assertNoLiveTransport(in: app)
    }

    /// The spoken item can differ from the newest catalog card; Now Playing names and links the actual item.
    func testNowPlayingShowsTheSpokenStoryAmongTwoCandidatesAndKeepsItsReadLink() {
        let app = launchLibraryRoot(.spokenHeadlines)
        XCTAssertTrue(app.staticTexts["Newest headline in the Larder"].waitForExistence(timeout: 5))
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let expand = app.buttons["wilted-player-expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        let state = app.descendants(matching: .any)["wilted-player-headline-state"]
        let forward = app.buttons["wilted-player-forward"]
        XCTAssertTrue(waitForLabel("Reading this story", on: state, timeout: 10),
                      "the fixture advances through its prepared ad seam before speaking")

        let card = app.descendants(matching: .any)["wilted-player-headline-story-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let title = app.staticTexts["wilted-player-headline-title"]
        XCTAssertEqual(title.label, "The story being spoken")
        XCTAssertEqual(app.staticTexts["wilted-player-headline-publisher"].label, "Example Dispatch")
        let read = app.descendants(matching: .any)["wilted-player-headline-read-fixture-story-spoken"]
        XCTAssertTrue(read.exists)
        XCTAssertEqual(read.value as? String, "https://example.com/spoken-story")
        XCTAssertEqual(state.label, "Reading this story")

        forward.tap()
        XCTAssertTrue(waitForLabel("Newest headline in the Larder", on: title, timeout: 5))
        XCTAssertEqual(state.label, "Reading this story")
        XCTAssertEqual(app.staticTexts["wilted-player-headline-publisher"].label, "Newer Daily")
        let nextRead = app.descendants(matching: .any)["wilted-player-headline-read-fixture-story-newer"]
        XCTAssertTrue(nextRead.waitForExistence(timeout: 5))
        XCTAssertEqual(nextRead.value as? String, "https://example.com/newer-story")

        forward.tap()
        XCTAssertTrue(waitForLabel("Last story read", on: state, timeout: 5))
        XCTAssertEqual(title.label, "Newest headline in the Larder")
        XCTAssertEqual(nextRead.value as? String, "https://example.com/newer-story")
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
        XCTAssertFalse(app.descendants(matching: .any)["wilted-author-publication"].exists)

        let status = settingsSyncStatus(in: app)
        XCTAssertTrue(status.label.hasPrefix("Paused"), status.label)
        // A paused sync is not an error: the Larder banner above explains it, and Settings adds no
        // detail row.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library-settings-sync-detail"].exists)
        assertNoLiveTransport(in: app)
    }

    func testPlayerEpisodeActionsKeepBothNamesAndAskBeforeActing() {
        let app = launchLibraryRoot(.normal)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let toggle = app.buttons["wilted-player-mini-toggle"]
        XCTAssertTrue(waitForLabel("Pause", on: toggle))
        toggle.tap()
        XCTAssertEqual(fullPlayerStatus(in: app), "Paused")

        let menu = app.buttons["wilted-player-episode-actions"]
        let actions = [("wilted-player-mark-completed", "Mark completed", "Mark completed?"),
                       ("wilted-player-remove-from-larder", "Remove from Larder", "Remove from the Larder?")]
        for (identifier, label, question) in actions {
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            let choice = app.buttons[identifier]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertEqual(choice.label, label)
            choice.tap()
            XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[label].exists)
            // iOS 26 anchors the question to the menu button as a popover, which has no Cancel button;
            // tapping outside it cancels the same way.
            let cancel = app.buttons["Cancel"]
            if cancel.waitForExistence(timeout: 2) {
                cancel.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            }
            XCTAssertTrue(app.staticTexts[question].waitForNonExistence(timeout: 5), "the question closes without acting")
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Cancelling leaves the episode available")
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

    /// The native cancel action keeps the real saved mirror despite an empty fixture Mac queue.
    func testLibraryRootKeepHeldPreservesSavedLibraryAndDownloads() {
        let app = launchLibraryRoot(.heldAccount)
        let review = openHeldSettings(in: app)
        assertCachedEpisodes(2, in: app)
        review.tap()
        guard let alert = accountAlert(in: app),
              let action = accountAlertAction(identifier: "wilted-account-keep-held", label: "Keep held", in: alert) else { return }
        action.tap()
        XCTAssertTrue(waitForDisappearance(of: alert))
        XCTAssertTrue(review.exists)
        assertCachedEpisodes(2, in: app)
        app.buttons["wilted-library-settings-done"].tap()
        for episode in 1...2 {
            XCTAssertTrue(app.descendants(matching: .any)["wilted-library-row-fixture-episode-\(episode)"].exists)
        }
        XCTAssertFalse(app.descendants(matching: .any)["wilted-library-empty"].exists)
        _ = openHeldSettings(in: app)
        assertCachedEpisodes(2, in: app)
        assertNoLiveTransport(in: app)
    }

    /// Native approval executes production recovery, removes scratch audio and fetches the empty Mac.
    func testLibraryRootConfirmedReplacementClearsDownloadsAndFetchesEmptyLibrary() {
        let app = launchLibraryRoot(.heldAccount)
        let review = openHeldSettings(in: app)
        assertCachedEpisodes(2, in: app)
        review.tap()
        guard let alert = accountAlert(in: app),
              let action = accountAlertAction(identifier: "wilted-account-confirm", label: "Replace saved library", in: alert) else { return }
        action.tap()
        XCTAssertTrue(waitForDisappearance(of: alert))
        XCTAssertTrue(waitForDisappearance(of: review))
        let status = app.staticTexts["wilted-library-settings-sync-status"]
        XCTAssertTrue(waitForPrefix("Fetched · ", on: status), status.label)
        let count = app.staticTexts["wilted-library-settings-cache-size"]
        XCTAssertTrue(waitForLabel("None", on: count), count.label)
        app.buttons["wilted-library-settings-done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["wilted-library-empty"].waitForExistence(timeout: 10))
        for episode in 1...2 {
            XCTAssertFalse(app.descendants(matching: .any)["wilted-library-row-fixture-episode-\(episode)"].exists)
        }
        XCTAssertFalse(app.buttons["wilted-player-mini-toggle"].exists)
        _ = settingsSyncStatus(in: app)
        XCTAssertFalse(app.buttons["wilted-use-current-account"].exists)
        assertCachedEpisodes(0, in: app)
        assertNoLiveTransport(in: app)
    }

    /// Native presses exercise the shipping hold gesture over real prepared fixture audio.
    func testLibraryRootTapSkipsAndHeldSeekingStopOnRelease() throws {
        let app = launchLibraryRoot(.normal)
        let play = app.buttons["wilted-library-play-\(Self.firstEpisode)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let miniToggle = app.buttons["wilted-player-mini-toggle"]
        XCTAssertTrue(waitForLabel("Pause", on: miniToggle))
        miniToggle.tap()
        XCTAssertTrue(waitForLabel("Play", on: miniToggle))
        XCTAssertEqual(fullPlayerStatus(in: app), "Paused")

        let scrubber = app.descendants(matching: .any)["wilted-player-scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let initial = try holdJourneyPosition(scrubber)
        let forward = app.buttons["wilted-player-forward"]
        let backward = app.buttons["wilted-player-back"]
        XCTAssertTrue(forward.isHittable)
        XCTAssertTrue(backward.isHittable)
        forward.tap()
        XCTAssertEqual(try holdJourneyPosition(scrubber), initial + 30)
        forward.tap()
        XCTAssertEqual(try holdJourneyPosition(scrubber), initial + 60)
        backward.tap()
        let beforeForwardHold = try holdJourneyPosition(scrubber)
        XCTAssertEqual(beforeForwardHold, initial + 45)

        forward.press(forDuration: 1.4)
        let afterForwardHold = try holdJourneyPosition(scrubber)
        XCTAssertGreaterThan(afterForwardHold - beforeForwardHold, 0)
        XCTAssertLessThan(afterForwardHold - beforeForwardHold, 15,
                          "8x hold movement must exclude an accidental 30-second tap")
        XCTAssertTrue(waitForLabel("Play", on: app.buttons["wilted-player-toggle"]))
        let forwardReleased = try XCTUnwrap(scrubber.value as? String)
        let forwardChanges = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", forwardReleased), object: scrubber)
        forwardChanges.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [forwardChanges], timeout: 1.4), .completed,
                       "release must stop seeking while the prepared fixture remains paused")

        backward.press(forDuration: 1.4)
        let afterBackwardHold = try holdJourneyPosition(scrubber)
        XCTAssertGreaterThan(afterForwardHold - afterBackwardHold, 0)
        XCTAssertLessThan(afterForwardHold - afterBackwardHold, 15,
                          "a recognized backward hold must not also perform its 15-second tap")
        XCTAssertTrue(waitForLabel("Play", on: app.buttons["wilted-player-toggle"]))
        let backwardReleased = try XCTUnwrap(scrubber.value as? String)
        let backwardChanges = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", backwardReleased), object: scrubber)
        backwardChanges.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [backwardChanges], timeout: 1.4), .completed)

        app.buttons["wilted-player-done"].tap()
        let miniScrubber = app.descendants(matching: .any)["wilted-player-mini-scrubber"].firstMatch
        XCTAssertTrue(miniScrubber.waitForExistence(timeout: 5))
        XCTAssertEqual(try holdJourneyPosition(miniScrubber), afterBackwardHold)
        let miniBack = app.buttons["wilted-player-mini-back"]
        XCTAssertTrue(miniBack.isHittable)
        miniBack.press(forDuration: 1.4)
        let afterMiniHold = try holdJourneyPosition(miniScrubber)
        XCTAssertGreaterThan(afterBackwardHold - afterMiniHold, 0)
        XCTAssertLessThan(afterBackwardHold - afterMiniHold, 15)
        XCTAssertTrue(waitForLabel("Play", on: miniToggle))
        let miniReleased = try XCTUnwrap(miniScrubber.value as? String)
        let miniChanges = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", miniReleased), object: miniScrubber)
        miniChanges.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [miniChanges], timeout: 1.4), .completed)
        XCTAssertEqual(fullPlayerStatus(in: app), "Paused")
        XCTAssertEqual(try holdJourneyPosition(scrubber), afterMiniHold)
        assertNoLiveTransport(in: app)
    }

    private func openHeldSettings(in app: XCUIApplication) -> XCUIElement {
        let status = settingsSyncStatus(in: app)
        XCTAssertTrue(status.label.hasPrefix("Needs review"), status.label)
        let settings = app.descendants(matching: .any)["wilted-library-settings"]
        let review = settings.buttons["wilted-use-current-account"]
        for _ in 0..<6 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(review.isHittable)
        return review
    }

    private func accountAlert(in app: XCUIApplication) -> XCUIElement? {
        let alerts = app.alerts.matching(NSPredicate(format: "label == %@", "Review this library"))
        let unique = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in alerts.count == 1 }, object: nil)
        guard XCTWaiter.wait(for: [unique], timeout: 5) == .completed else {
            XCTFail("Expected one native account review alert. \(app.debugDescription)")
            return nil
        }
        let alert = alerts.element(boundBy: 0)
        XCTAssertNotNil(accountAlertAction(identifier: "wilted-account-keep-held", label: "Keep held", in: alert))
        XCTAssertNotNil(accountAlertAction(identifier: "wilted-account-confirm", label: "Replace saved library", in: alert))
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("attempt removal of its old downloads"), message)
        XCTAssertTrue(message.contains("Keep held preserves"), message)
        return alert
    }

    /// Native alert accessibility exposes a parent and child Button for each action.
    private func accountAlertAction(identifier: String, label: String, in alert: XCUIElement) -> XCUIElement? {
        let leaves = alert.buttons.matching(identifier: identifier).allElementsBoundByIndex.filter {
            $0.label == label && $0.descendants(matching: .button).count == 0
        }
        guard leaves.count == 1 else {
            XCTFail("Expected one leaf action \(identifier). \(alert.debugDescription)")
            return nil
        }
        let action = leaves[0]
        guard action.isHittable else {
            XCTFail("Native account action is not hittable: \(identifier). \(alert.debugDescription)")
            return nil
        }
        return action
    }

    private func assertCachedEpisodes(_ expected: Int, in app: XCUIApplication) {
        let count = app.staticTexts["wilted-library-settings-cache-size"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(expected == 0 ? count.label == "None" : count.label.hasPrefix("\(expected) episodes"), count.label)
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
        case headlines
        case spokenHeadlines = "spoken-headlines"
        case delayedStart = "delayed-start"
        case startError = "start-error"
        case throttled
        case heldAccount = "held-account"
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
    /// Parses the shipping LibraryPlayerText.position clock, never slider percentages.
    private func holdJourneyPosition(_ scrubber: XCUIElement) throws -> Double {
        let value = try XCTUnwrap(scrubber.value as? String)
        let clocks = value.components(separatedBy: " of ")
        XCTAssertEqual(clocks.count, 2, value)
        XCTAssertEqual(clocks.last, "10:00", "the prepared fixture engine has 600-second duration")
        let clock = try XCTUnwrap(clocks.first)
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        XCTAssertTrue(parts.count == 2 || parts.count == 3, value)
        var seconds = 0
        for part in parts {
            let component = try XCTUnwrap(Int(part), value)
            XCTAssertGreaterThanOrEqual(component, 0, value)
            seconds = seconds * 60 + component
        }
        return Double(seconds)
    }


}
