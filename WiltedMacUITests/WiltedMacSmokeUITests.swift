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
        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        let navProcessor = app.descendants(matching: .any)["wilted-navigation-processor"]
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navLibrary.waitForExistence(timeout: 5))
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 5))
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
        // The address box lives behind this button, so the button is what
        // marks the Larder as the one destination that takes an article.
        let addArticle = app.descendants(matching: .any)["wilted-add-article-button"]
        let syncControls = app.descendants(matching: .any)["wilted-sync-controls"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(addArticle.exists)
        XCTAssertFalse(syncControls.exists)

        // Feeds is its own destination, so the feed card must leave Larder and
        // the add box must not follow it onto the Feeds page.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)
        navFeeds.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-feeds-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(addArticle.exists)
        XCTAssertFalse(emptyState.exists)

        navProcessor.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-processor-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(addArticle.exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-mac-feeds-detail"].exists)

        navSettings.click()
        XCTAssertTrue(syncControls.waitForExistence(timeout: 5))
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-mac-processor-detail"].exists)

        navLibrary.click()
        XCTAssertTrue(addArticle.waitForExistence(timeout: 5))
        XCTAssertTrue(emptyState.exists)
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(syncControls.exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)
    }

    func testSettingsAutomationControlsRevealOnlyTheRelevantOffPeakWindow() {
        let app = launch(arguments: ["--wilted-ui-smoke"])
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navSettings.waitForExistence(timeout: 5))
        navSettings.click()

        let controls = app.descendants(matching: .any)["wilted-automation-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-refresh-policy"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-download-policy"].exists)
        let processing = app.descendants(matching: .any)["wilted-automation-processing-policy"]
        XCTAssertTrue(processing.exists)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-transcript-policy"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-remove-ads"].exists)

        // The fixture starts at immediate processing. No dormant time controls
        // or stop action should occupy the Settings card while automation is idle,
        // but the status must still say that nothing is running.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-automation-off-peak-start"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-automation-off-peak-end"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-automation-off-peak-explanation"].exists)
        let status = app.descendants(matching: .any)["wilted-automation-status"]
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("idle"))
        XCTAssertFalse(app.descendants(matching: .any)["wilted-automation-stop"].exists)

        processing.click()
        let manual = app.menuItems["Manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        manual.click()
        XCTAssertFalse(app.descendants(matching: .any)["wilted-automation-off-peak-start"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-automation-off-peak-end"].exists)

        processing.click()
        let offPeak = app.menuItems["Off-peak"]
        XCTAssertTrue(offPeak.waitForExistence(timeout: 5))
        offPeak.click()

        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-off-peak-start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-off-peak-end"].exists)
        let explanation = app.descendants(matching: .any)["wilted-automation-off-peak-explanation"]
        XCTAssertTrue(explanation.exists)
        XCTAssertTrue(visibleText(of: explanation).localizedCaseInsensitiveContains("local time"))
        XCTAssertTrue(visibleText(of: explanation).localizedCaseInsensitiveContains("overnight"))
    }

    func testProcessorReportsActiveWorkAndRunHistory() {
        let app = launch(arguments: ["--wilted-ui-smoke"])

        let navProcessor = app.descendants(matching: .any)["wilted-navigation-processor"]
        XCTAssertTrue(navProcessor.waitForExistence(timeout: 5))
        navProcessor.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-processor-detail"].waitForExistence(timeout: 5)
        )
        // A fixture library has never prepared anything, so all three regions
        // state their emptiness rather than rendering nothing at all.
        XCTAssertTrue(app.descendants(matching: .any)["wilted-processor-idle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-processor-waiting-empty"].exists)
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
    /// or manage them. The Feeds page must list every feed with its own switch
    /// and unsubscribe, and state the refresh and download policy rather than
    /// leaving an absent schedule to read as a hidden one.
    func testFeedsPageListsPodcastFeedsWithPerFeedControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])

        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 8))
        navFeeds.click()

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

    /// Subscribing is a decision the Feeds page owns now.
    ///
    /// The complaint this closes is the one add box: a listener pasting a feed
    /// into a control labelled for articles had no way to tell what would
    /// happen. Larder now says Add article, and the feed composer -- with its
    /// own field, its own button, and its own rejection message -- lives on the
    /// page that keeps subscriptions.
    func testFeedsPageOwnsSubscribingAndLarderAsksForAnArticle() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])

        // The box is behind a button now, so opening it is part of the
        // journey: a trigger that draws but opens nothing would otherwise
        // leave the address field unreachable and this test still passing.
        let trigger = app.descendants(matching: .any)["wilted-add-article-button"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 8))
        XCTAssertEqual(trigger.label, "Add article", "Larder's button must name what it takes")
        trigger.click()

        let add = app.descendants(matching: .any)["wilted-add-link"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the trigger must open the address box")
        let articleField = app.descendants(matching: .any)["wilted-link-url"]
        XCTAssertTrue(articleField.waitForExistence(timeout: 5), "the opened box must carry its field")
        app.typeKey(.escape, modifierFlags: [])

        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 8))
        navFeeds.click()

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
        // The title is the notes button on a row that has notes, so it is
        // found by what it offers rather than as a bare text.
        XCTAssertTrue(app.buttons["Show notes for Quiet Machines"].exists)
        XCTAssertTrue(app.staticTexts["24:42"].exists)

        episode.click()
        XCTAssertTrue(episode.isSelected)

        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-actions-'")
            ).count, 0,
            "A row that never finished downloading has nothing to put in a menu, so it draws none."
        )

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

        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-actions-'")
            ).count, 1,
            "The retry finished the download, and a finished download can be fetched again from its menu."
        )
        // Skipping is a row button, not a menu item: it is the one action a
        // reader repeats down a feed, and reaching it through a menu that held
        // nothing else cost two presses per episode.
        let skip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-skip-'")
        ).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 3))
        skip.click()
        XCTAssertFalse(episode.exists)
        XCTAssertTrue(
            app.buttons["wilted-podcast-undo-removal"].waitForExistence(timeout: 3),
            "the removal message must offer Undo right after Skip"
        )
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(
            app.staticTexts["Fixture article"].waitForExistence(timeout: 3),
            "Article behavior remains available after episode removal"
        )

        // Removed now lives behind a button in the Larder's own list header,
        // not on Podcast feeds: no navigation away from this destination, and
        // no card holding the Larder's prime space either. The button opens a
        // popover, so its rows do not exist until it is clicked.
        let removedTitle = app.descendants(matching: .any)["wilted-podcast-removed-title"]
        XCTAssertTrue(removedTitle.waitForExistence(timeout: 5), "the Removed button must appear in the Larder")
        removedTitle.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-removed-row-'")
            ).firstMatch.waitForExistence(timeout: 5),
            "every durable dismissal must remain visible at the top of the Larder"
        )
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-restore-'")
            ).firstMatch.exists,
            "a removed episode must expose one stable Restore action"
        )
    }

    /// The notes were only reachable from the player, so answering "what is
    /// this episode about?" meant playing it. The row's own title has to open
    /// them, and the URLs the feed wrote out have to arrive as links.
    func testEpisodeTitleOpensItsShowNotes() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        let title = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-notes-item-'")
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "A row with notes must offer them from its title.")
        title.click()
        let notes = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-notes-text-'")
        ).firstMatch
        // The same first-click swallow the menu test guards against.
        if !notes.waitForExistence(timeout: 3) { title.click() }
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        // The row's own summary is the notes' first paragraph, so asserting on
        // that would pass without the popover having opened at all. The guest
        // line appears nowhere but the full notes.
        XCTAssertTrue(
            visibleText(of: notes).contains("Ada Ferris"),
            "The popover must carry the feed's notes, not just the row's one-line summary."
        )
    }

    /// A build that never loaded the ad detector marked every episode prepared
    /// with nothing cut, and removal is permanent, so a prepared row had no
    /// way back. Pressing the control must actually start a run: the fixture
    /// points at no media, so the row leaves the prepared state and exposes
    /// the durable failure instead of silently remaining prepared.
    func testPreparedEpisodeOffersToPrepareAgainFromItsMenu() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-row-'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready to play"].exists,
                      "A proven prepared row shows one explicit listening-ready status.")
        XCTAssertTrue(app.staticTexts["5 ads removed (7:22) · transcript synced"].exists,
                      "Preparation outcomes remain explicit beside the stable status.")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-prepare'")).count, 0,
            "A prepared row shows no preparation button; redoing lives in its menu."
        )

        let actions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-actions-'"))
            .firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.click()
        let again = app.menuItems["Prepare this copy again"]
        // A freshly launched app occasionally swallows the first click on a
        // menu button (seen once on 2026-09-01: passed alone, failed in a
        // pair). One more click is the same gesture the reader would make.
        if !again.waitForExistence(timeout: 3) { actions.click() }
        XCTAssertTrue(again.waitForExistence(timeout: 5), "A prepared episode's menu must offer Prepare this copy again.")
        XCTAssertTrue(
            app.menuItems["Download again, then prepare"].exists,
            "The fresh-copy route sits beside the re-cut route, so the two read as different files."
        )
        XCTAssertTrue(
            app.menuItems["Preparing writes the cut audio over the download."].exists,
            "The menu says why the two routes differ."
        )
        again.click()
        XCTAssertTrue(
            app.staticTexts["No preparation worker in fixture mode"].waitForExistence(timeout: 5),
            "Prepare again reaches the fixture's durable failed result."
        )
        XCTAssertFalse(app.staticTexts["5 ads removed (7:22) · transcript synced"].exists,
                       "A new failed attempt replaces the earlier completed status.")
    }

    func testPrepSurfacesReadyEpisodesAndMenuAddsAllPrepared() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        let prep = app.descendants(matching: .any)["wilted-navigation-processor"]
        XCTAssertTrue(prep.waitForExistence(timeout: 5))
        prep.click()

        XCTAssertTrue(app.staticTexts["Ready to play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-processor-ready-list"].exists)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-ready-'")).firstMatch.exists)

        let menu = app.descendants(matching: .any)["wilted-navigation-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let addAll = app.descendants(matching: .any)["wilted-menu-add-all-prepared"]
        XCTAssertTrue(addAll.waitForExistence(timeout: 5))
        XCTAssertTrue(addAll.isEnabled)
        addAll.click()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-row-'"))
            .firstMatch.waitForExistence(timeout: 8))
    }

    func testMenuBulkAddIsDisabledWithHonestEmptyState() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        let menu = app.descendants(matching: .any)["wilted-navigation-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let addAll = app.descendants(matching: .any)["wilted-menu-add-all-prepared"]
        XCTAssertTrue(addAll.waitForExistence(timeout: 5))
        XCTAssertFalse(addAll.isEnabled)
        XCTAssertEqual(addAll.label, "No prepared episodes to add")
    }

    func testUnpreparedEpisodeHasNoListeningActionAndPrepOwnsItsPreparationAction() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        let episode = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-row-'")
        ).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        XCTAssertTrue(episode.staticTexts["Downloaded"].exists)
        XCTAssertTrue(episode.staticTexts["Ready to prepare"].exists)
        XCTAssertEqual(
            episode.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-play-'")).count, 0
        )
        XCTAssertEqual(
            episode.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-add-menu-'")).count, 0
        )

        app.descendants(matching: .any)["wilted-navigation-processor"].click()
        XCTAssertTrue(app.staticTexts["Preparing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Queued"].exists)
        XCTAssertTrue(app.staticTexts["Not queued"].exists)
        XCTAssertTrue(app.buttons["wilted-processor-prepare-all"].isEnabled)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-prepare-'")
        ).firstMatch.exists)
    }

    /// Larder carries the successful run's concise recorded summary; Prep keeps
    /// the full narrative and the worker's own log when asked for.
    func testPrepNarratesARunAndShowsItsLogOnRequest() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        let navProcessor = app.descendants(matching: .any)["wilted-navigation-processor"]
        XCTAssertTrue(navProcessor.waitForExistence(timeout: 5))
        navProcessor.click()

        let run = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-run-podcast-prepare|'")
        ).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 5), "The fixture's prepared episode has a journalled run.")
        XCTAssertTrue(run.staticTexts["Quiet Machines"].exists)
        XCTAssertTrue(run.staticTexts["Succeeded"].exists)
        XCTAssertTrue(run.staticTexts["Ready · 5 ads removed (7:22) · transcript synced"].exists,
                      "A finished run is narrated from what it recorded.")

        XCTAssertFalse(app.staticTexts["ads.detect.calls · 50 requests, 0 failed"].exists, "The log is opt-in, per run.")

        let showLog = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-log-toggle-'")
        ).firstMatch
        XCTAssertTrue(showLog.waitForExistence(timeout: 3))
        let actions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-actions-'")
        ).firstMatch
        XCTAssertTrue(actions.exists, "Prep controls share one action row below the narrative.")
        XCTAssertTrue(
            actions.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-log-toggle-'")
            ).firstMatch.exists,
            "Show log remains in the run's action row."
        )
        showLog.click()
        let log = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-processor-log-'")
        ).firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 5), "The expanded journal is contained in its own log region.")
        XCTAssertTrue(
            app.staticTexts["ads.detect.calls · 50 requests, 0 failed"].waitForExistence(timeout: 5),
            "The run's log must list every journalled status in the worker's words."
        )
        XCTAssertTrue(
            app.staticTexts["ads.detect.span.1 · 0:01:20–0:02:10 · host read · 91%"].exists,
            "The log keeps each exact detected advertisement span for inspection."
        )
        XCTAssertTrue(app.staticTexts["transcript.stt.start"].exists)

        showLog.click()
        XCTAssertTrue(app.staticTexts["ads.detect.calls · 50 requests, 0 failed"].waitForNonExistence(timeout: 5))
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
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
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
            "wilted-player-forward", "wilted-player-transcript",
            "wilted-player-notes", "wilted-player-menu", "wilted-player-volume",
            "wilted-player-scrubber", "wilted-player-previous", "wilted-player-next",
            "wilted-player-restart", "wilted-player-keyboard-transports"
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

        let itemTitle = app.descendants(matching: .any)["wilted-player-item-title"]
        XCTAssertTrue(itemTitle.waitForExistence(timeout: 5))
        let itemTitleBeforeExpansion = visibleText(of: itemTitle)
        XCTAssertTrue(itemTitleBeforeExpansion.contains("Quiet Machines"))
        let speed = app.descendants(matching: .any)["wilted-player-speed"]
        let speedBeforeExpansion = speed.value
        XCTAssertNotNil(speedBeforeExpansion, "Playback speed must expose its selected value")

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
        guard let scrubberBeforeExpansion = Self.numericAXValue(of: scrubber) else {
            return XCTFail("Playback scrubber must retain a numeric accessibility value while paused")
        }

        let transcript = app.descendants(matching: .any)["wilted-player-transcript"]
        transcript.click()
        let transcriptExpansion = app.descendants(matching: .any)["wilted-player-transcript-expanded"]
        XCTAssertTrue(transcriptExpansion.waitForExistence(timeout: 5))
        let fullWindow = app.descendants(matching: .any)["wilted-player-full-window"]
        let collapse = app.descendants(matching: .any)["wilted-player-collapse"]
        XCTAssertTrue(fullWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(collapse.exists)
        XCTAssertFalse(library.isHittable, "The mounted work destination must not expose live controls beneath Now Playing")
        XCTAssertEqual(transcript.value as? String, "Expanded")
        XCTAssertEqual(visibleText(of: itemTitle), itemTitleBeforeExpansion)
        XCTAssertEqual("\(speed.value ?? "")", "\(speedBeforeExpansion ?? "")")
        guard let scrubberDuringExpansion = Self.numericAXValue(of: scrubber) else {
            return XCTFail("Playback scrubber must remain numeric while expanded")
        }
        XCTAssertEqual(scrubberDuringExpansion, scrubberBeforeExpansion, accuracy: 0.5)
        let playbackStateBeforeCollapse = playPause.label
        collapse.click()
        XCTAssertTrue(fullWindow.waitForNonExistence(timeout: 5))
        XCTAssertTrue(compact.exists)
        XCTAssertTrue(library.exists)
        XCTAssertTrue(library.isHittable)
        XCTAssertEqual(visibleText(of: itemTitle), itemTitleBeforeExpansion)
        XCTAssertEqual("\(speed.value ?? "")", "\(speedBeforeExpansion ?? "")")
        guard let scrubberAfterCollapse = Self.numericAXValue(of: scrubber) else {
            return XCTFail("Playback scrubber must remain numeric after collapse")
        }
        XCTAssertEqual(scrubberAfterCollapse, scrubberBeforeExpansion, accuracy: 0.5)
        XCTAssertEqual(playPause.label, playbackStateBeforeCollapse)

        let transcriptAfterCollapse = app.descendants(matching: .any)["wilted-player-transcript"]
        XCTAssertTrue(transcriptAfterCollapse.waitForExistence(timeout: 5))
        XCTAssertEqual(transcriptAfterCollapse.value as? String, "Collapsed")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(
            fullWindow.waitForExistence(timeout: 5),
            "Collapse must restore keyboard focus to the Transcript toggle"
        )
        XCTAssertFalse(library.isHittable)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(transcriptExpansion.waitForNonExistence(timeout: 5))
        XCTAssertTrue(fullWindow.waitForNonExistence(timeout: 5))
        let transcriptAfterEscape = app.descendants(matching: .any)["wilted-player-transcript"]
        XCTAssertTrue(transcriptAfterEscape.waitForExistence(timeout: 5))
        XCTAssertEqual(transcriptAfterEscape.value as? String, "Collapsed")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(
            transcriptExpansion.waitForExistence(timeout: 5),
            "Escape must restore keyboard focus to the Transcript toggle"
        )
        XCTAssertTrue(fullWindow.exists)

        // Switch sections inside the full-window player. This verifies that
        // the presentation owns one shared transport while avoiding a second
        // collapse/reopen cycle that would add no new focus evidence.
        let notes = app.descendants(matching: .any)["wilted-player-notes"]
        notes.click()
        let notesText = app.descendants(matching: .any)["wilted-player-notes-text"]
        XCTAssertTrue(notesText.waitForExistence(timeout: 5))
        XCTAssertTrue(
            visibleText(of: notesText).contains("Guest: Ada Ferris"),
            "Show notes pane must show the feed's notes"
        )
        XCTAssertTrue(fullWindow.waitForExistence(timeout: 5))
        XCTAssertEqual(notes.value as? String, "Expanded")
        XCTAssertEqual(notes.label, "Hide Notes")

        let menuButton = app.descendants(matching: .any)["wilted-player-menu"]
        menuButton.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-player-notes-expanded"].waitForNonExistence(timeout: 5)
        )
        let menu = app.descendants(matching: .any)["wilted-mac-menu-detail"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(fullWindow.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-menu-empty"].exists)

        let menuTranscript = app.descendants(matching: .any)["wilted-player-transcript"]
        XCTAssertTrue(menuTranscript.waitForExistence(timeout: 5))
        menuTranscript.click()
        XCTAssertTrue(transcriptExpansion.waitForExistence(timeout: 5),
                      "Transcript must open from Menu's bound Now Playing controls")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(transcriptExpansion.waitForNonExistence(timeout: 5))
        XCTAssertTrue(menu.waitForExistence(timeout: 5))

        app.descendants(matching: .any)["wilted-navigation-settings"].click()
        XCTAssertTrue(fullWindow.waitForNonExistence(timeout: 5))
        let settings = app.descendants(matching: .any)["wilted-mac-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.typeKey(.space, modifierFlags: [])
        XCTAssertFalse(fullWindow.exists, "Space must not reopen Now Playing after sidebar navigation")
        XCTAssertTrue(settings.exists, "Settings must remain visible after the stale focus regression probe")
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(library.exists)
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
        XCTAssertFalse(status.exists, "Plain playback state is conveyed by the play/pause transport")
        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertTrue(["Play", "Pause"].contains(playPause.label))

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
        XCTAssertFalse(routeRecovery.exists, "Recover audio appears only after automatic route recovery fails")
    }
    func testArticleFlowAddsThenCancelsPreparation() {
        let app = launch(arguments: ["--wilted-ui-fixture-article-flow"])

        let trigger = app.descendants(matching: .any)["wilted-add-article-button"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.click()
        let url = app.descendants(matching: .any)["wilted-link-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.click()
        url.typeText("https://example.test/article")

        let add = app.descendants(matching: .any)["wilted-add-link"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()

        app.descendants(matching: .any)["wilted-navigation-processor"].click()
        let progress = app.descendants(matching: .any)["wilted-preparation-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let cancel = app.descendants(matching: .any)["wilted-cancel-preparation"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()

        let detail = app.descendants(matching: .any)["wilted-preparation-detail"]
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-processor-idle"].waitForExistence(timeout: 5))
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

    /// The words an element shows. macOS puts a Text's words in its value, not
    /// its label, and a Text with links can hand each run to a child, so the
    /// element and its static-text descendants are read together.
    private func visibleText(of element: XCUIElement) -> String {
        let own = [element.value as? String, element.label].compactMap { $0 }
        let children = element.descendants(matching: .staticText).allElementsBoundByIndex
            .map { $0.value as? String ?? $0.label }
        return (own + children).joined(separator: " ")
    }

    /// Walkthrough frame 6.4 has never captured. The model half of this path is
    /// held down in WiltedMacModelTests; this is the view half, in the gate
    /// where it can be iterated without seizing the screen for a full capture.
    /// If this passes and the capture still fails, the fault is the harness.
    /// Walkthrough frame 6.4 never captured, across eight attempts. The cause
    /// was not the frame: the playing fixture launched already showing "Audio
    /// route recovery failed.", because it opened an article and then toggled
    /// playback, and the toggle beat the load. Frames 6.1 to 6.3 captured
    /// anyway, so the walkthrough had been documenting a faulted player.
    /// The walkthrough capture failed eight times at frame 6.4. The first of
    /// two causes was not the frame: the playing fixture launched already
    /// showing "Audio route recovery failed.", because it opened an article and
    /// then toggled playback, and the toggle beat the load. Frames 6.1 to 6.3
    /// captured anyway -- the rail draws with the fault banner present -- so the
    /// walkthrough had been documenting a faulted player and only the last frame
    /// said so.
    ///
    /// A second finding from the same capture is still open and is probably not
    /// an app defect: after Transcript or Up Next was expanded and collapsed, a
    /// click on a Larder row did not land. Expanding either one replaces the
    /// pane with the full-window player, where those rows are correctly
    /// disabled, so the likeliest reading is that the capture never got back to
    /// Larder. Tracked on its own, with this test's shape as the starting point.
    func testThePlayingFixtureComesUpWithoutAnAudioFault() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        XCTAssertTrue(app.descendants(matching: .any)["wilted-player-play-pause"]
            .waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-recoverable-error"]
            .waitForExistence(timeout: 3),
                       "a fixture that starts faulted documents a broken player")

        // The handoff itself works, which is what separates the fault above
        // from the click problem tracked separately.
        let playEpisode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-play-'"))
            .firstMatch
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 10))
        playEpisode.click()
        let notes = app.descendants(matching: .any)["wilted-player-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 15),
                      "an episode started while an article plays takes the rail over")
        notes.click()
        XCTAssertTrue(app.descendants(matching: .any)["wilted-player-notes-expanded"]
            .waitForExistence(timeout: 10))
    }

    /// The publisher's speaker names reach the reader, and only where the
    /// voice changes. The fixture episode alternates two people with one
    /// unattributed line between them, so this covers the whole rule: the
    /// first attributed line is labelled, a change is labelled, a line nobody
    /// was credited with is not, and a return to a previous voice is.
    ///
    /// Asserted through the cue's spoken label rather than the drawn heading.
    /// The heading is `accessibilityHidden` so the name is not announced twice,
    /// which means the label is the only place a reader who cannot see the
    /// screen learns the voice changed -- and so it is the thing worth pinning.
    func testTheTranscriptNamesWhoIsSpeakingWhereTheVoiceChanges() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        let playEpisode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-episode-play-'"))
            .firstMatch
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 15))
        playEpisode.click()

        let transcript = app.descendants(matching: .any)["wilted-player-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        transcript.click()

        let prefix = "wilted-now-playing-synced-transcript-cue-"
        let first = app.descendants(matching: .any)["\(prefix)0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10),
                      "a published transcript with cues follows the playback clock")
        XCTAssertTrue(first.label.contains("Angie"),
                      "the first attributed line says who is talking")
        XCTAssertTrue(app.descendants(matching: .any)["\(prefix)1"].label.contains("Chris"),
                      "the voice changed, so the new name is announced")
        let unattributed = app.descendants(matching: .any)["\(prefix)2"].label
        XCTAssertFalse(unattributed.contains("Angie") || unattributed.contains("Chris"),
                       "a line the publisher credited to nobody carries no name")
        XCTAssertTrue(app.descendants(matching: .any)["\(prefix)3"].label.contains("Angie"),
                      "the voice came back, so the name is announced again")
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
