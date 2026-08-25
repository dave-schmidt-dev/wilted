import XCTest

@MainActor
final class WiltediOSSmokeUITests: XCTestCase {
    func testFourPersistentTabsReachFunctionalListenerViews() {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--wilted-ui-smoke"]
        app.launch()

        let libraryTab = app.tabBars.buttons["Library"]
        let nowPlayingTab = app.tabBars.buttons["Now Playing"]
        let downloadsTab = app.tabBars.buttons["Downloads"]
        let settingsTab = app.tabBars.buttons["Settings"]
        for tab in [libraryTab, nowPlayingTab, downloadsTab, settingsTab] {
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
        }

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

        downloadsTab.tap()
        let downloads = app.descendants(matching: .any)["wilted-downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists)
        XCTAssertTrue(downloadsTab.isSelected)

        settingsTab.tap()
        let settings = app.descendants(matching: .any)["wilted-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let audioSetting = app.descendants(matching: .any)["wilted-audio-setting"]
        XCTAssertTrue(audioSetting.waitForExistence(timeout: 5))
        // The row no longer repeats its card's title; the card is "Audio"
        // and the row states which mode is in use.
        XCTAssertTrue(audioSetting.label.contains("Speech mode"))
        XCTAssertTrue(audioSetting.label.contains("Local speech"))
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
    }
}
