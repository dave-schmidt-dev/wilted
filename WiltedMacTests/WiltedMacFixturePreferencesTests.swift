import Foundation
import XCTest
@testable import WiltedMac

/// Fixture launches share the app's bundle identifier, so concurrent Mac test hosts in sibling
/// worktrees used to wipe one fixed defaults suite out from under each other.
@MainActor
final class WiltedMacFixturePreferencesTests: XCTestCase {
    private let fixtureArguments = ["--wilted-ui-fixture-ready"]

    func testTwoFixtureSuitesDoNotSeeEachOthersWrites() {
        let first = WiltedMacModel.fixturePreferencesSuiteName()
        let second = WiltedMacModel.fixturePreferencesSuiteName()
        XCTAssertNotEqual(first, second)
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: first)
            UserDefaults().removePersistentDomain(forName: second)
        }
        let one = WiltedMacModel.fixturePreferences(suiteName: first)
        one.set("mine", forKey: "wilted.test.key")
        let two = WiltedMacModel.fixturePreferences(suiteName: second)
        XCTAssertNil(two.string(forKey: "wilted.test.key"))
        XCTAssertEqual(one.string(forKey: "wilted.test.key"), "mine", "opening another suite does not wipe this one")
    }

    func testAFixtureModelOwnsItsOwnSuiteAndRemovesItWhenClosed() async throws {
        let first = WiltedMacModel(arguments: fixtureArguments, stateDirectoryOverride: wiltedTemporaryDirectory("fixture-prefs-a"),
            preferences: WiltedMacTestPreferences.ephemeral())
        let second = WiltedMacModel(arguments: fixtureArguments, stateDirectoryOverride: wiltedTemporaryDirectory("fixture-prefs-b"),
            preferences: WiltedMacTestPreferences.ephemeral())
        let firstSuite = try XCTUnwrap(first.fixturePreferencesSuite)
        let secondSuite = try XCTUnwrap(second.fixturePreferencesSuite)
        XCTAssertNotEqual(firstSuite, secondSuite)
        XCTAssertTrue(firstSuite.hasPrefix("\(WiltedMacModel.fixturePreferencesSuitePrefix).\(ProcessInfo.processInfo.processIdentifier)."))
        addTeardownBlock { await second.close() }

        first.preferences.set("a", forKey: "wilted.test.key")
        _ = WiltedMacModel(arguments: fixtureArguments, stateDirectoryOverride: wiltedTemporaryDirectory("fixture-prefs-c"),
            preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(first.preferences.string(forKey: "wilted.test.key"), "a", "a later fixture model does not wipe it")
        XCTAssertNil(second.preferences.string(forKey: "wilted.test.key"))
        XCTAssertNotNil(UserDefaults().persistentDomain(forName: firstSuite))

        await first.close()
        XCTAssertTrue(UserDefaults().persistentDomain(forName: firstSuite)?.isEmpty ?? true, "closing the fixture removes its suite")
    }

    func testANonFixtureModelUsesTheSuiteItWasGiven() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let model = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertNil(model.fixturePreferencesSuite)
        XCTAssertTrue(model.preferences === preferences)
    }

    func testSweepRemovesOnlySuitesWhoseProcessIsGone() throws {
        let directory = wiltedTemporaryDirectory("fixture-prefs-sweep")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let prefix = WiltedMacModel.fixturePreferencesSuitePrefix
        let names = [
            "\(prefix).\(gone.processIdentifier).stale",
            "\(prefix).\(ProcessInfo.processInfo.processIdentifier).live",
            "com.example.unrelated",
        ]
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name + ".plist"))
        }

        WiltedMacModel.sweepStaleFixturePreferenceSuites(in: directory)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(remaining, [names[1] + ".plist", names[2] + ".plist"])
    }
}
