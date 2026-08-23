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

        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()

        let remove = app.buttons["Remove Download"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))

        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 5))
        downloadsTab.tap()
        let downloadedItem = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "A fixture article for listening")
        ).firstMatch
        XCTAssertTrue(downloadedItem.waitForExistence(timeout: 5))
        downloadedItem.tap()

        let libraryTab = app.tabBars.buttons["Library"]
        libraryTab.tap()
        let player = app.descendants(matching: .any)["wilted-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        XCTAssertTrue(player.value as? String == "12 seconds")

        let nowPlayingControl = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertTrue(nowPlayingControl.waitForExistence(timeout: 5))
        XCTAssertEqual(nowPlayingControl.label, "Pause")
        nowPlayingControl.tap()
        let status = app.descendants(matching: .any)["wilted-listener-status"]
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
        XCTAssertTrue(app.staticTexts["Library ready"].waitForExistence(timeout: 5))
    }

    private func waitForLabel(_ label: String, on element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
