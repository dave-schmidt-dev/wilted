import XCTest

@MainActor
final class WiltedMacSmokeUITests: XCTestCase {
    /// The rejected composition rendered one destination unconditionally and
    /// merely appended a player, so selecting a destination changed nothing.
    /// These assertions are the inverse: exactly one destination occupies the
    /// detail region, and switching away actually removes the previous one.
    func testEachDestinationExclusivelyOccupiesTheDetailRegion() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        let navMenu = app.descendants(matching: .any)["wilted-navigation-menu"]
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 5))
        XCTAssertTrue(navMenu.waitForExistence(timeout: 5))
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
        navFeeds.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-feeds-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(addArticle.exists)
        XCTAssertFalse(menuEmpty.exists)

        navSettings.click()
        XCTAssertTrue(syncControls.waitForExistence(timeout: 5))
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-mac-feeds-detail"].exists)

        navMenu.click()
        XCTAssertTrue(addArticle.waitForExistence(timeout: 5))
        XCTAssertTrue(menuEmpty.exists)
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

    /// The Processor destination's active-work report was retired with the
    /// destination; the Menu row reports the state and its controls.
    func testActiveWorkReportHasNoSurfaceAfterTheDestinationRestructure() throws {
        throw XCTSkip("Active-work reporting has no surface after the destination restructure.")
    }

    /// The library had no removal path, so anything added once stayed on
    /// screen permanently. The article row lives on the Menu now.
    /// The library had no removal path, so anything added once stayed on
    /// screen permanently. The article row lives on the Menu now.
    func testMenuArticleRowOffersRemoval() {
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
            app.descendants(matching: .any)["wilted-menu-empty"].waitForExistence(timeout: 10),
            "Removing the only article must fall back to the Menu's empty state."
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
    /// happen. The Menu now says Add article, and the feed composer -- with its
    /// own field, its own button, and its own rejection message -- lives on the
    /// page that keeps subscriptions.
    func testFeedsPageOwnsSubscribingAndTheMenuAsksForAnArticle() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])

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

    /// The daily path: skip in Feeds and reverse it there, keep in Feeds, then
    /// act and search on the Menu.
    func testMenuSearchFiltersAndTheFeedsRestorePath() {
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

        // A skip leaves the list; Feeds owns the reversal.
        let skip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-skip-'")
        ).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.click()
        let restore = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-restore-skipped-'")
        ).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5),
                      "a skipped row must offer Restore on Feeds")
        restore.click()
        XCTAssertTrue(feedRow.waitForExistence(timeout: 5), "Restore returns the row to Feeds")

        // Keep is the other half of the one decision Feeds owns.
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
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
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-download-'")
        ).firstMatch.exists, "an Available row offers its one next step")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")
        ).count, 0, "an Available row cannot claim to be playable")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-skip-'")
        ).firstMatch.exists)
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

    /// The row-level notes control this test drove was deleted with the old
    /// destination. Notes now live in the player, opened from its own pane,
    /// so there is no row surface left to assert here.
    func testEpisodeRowNotesHaveNoSurfaceOnTheMenu() throws {
        throw XCTSkip("Episode notes open from the player pane; no row control remains to drive.")
    }

    /// The re-run menu this test drove was deleted with the old destination.
    /// A ready Menu row offers Play and nothing that starts another run, so
    /// there is no surface left for the intent.
    func testReRunningAReadyEpisodeFromTheRowMenuHasNoSurface() throws {
        throw XCTSkip("A ready Menu row offers Play only; the re-run menu is retired.")
    }

    /// The Menu surfaces ready episodes and owns the bulk step for the group
    /// that has work.
    func testMenuSurfacesReadyEpisodesAndBulkActions() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        // The fixture episode arrives in the Feeds inbox, the way a real one
        // does; the Menu is where it waits once kept. The sibling tests that
        // share these launch arguments keep it first for the same reason.
        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 8))
        navFeeds.click()
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8))
        keep.click()

        let navMenu = app.descendants(matching: .any)["wilted-navigation-menu"]
        XCTAssertTrue(navMenu.waitForExistence(timeout: 5))
        navMenu.click()

        let menuRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-row-'")
        ).firstMatch
        XCTAssertTrue(menuRow.waitForExistence(timeout: 8))
        // The Menu's own playable group, by identifier rather than by copy.
        // The sidebar's "Ready to play" row combines its children into one
        // element, so its label is never that string on its own.
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-menu-ready-count"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["wilted-menu-play-first"].exists)
        XCTAssertTrue(app.buttons["wilted-menu-prepare-all"].exists)
        XCTAssertTrue(app.buttons["wilted-menu-play-first"].isEnabled)
    }

    func testMenuBulkActionsAreDisabledWithHonestEmptyState() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])
        let navMenu = app.descendants(matching: .any)["wilted-navigation-menu"]
        XCTAssertTrue(navMenu.waitForExistence(timeout: 5))
        navMenu.click()
        XCTAssertTrue(app.descendants(matching: .any)["wilted-menu-empty"].waitForExistence(timeout: 5))
        let prepareAll = app.buttons["wilted-menu-prepare-all"]
        XCTAssertTrue(prepareAll.exists)
        XCTAssertFalse(prepareAll.isEnabled)
        let downloadAll = app.buttons["wilted-menu-download-all"]
        XCTAssertTrue(downloadAll.exists)
        XCTAssertFalse(downloadAll.isEnabled)
    }

    func testUnpreparedEpisodeHasNoListeningActionAndTheMenuOwnsItsStep() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-download-failure"
        ])
        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 5))
        navFeeds.click()
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8))
        keep.click()

        app.descendants(matching: .any)["wilted-navigation-menu"].click()
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-row-'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Available"].exists)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")).count, 0,
            "an Available row cannot play before it is downloaded"
        )
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-download-'")
        ).firstMatch.exists)
    }

    /// The Processor destination's run narrative and per-run event log were
    /// retired with the destination. The Menu row carries the state and the
    /// two controls; the file log holds the diagnostics.
    func testRunNarrativeAndEventLogHaveNoSurface() throws {
        throw XCTSkip("Run history and its log have no surface after the destination restructure.")
    }

    /// The sidebar lists destinations only. It used to repeat every article the
    /// detail column already showed.
    func testSidebarListsDestinationsOnlyAndNotTheArticleList() {
        let app = launch(arguments: ["--wilted-ui-fixture-preparing"])

        let navMenu = app.descendants(matching: .any)["wilted-navigation-menu"]
        XCTAssertTrue(navMenu.waitForExistence(timeout: 5))

        let duplicateRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-sidebar-article-'"))
        XCTAssertEqual(duplicateRows.count, 0)

        // The article is present exactly once, in the Menu detail.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-article-row-'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // An article still being read cannot start playback; the persistent
        // idle rail remains truthful and minimized.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-open-now-playing"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-compact-player"]
                .waitForExistence(timeout: 5)
        )
        let idle = app.descendants(matching: .any)["wilted-player-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-play-pause"].exists)
    }

    func testTheMenuNavigatesToNowPlayingControls() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready"])

        let menu = app.descendants(matching: .any)["wilted-mac-menu-detail"]
        let openPlayer = app.descendants(matching: .any)["wilted-open-now-playing"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.click()

        let compact = app.descendants(matching: .any)["wilted-compact-player"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.exists, "Starting article playback must preserve the Menu destination")
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
    func testPodcastCompactPlayerPersistsAcrossDestinationsAndExposesCompleteControls() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])

        // Keep the fixture episode and start it from the Menu's own player.
        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 8))
        navFeeds.click()
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8))
        keep.click()

        let navMenu = app.descendants(matching: .any)["wilted-navigation-menu"]
        navMenu.click()
        let menu = app.descendants(matching: .any)["wilted-mac-menu-detail"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let playEpisode = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")
        ).firstMatch
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 8))
        playEpisode.click()

        let compact = app.descendants(matching: .any)["wilted-compact-player"]
        XCTAssertTrue(compact.waitForExistence(timeout: 8))
        XCTAssertTrue(menu.isHittable)
        for identifier in [
            "wilted-player-speed", "wilted-player-rewind", "wilted-player-play-pause",
            "wilted-player-forward", "wilted-player-transcript",
            "wilted-player-notes", "wilted-player-volume",
            "wilted-player-scrubber", "wilted-player-previous", "wilted-player-next",
            "wilted-player-restart", "wilted-player-keyboard-transports"
        ] {
            XCTAssertEqual(
                app.descendants(matching: .any).matching(identifier: identifier).count, 1,
                "missing or duplicate \(identifier)"
            )
        }

        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "wilted-player-menu").count, 0,
            "on the Menu the player offers no shortcut back to the Menu"
        )

        let playPause = app.descendants(matching: .any)["wilted-player-play-pause"]
        XCTAssertEqual(playPause.label, "Pause")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(playPause.label, "Play", "Space must invoke the compact player's primary shortcut")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(playPause.label, "Pause")

        let itemTitle = app.descendants(matching: .any)["wilted-player-item-title"]
        XCTAssertTrue(itemTitle.waitForExistence(timeout: 5))
        let itemTitleBeforeExpansion = visibleText(of: itemTitle)
        XCTAssertTrue(itemTitleBeforeExpansion.contains("Quiet Machines"))

        // The Menu's inline expansion keeps the same player implementation.
        let transcript = app.descendants(matching: .any)["wilted-player-transcript"]
        transcript.click()
        let transcriptExpansion = app.descendants(matching: .any)["wilted-player-transcript-expanded"]
        XCTAssertTrue(transcriptExpansion.waitForExistence(timeout: 5))
        XCTAssertEqual(transcript.value as? String, "Expanded")
        XCTAssertEqual(visibleText(of: itemTitle), itemTitleBeforeExpansion)
        transcript.click()
        XCTAssertTrue(transcriptExpansion.waitForNonExistence(timeout: 5))
        XCTAssertEqual(transcript.value as? String, "Collapsed")

        // The same live player follows the reader to every other destination.
        navFeeds.click()
        XCTAssertTrue(app.descendants(matching: .any)["wilted-mac-feeds-detail"].waitForExistence(timeout: 5))
        // The player's way back to the Menu exists only off the Menu: on the
        // Menu itself the shortcut would point at the page already showing.
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "wilted-player-menu").count, 1,
            "the player offers one way back to the Menu from another destination"
        )
        XCTAssertTrue(compact.exists)
        XCTAssertTrue(compact.isHittable)
        XCTAssertEqual(playPause.label, "Pause")
        XCTAssertEqual(visibleText(of: itemTitle), itemTitleBeforeExpansion)

        app.descendants(matching: .any)["wilted-navigation-settings"].click()
        let settings = app.descendants(matching: .any)["wilted-mac-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(compact.exists)
        XCTAssertEqual(playPause.label, "Pause")
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
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

        app.descendants(matching: .any)["wilted-navigation-feeds"].click()
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
    /// The article composer's progress and cancel controls were deleted with
    /// the Processor destination, and fixture mode does not persist a composed
    /// article, so there is no surface left to drive the old journey from.
    func testArticleComposerProgressAndCancelHaveNoSurface() throws {
        throw XCTSkip("Article composition has no progress or cancel surface after the destination restructure.")
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
        XCTAssertTrue(app.descendants(matching: .any)["wilted-mac-menu-detail"].exists)
        playPause.click()

        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Pause"), object: playPause
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 5), .completed)

        app.descendants(matching: .any)["wilted-navigation-feeds"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-feeds-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
        XCTAssertEqual(playPause.label, "Pause")

        app.descendants(matching: .any)["wilted-navigation-settings"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-settings"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
        XCTAssertEqual(playPause.label, "Pause")

        app.descendants(matching: .any)["wilted-navigation-menu"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-menu-detail"].waitForExistence(timeout: 5)
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
    /// an app defect: after Transcript was expanded and collapsed, a click on a
    /// waiting row did not land. Expanding replaces the pane with the
    /// full-window player, where those rows are correctly disabled, so the
    /// likeliest reading is that the capture never got back to the destination.
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
        // from the click problem tracked separately. Keeping the episode in
        // Feeds and starting it from the Menu takes the player over.
        app.descendants(matching: .any)["wilted-navigation-feeds"].click()
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 15))
        keep.click()
        app.descendants(matching: .any)["wilted-navigation-menu"].click()
        let playEpisode = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")
        ).firstMatch
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 15))
        playEpisode.click()
        let notes = app.descendants(matching: .any)["wilted-player-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 15),
                      "an episode started while an article plays takes the player over")
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
        app.descendants(matching: .any)["wilted-navigation-feeds"].click()
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 15))
        keep.click()
        app.descendants(matching: .any)["wilted-navigation-menu"].click()
        let playEpisode = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")
        ).firstMatch
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

    /// The full-window player belongs to the destination that presented it.
    /// Sidebar navigation must retire it through the detail's onChange, so the
    /// destination accepts hits again and no overlay still contains the
    /// player.
    func testNavigationChangeClearsTheFullWindowPlayer() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])

        let feeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 15))
        feeds.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-feeds-detail"].waitForExistence(timeout: 10)
        )

        let transcript = app.descendants(matching: .any)["wilted-player-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10),
                      "the rail player must be live off-Menu while the fixture plays")
        transcript.click()
        let fullWindow = app.descendants(matching: .any)["wilted-player-full-window"]
        XCTAssertTrue(fullWindow.waitForExistence(timeout: 10),
                      "expanding from the rail presents the full-window player")

        let settings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()

        let settingsDetail = app.descendants(matching: .any)["wilted-mac-settings"]
        XCTAssertTrue(settingsDetail.waitForExistence(timeout: 10))
        XCTAssertTrue(settingsDetail.isHittable,
                      "the destination must accept hits once navigation retires the player")
        XCTAssertTrue(fullWindow.waitForNonExistence(timeout: 10),
                      "no overlay may still contain the player after a navigation change")
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return app
    }
}
