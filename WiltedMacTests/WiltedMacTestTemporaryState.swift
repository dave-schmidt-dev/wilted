import Foundation
import XCTest
@testable import WiltedMac

/// One marked root per test case, with separate children for independent stores.
@MainActor
enum WiltedMacTestTemporaryState {
    private static let testTemporaryParentEnvironmentKey = "WILTED_TEST_TMPDIR"
    private static var roots: [ObjectIdentifier: URL] = [:]

    static func directory(for testCase: XCTestCase, suffix: String) -> URL {
        let identifier = ObjectIdentifier(testCase)
        let root: URL
        if let existing = roots[identifier] {
            root = existing
        } else {
            root = testTemporaryParent().appendingPathComponent(
                "wilted-mac-test-\(UUID().uuidString)", isDirectory: true
            )
            roots[identifier] = root
            // Install cleanup before the first filesystem write. Capture values,
            // rather than the test case that retains this teardown block.
            testCase.addTeardownBlock { [root, identifier] in
                try await close(root: root, identifier: identifier)
            }
            do {
                try WiltedMacTemporaryState.markTestRoot(root)
                try WiltedMacTestRootOwnership.bindCreatedRoot(root, parent: root.deletingLastPathComponent())
            } catch {
                XCTFail("Could not create temporary test root: \(error)")
            }
        }

        let directory = root.appendingPathComponent(
            "\(suffix)-\(UUID().uuidString)", isDirectory: true
        )
        do {
            // Fixture stores require the override directory to exist already.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Could not create temporary test directory: \(error)")
        }
        return directory
    }

    /// Uses the runner-owned parent when it is explicitly supplied. Foundation
    /// does not consistently honor `TMPDIR` for `temporaryDirectory`, so an
    /// invalid runner parent must stop this test instead of leaking into the
    /// operating system's shared temporary directory.
    private static func testTemporaryParent() -> URL {
        let value = ProcessInfo.processInfo.environment[testTemporaryParentEnvironmentKey]
        do {
            return try validatedTestTemporaryParent(rawValue: value)
        } catch {
            XCTFail("WILTED_TEST_TMPDIR must name an existing canonical non-symlink directory.")
            fatalError("Invalid WILTED_TEST_TMPDIR: \(value ?? "<unset>")")
        }
    }

    /// Resolves the runner's explicit parent without allocating any files.
    /// Tests call this directly so malformed runner state fails a test rather
    /// than terminating the test host through the caller's fail-closed guard.
    static func validatedTestTemporaryParent(rawValue: String?) throws -> URL {
        try WiltedMacTestRootOwnership.parent(rawValue: rawValue)
    }

    static func close(root: URL, identifier: ObjectIdentifier) async throws {
        await WiltedMacTemporaryState.closeRegisteredModels(forTestRoot: root)
        defer { roots.removeValue(forKey: identifier) }
        try dispose(root: root)
    }

    static func dispose(root: URL) throws {
        if try WiltedMacTestRootOwnership.isManaged(root) { return }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}


extension XCTestCase {
    @MainActor
    func wiltedTemporaryDirectory(_ suffix: String = "fixture") -> URL {
        WiltedMacTestTemporaryState.directory(for: self, suffix: suffix)
    }
}
