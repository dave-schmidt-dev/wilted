import XCTest

@MainActor
extension WiltedMacJourneyUITests {
    func test02ShowSettingsUsesTheSameFeedIDFromFeedsLarderAndAllShows() throws {
        let app = try launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        let navLarder = app.descendants(matching: .any)["wilted-navigation-larder"]
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 5))
        XCTAssertTrue(navLarder.waitForExistence(timeout: 5))
        XCTAssertTrue(navSettings.waitForExistence(timeout: 5))

        navFeeds.click()
        let feedName = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-name-' AND label == 'Settings for Field Notes'")
        ).firstMatch
        XCTAssertTrue(feedName.waitForExistence(timeout: 5))
        let feedID = String(feedName.identifier.dropFirst("wilted-podcast-feed-name-".count))
        let page = app.descendants(matching: .any)["wilted-show-settings-page-\(feedID)"]

        feedName.click()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "Feeds opens settings for the selected feed ID")
        app.buttons["wilted-feed-sheet-done"].click()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))

        let episodeTitle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-show-notes-' AND label == 'Show notes for Quiet Machines'")
        ).firstMatch
        XCTAssertTrue(episodeTitle.waitForExistence(timeout: 5))
        let episodeID = String(episodeTitle.identifier.dropFirst("wilted-feeds-show-notes-".count))
        let keep = app.buttons["wilted-feeds-keep-\(episodeID)"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()

        navLarder.click()
        let larderRow = app.descendants(matching: .any)["wilted-larder-row-\(episodeID)"]
        XCTAssertTrue(larderRow.waitForExistence(timeout: 5))
        larderRow.rightClick()
        let larderSettings = app.menuItems["wilted-larder-show-settings-\(feedID)"]
        XCTAssertTrue(larderSettings.waitForExistence(timeout: 5))
        larderSettings.click()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "Larder opens the same feed ID")
        app.buttons["wilted-feed-sheet-done"].click()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))

        navSettings.click()
        element(app, "wilted-settings-tab-ads-providers").click()
        let consentSummary = app.buttons["wilted-ad-finding-consent-summary"]
        XCTAssertTrue(consentSummary.waitForExistence(timeout: 5))
        consentSummary.click()
        let allShowsPage = app.descendants(matching: .any)["wilted-settings-all-shows-page"]
        XCTAssertTrue(allShowsPage.waitForExistence(timeout: 5))
        app.buttons["wilted-settings-all-show-\(feedID)"].click()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "All shows opens the same feed ID")
    }

    /// Absorbs:
    /// - testEachDestinationExclusivelyOccupiesTheDetailRegion
    /// - testSidebarListsDestinationsOnlyAndNotTheArticleList (sidebar assertion only)
    /// - testFeedsPageOwnsSubscribingAndTheLarderAsksForAnArticle
    /// - testLarderArticleRowOffersRemoval
    /// - testFeedsPageListsPodcastFeedsWithPerFeedControls
    func test01IntakeJourneyAcrossLarderFeedsAndSettings() throws {
        let app = try launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-window-width", "900"])

        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        let navLarder = app.descendants(matching: .any)["wilted-navigation-larder"]
        let navSettings = app.descendants(matching: .any)["wilted-navigation-settings"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 5))
        XCTAssertTrue(navLarder.waitForExistence(timeout: 5))
        XCTAssertTrue(navSettings.waitForExistence(timeout: 5))
        XCTAssertEqual(navLarder.label, "Larder")
        XCTAssertEqual(navFeeds.label, "Feeds")
        XCTAssertEqual(navSettings.label, "Settings")
        XCTAssertFalse(app.descendants(matching: .any)["wilted-navigation-nowPlaying"].exists)

        // macOS exposes the real minimized idle content rather than its SwiftUI wrapper.
        let compact = app.descendants(matching: .any)["wilted-player-idle"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        XCTAssertEqual(compact.value as? String, "Minimized")
        let idle = compact
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        XCTAssertEqual(idle.label, "Nothing is playing")
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-play-pause"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-scrubber"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-speed"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-player-keyboard-transports"].exists)

        let larderEmpty = app.descendants(matching: .any)["wilted-larder-empty"]
        // The toolbar owns Add; the redundant Larder hint stays removed.
        let removedAddHint = app.descendants(matching: .any)["wilted-larder-add-hint"]
        let syncControls = app.descendants(matching: .any)["wilted-sync-controls"]
        let seededArticle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-article-row-'")
        ).firstMatch
        XCTAssertTrue(seededArticle.waitForExistence(timeout: 5), "the ready fixture seeds an article")
        XCTAssertFalse(larderEmpty.exists, "a seeded article makes the initial Larder nonempty")
        XCTAssertFalse(removedAddHint.exists, "the redundant Add hint must remain absent")
        let search = app.textFields["wilted-larder-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.label, "Search episodes")
        XCTAssertEqual(search.placeholderValue ?? "", "")
        app.typeKey("f", modifierFlags: .command)
        app.typeText("garden")
        XCTAssertEqual(search.value as? String, "garden", "Find focuses the visible toolbar search field")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        XCTAssertFalse(syncControls.exists)

        // Feeds is its own destination, so the feed card must not follow the
        // add box onto the Feeds page.
        XCTAssertFalse(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)

        let duplicateRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-sidebar-article-'"))
        XCTAssertEqual(duplicateRows.count, 0)

        // Opening the sheet is part of the journey: a button that draws but opens
        // nothing would leave the field unreachable and this test still passing.
        let trigger = app.descendants(matching: .any)["wilted-add-button"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 8))
        XCTAssertEqual(trigger.label, "Add", "The toolbar opens the Add sheet")
        trigger.click()

        let add = app.descendants(matching: .any)["wilted-add-field"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the trigger must open the Add sheet's field")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(add.waitForNonExistence(timeout: 8), "Escape closes the Add sheet before article menu interaction")
        app.activate()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-article-row-'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        let actions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-article-actions-'"))
            .firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isEnabled, "the article actions popover button is enabled")
        XCTAssertGreaterThan(actions.frame.width, 0)
        XCTAssertGreaterThan(actions.frame.height, 0)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.frame.contains(actions.frame), "the article actions popover button is inside the fixture window")
        // A centered HID click bypasses XCTest's rejected AX click; the Delete outcome below proves it opened.
        actions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // Drive the removal rather than merely proving the control is drawn.
        // This is the library's only destructive path, so "the menu exists" is
        // not evidence that pressing it removes anything.
        let remove = app.buttons["Delete…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        confirmRemoval(in: app, label: "Confirm delete")

        XCTAssertTrue(
            row.waitForNonExistence(timeout: 10),
            "Delete left the article on screen; the row must disappear once the item is tombstoned."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-larder-empty"].waitForExistence(timeout: 10),
            "Removing the only article must fall back to the Larder's empty state."
        )
        XCTAssertFalse(removedAddHint.exists, "the empty Larder must not restore the removed Add hint")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5), "Deleting the only article must leave the toolbar Add button available")
        XCTAssertTrue(trigger.isEnabled)
        XCTAssertTrue(trigger.isHittable, "The real Add entry point remains reachable after deletion")

        navFeeds.click()
        let card = app.descendants(matching: .any)["wilted-podcast-feeds"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "navigation opens the podcast feeds card")
        XCTAssertTrue(card.exists)
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(removedAddHint.exists)
        XCTAssertFalse(larderEmpty.exists)
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

        let feedName = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-name-'")
        ).firstMatch
        XCTAssertTrue(feedName.waitForExistence(timeout: 5))
        feedName.click()
        let showSettingsPage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-show-settings-page-'")
        ).firstMatch
        XCTAssertTrue(showSettingsPage.waitForExistence(timeout: 5), "the feed name opens Show settings")
        for section in ["new-episodes", "playback", "ads", "type", "details"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["wilted-show-settings-section-\(section)"].exists,
                "Show settings includes the \(section) section"
            )
        }
        let sourceFacts = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feed-details-source-facts-'")
        ).firstMatch
        XCTAssertTrue(sourceFacts.waitForExistence(timeout: 5), "the page keeps source facts in Details")
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feed-details-source-' AND NOT identifier BEGINSWITH 'wilted-feed-details-source-facts-'")
        ).firstMatch.exists, "details includes the stored source URL")
        let detailsDone = app.buttons["wilted-feed-sheet-done"]
        XCTAssertTrue(detailsDone.waitForExistence(timeout: 5))
        detailsDone.click()
        XCTAssertTrue(sourceFacts.waitForNonExistence(timeout: 5))
        let rename = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-rename-'")
        ).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()
        let nameEditor = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-name-editor-'")
        ).firstMatch
        XCTAssertTrue(nameEditor.waitForExistence(timeout: 5), "the pencil opens rename")
        nameEditor.click()
        nameEditor.typeKey("a", modifierFlags: .command)
        nameEditor.typeText("Draft rename")
        XCTAssertEqual(nameEditor.value as? String, "Draft rename", "the editor accepted focused text entry")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(nameEditor.waitForNonExistence(timeout: 5), "Escape cancels rename")
        XCTAssertTrue(feedName.exists)

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

        let feedTrigger = app.descendants(matching: .any)["wilted-add-button"]
        XCTAssertTrue(feedTrigger.waitForExistence(timeout: 8), "the toolbar Add button opens the Add sheet")
        feedTrigger.click()

        let field = app.descendants(matching: .any)["wilted-add-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8), "the toolbar button must open the Add sheet")
        field.click()
        field.typeText("not-an-address")
        // A string that is neither a link nor a catalogue hit offers no result action, so the
        // sheet answers with a status instead of subscribing.
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-add-status"].waitForExistence(timeout: 8),
            "an unusable entry must be answered in the sheet"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-podcast-feeds"].exists,
            "the subscription list stays on the page the sheet subscribes into"
        )
        app.typeKey(.escape, modifierFlags: [])

        navSettings.click()
        XCTAssertTrue(element(app, "wilted-settings-tab-listening").waitForExistence(timeout: 5))
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-settings-tab-'"))
        XCTAssertEqual(tabs.count, 4)
        let sectionButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'wilted-settings-section-'"))
        XCTAssertEqual(sectionButtons.count, 0)
        var previousTab: XCUIElement?
        for (tab, sections) in [
            ("listening", [("general", "wilted-text-scale"), ("preparing", "wilted-automation-processing-policy")]),
            ("feeds-reports", [("new-episodes", "wilted-automation-status"), ("reports", "wilted-reports-controls")]),
            ("ads-providers", [("ads", "wilted-automation-remove-ads"), ("providers", "wilted-providers-page")]),
            ("library-sync", [("devices", "wilted-sync-controls"), ("about", "wilted-lifetime-statistics")])
        ] {
            let selector = element(app, "wilted-settings-tab-\(tab)")
            XCTAssertTrue(selector.waitForExistence(timeout: 5), tab)
            if let previousTab {
                XCTAssertGreaterThanOrEqual(selector.frame.minX, previousTab.frame.maxX, tab)
                XCTAssertEqual(selector.frame.midY, previousTab.frame.midY, accuracy: 1, tab)
            }
            previousTab = selector
            selector.click()
            for (section, control) in sections {
                XCTAssertTrue(element(app, "wilted-settings-section-\(section)").waitForExistence(timeout: 5), section)
                XCTAssertTrue(element(app, control).waitForExistence(timeout: 5), section)
            }
            if tab == "feeds-reports" {
                let addSource = app.buttons["wilted-reports-add-news-feed"]
                addSource.click()
                let address = app.textFields["wilted-reports-headline-feed-address"]
                XCTAssertTrue(address.waitForExistence(timeout: 5))
                address.click()
                address.typeText("not-a-feed")
                app.buttons["wilted-reports-headline-feed-add"].click()
                XCTAssertTrue(element(app, "wilted-reports-headline-feed-error").waitForExistence(timeout: 5))
                XCTAssertEqual(address.value as? String, "not-a-feed")
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(address.waitForNonExistence(timeout: 5))
                XCTAssertTrue(addSource.exists, "closing headline setup returns to Reports")
            }
            if tab == "ads-providers" {
                let page = element(app, "wilted-providers-page")
                let rows = page.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH 'wilted-providers-card-'"))
                XCTAssertEqual(rows.count, 7)
                for provider in ["openCodeCLI", "claudeCodeCLI", "codexCLI", "opencodeGoKey",
                                 "openRouterKey", "openAIKey", "anthropicKey"] {
                    let row = rows["wilted-providers-card-\(provider)"]
                    XCTAssertTrue(row.buttons["wilted-providers-check-\(provider)"].exists, provider)
                    XCTAssertTrue(row.staticTexts["wilted-providers-status-\(provider)"].exists, provider)
                    let tag = row.staticTexts["wilted-providers-in-use-\(provider)"]
                    XCTAssertEqual(tag.exists, provider == "opencodeGoKey", provider)
                    if tag.exists { XCTAssertEqual(tag.label, "Selected for ad finding") }
                }
                XCTAssertFalse(page.staticTexts["Kind"].exists)
                let checkAll = page.buttons["wilted-providers-check-all"]
                XCTAssertTrue(checkAll.exists)
                app.buttons["wilted-ad-finding-setup-providers"].click()
                XCTAssertTrue(waitForHittable(checkAll, timeout: 5),
                              "Set up providers must scroll the row actions into view")
            }
        }
        XCTAssertTrue(syncControls.waitForExistence(timeout: 5))
        XCTAssertFalse(removedAddHint.exists)
        XCTAssertTrue(compact.exists)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-mac-feeds-detail"].exists)

        navLarder.click()
        XCTAssertTrue(larderEmpty.waitForExistence(timeout: 5))
        XCTAssertFalse(removedAddHint.exists, "Returning to the Larder must not restore the removed Add hint")
        XCTAssertTrue(compact.exists)
        XCTAssertFalse(syncControls.exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-podcast-feeds"].exists)

        let finalAddButton = app.descendants(matching: .any)["wilted-add-button"]
        XCTAssertTrue(finalAddButton.waitForExistence(timeout: 8), "the toolbar Add button opens the Add sheet")
        XCTAssertTrue(finalAddButton.isEnabled)
        XCTAssertTrue(finalAddButton.isHittable, "The real Add entry point remains reachable after returning to the Larder")
        finalAddButton.click()
        XCTAssertTrue(
            add.waitForExistence(timeout: 8),
            "Opening the Larder's Add button after the roundtrip must expose the Add sheet's field."
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Absorbs:
    /// - testLarderSearchFiltersAndTheFeedsRestorePath
    /// - testUnpreparedEpisodeHasNoListeningActionAndTheLarderOwnsItsStep
    /// - the Feeds show-notes popover
    func test02EpisodeDecisionJourneyFromFeedsToLarder() throws {
        let app = try launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
            "--wilted-ui-fixture-download-failure",
            "--wilted-ui-fixture-window-width", "1200"
        ])

        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(navFeeds.waitForExistence(timeout: 8))
        navFeeds.click()

        let feedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-row-'")
        ).firstMatch
        XCTAssertTrue(feedRow.waitForExistence(timeout: 8))
        let episodeID = String(feedRow.identifier.dropFirst("wilted-feeds-row-".count))
        XCTAssertFalse(episodeID.isEmpty, "the matched Feeds row exposes its episode ID")

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
        let skip = app.buttons["wilted-feeds-skip-\(episodeID)"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        XCTAssertTrue(skip.isEnabled, "the episode Skip action is enabled")
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
        let historySearch = app.textFields["wilted-feed-history-search"]
        XCTAssertTrue(historySearch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-feed-history-feed-filter"].exists)
        let statusFilter = app.descendants(matching: .any)["wilted-feed-history-status-filter"]
        XCTAssertTrue(statusFilter.exists)
        historySearch.click()
        historySearch.typeText("no-matching-history-episode")
        XCTAssertTrue(restore.waitForNonExistence(timeout: 5), "history search filters Restore rows")
        XCTAssertTrue(app.descendants(matching: .any)["wilted-feed-history-empty"].exists)
        historySearch.typeKey("a", modifierFlags: .command)
        historySearch.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        statusFilter.click()
        let skippedFilter = app.menuItems["Skipped"]
        XCTAssertTrue(skippedFilter.waitForExistence(timeout: 5))
        skippedFilter.click()
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "Skipped retains the skipped episode")
        restore.click()
        let historyDone = app.buttons["wilted-feed-sheet-done"]
        XCTAssertTrue(historyDone.waitForExistence(timeout: 5))
        historyDone.click()
        XCTAssertTrue(historySearch.waitForNonExistence(timeout: 5), "Done closes history before returning to Feeds")
        XCTAssertTrue(feedRow.waitForExistence(timeout: 5), "Restore returns the row to Feeds")

        // Keep is the other half of the one decision Feeds owns.
        // It is made from the notes popover; the row's Keep is driven headlessly by WiltedMacPlaybackJourneyTests.
        showNotes.click()
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-decide-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()

        // The Larder waits the kept row with its one next step.
        let navLarder = app.descendants(matching: .any)["wilted-navigation-larder"]
        navLarder.click()
        let larderRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-larder-row-'")
        ).firstMatch
        XCTAssertTrue(larderRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Not downloaded"].exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-larder-download-'")
        ).firstMatch.exists, "an Available row offers its one next step")
        XCTAssertEqual(larderRow.descendants(matching: .button).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-larder-play-'")
        ).count, 0, "an Available row cannot claim to be playable")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-larder-skip-' OR identifier BEGINSWITH 'wilted-larder-mark-completed-'")
        ).count, 0, "an unstarted row has no skip or completion action")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-larder-remove-'")
        ).firstMatch.exists)

        // Search narrows the Larder and never the queue.
        let search = app.textFields["wilted-larder-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Quiet")
        XCTAssertTrue(larderRow.waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("missing")
        XCTAssertTrue(app.descendants(matching: .any)["wilted-larder-empty"].waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(larderRow.waitForExistence(timeout: 5))

        // The group action captures the Articles filter. Cancel leaves the row available for a retry.
        let kinds = app.descendants(matching: .any)["wilted-larder-kind"]
        kinds.click()
        app.menuItems["Articles"].click()
        let clear = app.buttons["wilted-larder-clear-ready"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(clear.label, "Delete 1 article in Ready")
        clear.click()
        let confirm = app.buttons["wilted-larder-clear-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(clear.exists)
        clear.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))
        kinds.click()
        app.menuItems["All"].click()
        XCTAssertTrue(app.buttons["wilted-larder-show-notes-\(episodeID)"].waitForExistence(timeout: 5),
                      "the hidden podcast is still in Larder after the article is deleted")

        // The same journey ends with a wide playing fixture to exercise the side pane.
        let playing = try launch(arguments: ["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts",
                                             "--wilted-ui-fixture-window-width", "1400"])
        let itemTitle = playing.descendants(matching: .any)["wilted-player-item-title"]
        XCTAssertTrue(itemTitle.waitForExistence(timeout: 10), "the actual playing item is visible in the side pane")
        XCTAssertGreaterThan(itemTitle.frame.minX, playing.windows.firstMatch.frame.midX,
                             "the real item title occupies the side pane beside the Larder")
        let completion = playing.buttons["wilted-player-mark-completed"]
        XCTAssertTrue(completion.waitForExistence(timeout: 5))
        XCTAssertTrue(completion.isHittable, "completion stays visible beside transport")
        XCTAssertTrue(playing.buttons["wilted-player-play-pause"].isHittable)
        let speed = playing.descendants(matching: .any)["wilted-player-speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 5), "speed sits in the Transcript and Notes row")
        XCTAssertTrue(speed.isHittable)
        // By identifier: the Apple menu carries its own hidden "Restart" item.
        let restartItem = playing.menuItems["wilted-player-restart"]
        XCTAssertFalse(restartItem.exists, "Restart stays inside the closed More menu")
        playing.descendants(matching: .any)["wilted-player-menu"].click()
        XCTAssertTrue(restartItem.waitForExistence(timeout: 5), "More opens the native menu with Restart")
        playing.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(restartItem.waitForNonExistence(timeout: 5))
        XCTAssertTrue(completion.isHittable)

        // The fixture clock stays put: a forward press establishes a measurable
        // playhead, and Cmd-R must reset it while the More menu stays closed.
        let position = playing.sliders["wilted-player-scrubber"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        playing.buttons["wilted-player-forward"].click()
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in Double(String(describing: position.value ?? "")) == 30 }, object: position
        )
        XCTAssertEqual(XCTWaiter().wait(for: [advanced], timeout: 5), .completed,
                       "the forward transport establishes 30 seconds before restart")
        XCTAssertFalse(restartItem.exists)
        playing.typeKey("r", modifierFlags: .command)
        let restarted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in Double(String(describing: position.value ?? "")) == 0 }, object: position
        )
        XCTAssertEqual(XCTWaiter().wait(for: [restarted], timeout: 5), .completed,
                       "Command-R resets the actual playhead with the More menu closed")
        XCTAssertFalse(restartItem.exists, "restart does not open the More menu")
    }

    /// Uses the label when the removal dialog drops its button identifier.
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

    private func launch(arguments: [String]) throws -> XCUIApplication {
        try openFixture(arguments + ["--wilted-ui-fixture-window-trace"], prefix: "wilted-ui-test")
    }
}
