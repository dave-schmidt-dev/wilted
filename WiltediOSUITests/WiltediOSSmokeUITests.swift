import XCTest

@MainActor
final class WiltediOSSmokeUITests: XCTestCase {
    func testLibraryAndDownloadsNavigationJourneyIsAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--wilted-ui-smoke"]
        app.launch()

        let emptyState = app.descendants(matching: .any)["wilted-state-emptyLibrary"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyState.label.contains("Your library is empty"))

        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 5))
        downloadsTab.tap()
        let downloads = app.descendants(matching: .any)["wilted-no-downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        XCTAssertEqual(downloads.label, "No Downloads")

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        let settings = app.descendants(matching: .any)["wilted-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let audioSetting = app.descendants(matching: .any)["wilted-audio-setting"]
        XCTAssertTrue(audioSetting.waitForExistence(timeout: 5))
        XCTAssertTrue(audioSetting.label.contains("Audio"))
    }

    func testPlayingLibraryNavigatesToNowPlayingControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--wilted-ui-fixture-playing"]
        app.launch()

        let openPlayer = app.descendants(matching: .any)["wilted-open-player"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.tap()

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
