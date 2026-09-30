import XCTest

/// Native counterpart to the approved Phase 2 owner-feedback scenarios. This
/// journey is deliberately separate from the smoke suite because it needs
/// presentation-specific fixtures and is run only by the attended owner gate.
@MainActor
final class WiltedMacOwnerFeedbackUITests: XCTestCase {
    private var fixtureStateDirectory: URL?

    /// NAV-001, DECISION-001, LARDER-001, and RESTORE-001. ORDER-001's
    /// comparator has a headless presentation contract; this journey covers
    /// factual metadata and selection interactions.
    func testCanonicalEpisodePresentationJourney() {
        let app = launch(arguments: [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared",
        ])
        let feeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()

        let feedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-row-'")
        ).firstMatch
        XCTAssertTrue(feedRow.waitForExistence(timeout: 10))
        let episodeID = identifierSuffix(of: feedRow, prefix: "wilted-feeds-row-")
        let feedMetadata = app.descendants(matching: .any).matching(
            identifier: "wilted-feeds-metadata-\(episodeID)"
        ).firstMatch
        XCTAssertTrue(feedMetadata.exists, "NAV-001: Feeds renders canonical metadata")
        let feedFacts = feedMetadata.label
        XCTAssertFalse(feedFacts.isEmpty, "NAV-001: Feeds exposes factual show, publication, and source duration")

        let keep = app.buttons["wilted-feeds-keep-\(episodeID)"]
        let skip = app.buttons["wilted-feeds-skip-\(episodeID)"]
        XCTAssertTrue(keep.exists)
        XCTAssertTrue(skip.exists)
        skip.click()
        let offList = app.descendants(matching: .any)["wilted-feeds-off-list-toggle"]
        XCTAssertTrue(offList.waitForExistence(timeout: 10), "RESTORE-001: Skip exposes Off the list")
        let feedManagement = app.descendants(matching: .any)["wilted-podcast-feeds"]
        XCTAssertTrue(feedManagement.exists)
        XCTAssertGreaterThan(offList.frame.minY, feedManagement.frame.minY,
                             "Off the list remains after the feed-management card")
        offList.click()
        let offMetadata = app.descendants(matching: .any)["wilted-feeds-metadata-skipped-\(episodeID)"]
        XCTAssertTrue(offMetadata.waitForExistence(timeout: 5))
        XCTAssertEqual(offMetadata.label, feedFacts,
                       "RESTORE-001: Skip keeps the same factual metadata for the same episode")
        let restore = app.buttons["wilted-feeds-restore-skipped-\(episodeID)"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()
        XCTAssertTrue(feedRow.waitForExistence(timeout: 10), "RESTORE-001: Restore returns the canonical row")
        XCTAssertEqual(feedMetadata.label, feedFacts,
                       "RESTORE-001: Restore returns the same factual metadata")

        let keptRow = app.buttons["wilted-feeds-keep-\(episodeID)"]
        XCTAssertTrue(keptRow.waitForExistence(timeout: 5))
        keptRow.click()
        let larder = app.descendants(matching: .any)["wilted-navigation-menu"]
        XCTAssertTrue(larder.waitForExistence(timeout: 5))
        larder.click()
        let larderMetadata = app.descendants(matching: .any).matching(
            identifier: "wilted-menu-metadata-\(episodeID)"
        ).firstMatch
        XCTAssertTrue(larderMetadata.waitForExistence(timeout: 10),
                      "NAV-001: Larder uses the same canonical metadata")
        XCTAssertEqual(larderMetadata.label, feedFacts,
                       "LARDER-001: Keep preserves show, publication, and source facts")
        let playable = app.buttons["wilted-menu-play-\(episodeID)"]
        XCTAssertTrue(playable.exists, "LARDER-001: only the ready fixture receives Play")
    }

    func testSubscriptionIntakeFixtureAdmitsFiveMetadataRowsThenBulkKeepPreservesTheirFacts() {
        let app = launch(arguments: ["--wilted-ui-fixture-subscription-intake-26"])
        let feeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()
        subscribe(app, url: "https://feeds.example.test/fixture-26.xml", expectedAddedCount: 5)

        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-row-'")
        )
        XCTAssertEqual(rows.count, 5)
        let firstRow = rows.firstMatch
        let episodeID = identifierSuffix(of: firstRow, prefix: "wilted-feeds-row-")
        let feedMetadata = app.descendants(matching: .any)["wilted-feeds-metadata-\(episodeID)"]
        XCTAssertFalse(feedMetadata.label.isEmpty)

        let selectAll = app.descendants(matching: .any)["wilted-feeds-select-all"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.click()
        let keepSelected = app.buttons["wilted-feeds-keep-selected"]
        XCTAssertTrue(keepSelected.isEnabled)
        keepSelected.click()
        let menu = app.descendants(matching: .any)["wilted-navigation-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.click()
        let menuMetadata = app.descendants(matching: .any)["wilted-menu-metadata-\(episodeID)"]
        XCTAssertTrue(menuMetadata.waitForExistence(timeout: 10))
        XCTAssertEqual(menuMetadata.label, feedMetadata.label,
                       "bulk Keep moves metadata exactly once without reshaping its canonical facts")
    }

    func testSubscriptionIntakeFixtureHonorsRequestLocalTenMetadataOverride() {
        let app = launch(arguments: ["--wilted-ui-fixture-subscription-intake-26"])
        let feeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()
        subscribe(
            app, url: "https://feeds.example.test/fixture-26.xml", expectedAddedCount: 10,
            metadataOverride: "10 latest"
        )
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-row-'")
        )
        XCTAssertEqual(rows.count, 10)
    }

