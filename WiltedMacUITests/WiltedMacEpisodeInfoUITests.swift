import XCTest

@MainActor
final class WiltedMacEpisodeInfoUITests: XCTestCase {
    private var latestFixtureRoot: URL?
    private let savedNotes = "A walk through the machines that keep the field office quiet."
    private let savedTranscript = "Welcome back to Field Notes. Today, the machines that keep the office quiet."

    func testTranscriptRetryReadsAgainAndShowsSavedText() throws {
        let app = try launchFixture(extraArguments: ["--wilted-ui-fixture-transcript-read-fails-once"])
        let id = openFeedsNotes(app)
        let notes = element(app, "wilted-feeds-notes-text-\(id)")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        selectTab(app, prefix: "wilted-feeds", id: id, label: "Transcript")
        let error = element(app, "wilted-feeds-transcript-error-\(id)")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(words(error).contains("Could not read the saved transcript."))
        try assertReadCounts(id: id, info: 0, transcript: 1)
        attachWindow(app, name: "Transcript read failure with Retry")
        let retry = app.buttons["wilted-feeds-notes-retry-\(id)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        let text = element(app, "wilted-feeds-transcript-text-\(id)")
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(words(text).contains(savedTranscript))
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        try assertReadCounts(id: id, info: 0, transcript: 2)
        selectTab(app, prefix: "wilted-feeds", id: id, label: "Notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        selectTab(app, prefix: "wilted-feeds", id: id, label: "Transcript")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        try assertReadCounts(id: id, info: 0, transcript: 2)
        attachWindow(app, name: "Transcript Retry recovered saved text")
        closePopover(app, prefix: "wilted-feeds", id: id)
    }

    func testByIDRetryLoadsNotesAfterFailure() throws {
        let app = try launchFixture(extraArguments: ["--wilted-ui-fixture-info-read-fails-once"])
        let id = openFeedsNotes(app)
        XCTAssertTrue(element(app, "wilted-feeds-notes-text-\(id)").waitForExistence(timeout: 10))
        closePopover(app, prefix: "wilted-feeds", id: id)
        let skip = app.buttons["wilted-feeds-skip-\(id)"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.click()
        let offList = element(app, "wilted-feeds-off-list-toggle")
        XCTAssertTrue(offList.waitForExistence(timeout: 5))
        offList.click()
        let title = app.buttons["wilted-feed-history-show-notes-\(id)"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.click()
        let error = element(app, "wilted-feed-history-notes-popover-\(id)")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        let retry = app.buttons["wilted-feed-history-notes-retry-\(id)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(words(error).contains("Could not load this episode's details."))
        try assertReadCounts(id: id, info: 1, transcript: 0)
        attachWindow(app, name: "History by-ID failure with Retry")
        retry.click()
        let notes = element(app, "wilted-feed-history-notes-text-\(id)")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        XCTAssertTrue(words(notes).contains(savedNotes))
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
        try assertReadCounts(id: id, info: 2, transcript: 0)
        attachWindow(app, name: "History Retry recovered stored notes")
        closePopover(app, prefix: "wilted-feed-history", id: id)
    }

    func testEpisodeInfoJourneyAcrossFeedsHistoryAndPlayer() throws {
        let app = try launchFixture()
        let feeds = element(app, "wilted-navigation-feeds")
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()
        let title = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-show-notes-'")
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let episodeID = String(title.identifier.dropFirst("wilted-feeds-show-notes-".count))
        XCTAssertFalse(episodeID.isEmpty)
        title.click()
        assertNotesThenTranscript(app, prefix: "wilted-feeds", id: episodeID)
        closePopover(app, prefix: "wilted-feeds", id: episodeID)

        // Skip retires media, but its History title must still resolve the
        // stored episode notes and transcript after the row leaves the inbox.
        let skip = app.buttons["wilted-feeds-skip-\(episodeID)"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))
        let offList = element(app, "wilted-feeds-off-list-toggle")
        XCTAssertTrue(offList.waitForExistence(timeout: 5))
        offList.click()
        let historyTitle = app.buttons["wilted-feed-history-show-notes-\(episodeID)"]
        XCTAssertTrue(historyTitle.waitForExistence(timeout: 10))
        historyTitle.click()
        assertNotesThenTranscript(app, prefix: "wilted-feed-history", id: episodeID)
        closePopover(app, prefix: "wilted-feed-history", id: episodeID)

        // Retirement removed the playable revision. A fresh, owned fixture
        // gives the player a prepared episode without assuming Restore also
        // reacquires media from the synthetic feed's unreachable URL.
        app.terminate()
        let playing = try launchFixture()
        let playingFeeds = element(playing, "wilted-navigation-feeds")
        XCTAssertTrue(playingFeeds.waitForExistence(timeout: 10))
        playingFeeds.click()
        let keep = playing.buttons["wilted-feeds-keep-\(episodeID)"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        keep.click()
        element(playing, "wilted-navigation-larder").click()
        let play = playing.buttons["wilted-larder-play-\(episodeID)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let playReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: play)
        if XCTWaiter().wait(for: [playReady], timeout: 3) == .completed {
            play.click()
        } else {
            // The captured fixture shows this Ready-row Play control visibly
            // inside the window even when XCTest rejects its AX click.
            let window = playing.windows.firstMatch
            guard play.exists, play.isEnabled, play.label == "Play Quiet Machines now",
                  play.frame.width > 0, play.frame.height > 0,
                  window.exists, window.frame.contains(play.frame) else {
                return XCTFail("The exact episode's enabled Play button must be visible inside its fixture window")
            }
            play.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        // Settings leaves the player visible while keeping the Larder title
        // out of the query, so this click proves the actual player entry point.
        element(playing, "wilted-navigation-settings").click()
        let playerTitle = playing.buttons["wilted-player-show-notes-\(episodeID)"]
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 10))
        playerTitle.click()
        let playerNotes = element(playing, "wilted-player-notes-text-\(episodeID)")
        XCTAssertTrue(playerNotes.waitForExistence(timeout: 10))
        XCTAssertTrue(words(playerNotes).contains(savedNotes))
        attachWindow(playing, name: "Player episode notes")
        closePopover(playing, prefix: "wilted-player", id: episodeID)
    }

    private func assertNotesThenTranscript(_ app: XCUIApplication, prefix: String, id: String) {
        let notes = element(app, "\(prefix)-notes-text-\(id)")
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "Notes is the default tab")
        XCTAssertTrue(words(notes).contains(savedNotes), "the exact episode's saved notes are readable")
        let transcript = element(app, "\(prefix)-transcript-text-\(id)")
        XCTAssertFalse(transcript.exists, "Transcript is loaded when its tab is opened")
        attachWindow(app, name: "\(prefix) episode notes")
        let tabs = element(app, "\(prefix)-notes-tabs-\(id)")
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        selectTab(app, prefix: prefix, id: id, label: "Transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "the saved transcript read completes")
        XCTAssertTrue(words(transcript).contains(savedTranscript), "the saved fixture transcript survives retirement")
        XCTAssertFalse(element(app, "\(prefix)-transcript-none-\(id)").exists)
        XCTAssertFalse(element(app, "\(prefix)-transcript-error-\(id)").exists)
        attachWindow(app, name: "\(prefix) saved transcript")
    }

    private func closePopover(_ app: XCUIApplication, prefix: String, id: String) {
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "\(prefix)-notes-popover-\(id)").waitForNonExistence(timeout: 5),
                      "Escape closes the episode info popover")
    }

    private func openFeedsNotes(_ app: XCUIApplication) -> String {
        let feeds = element(app, "wilted-navigation-feeds")
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()
        let title = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-show-notes-'")
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let id = String(title.identifier.dropFirst("wilted-feeds-show-notes-".count))
        XCTAssertFalse(id.isEmpty)
        title.click()
        return id
    }

    private func selectTab(_ app: XCUIApplication, prefix: String, id: String, label: String) {
        let tabs = element(app, "\(prefix)-notes-tabs-\(id)")
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        let radio = tabs.radioButtons[label]
        let button = tabs.buttons[label]
        let tab = radio.exists ? radio : (button.exists ? button : tabs.descendants(matching: .any)[label])
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
    }

    private func assertReadCounts(id: String, info: Int, transcript: Int) throws {
        let root = try XCTUnwrap(latestFixtureRoot)
        let data = try Data(contentsOf: root.appendingPathComponent("episode-info-ui-read-counts.json"))
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(counts["episodeID"] as? String, id)
        XCTAssertEqual(counts["info"] as? Int, info)
        XCTAssertEqual(counts["transcript"] as? Int, transcript)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func words(_ element: XCUIElement) -> String {
        ([element] + element.staticTexts.allElementsBoundByIndex).map {
            [$0.label, $0.value as? String ?? ""].joined(separator: " ")
        }.joined(separator: " ")
    }

    private func attachWindow(_ app: XCUIApplication, name: String) {
        guard app.windows.firstMatch.exists else { return }
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFixture(extraArguments: [String] = []) throws -> XCUIApplication {
        let root = try WiltedMacUITemporaryState.fixtureRoot(prefix: "wilted-episode-info-ui-test")
        let app = XCUIApplication()
        addTeardownBlock { [weak self, app, root] in
            if (self?.testRun?.totalFailureCount ?? 0) > 0 {
                self?.attachWindow(app, name: "Episode info failure")
            }
            app.terminate()
            try WiltedMacUITemporaryState.removeFixtureRoot(root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        latestFixtureRoot = root
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "--wilted-ui-fixture-ready",
            "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared",
            "--wilted-ui-fixture-window-width", "1400",
            "--wilted-ui-fixture-state-directory", root.path,
        ] + extraArguments
        app.launch()
        try WiltedMacUITestApplicationLaunch.reopenFixture(app)
        app.activate()
        if !app.wait(for: .runningForeground, timeout: 10) {
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }
}
