import XCTest

@MainActor
final class WiltedMacSmokeUITests: XCTestCase {
    func testLibraryEmptyStateAndArticleActionAreAccessible() {
        let app = launch(arguments: ["--wilted-ui-smoke"])

        let library = app.descendants(matching: .any)["wilted-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))

        let emptyState = app.descendants(matching: .any)["wilted-state-emptyLibrary"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyState.label.contains("Your library is empty"))

        let addArticle = app.descendants(matching: .any)["wilted-add-article"]
        XCTAssertTrue(addArticle.waitForExistence(timeout: 5))
        XCTAssertTrue(addArticle.isEnabled)
    }

    func testReadyLibraryNavigatesToNowPlayingControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let openPlayer = app.descendants(matching: .any)["wilted-open-player"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

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
        XCTAssertEqual(playPause.label, "Play")
        XCTAssertEqual(forward.label, "Skip forward 30 seconds")
    }

    func testArticleFlowAddsThenCancelsPreparation() {
        let app = launch(arguments: ["--wilted-ui-fixture-article-flow"])

        let url = app.descendants(matching: .any)["wilted-article-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.click()
        url.typeText("https://example.test/article")

        let add = app.descendants(matching: .any)["wilted-add-article-url"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()

        let progress = app.descendants(matching: .any)["wilted-preparation-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let cancel = app.descendants(matching: .any)["wilted-cancel-preparation"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()

        let detail = app.descendants(matching: .any)["wilted-preparation-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let detailExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", "current work"), object: detail
        )
        XCTAssertEqual(XCTWaiter().wait(for: [detailExpectation], timeout: 5), .completed)
    }

    func testFixtureReadyArticleOpensLiveNowPlayingControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-article-flow", "--wilted-ui-fixture-ready"])

        let openPlayer = app.descendants(matching: .any)["wilted-open-now-playing"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

        let player = app.descendants(matching: .any)["wilted-now-playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.click()
        let playingExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Pause"), object: playPause
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playingExpectation], timeout: 5), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-player-route-recovery"].exists)
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return app
    }
}
