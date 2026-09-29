import XCTest
@testable import WiltedMac

private actor TemporaryStateWriteGate {
    private var hasArrived = false
    private var isReleased = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasObservedCancellation = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasWritten = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        hasArrived = true
        let arrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in arrivals { waiter.resume() }
        guard !isReleased else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { releaseWaiters.append($0) }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
    }

    func waitUntilArrived() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilCancellationObserved() async {
        guard !hasObservedCancellation else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func markWritten() {
        hasWritten = true
        let waiters = writeWaiters
        writeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilWritten() async {
        guard !hasWritten else { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func observeCancellation() {
        hasObservedCancellation = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor CloseCompletions {
    private var completed = 0

    func markComplete() { completed += 1 }
    func count() -> Int { completed }
}

private enum TemporaryStateMarkerWriteFailure: Error {
    case injected
}

@MainActor
extension WiltedMacModelTests {
    func testCommonTemporaryDirectoriesExistAndShareOnlyTheirTestCaseRoot() throws {
        let first = temporaryDirectory("common-first")
        let second = wiltedTemporaryDirectory("common-second")
        let repeatedSuffix = wiltedTemporaryDirectory("common-second")
        let root = first.deletingLastPathComponent()

        XCTAssertEqual(second.deletingLastPathComponent(), root)
        XCTAssertEqual(repeatedSuffix.deletingLastPathComponent(), root)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, repeatedSuffix)
        XCTAssertTrue(WiltedMacTemporaryState.isMarkedTestRoot(root))
        for directory in [first, second, repeatedSuffix] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue, "overrides exist before fixture stores open")
        }
    }

    func testCaseRootRetainsBorrowedModelUntilItsNoncooperativeWriterDrains() async throws {
        let directory = wiltedTemporaryDirectory("retained-borrowed-writer")
        let root = directory.deletingLastPathComponent()
        let gate = TemporaryStateWriteGate()
        let completions = CloseCompletions()
        var model: WiltedMacModel? = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: .init(suiteName: UUID().uuidString)!
        )
        await model?.fixtureInstallTask?.value
        weak var observedModel = model
        let lateWrite = directory.appendingPathComponent("retained-late-writer")
        model?.fixtureInstallTask = Task {
            await gate.waitForRelease()
            try? FileManager.default.createDirectory(at: lateWrite, withIntermediateDirectories: true)
            await gate.markWritten()
        }
        await gate.waitUntilArrived()
        model = nil
        XCTAssertNotNil(observedModel, "the test root retains a model after its caller releases it")

        let identifier = ObjectIdentifier(self)
        let close = Task {
            try await WiltedMacTestTemporaryState.close(root: root, identifier: identifier)
            await completions.markComplete()
        }
        await gate.waitUntilCancellationObserved()
        let completedBeforeRelease = await completions.count()
        XCTAssertEqual(completedBeforeRelease, 0, "teardown awaits cancellation-ignoring work")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        await gate.release()
        try await close.value
        await gate.waitUntilWritten()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNil(observedModel, "awaited teardown releases the registry's model ownership")
    }

    func testOwnedFixtureStateDisappearsAfterExplicitClose() async throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], preferences: .init(suiteName: UUID().uuidString)!
        )
        let root = model.libraryURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        await model.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testUnmarkedOwnedFixtureStateDisappearsAfterExplicitClose() throws {
        let parent = wiltedTemporaryDirectory("unmarked-owned-close")
        let state = WiltedMacModel.makeOwnedFixtureState(in: parent) { _ in
            throw TemporaryStateMarkerWriteFailure.injected
        }
        let root = state.directory

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".wilted-fixture-owner").path
        ))
        XCTAssertNotNil(state.ownerMarkerWriteError)

        state.closeSynchronously()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOwnedFixtureStateDoesNotRemoveReplacementDirectory() throws {
        let parent = wiltedTemporaryDirectory("replacement-directory")
        let state = WiltedMacModel.makeOwnedFixtureState(in: parent)
        let root = state.directory
        let heldOriginal = parent.appendingPathComponent("held-original", isDirectory: true)
        // Keep the original inode alive so the replacement cannot reuse it.
        try FileManager.default.moveItem(at: root, to: heldOriginal)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        state.closeSynchronously()

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heldOriginal.path))
    }

    func testExistingFixtureDirectoryIsNotMarkedOrRemoved() throws {
        let parent = wiltedTemporaryDirectory("preexisting-directory")
        let directory = parent.appendingPathComponent("wilted-ui-fixture-preexisting", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let state = WiltedMacModel.makeOwnedFixtureState(at: directory) { _ in
            XCTFail("A preexisting directory must not receive an owner marker")
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".wilted-fixture-owner").path
        ))
        state.closeSynchronously()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testBorrowedOverrideSurvivesModelClose() async throws {
        let directory = temporaryDirectory("borrowed-close")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // This is the shared per-test root: fixture setup still starts its
        // finite store writer, but ownership stays with XCTest's teardown.
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: .init(suiteName: UUID().uuidString)!
        )

        await model.close()

        XCTAssertTrue(model.fixtureInstallTask?.isCancelled ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOwnedFixtureStateDisappearsOnDeinitFallback() async throws {
        let gate = TemporaryStateWriteGate()
        var model: WiltedMacModel? = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], preferences: .init(suiteName: UUID().uuidString)!
        )
        let root = try XCTUnwrap(model?.libraryURL.deletingLastPathComponent())
        let lateWrite = root.appendingPathComponent("deinit-late-writer")
        await model?.fixtureInstallTask?.value
        model?.fixtureInstallTask = Task {
            await gate.waitForRelease()
            try? FileManager.default.createDirectory(at: lateWrite, withIntermediateDirectories: true)
            await gate.markWritten()
        }
        await gate.waitUntilArrived()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        model = nil

        // Cancellation is advisory: the captured writer deliberately waits.
        // The root must still exist until that writer has settled.
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        await gate.release()
        await gate.waitUntilWritten()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: root.path) {
            await Task.yield()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRegisteredSharedTestRootDrainsDelayedFixtureWriter() async throws {
        let first = temporaryDirectory("shared-first")
        let second = temporaryDirectory("shared-second")
        XCTAssertEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: first,
            preferences: .init(suiteName: UUID().uuidString)!
        )
        let lateWrite = first.appendingPathComponent("late-writer")
        await model.fixtureInstallTask?.value
        model.fixtureInstallTask = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            try? FileManager.default.createDirectory(at: lateWrite, withIntermediateDirectories: true)
        }
        let root = try XCTUnwrap(WiltedMacTemporaryState.markedTestRoot(containing: first))

        await WiltedMacTemporaryState.closeRegisteredModels(forTestRoot: root)
        await Task.yield()

        XCTAssertTrue(model.fixtureInstallTask?.isCancelled ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateWrite.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "the shared parent survives until central teardown removes it")
    }

    func testConcurrentCloseWaitsForTheSameDelayedWriterDrain() async throws {
        let gate = TemporaryStateWriteGate()
        let completions = CloseCompletions()
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], preferences: .init(suiteName: UUID().uuidString)!
        )
        let root = model.libraryURL.deletingLastPathComponent()
        let lateWrite = root.appendingPathComponent("late-concurrent-writer")
        await model.fixtureInstallTask?.value
        model.fixtureInstallTask = Task {
            await gate.waitForRelease()
            try? FileManager.default.createDirectory(at: lateWrite, withIntermediateDirectories: true)
            await gate.markWritten()
        }
        await gate.waitUntilArrived()

        let first = Task {
            await model.close()
            await completions.markComplete()
        }
        let second = Task {
            await model.close()
            await completions.markComplete()
        }
        await gate.waitUntilCancellationObserved()
        let completedBeforeRelease = await completions.count()
        XCTAssertEqual(completedBeforeRelease, 0,
                       "both callers wait for the same unsettled writer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        await gate.release()
        await first.value
        await second.value
        await gate.waitUntilWritten()
        XCTAssertTrue(model.fixtureInstallTask?.isCancelled ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

@MainActor
final class WiltedMacTestParentOwnershipTests: XCTestCase {
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
        let canonical = parent.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL

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
