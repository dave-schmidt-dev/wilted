import XCTest
import WiltedProducer
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
    func testManagedCaseCloseKeepsRetainedRealSQLiteStoreUsableUntilHostExit() async throws {
        let directory = wiltedTemporaryDirectory("managed-retained-store")
        let root = directory.deletingLastPathComponent()
        let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"],
                                   stateDirectoryOverride: directory,
                                   preferences: .init(suiteName: UUID().uuidString)!)
        await model.fixtureInstallTask?.value
        let store = try XCTUnwrap(model.store)
        let before = try await store.inspect()
        try await WiltedMacTestTemporaryState.close(root: root, identifier: ObjectIdentifier(self))
        XCTAssertTrue(model.fixtureInstallTask?.isCancelled ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "real store remains retained")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.libraryURL.path))
        let after = try await store.inspect()
        XCTAssertEqual(after, before)
    }

    func testStandaloneUnmarkedParentStillRemovesExactCaseRoot() async throws {
        let parent = wiltedTemporaryDirectory("standalone-parent")
        let root = parent.appendingPathComponent("standalone-root")
        try WiltedMacTemporaryState.markTestRoot(root)
        try Data("standalone".utf8).write(to: root.appendingPathComponent("fixture"))
        let token = NSObject()
        try await WiltedMacTestTemporaryState.close(root: root, identifier: ObjectIdentifier(token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
    }

    func testManagedCaseAndHostRootsBindCreatedIdentityAndLiveOwner() throws {
        let directory = wiltedTemporaryDirectory("managed-root-identity")
        for root in [directory.deletingLastPathComponent(), WiltedMacModel.testHostStateDirectory] {
            let receipt = root.appendingPathComponent(".wilted-managed-test-root")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            XCTAssertEqual(fields["path"] as? String, root.path)
            XCTAssertEqual(fields["device"] as? NSNumber, attributes[.systemNumber] as? NSNumber)
            XCTAssertEqual(fields["inode"] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(fields["host_pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
            let delivered = ProcessInfo.processInfo.environment
            XCTAssertEqual(fields["owner_pid"] as? Int, delivered["WILTED_TEST_OWNER_PID"].flatMap(Int.init))
            XCTAssertEqual(fields["owner_started"] as? String, delivered["WILTED_TEST_OWNER_STARTED"])
            XCTAssertEqual(fields["owner_path"] as? String, delivered["WILTED_TEST_OWNER_PATH"])
        }
    }

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
        XCTAssertEqual(FileManager.default.fileExists(atPath: root.path),
                       try WiltedMacTestRootOwnership.isManaged(root))
        XCTAssertNil(observedModel, "awaited teardown releases the registry's model ownership")
    }

    func testOwnedFixtureStateDisappearsAfterExplicitClose() async throws {
        let storeURL = wiltedTemporaryDirectory("owned-close-store").appendingPathComponent("library.sqlite")
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            storeBootstrap: { _ in try LocalLibraryStore(url: storeURL) },
            preferences: .init(suiteName: UUID().uuidString)!
        )
        let mediaState = WiltedMacModel.makeOwnedFixtureState(in: wiltedTemporaryDirectory("owned-close-media"))
        let root = mediaState.directory
        await model.fixtureInstallTask?.value
        await model.statisticsTask?.value
        await model.performStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        XCTAssertEqual(model.startupState, .ready)
        let actualStoreURL = await store.url
        XCTAssertEqual(actualStoreURL, storeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        await model.close()
        mediaState.closeSynchronously()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try await store.inspect()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
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
        let storeURL = wiltedTemporaryDirectory("owned-deinit-store").appendingPathComponent("library.sqlite")
        let gate = TemporaryStateWriteGate()
        var model: WiltedMacModel? = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            storeBootstrap: { _ in try LocalLibraryStore(url: storeURL) },
            preferences: .init(suiteName: UUID().uuidString)!
        )
        let mediaState = WiltedMacModel.makeOwnedFixtureState(in: wiltedTemporaryDirectory("owned-deinit-media"))
        let root = mediaState.directory
        let lateWrite = root.appendingPathComponent("deinit-late-writer")
        await model?.fixtureInstallTask?.value
        await model?.statisticsTask?.value
        await model?.performStoreBootstrap()
        let store = try XCTUnwrap(model?.store)
        XCTAssertEqual(model?.startupState, .ready)
        let actualStoreURL = await store.url
        XCTAssertEqual(actualStoreURL, storeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        model?.fixtureInstallTask = Task {
            await gate.waitForRelease()
            try? FileManager.default.createDirectory(at: lateWrite, withIntermediateDirectories: true)
            await gate.markWritten()
        }
        await gate.waitUntilArrived()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let writer = try XCTUnwrap(model?.fixtureInstallTask)
        model = nil
        let mediaDrain = Task {
            await closeOwnedTemporaryStateAfterDeinit(mediaState, voidTasks: [writer], downloadTasks: [],
                automation: nil, syncLifecycle: nil)
        }

        // Cancellation is advisory: the captured writer deliberately waits.
        // The root must still exist until that writer has settled.
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        await gate.release()
        await gate.waitUntilWritten()
        await mediaDrain.value
        for _ in 0..<100 where FileManager.default.fileExists(atPath: root.path) {
            await Task.yield()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try await store.inspect()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
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
        let storeURL = wiltedTemporaryDirectory("concurrent-close-store").appendingPathComponent("library.sqlite")
        let gate = TemporaryStateWriteGate()
        let completions = CloseCompletions()
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            storeBootstrap: { _ in try LocalLibraryStore(url: storeURL) },
            preferences: .init(suiteName: UUID().uuidString)!
        )
        let mediaState = WiltedMacModel.makeOwnedFixtureState(in: wiltedTemporaryDirectory("owned-close-media"))
        let root = mediaState.directory
        let lateWrite = root.appendingPathComponent("late-concurrent-writer")
        await model.fixtureInstallTask?.value
        await model.statisticsTask?.value
        await model.performStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        XCTAssertEqual(model.startupState, .ready)
        let actualStoreURL = await store.url
        XCTAssertEqual(actualStoreURL, storeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
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
        await closeOwnedTemporaryStateAfterDeinit(mediaState, voidTasks: [try XCTUnwrap(model.fixtureInstallTask)],
            downloadTasks: [], automation: nil, syncLifecycle: nil)
        XCTAssertTrue(model.fixtureInstallTask?.isCancelled ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try await store.inspect()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
