import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

private actor LibraryShutdownGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []
    private(set) var drainObserved = false
    private(set) var rootExistedAtDrain = false

    func hold() async {
        arrived = true
        let waiting = arrivals
        arrivals.removeAll()
        waiting.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releases.append($0) } }
    }

    func waitUntilHeld() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }

    func release() {
        released = true
        let waiting = releases
        releases.removeAll()
        waiting.forEach { $0.resume() }
    }

    func observeDrain(root: URL) {
        drainObserved = true
        rootExistedAtDrain = FileManager.default.fileExists(atPath: root.path)
        release()
    }
}

private struct ShutdownEmptyAudio: WiltedMacReadyAudioSource {
    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? { nil }
    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] { [:] }
}

@MainActor
final class WiltedMacLibraryShutdownTests: XCTestCase {
    func testStopRacingSuspendedStartupCannotRestartPoller() async throws {
        let directory = wiltedTemporaryDirectory("library-shutdown-startup")
        let gate = LibraryShutdownGate()
        let runtime = WiltedMacInboundRuntime(
            source: ShutdownEmptyAudio(),
            transport: InMemoryLibraryTransport(deviceID: "mac", server: InMemoryLibraryServer(writerDeviceID: "mac")),
            directory: directory,
            maintenance: {},
            beforePollerStart: { await gate.hold() },
            onPollerStop: { await gate.release() }
        )
        let startup = try XCTUnwrap(runtime.start(sink: WiltedMacLibraryIntentSink()))
        let poller = try XCTUnwrap(runtime.poller)
        await gate.waitUntilHeld()
        let shutdown = try XCTUnwrap(runtime.stop())
        await shutdown.value
        await startup.value
        let running = await poller.isRunning
        XCTAssertFalse(running, "a delayed startup must not restart the timer after stop")
        XCTAssertNil(runtime.poller)
        await poller.stop()
    }

    func testModelCloseDrainsBlockedMaintenanceBeforeRemovingRoot() async throws {
        try await checkMaintenanceDrain(explicitStop: false)
    }

    func testExplicitStopThenModelCloseStillDrainsBlockedMaintenance() async throws {
        try await checkMaintenanceDrain(explicitStop: true)
    }

    /// The quit path's network step cancels the library controllers, then
    /// joins them: it returns only after a blocked maintenance writer finished.
    func testTerminationNetworkStepJoinsBlockedMaintenanceBeforeReturning() async throws {
        let directory = wiltedTemporaryDirectory("library-shutdown-termination")
        let root = directory.deletingLastPathComponent()
        let accounting = directory.appendingPathComponent("library-sync/media-accounting.json")
        let gate = LibraryShutdownGate()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { try LocalLibraryStore(url: $0) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"],
            transport: InMemoryLibraryTransport(deviceID: "mac", server: InMemoryLibraryServer(writerDeviceID: "mac")),
            inboundMaintenance: {
                await gate.hold()
                try? FileManager.default.createDirectory(at: accounting.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("termination-maintenance".utf8).write(to: accounting)
            }
        ))
        let controller = try XCTUnwrap(model.librarySyncController)
        controller.onShutdownDrain = { await gate.observeDrain(root: root) }
        await gate.waitUntilHeld()

        await model.closeLibraryControllersForTermination()
        let writerDoneAtReturn = FileManager.default.fileExists(atPath: accounting.path)
        await gate.release()  // only matters if the step returned without joining

        let drainObserved = await gate.drainObserved
        XCTAssertTrue(drainObserved, "the termination step stops the controller through its drain")
        XCTAssertTrue(writerDoneAtReturn, "the termination step joins the controller before returning")
        XCTAssertNil(model.librarySyncController)
    }

    private func checkMaintenanceDrain(explicitStop: Bool) async throws {
        let directory = wiltedTemporaryDirectory("library-shutdown-maintenance")
        let root = directory.deletingLastPathComponent()
        let accounting = directory.appendingPathComponent("library-sync/media-accounting.json")
        let gate = LibraryShutdownGate()
        let writerFinished = expectation(description: "controlled maintenance writer finished")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { try LocalLibraryStore(url: $0) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"],
            transport: InMemoryLibraryTransport(deviceID: "mac", server: InMemoryLibraryServer(writerDeviceID: "mac")),
            inboundMaintenance: {
                await gate.hold()
                try? FileManager.default.createDirectory(at: accounting.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("controlled-maintenance".utf8).write(to: accounting)
                writerFinished.fulfill()
            }
        ))
        let controller = try XCTUnwrap(model.librarySyncController)
        controller.onShutdownDrain = { await gate.observeDrain(root: root) }
        await gate.waitUntilHeld()
        if explicitStop {
            model.stopLibrarySync()
            XCTAssertNil(model.librarySyncController, "synchronous stop still clears the UI association immediately")
        }
        let identifier = ObjectIdentifier(self)
        let closing = Task { try await WiltedMacTestTemporaryState.close(root: root, identifier: identifier) }
        // On the baseline close returns without draining, so releasing the writer recreates its
        // removed root. A draining controller releases it at the observed join instead.
        let fallbackRelease = Task { _ = try? await closing.value; await gate.release() }
        try await closing.value
        await fallbackRelease.value
        await fulfillment(of: [writerFinished], timeout: 3)
        let drainObserved = await gate.drainObserved
        let rootExistedAtDrain = await gate.rootExistedAtDrain
        XCTAssertTrue(drainObserved, "model close must retain and await a stopped controller")
        XCTAssertTrue(rootExistedAtDrain, "the root must remain owned while maintenance is pending")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "maintenance must not recreate the removed root")
        // Baseline failures still clean their intentionally recreated root.
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