    func testSubscriptionOverrideResetsForTheNextFeed() {
        let app = launch(arguments: ["--wilted-ui-fixture-subscription-intake-26"])
        let feeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()

        subscribe(
            app,
            url: "https://feeds.example.test/fixture-ten.xml",
            expectedAddedCount: 10,
            expectedTotalCount: 10,
            metadataOverride: "10 latest"
        )
        subscribe(
            app,
            url: "https://feeds.example.test/fixture-default.xml",
            expectedAddedCount: 5,
            expectedTotalCount: 15
        )
    }

    func testBulkSkipDoesNotReselectAnEpisodeAfterRestore() throws {
        let app = launch(arguments: ["--wilted-ui-fixture-subscription-intake-26"])
        let feeds = app.descendants(matching: .any)["wilted-navigation-feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()
        subscribe(app, url: "https://feeds.example.test/fixture-default.xml", expectedAddedCount: 5)

        let firstRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-row-'")
        ).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let episodeID = identifierSuffix(of: firstRow, prefix: "wilted-feeds-row-")
        app.descendants(matching: .any)["wilted-feeds-select-all"].click()
        app.buttons["wilted-feeds-skip-selected"].click()

        let offList = app.descendants(matching: .any)["wilted-feeds-off-list-toggle"]
        XCTAssertTrue(offList.waitForExistence(timeout: 5))
        offList.click()
        let restore = app.buttons["wilted-feeds-restore-skipped-\(episodeID)"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.click()

        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let keepSelected = app.buttons["wilted-feeds-keep-selected"]
        XCTAssertTrue(keepSelected.waitForExistence(timeout: 5))
        XCTAssertFalse(keepSelected.isEnabled)
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let root = fixtureRoot()
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments + [
            "--wilted-ui-fixture-state-directory", root.path,
        ]
        // Registered after root cleanup, so XCTest's LIFO teardown terminates
        // this app before removing the state directory even if the test fails.
        addTeardownBlock { app.terminate() }
        app.launch()
        // On macOS 27 a fixture app launched by XCUITest can stay inactive, and an inactive app
        // exposes only its menu bar to accessibility, so bring it forward before looking for a window.
        app.activate()
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            XCTFail("Fixture app did not present a window before owner-feedback assertions")
            fatalError("Fixture app window is unavailable")
        }
        return app
    }

    private func fixtureRoot() -> URL {
        if let fixtureStateDirectory { return fixtureStateDirectory }
        let root: URL
        do {
            root = try WiltedMacUITemporaryState.fixtureRoot(prefix: "wilted-owner-feedback-ui")
        } catch {
            XCTFail("Could not resolve owner-feedback fixture parent: \(error)")
            fatalError("Invalid UI fixture parent")
        }
        fixtureStateDirectory = root
        // Register before writing the root, so every failure after allocation
        // still has a dedicated owner cleanup path.
        addTeardownBlock { [root] in
            try WiltedMacUITemporaryState.removeFixtureRoot(root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        } catch {
            XCTFail("Could not create owner-feedback fixture root: \(error)")
            fatalError("The UI test runner temporary directory is unavailable")
        }
        return root
    }

    private func identifierSuffix(of element: XCUIElement, prefix: String) -> String {
        XCTAssertTrue(element.identifier.hasPrefix(prefix), "unexpected identifier \(element.identifier)")
        return String(element.identifier.dropFirst(prefix.count))
    }

    private func subscribe(
        _ app: XCUIApplication,
        url: String,
        expectedAddedCount: Int,
        expectedTotalCount: Int? = nil,
        metadataOverride: String? = nil
    ) {
        let add = app.buttons["wilted-add-feed-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        if let metadataOverride {
            let override = app.descendants(matching: .any)["wilted-podcast-subscribe-initial-metadata-count"]
            XCTAssertTrue(override.waitForExistence(timeout: 5))
            override.click()
            let choice = app.menuItems[metadataOverride]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.click()
        }
        let input = app.textFields["wilted-podcast-feed-url"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText(url)
        let subscribe = app.buttons["wilted-podcast-subscribe"]
        XCTAssertTrue(subscribe.isEnabled)
        subscribe.click()
        let status = app.descendants(matching: .any)["wilted-podcast-subscribe-status"]
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "added with \(expectedAddedCount) episodes"), object: status
        )
        XCTAssertEqual(XCTWaiter().wait(for: [completed], timeout: 10), .completed)
        let count = app.descendants(matching: .any)["wilted-feeds-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "\(expectedTotalCount ?? expectedAddedCount)")
    }
}
