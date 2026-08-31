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
        let navProcessor = app.descendants(matching: .any)["wilted-navigation-processor"]
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navLibrary.waitForExistence(timeout: 5))
        XCTAssertTrue(navProcessor.waitForExistence(timeout: 5))
        XCTAssertTrue(navSettings.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["wilted-navigation-nowPlaying"].exists)

        let compact = app.descendants(matching: .any)["wilted-compact-player"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        let idle = app.descendants(matching: .any)["wilted-player-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        XCTAssertEqual(idle.label, "Nothing is playing")
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-play-pause"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-scrubber"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-speed"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-keyboard-transports"].exists)

        let emptyState = app.descendants(matching: .any)["wilted-mac-empty-state"]
        let urlField = app.descendants(matching: .any)["wilted-article-url"]
        let syncControls = app.descendants(matching: .any)["wilted-sync-controls"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(urlField.exists)
        XCTAssertFalse(syncControls.exists)

        navProcessor.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-processor-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(urlField.exists)

        navSettings.click()
        XCTAssertTrue(syncControls.waitForExistence(timeout: 5))
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-mac-processor-detail"].exists)

        navLibrary.click()
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyState.exists)
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(syncControls.exists)
    }
    func testProcessorReportsActiveWorkAndRunHistory() {
        let app = launch(arguments: ["--wilted-ui-smoke"])

        let navProcessor = app.descendants(matching: .any)["wilted-navigation-processor"]
        XCTAssertTrue(navProcessor.waitForExistence(timeout: 5))
        navProcessor.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-processor-detail"].waitForExistence(timeout: 5)
        )
        // A fixture library has never prepared anything, so both regions
        // state their emptiness rather than rendering nothing at all.
        XCTAssertTrue(app.descendants(matching: .any)["wilted-processor-idle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-processor-empty"].exists)
    }

    /// The library had no removal path, so anything prepared once stayed on
    /// screen permanently, including rows written before fixture mode moved to
    /// a temporary directory.
    func testLibraryRowOffersRemoval() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-article-row-'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        let actions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-article-actions-'"))
            .firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.click()

        // Drive the removal rather than merely proving the control is drawn.
        // This is the library's only destructive path, so "the menu exists" is
        // not evidence that pressing it removes anything.
        let remove = app.menuItems["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()

        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Remove left the article on screen; the row must disappear once the item is tombstoned."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-empty-state"].waitForExistence(timeout: 10),
            "Removing the only article must fall back to the empty state."
        )
    }

    /// The reported gap: subscriptions existed in the store with nowhere to see
    /// or manage them. Larder must list every feed with its own switch and
    /// unsubscribe, and state the refresh and download policy rather than
    /// leaving an absent schedule to read as a hidden one.
    func testLarderListsPodcastFeedsWithPerFeedControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])

        let card = app.descendants(matching: .any)["wilted-podcast-feeds"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-row-'")
            ).count >= 2,
            "every subscribed feed needs a row, including one the listener has hidden"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-podcast-feeds-policy"].exists,
            "the card must state the refresh and download policy"
        )

        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-enabled-'")
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let unsubscribe = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-unsubscribe-'")
        ).firstMatch
        XCTAssertTrue(unsubscribe.waitForExistence(timeout: 5))

        // Drive unsubscribe rather than merely proving the button is drawn: it
        // is the destructive path, and "the control exists" is not evidence it
        // removes anything.
        let rowsBefore = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-row-'")
        ).count
        unsubscribe.click()
        let message = app.descendants(matching: .any)["wilted-podcast-operation-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 8))
        let rowsAfter = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-row-'")
        ).count
        XCTAssertLessThan(rowsAfter, rowsBefore, "unsubscribing must remove the feed's row")
    }

    func testMixedLarderSearchFiltersDownloadRetryAndSelection() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-article-flow", "--wilted-ui-fixture-ready",
            "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-download-failure"
        ])
        let episode = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-row-'")
        ).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Quiet Machines"].exists)
        XCTAssertTrue(app.staticTexts["24:42"].exists)

        episode.click()
        XCTAssertTrue(episode.isSelected)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("Quiet")
        XCTAssertTrue(episode.exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("missing")
        XCTAssertTrue(app.staticTexts["No matching Larder items"].waitForExistence(timeout: 3))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Quiet")

        let download = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-download-'")
        ).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        download.click()
        let retry = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-retry-'")
        ).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        retry.click()
        let offline = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-offline-'")
        ).firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 3))

        let actions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-actions-'")
        ).firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.click()
        app.menuItems["Remove from Larder"].click()
        XCTAssertFalse(episode.exists)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(
            app.staticTexts["Fixture article"].waitForExistence(timeout: 3),
            "Article behavior remains available after episode removal"
        )
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

        // A preparing article cannot start playback; the persistent idle rail
        // remains truthful and minimized.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-open-now-playing"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-compact-player"]
                .waitForExistence(timeout: 5)
        )
        let idle = app.descendants(matching: .any)["wilted-player-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-play-pause"].exists)
    }

    func testReadyLibraryNavigatesToNowPlayingControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let library = app.descendants(matching: .any)["wilted-mac-library-detail"]
        let openPlayer = app.descendants(matching: .any)["wilted-open-now-playing"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

        let compact = app.descendants(matching: .any)["wilted-compact-player"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertTrue(library.exists, "Starting article playback must preserve the Larder destination")
        XCTAssertFalse(app.descendants(matching: .any)["wilted-navigation-nowPlaying"].exists)

        let rewind = app.descendants(matching: .any)["wilted-player-rewind"]
        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        let forward = app.descendants(matching: .any)["wilted-player-forward"]
        XCTAssertTrue(rewind.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.isEnabled)
        XCTAssertTrue(forward.isEnabled)
        XCTAssertEqual(rewind.label, "Rewind 15 seconds")
        XCTAssertEqual(playPause.label, "Play")
        XCTAssertEqual(forward.label, "Skip forward 30 seconds")
    }
    func testPodcastCompactPlayerPersistsAcrossLarderScrollAndExposesCompleteControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        let library = app.descendants(matching: .any)["wilted-mac-library-detail"]
        let playEpisode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-play-'"))
            .firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 5))
        playEpisode.click()

        let compact = app.descendants(matching: .any)["wilted-compact-player"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertTrue(library.exists)
        XCTAssertTrue(library.isHittable)
        for identifier in [
            "wilted-player-speed", "wilted-player-rewind", "wilted-player-play-pause",
            "wilted-player-forward", "wilted-player-overflow", "wilted-player-transcript",
            "wilted-player-up-next", "wilted-player-route-recovery", "wilted-player-volume",
            "wilted-player-scrubber", "wilted-player-previous", "wilted-player-next",
            "wilted-player-restart", "wilted-player-keyboard-transports", "wilted-player-status"
        ] {
            XCTAssertEqual(
                app.descendants(matching: .any).matching(identifier: identifier).count, 1,
                "missing or duplicate \(identifier)"
            )
        }

        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertEqual(playPause.label, "Pause")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(playPause.label, "Play", "Space must invoke the compact player's primary shortcut")

        let scrubber = app.descendants(matching: .any)["wilted-player-scrubber"]
        guard let initialScrubberValue = Self.numericAXValue(of: scrubber) else {
            return XCTFail("Playback scrubber must expose a numeric accessibility value")
        }
        app.descendants(matching: .any)["wilted-player-forward"].click()
        expectation(
            for: NSPredicate { value, _ in
                guard let element = value as? XCUIElement,
                      let current = Self.numericAXValue(of: element) else { return false }
                return current > initialScrubberValue
            },
            evaluatedWith: scrubber
        )
        waitForExpectations(timeout: 2)

        let transcript = app.descendants(matching: .any)["wilted-player-transcript"]
        transcript.click()
        let transcriptExpansion = app.descendants(matching: .any)["wilted-player-transcript-expanded"]
        XCTAssertTrue(transcriptExpansion.waitForExistence(timeout: 5))
        XCTAssertEqual(transcript.value as? String, "Expanded")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(transcriptExpansion.waitForNonExistence(timeout: 5))
        XCTAssertEqual(transcript.value as? String, "Collapsed")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(
            transcriptExpansion.waitForExistence(timeout: 5),
            "Escape must restore keyboard focus to the Transcript toggle"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(transcriptExpansion.waitForNonExistence(timeout: 5))

        let upNext = app.descendants(matching: .any)["wilted-player-up-next"]
        upNext.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-player-up-next-expanded"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(library.exists)
        XCTAssertTrue(library.isHittable)

        let remove = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-player-up-next-remove-'")
        ).firstMatch
        let earlier = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-player-up-next-move-earlier-'")
        ).firstMatch
        let later = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-player-up-next-move-later-'")
        ).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertFalse(remove.isEnabled)
        XCTAssertEqual(remove.value as? String, "Unavailable for the current episode")
        XCTAssertTrue(earlier.exists)
        XCTAssertFalse(earlier.isEnabled)
        XCTAssertTrue(later.exists)
        XCTAssertFalse(later.isEnabled)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-player-up-next-expanded"]
                .waitForNonExistence(timeout: 5)
        )
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-player-up-next-expanded"]
                .waitForExistence(timeout: 5),
            "Escape must restore keyboard focus to the Up Next toggle"
        )
        app.typeKey(.escape, modifierFlags: [])
        library.scroll(byDeltaX: 0, deltaY: -500)
        XCTAssertTrue(compact.exists)
    }
    func testSelectingEmptyNowPlayingDoesNotResizeWindow() {
        let app = launch(arguments: ["--wilted-ui-smoke"])

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let before = window.frame
        let compact = app.descendants(matching: .any)["wilted-compact-player"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        let idle = app.descendants(matching: .any)["wilted-player-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        XCTAssertEqual(idle.label, "Nothing is playing")
        XCTAssertFalse(app.descendants(matching: .any)["wilted-navigation-nowPlaying"].exists)

        app.descendants(matching: .any)["wilted-navigation-processor"].click()
        XCTAssertTrue(compact.exists)
        app.descendants(matching: .any)["wilted-navigation-settings"].click()
        XCTAssertTrue(compact.exists)
        let after = window.frame

        XCTAssertEqual(after.width, before.width, accuracy: 1)
        XCTAssertLessThanOrEqual(after.height, before.height + 1)
    }
    func testPlayerReportsProgressAndStatusLikeTheListener() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let openPlayer = app.descendants(matching: .any)["wilted-open-now-playing"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

        let progress = app.descendants(matching: .any)["wilted-player-scrubber"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "Playback position")

        let status = app.descendants(matching: .any)["wilted-player-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        app.descendants(matching: .any)["wilted-player-transcript"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-player-transcript-expanded"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-now-playing-transcript"]
                .waitForExistence(timeout: 5)
        )

        let routeRecovery = app.descendants(matching: .any)["wilted-player-route-recovery"]
        XCTAssertTrue(routeRecovery.waitForExistence(timeout: 5))
        XCTAssertFalse(routeRecovery.isEnabled)
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

        let compact = app.descendants(matching: .any)["wilted-compact-player"]
        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-mac-library-detail"].exists)
        playPause.click()

        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Pause"), object: playPause
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 5), .completed)

        app.descendants(matching: .any)["wilted-navigation-processor"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-processor-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
        XCTAssertEqual(playPause.label, "Pause")

        app.descendants(matching: .any)["wilted-navigation-settings"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-settings"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
        XCTAssertEqual(playPause.label, "Pause")

        app.descendants(matching: .any)["wilted-navigation-library"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-library-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
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

    private static func numericAXValue(of element: XCUIElement) -> Double? {
        switch element.value {
        case let value as NSNumber: value.doubleValue
        case let value as Double: value
        case let value as Float: Double(value)
        case let value as Int: Double(value)
        case let value as String: Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }
}
