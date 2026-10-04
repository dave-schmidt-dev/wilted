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
/// included, when the test case that requested it finishes.
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

    private final class Registry: NSObject, XCTestObservation, @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var created: [String] = []
        private var observing = false

        var names: [String] { lock.withLock { created } }

        func track(_ name: String) {
            lock.withLock {
                if !observing {
                    observing = true
                    XCTestObservationCenter.shared.addTestObserver(self)
                }
                created.append(name)
            }
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
            let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Preferences", isDirectory: true)
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
}
