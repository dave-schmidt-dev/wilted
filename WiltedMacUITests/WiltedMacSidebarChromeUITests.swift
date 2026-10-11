import XCTest

/// One attended journey checks native window chrome across collapse transitions.
@MainActor
final class WiltedMacSidebarChromeUITests: XCTestCase {
    func testCollapsedSidebarKeepsContentBelowWindowControls() throws {
        let app = XCUIApplication()
        let root = try WiltedMacUITemporaryState.fixtureRoot(prefix: "wilted-ui-chrome")
        addTeardownBlock { [weak self] in
            if (self?.testRun?.totalFailureCount ?? 0) > 0 { self?.attachFixtureWindowIfAvailable(app) }
            app.terminate()
            try WiltedMacUITemporaryState.removeFixtureRoot(root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "--wilted-ui-fixture-ready",
            "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-window-width", "1400",
            "--wilted-ui-fixture-state-directory", root.path,
        ]
        app.launch()
        try WiltedMacUITestApplicationLaunch.reopenFixture(app)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let toggle = app.buttons["wilted-sidebar-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let navigation = app.buttons["wilted-navigation-larder"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5), "native sidebar navigation is available")
        let detailViewport = app.scrollViews["wilted-mac-root"]
        XCTAssertTrue(detailViewport.waitForExistence(timeout: 5), "the native detail viewport is available")
        let heading = app.descendants(matching: .any)["wilted-larder-audio-total"]
        let controls = [XCUIIdentifierCloseWindow, XCUIIdentifierMinimizeWindow, "_XCUI:FullScreenWindow"]
            .map { window.buttons[$0] }
        for control in controls { XCTAssertTrue(control.exists, "native window control must be available") }

        for _ in 0..<2 {
            toggle.click()
            let collapsed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in navigation.exists && detailViewport.exists && abs(detailViewport.frame.minX - window.frame.minX - 56) < 2 },
                object: navigation)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed,
                           "Collapse preserves the shipping 56-point navigation rail")
            XCTAssertTrue(heading.waitForExistence(timeout: 5), "first Larder content is available in the rail layout")
            XCTAssertGreaterThan(heading.frame.width, 0)
            for control in controls {
                XCTAssertGreaterThanOrEqual(heading.frame.minY, control.frame.maxY,
                                            "Larder content begins below the native title-bar controls")
                XCTAssertFalse(heading.frame.intersects(control.frame))
            }
            toggle.click()
            let expanded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in navigation.exists && detailViewport.exists && detailViewport.frame.minX - window.frame.minX > 100 },
                object: navigation)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        }
    }

    /// Diagnostics are limited to the synthetic fixture window.
    private func attachFixtureWindowIfAvailable(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.exists else { return }
        let hierarchy = XCTAttachment(string: window.debugDescription)
        hierarchy.name = "Fixture window hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let image = XCTAttachment(screenshot: window.screenshot())
        image.name = "Fixture window"
        image.lifetime = .keepAlways
        add(image)
    }

}
