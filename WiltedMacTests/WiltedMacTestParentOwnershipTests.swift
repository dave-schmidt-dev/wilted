import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacTestParentOwnershipTests: XCTestCase {
    func testDanglingOwnerMarkerIsRefusedBeforeBinding() throws {
        let parent = wiltedTemporaryDirectory("dangling-owner")
        let marker = parent.appendingPathComponent(".wilted-temp-owned")
        try FileManager.default.createSymbolicLink(atPath: marker.path,
                                                  withDestinationPath: parent.appendingPathComponent("missing").path)
        let root = parent.appendingPathComponent("created-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try WiltedMacTestRootOwnership.bindCreatedRoot(root, parent: parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(WiltedMacTestRootOwnership.receiptName).path))
    }

    func testLiveMatchingForeignOwnerIsRefusedBeforeBinding() throws {
        let parent = wiltedTemporaryDirectory("foreign-owner")
        let foreign = Process()
        foreign.executableURL = URL(fileURLWithPath: "/bin/sleep")
        foreign.arguments = ["30"]
        try foreign.run()
        defer { foreign.terminate(); foreign.waitUntilExit() }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-o", "lstart=", "-p", String(foreign.processIdentifier)]
        let output = Pipe()
        probe.standardOutput = output
        try probe.run()
        let start = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        probe.waitUntilExit()
        XCTAssertEqual(probe.terminationStatus, 0)
        try "pid=\(foreign.processIdentifier)\nstarted=\(start)\npath=\(parent.path)\n"
            .write(to: parent.appendingPathComponent(".wilted-temp-owned"), atomically: true, encoding: .utf8)
        let root = parent.appendingPathComponent("created-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try WiltedMacTestRootOwnership.bindCreatedRoot(root, parent: parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(WiltedMacTestRootOwnership.receiptName).path))
    }

    func testManagedBindingRejectsMissingPartialAndChangedDeliveredProof() throws {
        let parent = wiltedTemporaryDirectory("delivered-proof")
        let original = ProcessInfo.processInfo.environment
        for mutation in ["missing", "partial", "pid", "started", "path"] {
            var environment = original
            switch mutation {
            case "missing":
                for key in ["WILTED_TEST_OWNER_PID", "WILTED_TEST_OWNER_STARTED", "WILTED_TEST_OWNER_PATH"] {
                    environment.removeValue(forKey: key)
                }
            case "partial": environment.removeValue(forKey: "WILTED_TEST_OWNER_STARTED")
            case "pid": environment["WILTED_TEST_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            case "started": environment["WILTED_TEST_OWNER_STARTED"] = "stale-start"
            default: environment["WILTED_TEST_OWNER_PATH"] = parent.path
            }
            let root = parent.appendingPathComponent(mutation)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            XCTAssertThrowsError(try WiltedMacTestRootOwnership.bindCreatedRoot(root, parent: parent,
                                                                               environment: environment), mutation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(WiltedMacTestRootOwnership.receiptName).path))
        }
    }

    func testManagedBindingRejectsMarkerChangesAfterProofDelivery() throws {
        let parent = wiltedTemporaryDirectory("changed-owner-marker")
        let original = ProcessInfo.processInfo.environment
        let ownerPID = try XCTUnwrap(original["WILTED_TEST_OWNER_PID"])
        let ownerStart = try XCTUnwrap(original["WILTED_TEST_OWNER_STARTED"])
        var environment = original
        environment["WILTED_TEST_OWNER_PATH"] = parent.path
        let marker = parent.appendingPathComponent(".wilted-temp-owned")
        for mutation in ["pid", "started", "path", "missing"] {
            let pid = mutation == "pid" ? String(ProcessInfo.processInfo.processIdentifier) : ownerPID
            let start = mutation == "started" ? "stale-start" : ownerStart
            let path = mutation == "path" ? parent.appendingPathComponent("foreign").path : parent.path
            try "pid=\(pid)\nstarted=\(start)\npath=\(path)\n".write(to: marker, atomically: true, encoding: .utf8)
            if mutation == "missing" { try FileManager.default.removeItem(at: marker) }
            let root = parent.appendingPathComponent(mutation)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            XCTAssertThrowsError(try WiltedMacTestRootOwnership.bindCreatedRoot(root, parent: parent,
                                                                               environment: environment), mutation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(WiltedMacTestRootOwnership.receiptName).path))
        }
    }

    func testAllocatedTestRootUsesRunnerOwnedParentOrFoundationDefault() throws {
        let directory = wiltedTemporaryDirectory("parent-ownership-allocated")
        let allocatedParent = directory.deletingLastPathComponent().deletingLastPathComponent()
        let configuredParent = ProcessInfo.processInfo.environment["WILTED_TEST_TMPDIR"]
        let expected = try WiltedMacTestTemporaryState.validatedTestTemporaryParent(rawValue: configuredParent)
        let activity = configuredParent == nil ? "default parent" : "runner-owned parent"

        XCTContext.runActivity(named: activity) { _ in
            XCTAssertEqual(allocatedParent, expected)
        }
    }

    func testParentResolverRejectsMissingRelativeFileAndSymlinkWithoutFallback() throws {
        let fixture = wiltedTemporaryDirectory("parent-ownership-resolver")
        let fileManager = FileManager.default
        let parent = fixture.appendingPathComponent("valid-parent", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
        let canonical = parent

        XCTAssertEqual(
            try WiltedMacTestTemporaryState.validatedTestTemporaryParent(rawValue: parent.path), canonical
        )
        XCTAssertEqual(
            try WiltedMacTestTemporaryState.validatedTestTemporaryParent(rawValue: nil),
            FileManager.default.temporaryDirectory
        )
        XCTAssertThrowsError(try WiltedMacTestTemporaryState.validatedTestTemporaryParent(
            rawValue: fixture.appendingPathComponent("missing-parent", isDirectory: true).path
        ))
        XCTAssertThrowsError(try WiltedMacTestTemporaryState.validatedTestTemporaryParent(rawValue: "relative-parent"))

        let regularFile = fixture.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: regularFile)
        XCTAssertThrowsError(try WiltedMacTestTemporaryState.validatedTestTemporaryParent(rawValue: regularFile.path))

        let symlink = fixture.appendingPathComponent("parent-link", isDirectory: true)
        try fileManager.createSymbolicLink(atPath: symlink.path, withDestinationPath: parent.path)
        XCTAssertThrowsError(try WiltedMacTestTemporaryState.validatedTestTemporaryParent(rawValue: symlink.path))
    }
}
