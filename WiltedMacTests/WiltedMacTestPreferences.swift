import Foundation
import XCTest

/// The defaults domain unit tests hand `WiltedMacModel`.
///
/// The test host is the app bundle, so `UserDefaults.standard` here is the
/// daily driver's own domain; a model built on it once wrote the Larder
/// order a test chose into the owner's preferences. Every request gets its
/// own suite, named by process and UUID, so concurrently running test hosts
/// never wipe each other's state. A relaunch-style test keeps one returned
/// `UserDefaults` and hands it to both models. Each suite is removed, plist
/// included, when the test case that requested it finishes, and the first
/// request in a host sweeps what exited hosts left behind.
enum WiltedMacTestPreferences {
    static let suitePrefix = "com.zerodelta.wilted.mac.tests"

    static func ephemeral() -> UserDefaults {
        Registry.shared.make(suiteName("ephemeral"))
    }

    /// A per-process, per-call suite name for a test that opens its own
    /// `UserDefaults`; removed with its test case like `ephemeral()`'s.
    static func suiteName(_ label: String) -> String {
        let name = "\(suitePrefix).\(label).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        Registry.shared.track(name)
        return name
    }

    /// The suite names created and not yet removed, for the cleanup test.
    static var liveSuiteNames: [String] { Registry.shared.names }

    /// Removes the plists of suites whose test host has exited.
    ///
    /// `removeAll` deletes each plist when its test finishes, but `cfprefsd`
    /// can write an empty one back afterwards and a killed host never gets
    /// there; over 90,000 had piled up in `~/Library/Preferences`. Every name
    /// carries its creator's PID, so a later host can tell an exited host's
    /// leftovers from a running one's. Capped so one launch never spends long
    /// on a backlog.
    @discardableResult
    static func sweepExitedHostSuites(in directory: URL? = nil, limit: Int = 5_000) -> Int {
        guard let directory = directory ?? preferencesDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var removed = 0
        for entry in entries where removed < limit {
            guard let pid = creatorPID(ofPlist: entry), pid != ownPID, !isRunning(pid) else { continue }
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// The PID in `<suitePrefix>.<label>.<pid>.<UUID>.plist`; nil for any other file.
    static func creatorPID(ofPlist entry: String) -> pid_t? {
        guard entry.hasPrefix(suitePrefix + "."), entry.hasSuffix(".plist") else { return nil }
        let parts = entry.dropLast(".plist".count).split(separator: ".")
        guard parts.count >= 2, UUID(uuidString: String(parts[parts.count - 1])) != nil,
              let pid = pid_t(parts[parts.count - 2]), pid > 0 else { return nil }
        return pid
    }

    /// `EPERM` means the process exists but belongs to someone else.
    private static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private static var preferencesDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
    }

    private final class Registry: NSObject, XCTestObservation, @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var created: [String] = []
        private var observing = false

        var names: [String] { lock.withLock { created } }

        func track(_ name: String) {
            let firstRequest = lock.withLock { () -> Bool in
                created.append(name)
                guard !observing else { return false }
                observing = true
                return true
            }
            guard firstRequest else { return }
            XCTestObservationCenter.shared.addTestObserver(self)
            WiltedMacTestPreferences.sweepExitedHostSuites()
        }

        func make(_ name: String) -> UserDefaults {
            let defaults = UserDefaults(suiteName: name) ?? UserDefaults()
            defaults.removePersistentDomain(forName: name)
            return defaults
        }

        func testCaseDidFinish(_ testCase: XCTestCase) { removeAll() }
        func testBundleDidFinish(_ testBundle: Bundle) { removeAll() }

        private func removeAll() {
            let doomed = lock.withLock { () -> [String] in
                defer { created.removeAll() }
                return created
            }
            let preferences = WiltedMacTestPreferences.preferencesDirectory
            for name in doomed {
                UserDefaults().removePersistentDomain(forName: name)
                if let plist = preferences?.appendingPathComponent("\(name).plist") {
                    try? FileManager.default.removeItem(at: plist)
                }
            }
        }
    }
}

final class WiltedMacTestPreferencesTests: XCTestCase {
    func testTwoSuitesDoNotCollide() {
        let first = WiltedMacTestPreferences.ephemeral()
        first.set("larder", forKey: "origin")
        // A second request must not wipe the first: this is what a
        // concurrent test host's `ephemeral()` used to do to a running test.
        let second = WiltedMacTestPreferences.ephemeral()
        XCTAssertEqual(first.string(forKey: "origin"), "larder")
        XCTAssertNil(second.string(forKey: "origin"))
        second.set("generic", forKey: "origin")
        XCTAssertEqual(first.string(forKey: "origin"), "larder")
        XCTAssertEqual(second.string(forKey: "origin"), "generic")
    }

    func testRelaunchSharesOneSuiteWithinATest() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set(19, forKey: "episode")
        XCTAssertEqual(preferences.integer(forKey: "episode"), 19, "the same instance serves both models")
    }

    func testSuitesAreNamedPerProcessAndRemovedWithTheirTest() {
        _ = WiltedMacTestPreferences.ephemeral()
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(WiltedMacTestPreferences.liveSuiteNames.allSatisfy { $0.contains(".\(pid).") })
        XCTAssertFalse(WiltedMacTestPreferences.liveSuiteNames.isEmpty)
    }

    func testSweepRemovesOnlyExitedHostSuites() throws {
        let directory = try sweepDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = WiltedMacTestPreferences.suitePrefix
        let pid = ProcessInfo.processInfo.processIdentifier
        let names = [
            // Above the macOS PID ceiling, so never a running process.
            "\(prefix).ephemeral.999999.\(UUID().uuidString).plist",
            "\(prefix).ephemeral.\(pid).\(UUID().uuidString).plist",
            // launchd: running, and `kill` answers EPERM rather than success.
            "\(prefix).model-tests.1.\(UUID().uuidString).plist",
            "com.zerodelta.wilted.mac.ui-fixture.999999.\(UUID().uuidString).plist",
            "com.zerodelta.wilted.mac.plist",
            "\(prefix).ephemeral.999999.not-a-uuid.plist",
        ]
        try create(names, in: directory)
        XCTAssertEqual(WiltedMacTestPreferences.sweepExitedHostSuites(in: directory), 1)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(left, Set(names.dropFirst()))
    }

    func testSweepStopsAtItsLimit() throws {
        let directory = try sweepDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = (0..<3).map { _ in "\(WiltedMacTestPreferences.suitePrefix).ephemeral.999999.\(UUID().uuidString).plist" }
        try create(names, in: directory)
        XCTAssertEqual(WiltedMacTestPreferences.sweepExitedHostSuites(in: directory, limit: 2), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testOtherSuitesCarryTheirHostPID() {
        let name = WiltedMacTestPreferences.suiteName("nowplaying-tests")
        XCTAssertEqual(WiltedMacTestPreferences.creatorPID(ofPlist: name + ".plist"),
                       ProcessInfo.processInfo.processIdentifier)
    }

    private func sweepDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("preference-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func create(_ names: [String], in directory: URL) throws {
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }
    }
}
