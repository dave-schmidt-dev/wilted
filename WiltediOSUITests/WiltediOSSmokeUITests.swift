import XCTest

@MainActor
final class WiltediOSSmokeUITests: XCTestCase {
    func testThreePersistentTabsReachFunctionalListenerViews() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--wilted-ui-smoke"]
        app.launch()

        let libraryTab = app.tabBars.buttons["Larder"]
        let nowPlayingTab = app.tabBars.buttons["Now Playing"]
        let settingsTab = app.tabBars.buttons["Settings"]
        for tab in [libraryTab, nowPlayingTab, settingsTab] {
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
        }
        // Downloads was a strict subset of Library rendered with the same
        // card and the same actions. It is a filter on Library now, so a
        // fourth tab would be the redundancy this removed.
        XCTAssertFalse(app.tabBars.buttons["Downloads"].exists)

        let library = app.descendants(matching: .any)["wilted-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-listener-refresh"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-listener-status"].exists)
        XCTAssertTrue(app.navigationBars.firstMatch.exists)

        nowPlayingTab.tap()
        let emptyPlayer = app.descendants(matching: .any)["wilted-player-empty"]
        XCTAssertTrue(emptyPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyPlayer.label.contains("Nothing is playing"))
        XCTAssertTrue(app.navigationBars["Now Playing"].exists)

        libraryTab.tap()
        let scope = app.descendants(matching: .any)["wilted-library-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        app.buttons["Downloads"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["wilted-downloads-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists)

        settingsTab.tap()
        let settings = app.descendants(matching: .any)["wilted-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let audioSetting = app.descendants(matching: .any)["wilted-audio-setting"]
        XCTAssertFalse(audioSetting.exists)
        XCTAssertTrue(settingsTab.isSelected)

        libraryTab.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 5))
    }

    func testActiveNowPlayingTabExposesAllTransportControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--wilted-ui-fixture-playing"]
        app.launch()

        let nowPlayingTab = app.tabBars.buttons["Now Playing"]
        XCTAssertTrue(nowPlayingTab.waitForExistence(timeout: 5))
        XCTAssertTrue(nowPlayingTab.isSelected)

        let player = app.descendants(matching: .any)["wilted-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        XCTAssertTrue(player.label.contains("Now Playing"))
        let rewind = app.descendants(matching: .any)["wilted-player-rewind"]
        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        let forward = app.descendants(matching: .any)["wilted-player-forward"]
        XCTAssertTrue(rewind.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        XCTAssertEqual(rewind.label, "Rewind 15 seconds")
        XCTAssertEqual(playPause.label, "Pause")
        XCTAssertEqual(forward.label, "Skip forward 30 seconds")
        let restart = app.descendants(matching: .any)["wilted-listener-restart"]
        let transcript = app.descendants(matching: .any)["wilted-now-playing-transcript"]
        XCTAssertTrue(restart.exists)
        XCTAssertTrue(transcript.exists)
        XCTAssertLessThan(restart.frame.maxY, transcript.frame.minY)
        XCTAssertGreaterThan(transcript.frame.height, restart.frame.height)
        transcript.swipeUp()
        XCTAssertTrue(restart.exists)
    }
}
