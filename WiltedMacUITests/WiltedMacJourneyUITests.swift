import XCTest

/// Every Mac UI journey, in one class sharing one app launch
/// (`WiltedMacUIFixtureSession`). XCTest runs a class's methods in name
/// order, so the numbers fix the order; Quit is last because it ends the
/// process. Each journey still opens its own fresh fixture and fails under
/// its own name. The journeys live in extensions beside their helpers:
/// 01-02 `WiltedMacSmokeUITests.swift`, 03 `WiltedMacSidebarChromeUITests.swift`,
/// 04-06 `WiltedMacEpisodeInfoUITests.swift`, 07-08 `WiltedMacPlaylistUITests.swift`,
/// 09 `WiltedMacQuitUITests.swift`.
@MainActor
final class WiltedMacJourneyUITests: XCTestCase {
    var latestFixtureRoot: URL?
    let savedNotes = "A walk through the machines that keep the field office quiet."
    let savedTranscript = "Welcome back to Field Notes. Today, the machines that keep the office quiet."

    nonisolated override class func tearDown() {
        MainActor.assumeIsolated { WiltedMacUIFixtureSession.finish() }
        super.tearDown()
    }

    /// Switches the shared app to a fresh fixture in its own owned root.
    func openFixture(_ arguments: [String], prefix: String) throws -> XCUIApplication {
        let (app, root) = try WiltedMacUIFixtureSession.open(arguments, prefix: prefix, for: self)
        latestFixtureRoot = root
        return app
    }

    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// The words an element shows. macOS puts a Text's words in its value, not
    /// its label, and a Text with links can hand each run to a child, so the
    /// element and its static-text descendants are read together.
    func words(_ element: XCUIElement) -> String {
        ([element] + element.staticTexts.allElementsBoundByIndex).map {
            [$0.label, $0.value as? String ?? ""].joined(separator: " ")
        }.joined(separator: " ")
    }

    func attachWindow(_ app: XCUIApplication, name: String) {
        guard app.windows.firstMatch.exists else { return }
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
