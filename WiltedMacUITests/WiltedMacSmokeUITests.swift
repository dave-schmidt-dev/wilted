import XCTest

@MainActor
final class WiltedMacSmokeUITests: XCTestCase {
    private var fixtureStateDirectory: URL?
    private var launchedFixtureApps: [XCUIApplication] = []
    /// Absorbs:
    /// - testEachDestinationExclusivelyOccupiesTheDetailRegion
    /// - testSidebarListsDestinationsOnlyAndNotTheArticleList (sidebar assertion only)
    /// - testFeedsPageOwnsSubscribingAndTheMenuAsksForAnArticle
    /// - testMenuArticleRowOffersRemoval
    /// - testFeedsPageListsPodcastFeedsWithPerFeedControls
    func testIntakeJourneyAcrossLarderFeedsAndSettings() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-window-width", "900"])

        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        let navMenu = app.descendants(matching: .any)["wilted-navigation-menu"]
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 5))
        XCTAssertTrue(navMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(navSettings.waitForExistence(timeout: 5))
        XCTAssertEqual(navMenu.label, "Larder")
        XCTAssertEqual(navFeeds.label, "Feeds")
        XCTAssertEqual(navSettings.label, "Settings")
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

        let menuEmpty = app.descendants(matching: .any)["wilted-menu-empty"]
        // The address box lives behind this button, so the button is what marks
        // the Menu as the destination that takes an article.
        let addArticle = app.descendants(matching: .any)["wilted-add-article-button"]
        let syncControls = app.descendants(matching: .any)["wilted-sync-controls"]
        XCTAssertTrue(menuEmpty.waitForExistence(timeout: 5))
        XCTAssertTrue(addArticle.exists)
        XCTAssertFalse(syncControls.exists)

        // Feeds is its own destination, so the feed card must not follow the
        // add box onto the Feeds page.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)

        let duplicateRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-sidebar-article-'"))
        XCTAssertEqual(duplicateRows.count, 0)

        // The box is behind a button now, so opening it is part of the
        // journey: a trigger that draws but opens nothing would otherwise
        // leave the address field unreachable and this test still passing.
        let trigger = app.descendants(matching: .any)["wilted-add-article-button"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 8))
        XCTAssertEqual(trigger.label, "Add article", "The Menu's button must name what it takes")
        trigger.click()

        let add = app.descendants(matching: .any)["wilted-add-link"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the trigger must open the address box")
        let articleField = app.descendants(matching: .any)["wilted-link-url"]
        XCTAssertTrue(articleField.waitForExistence(timeout: 5), "the opened box must carry its field")
        app.typeKey(.escape, modifierFlags: [])

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
        let remove = app.menuItems["Delete…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        confirmRemoval(in: app, label: "Confirm delete")

        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Delete left the article on screen; the row must disappear once the item is tombstoned."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-menu-empty"].waitForExistence(timeout: 10),
            "Removing the only article must fall back to the Menu's empty state."
        )
        XCTAssertTrue(
            addArticle.waitForExistence(timeout: 5),
            "Removing the only article must leave the Add article entry point reachable."
        )

        navFeeds.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-feeds-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(addArticle.exists)
        XCTAssertFalse(menuEmpty.exists)

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
        confirmRemoval(in: app, label: "Confirm unsubscribe")
        let removalStatus = app.descendants(matching: .any)["wilted-delete-save-status"]
        XCTAssertTrue(removalStatus.waitForExistence(timeout: 8))
        let rowsAfter = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-row-'")
        ).count
        XCTAssertLessThan(rowsAfter, rowsBefore, "unsubscribing must remove the feed's row")

        let feedTrigger = app.descendants(matching: .any)["wilted-add-feed-button"]
        XCTAssertTrue(feedTrigger.waitForExistence(timeout: 8), "Feeds asks for a subscription behind a button")
        feedTrigger.click()

        let composer = app.descendants(matching: .any)["wilted-podcast-subscribe-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "the trigger must open the subscribe box")
        let field = app.descendants(matching: .any)["wilted-podcast-feed-url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let subscribe = app.descendants(matching: .any)["wilted-podcast-subscribe"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 5))

        // An address that is not a complete HTTPS one is refused before any
        // network work, so the rejection is deterministic evidence that the
        // button is wired to the composer rather than merely drawn.
        field.click()
        field.typeText("not-an-address")
        subscribe.click()

        let status = app.descendants(matching: .any)["wilted-podcast-subscribe-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let refused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", "HTTPS"), object: status
        )
        XCTAssertEqual(XCTWaiter().wait(for: [refused], timeout: 5), .completed)
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-podcast-feeds"].exists,
            "the subscription list stays on the page the composer subscribes into"
        )
        app.typeKey(.escape, modifierFlags: [])

        navSettings.click()
        XCTAssertTrue(syncControls.waitForExistence(timeout: 5))
        XCTAssertTrue(compact.exists)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-mac-feeds-detail"].exists)

        navMenu.click()
        XCTAssertTrue(addArticle.waitForExistence(timeout: 5))
        XCTAssertTrue(menuEmpty.exists)
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(syncControls.exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)

        addArticle.click()
        XCTAssertTrue(
            add.waitForExistence(timeout: 8),
            "Opening the Add article button after the roundtrip must expose the add-link control."
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Absorbs:
    /// - testMenuSearchFiltersAndTheFeedsRestorePath
    /// - testUnpreparedEpisodeHasNoListeningActionAndTheMenuOwnsItsStep
    /// - the Feeds show-notes popover
    func testEpisodeDecisionJourneyFromFeedsToLarder() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
            "--wilted-ui-fixture-download-failure"
        ])

        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 8))
        navFeeds.click()

        let feedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-row-'")
        ).firstMatch
        XCTAssertTrue(feedRow.waitForExistence(timeout: 8))

        // Show notes inform the Feeds decision without adding another journey.
        let showNotes = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-show-notes-'")
        ).firstMatch
        XCTAssertTrue(showNotes.waitForExistence(timeout: 5))
        showNotes.click()
        let notes = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-notes-text-'")
        ).firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "the title opens the episode's show notes")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-decide-keep-'")
        ).firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        let notesDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: notes
        )
        XCTAssertEqual(XCTWaiter().wait(for: [notesDismissed], timeout: 5), .completed,
                       "Escape closes the notes popover")

        // A skip leaves the list; Feeds owns the reversal.
        let skip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-skip-'")
        ).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.click()
        let offList = app.descendants(matching: .any)["wilted-feeds-off-list-toggle"]
        XCTAssertTrue(offList.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["wilted-feeds-restorable"].exists)
        offList.click()
        let restore = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-restore-skipped-'")
        ).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5),
                      "a skipped row must offer Restore on Feeds")
        restore.click()
        XCTAssertTrue(feedRow.waitForExistence(timeout: 5), "Restore returns the row to Feeds")

        // Keep is the other half of the one decision Feeds owns.
        // It is made from the notes popover; the row's Keep is driven headlessly by WiltedMacPlaybackJourneyTests.
        showNotes.click()
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-decide-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()

        // The Menu waits the kept row with its one next step.
        let navMenu = app.descendants(matching: .any)["wilted-navigation-menu"]
        navMenu.click()
        let menuRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-row-'")
        ).firstMatch
        XCTAssertTrue(menuRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Not downloaded"].exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-download-'")
        ).firstMatch.exists, "an Available row offers its one next step")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")
        ).count, 0, "an Available row cannot claim to be playable")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-skip-' OR identifier BEGINSWITH 'wilted-menu-mark-completed-'")
        ).count, 0, "an unstarted row has no skip or completion action")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-remove-'")
        ).firstMatch.exists)

        // Search narrows the Menu and never the queue.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Quiet")
        XCTAssertTrue(menuRow.waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("missing")
        XCTAssertTrue(app.descendants(matching: .any)["wilted-menu-empty"].waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(menuRow.waitForExistence(timeout: 5))
    }

    /// The words an element shows. macOS puts a Text's words in its value, not
    /// its label, and a Text with links can hand each run to a child, so the
    /// element and its static-text descendants are read together.
    /// Presses the removal dialog's destructive button: by identifier, or by
    /// its label where the dialog does not carry identifiers through.
    private func confirmRemoval(in app: XCUIApplication, label: String) {
        let byIdentifier = app.descendants(matching: .any)["wilted-delete-confirm"]
        let confirm = byIdentifier.waitForExistence(timeout: 5) ? byIdentifier : app.buttons[label]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the removal dialog must offer \(label)")
        confirm.click()
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments + [
            "--wilted-ui-fixture-state-directory", fixtureRoot().path,
        ]
        app.launch()
        launchedFixtureApps.append(app)
        // On macOS 27 a fixture app launched by XCUITest can stay inactive, and an inactive app
        // exposes only its menu bar to accessibility, so bring it forward before looking for a window.
        app.activate()
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            XCTFail("Fixture app did not present a window before smoke assertions")
            fatalError("Fixture app window is unavailable")
        }
        return app
    }

    private func fixtureRoot() -> URL {
        if let fixtureStateDirectory { return fixtureStateDirectory }
        do {
            let root = try WiltedMacUITemporaryState.fixtureRoot(prefix: "wilted-ui-test")
            addTeardownBlock { [weak self, root] in
                self?.launchedFixtureApps.forEach { $0.terminate() }
                try WiltedMacUITemporaryState.removeFixtureRoot(root)
            }
            // Register removal before creating the fixture root.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            fixtureStateDirectory = root
            return root
        } catch {
            XCTFail("Could not create owned UI fixture root: \(error)")
            fatalError("The UI test runner temporary directory is unavailable")
        }
    }
}
