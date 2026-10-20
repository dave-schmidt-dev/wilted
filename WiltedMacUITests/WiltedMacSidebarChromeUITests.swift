import XCTest

/// One attended journey checks native window chrome across collapse transitions.
@MainActor
extension WiltedMacJourneyUITests {
    func test03CollapsedSidebarKeepsContentBelowWindowControls() throws {
        let app = try openFixture([
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-window-width", "1400",
        ], prefix: "wilted-ui-chrome")
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
}
