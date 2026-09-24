import XCTest

@MainActor
final class WiltedMacSmokeUITests: XCTestCase {
    /// Absorbs:
    /// - testEachDestinationExclusivelyOccupiesTheDetailRegion
    /// - testSidebarListsDestinationsOnlyAndNotTheArticleList (sidebar assertion only)
    /// - testLarderSortControlNamesItselfAndExposesEveryOrder
    /// - testFeedsPageOwnsSubscribingAndTheMenuAsksForAnArticle
    /// - testMenuArticleRowOffersRemoval
    /// - testFeedsPageListsPodcastFeedsWithPerFeedControls
    func testIntakeJourneyAcrossLarderFeedsAndSettings() {
        let app = launch(arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])

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

        let sort = app.descendants(matching: .any)["wilted-menu-sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertEqual(sort.label, "Sort Larder: Custom order")

        sort.click()
        for choice in ["Custom order", "Newest", "Oldest", "Length · shortest", "Show · A–Z", "Title · A–Z"] {
            XCTAssertTrue(app.menuItems[choice].exists, "missing Larder sort choice: \(choice)")
        }
        app.menuItems["Oldest"].click()
        XCTAssertEqual(sort.label, "Sort Larder: Oldest")

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
        let message = app.descendants(matching: .any)["wilted-podcast-operation-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 8))
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
        // It is made from the notes popover; the row's Keep is driven by testPodcastPlaybackJourneyAcrossDestinations.
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

    /// Absorbs:
    /// - testThePlayingFixtureComesUpWithoutAnAudioFault
    /// - testMenuSurfacesReadyEpisodesAndBulkActions
    /// - testPodcastCompactPlayerPersistsAcrossDestinationsAndExposesCompleteControls
    /// - testInlineTranscriptFollowsAnOffscreenActiveCueAcrossABoundary
    /// - testNavigationChangeClearsTheFullWindowPlayer
    /// - testTheMenuNavigatesToNowPlayingControls (podcast-applicable assertions)
    /// - testPlayerReportsProgressAndStatusLikeTheListener (podcast-applicable assertions)
    /// - testPlaybackSurvivesDestinationSwitchesAndProducerStaysOneClickAway (podcast-applicable assertions)
    ///
    /// The playing fixture once launched already showing "Audio route recovery
    /// failed." because a playback toggle beat the load, so the walkthrough
    /// documented a faulted player; the first step guards that. A second
    /// finding from the same capture is still open and is probably not an app
    /// defect: after Transcript was expanded and collapsed, a click on a
    /// waiting row did not land. Expanding replaces the pane with the
    /// full-window player, where those rows are correctly disabled, so the
    /// likeliest reading is that the capture never got back to the destination.
    func testPodcastPlaybackJourneyAcrossDestinations() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts",
            "--wilted-ui-fixture-prepared", "--wilted-ui-fixture-long-transcript"
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

        XCTAssertEqual(
            app.descendants(matching: .any)["wilted-player-rewind"].label,
            "Rewind 15 seconds"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["wilted-player-forward"].label,
            "Skip forward 30 seconds"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["wilted-player-scrubber"].label,
            "Playback position"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["wilted-player-status"].exists,
            "Plain playback state is conveyed by the play/pause transport"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["wilted-player-route-recovery"].exists,
            "Recover audio appears only after automatic route recovery fails"
        )

        let scrubber = app.descendants(matching: .any)["wilted-player-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 15))
        scrubber.adjust(toNormalizedSliderPosition: 0.685)

        // The Menu's inline expansion keeps the same player implementation.
        let transcript = app.descendants(matching: .any)["wilted-player-transcript"]
        transcript.click()
        let transcriptExpansion = app.descendants(matching: .any)["wilted-player-transcript-expanded"]
        XCTAssertTrue(transcriptExpansion.waitForExistence(timeout: 5))
        XCTAssertEqual(transcript.value as? String, "Expanded")

        let prefix = "wilted-now-playing-synced-transcript-"
        let startingCue = app.descendants(matching: .any)["\(prefix)cue-67"]
        XCTAssertTrue(startingCue.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForHittable(startingCue),
                      "the active cue must be visible when the inline transcript mounts")
        let nearbyMarker = app.descendants(matching: .any)["\(prefix)removed-5"]
        XCTAssertTrue(nearbyMarker.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForHittable(nearbyMarker),
                      "prepared cuts stay in the synchronized transcript's visible rows")

        scrubber.adjust(toNormalizedSliderPosition: 0.81)
        let advancedCue = app.descendants(matching: .any)["\(prefix)cue-79"]
        XCTAssertTrue(advancedCue.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForHittable(advancedCue),
                      "the next active cue must become visible after the cue boundary")

        XCTAssertEqual(visibleText(of: itemTitle), itemTitleBeforeExpansion)
        transcript.click()
        XCTAssertTrue(transcriptExpansion.waitForNonExistence(timeout: 5))
        XCTAssertEqual(transcript.value as? String, "Collapsed")

        // The same live player follows the reader to every other destination.
        let navFeeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
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

        XCTAssertTrue(compact.exists)
        XCTAssertEqual(playPause.label, "Pause")
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))

        app.descendants(matching: .any)["wilted-navigation-menu"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["wilted-mac-menu-detail"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(compact.exists)
        XCTAssertEqual(playPause.label, "Pause")

        let notes = app.descendants(matching: .any)["wilted-player-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 15),
                      "an episode started while an article plays takes the player over")
        notes.click()
        XCTAssertTrue(app.descendants(matching: .any)["wilted-player-notes-expanded"]
            .waitForExistence(timeout: 10))
    }

    /// Absorbs:
    /// - testSelectingEmptyNowPlayingDoesNotResizeWindow
    /// - testSettingsAutomationControlsRevealOnlyTheRelevantOffPeakWindow
    /// - testQuarantinedSyncOffersAccountReviewAndRecoversFromSettings
    func testSettingsAutomationAndSyncRecoveryJourney() {
        let app = launch(arguments: ["--wilted-ui-fixture-quarantined"])

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

        let controls = app.descendants(matching: .any)["wilted-automation-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-refresh-policy"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["wilted-automation-download-policy"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["wilted-automation-feeds-admission-policy"].exists)
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

        let syncStatus = app.descendants(matching: .any)["wilted-sync-status"]
        XCTAssertTrue(syncStatus.waitForExistence(timeout: 5))
        let quarantined = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Quarantined"), object: syncStatus
        )
        XCTAssertEqual(XCTWaiter().wait(for: [quarantined], timeout: 5), .completed)

        let review = app.descendants(matching: .any)["wilted-sync-use-current-account"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(review.isEnabled)
        review.click()

        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Disabled"), object: syncStatus
        )
        XCTAssertEqual(XCTWaiter().wait(for: [recovered], timeout: 5), .completed)
        XCTAssertFalse(review.exists)
    }

    /// A deferred episode's only way forward is the override, so the leg has
    /// to prove the control exists and that pressing it actually starts the
    /// work rather than just changing the copy.
    ///
    /// The deferred state is stored as `.preparing(stage: "Queued")`, so
    /// asserting on "Preparing…" alone would pass whether or not the override
    /// did anything. The assertion is that the deferral is gone: the row stops
    /// offering "Prepare now".
    func testMenuOverridesAnOffPeakDeferralWithPrepareNow() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-deferred"
        ])
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

        let prepareNow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-prepare-now-'")
        ).firstMatch
        XCTAssertTrue(prepareNow.waitForExistence(timeout: 8),
                      "a deferred episode must offer a way past its off-peak window")
        prepareNow.click()

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: prepareNow
        )
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed,
                       "pressing Prepare now left the episode deferred")
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

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return app
    }
}
