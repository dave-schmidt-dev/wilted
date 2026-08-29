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

        // The transcript left the library row when the row became two lines.
        // Now Playing is where it is read, and it is still one tap away.
        let transcript = app.buttons["Transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.tap()
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "quarantined")).firstMatch.waitForExistence(timeout: 5))

        let recover = app.descendants(matching: .any)["wilted-listener-fixture-recover"]
        XCTAssertTrue(recover.waitForExistence(timeout: 5))
        recover.tap()
        XCTAssertTrue(app.staticTexts["Larder ready"].waitForExistence(timeout: 5))
    }

    private func waitForLabel(_ label: String, on element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
