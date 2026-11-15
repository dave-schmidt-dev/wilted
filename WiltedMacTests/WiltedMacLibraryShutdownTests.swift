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
    private(set) var writerFinished = false

    func recordWriterFinished() { writerFinished = true }

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
    func preparedQueued() async throws -> WiltedMacPreparedQueue { WiltedMacPreparedQueue() }
}

private struct ShutdownPreparedAudio: WiltedMacReadyAudioSource {
    let entryID: ItemID
    let audio: WiltedMacReadyAudio

    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? {
        entryID == self.entryID ? audio : nil
    }
    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] {
        [entryID: audio]
    }
    func preparedQueued() async throws -> WiltedMacPreparedQueue {
        WiltedMacPreparedQueue(entries: [(entryID, audio)], larderIDs: [entryID])
    }
}

private final class ShutdownBlockingUploadTransport: LibraryTransport, @unchecked Sendable {
    private let inner: InMemoryLibraryTransport
    private let gate: LibraryShutdownGate

    init(inner: InMemoryLibraryTransport, gate: LibraryShutdownGate) {
        self.inner = inner
        self.gate = gate
    }

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
    func removeMedia(entryID: ItemID) async throws { try await inner.removeMedia(entryID: entryID) }
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await inner.publishTranscript(transcript) }
    func removeTranscript(entryID: ItemID) async throws { try await inner.removeTranscript(entryID: entryID) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }

    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        if offer.state == .ready {
            await gate.hold()
            await gate.recordWriterFinished()
        }
        try await inner.publishMedia(offer: offer, fileURL: fileURL)
    }
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
        let accounting = directory.appendingPathComponent("controlled-maintenance-\(UUID().uuidString).txt")
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
                await gate.recordWriterFinished()
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
        try await closing.value
        // Capture the join boundary before this test can release a non-draining writer.
        let accountingBytesAtClose = try? Data(contentsOf: accounting)
        let writerFinishedAtClose = await gate.writerFinished
        await gate.release()
        await fulfillment(of: [writerFinished], timeout: 3)
        XCTAssertTrue(writerFinishedAtClose, "close must finish the writer before returning")
        XCTAssertEqual(accountingBytesAtClose, Data("controlled-maintenance".utf8),
                       "the controlled write must be complete at the close-return boundary")
        let drainObserved = await gate.drainObserved
        let rootExistedAtDrain = await gate.rootExistedAtDrain
        XCTAssertTrue(drainObserved, "model close must retain and await a stopped controller")
        XCTAssertTrue(rootExistedAtDrain, "the root must remain owned while maintenance is pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "the managed SQLite root remains retained until terminal host cleanup")
        XCTAssertTrue(try WiltedMacTestRootOwnership.isManaged(root),
                      "close must preserve the exact managed root and its ownership marker")
    }

    func testCloseWithPreuploadBlockedInTransportReturnsWithinBudget() async throws {
        let directory = wiltedTemporaryDirectory("library-shutdown-preupload")
        let gate = LibraryShutdownGate()
        let entryID = try ItemID(rawValue: "shutdown-entry")
        let file = directory.appendingPathComponent("shutdown.m4a")
        try Data(repeating: 0x42, count: 1024).write(to: file)
        let audio = WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: "rev-shutdown"),
            contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: 1024,
            mediaType: "audio/mp4",
            durationSeconds: 60,
            fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        )
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let inner = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let transport = ShutdownBlockingUploadTransport(inner: inner, gate: gate)
        let runtime = WiltedMacInboundRuntime(
            source: ShutdownPreparedAudio(entryID: entryID, audio: audio),
            transport: transport,
            directory: directory,
            onPollerStop: { await gate.release() },
            preuploadLimit: 10
        )
        let startup = try XCTUnwrap(runtime.start(sink: WiltedMacLibraryIntentSink()))
        await startup.value
        // Nothing in a bare runtime reconciles offers (the model does that in production), and
        // the pump only starts after a successful reconcile.
        let reconciled = await runtime.service.reconcileAvailable()
        XCTAssertTrue(reconciled)
        await gate.waitUntilHeld()

        let writerFinishedBeforeClose = await gate.writerFinished
        XCTAssertFalse(writerFinishedBeforeClose, "pre-upload should be blocked in transport before close")

        // close joins service.drainEndingThrottleWaits, releasing gate via onPollerStop
        await runtime.close()

        let writerFinishedAfterClose = await gate.writerFinished
        XCTAssertTrue(writerFinishedAfterClose, "pre-upload writer must finish as part of close")
    }
}
