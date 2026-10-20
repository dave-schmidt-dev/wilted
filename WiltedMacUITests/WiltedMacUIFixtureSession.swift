import XCTest

/// One app launch for the whole Mac UI suite. The first journey launches the
/// fixture app; every later journey asks the running app to switch to a fresh
/// fixture of its own (`WiltedMacFixtureSession` in the app), so a run takes
/// the screen once instead of relaunching per journey.
///
/// The app answers each `fixture-switch-<n>.json` with `fixture-switch-<n>.ack`
/// after it has drained and closed the previous fixture. A refused or silent
/// switch falls back to a relaunch, which the app's launch ledger then shows.
@MainActor
final class WiltedMacUIFixtureSession {
    private static var shared: WiltedMacUIFixtureSession?
    private static let sessionArgument = "--wilted-ui-fixture-session"
    private static let ledgerVariable = "WILTED_UI_LAUNCH_LEDGER"

    let app = XCUIApplication()
    private var directory: URL?
    private var switches = 0
    /// Every root this runner created, removed once the app has quit.
    private var roots: [URL] = []

    /// Shows `arguments` over a fresh owned state root and returns the app and that root.
    static func open(_ arguments: [String], prefix: String, for test: XCTestCase) throws -> (XCUIApplication, URL) {
        let session = shared ?? WiltedMacUIFixtureSession()
        shared = session
        let root = try session.makeRoot(prefix: prefix)
        let fixture = ["-ApplePersistenceIgnoreState", "YES"] + arguments
            + ["--wilted-ui-fixture-state-directory", root.path]
        if session.app.state == .notRunning {
            try session.launch(fixture)
        } else if let refusal = session.switchApp(to: fixture) {
            XCTContext.runActivity(named: "Fixture switch failed (\(refusal)); relaunching") { _ in }
            try session.launch(fixture)
        }
        let app = session.app
        test.addTeardownBlock { [weak test, session, root] in
            guard let test, (test.testRun?.totalFailureCount ?? 0) > 0 else { return }
            session.attachDiagnostics(to: test, root: root)
        }
        app.activate()
        if !app.wait(for: .runningForeground, timeout: 10) {
            app.activate()
            guard app.wait(for: .runningForeground, timeout: 10) else {
                throw SessionError.unavailable("the fixture app did not reach runningForeground; observed \(app.state)")
            }
        }
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            throw SessionError.unavailable("the fixture app did not present a window; observed \(app.state)")
        }
        return (app, root)
    }

    /// Quits the shared app if a journey left it running, then removes every root.
    static func finish() {
        guard let session = shared else { return }
        shared = nil
        if session.app.state != .notRunning { session.app.terminate() }
        for root in session.roots {
            do { try WiltedMacUITemporaryState.removeFixtureRoot(root) }
            catch { print("wilted.ui.fixture.cleanup-failed root=\(root.path) error=\(error)") }
        }
    }

    private func makeRoot(prefix: String) throws -> URL {
        let root = try WiltedMacUITemporaryState.fixtureRoot(prefix: prefix)
        // Registered before creation, so a failed create still leaves nothing behind.
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// Launches the app with a fresh session directory. A relaunch gets a new
    /// directory too, so the new process never reads an earlier request.
    private func launch(_ fixture: [String]) throws {
        if app.state != .notRunning { app.terminate() }
        let directory = try makeRoot(prefix: "wilted-ui-session")
        self.directory = directory
        switches = 0
        app.launchArguments = fixture + [Self.sessionArgument, directory.path]
        if let ledger = ProcessInfo.processInfo.environment[Self.ledgerVariable] {
            app.launchEnvironment[Self.ledgerVariable] = ledger
        }
        app.launch()
        try WiltedMacUITestApplicationLaunch.reopenFixture(app)
    }

    /// Asks the running app to switch fixtures; nil once it has, else why not.
    private func switchApp(to fixture: [String]) -> String? {
        guard let directory else { return "no session directory" }
        // Close any menu, popover or sheet still tracking the previous fixture.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        switches += 1
        let request = directory.appendingPathComponent("fixture-switch-\(switches).json")
        let ack = directory.appendingPathComponent("fixture-switch-\(switches).ack")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["arguments": fixture])
            try data.write(to: request, options: .atomic)
        } catch {
            return "request write failed: \(error)"
        }
        // The previous fixture drains the way a quit does before the next opens.
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: ack.path) {
            guard Date() < deadline, app.state != .notRunning else { return "no acknowledgment" }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let data = try? Data(contentsOf: ack),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unreadable acknowledgment"
        }
        if let error = answer["error"] as? String { return error }
        return nil
    }

    /// Diagnostics are limited to the synthetic fixture window and its own trace.
    private func attachDiagnostics(to test: XCTestCase, root: URL) {
        let trace = root.appendingPathComponent("ns-window-lifecycle.jsonl", isDirectory: false)
        if let contents = try? String(contentsOf: trace, encoding: .utf8) {
            let attachment = XCTAttachment(string: contents)
            attachment.name = "Fixture native window lifecycle"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        let window = app.windows.firstMatch
        guard app.state != .notRunning, window.exists else { return }
        let hierarchy = XCTAttachment(string: window.debugDescription)
        hierarchy.name = "Fixture window hierarchy"
        hierarchy.lifetime = .keepAlways
        test.add(hierarchy)
        let image = XCTAttachment(screenshot: window.screenshot())
        image.name = "Fixture window"
        image.lifetime = .keepAlways
        test.add(image)
    }

    private enum SessionError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case let .unavailable(message): message }
        }
    }
}
