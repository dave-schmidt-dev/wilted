import XCTest

@MainActor
final class WiltedMacSmokeUITests: XCTestCase {
    /// The rejected composition rendered Library unconditionally and merely
    /// appended a player, so selecting a destination changed nothing. These
    /// assertions are the inverse: exactly one destination occupies the detail
    /// region, and switching away actually removes the previous one.
    func testEachDestinationExclusivelyOccupiesTheDetailRegion() {
        let app = launch(arguments: ["--wilted-ui-smoke"])

        let navLibrary = app.descendants(matching: .any)["wilted-navigation-library"]
        let navNowPlaying = app.descendants(matching: .any)["wilted-navigation-nowPlaying"]
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navLibrary.waitForExistence(timeout: 5))
        XCTAssertTrue(navNowPlaying.waitForExistence(timeout: 5))
        XCTAssertTrue(navSettings.waitForExistence(timeout: 5))

        // Library owns the composer and the empty state.
        let emptyState = app.descendants(matching: .any)["wilted-mac-empty-state"]
        let urlField = app.descendants(matching: .any)["wilted-article-url"]
        let addArticle = app.descendants(matching: .any)["wilted-add-article-url"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(urlField.exists)
        XCTAssertTrue(addArticle.exists)
        XCTAssertTrue(addArticle.isEnabled)

        // Sync is a Settings concern, not a Library one.
        let syncControls = app.descendants(matching: .any)["wilted-sync-controls"]
        XCTAssertFalse(syncControls.exists)

        navNowPlaying.click()
        let player = app.descendants(matching: .any)["wilted-now-playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))

        // An empty player must point at a destination this window actually has.
        // AppKit surfaces a combined element's text through `value`, UIKit
        // through `label`, so read both rather than guessing.
        let playerText = [player.label, player.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(playerText.contains("Nothing is playing"), playerText)
        XCTAssertFalse(playerText.contains("Downloads"), playerText)
        let composerGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: urlField
        )
        XCTAssertEqual(XCTWaiter().wait(for: [composerGone], timeout: 5), .completed)

        navSettings.click()
        XCTAssertTrue(syncControls.waitForExistence(timeout: 5))
        let playerGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: player
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playerGone], timeout: 5), .completed)
        XCTAssertFalse(urlField.exists)

        navLibrary.click()
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyState.exists)
        XCTAssertFalse(syncControls.exists)
    }

    /// The sidebar lists destinations only. It used to repeat every article the
    /// Library detail already showed.
    func testSidebarListsDestinationsOnlyAndNotTheArticleList() {
        let app = launch(arguments: ["--wilted-ui-fixture-preparing"])

        let navLibrary = app.descendants(matching: .any)["wilted-navigation-library"]
        XCTAssertTrue(navLibrary.waitForExistence(timeout: 5))

        let duplicateRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-sidebar-article-'"))
        XCTAssertEqual(duplicateRows.count, 0)

        // The article is present exactly once, in the Library detail.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-article-row-'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // A preparing article offers no way into the player.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-open-now-playing"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-play-pause"].exists)
    }

    func testReadyLibraryNavigatesToNowPlayingControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let openPlayer = app.descendants(matching: .any)["wilted-open-now-playing"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

        let player = app.descendants(matching: .any)["wilted-now-playing"]
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

    /// Producer parity with the listener: the Mac player reports where it is,
    /// not just what its transports do.
    func testPlayerReportsProgressAndStatusLikeTheListener() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let openPlayer = app.descendants(matching: .any)["wilted-open-now-playing"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

        let progress = app.descendants(matching: .any)["wilted-now-playing-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "Playback progress")

        let status = app.descendants(matching: .any)["wilted-now-playing-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        // The listener always offers this row; the producer used to omit it
        // entirely whenever no transcript had loaded.
        let transcript = app.descendants(matching: .any)["wilted-now-playing-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))

        // Route recovery is offered against a fault, not unconditionally.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-route-recovery"].exists)
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

    /// Navigating away from the player must not stop playback, and getting back
    /// to the producer surface must stay a single click. That is the guarantee
    /// the rejected three-region window was trying to buy with a permanent
    /// side-by-side layout.
    func testPlaybackSurvivesDestinationSwitchesAndProducerStaysOneClickAway() {
        let app = launch(arguments: ["--wilted-ui-fixture-article-flow", "--wilted-ui-fixture-ready"])

        let openPlayer = app.descendants(matching: .any)["wilted-open-now-playing"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.click()

        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Pause"), object: playPause
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 5), .completed)

        // One click to the producer surface.
        let navLibrary = app.descendants(matching: .any)["wilted-navigation-library"]
        navLibrary.click()
        let urlField = app.descendants(matching: .any)["wilted-article-url"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        XCTAssertTrue(urlField.isEnabled)

        // One click back, with playback still running.
        let navNowPlaying = app.descendants(matching: .any)["wilted-navigation-nowPlaying"]
        navNowPlaying.click()
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertEqual(playPause.label, "Pause")
    }

    func testQuarantinedSyncOffersAccountReviewAndRecoversFromSettings() {
        let app = launch(arguments: ["--wilted-ui-fixture-quarantined"])

        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navSettings.waitForExistence(timeout: 5))
        navSettings.click()

        let status = app.descendants(matching: .any)["wilted-sync-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let quarantined = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Quarantined"), object: status
        )
        XCTAssertEqual(XCTWaiter().wait(for: [quarantined], timeout: 5), .completed)

        let review = app.descendants(matching: .any)["wilted-sync-use-current-account"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(review.isEnabled)
        review.click()

        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Disabled"), object: status
        )
        XCTAssertEqual(XCTWaiter().wait(for: [recovered], timeout: 5), .completed)
        XCTAssertFalse(review.exists)
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return app
    }
}
