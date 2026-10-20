import XCTest

/// Cmd-Q through the real larder-bar shortcut. This seizes the screen, so it runs
/// only in the morning `make native-ui` batch, never in an unattended loop.
/// The isolated child-process tests in `WiltedMacTerminationTests` cover the
/// same quit routing headlessly with a directed quit event.
@MainActor
extension WiltedMacJourneyUITests {
    /// Last in the suite: it ends the one shared app process.
    func test09CommandQuitDrainsRepliesOnceAndExits() throws {
        // The journal sits in a root of its own, so the quit fixture's state
        // root holds only what the app wrote.
        let journalRoot = try WiltedMacUITemporaryState.fixtureRoot(prefix: "wilted-ui-quit")
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: false)
        addTeardownBlock { try WiltedMacUITemporaryState.removeFixtureRoot(journalRoot) }
        let journal = journalRoot.appendingPathComponent("termination.jsonl")
        let app = try openFixture([
            "--wilted-ui-fixture-playing",
            "--wilted-ui-fixture-window-width", "1200",
            "--wilted-termination-journal", journal.path,
        ], prefix: "wilted-ui-quit-state")
        XCTAssertTrue(waitFor(timeout: 30) { Self.events(journal).contains { $0["event"] == "ready" } },
                      "the fixture reported ready")

        app.typeKey("q", modifierFlags: .command)

        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "Cmd-Q exits after the drain")
        let events = Self.events(journal)
        XCTAssertTrue(events.contains { $0["event"] == "should-terminate" }, "Cmd-Q entered the delegate")
        XCTAssertEqual(events.filter { $0["event"] == "reply" }.map { $0["detail"] }, ["terminate"])
        let playhead = try XCTUnwrap(events.last { $0["event"] == "playhead" })
        XCTAssertEqual(Double(playhead["position"] ?? ""), 37, "the drained playhead is the fixture's seek")
        XCTAssertGreaterThanOrEqual(Int(playhead["playedMilliseconds"] ?? "") ?? 0, 1_400)
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private static func events(_ journal: URL) -> [[String: String]] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }
}
