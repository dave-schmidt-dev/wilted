import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Controllable wall clock shared by the coordinator and the in-memory server.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 10_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// A scripted Mac player: the test sets what plays, and pausing really stops it.
@MainActor
private final class ScriptedPlayer: WiltedMacHandoffPlayer {
    var sample: WiltedMacPlaybackSample?
    var revision: RevisionID?
    var pauseSucceeds = true
    private(set) var pauseCount = 0
    private(set) var checkpointCount = 0

    func handoffSample() -> WiltedMacPlaybackSample? { sample }
    func handoffRevision(for entryID: ItemID) async -> RevisionID? { revision }
    func trackPlayback(onChange: @escaping @MainActor () -> Void) {}

    func pauseAndCheckpoint() async {
        pauseCount += 1
        guard pauseSucceeds else { return }
        sample?.isPlaying = false
        checkpointCount += 1
    }
}

@MainActor
final class WiltedMacHandoffControllerTests: XCTestCase {
    private let macID = "mac-test"
    private let phoneID = "iphone-a"
    private let entry = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let revision = try! RevisionID(rawValue: "rev-a")

    @MainActor private struct Rig {
        let clock = TestClock()
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let player = ScriptedPlayer()
        var controller: WiltedMacHandoffController!
        var records: LibraryDeviceRecords?
    }

    private func makeRig(usePollerRecords: Bool = false) async -> Rig {
        var rig = Rig()
        await rig.server.setClock(rig.clock.now)
        rig.player.revision = revision
        let clock = rig.clock
        let coordinator = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: macID, server: rig.server), deviceID: macID,
            clock: { clock.now }, sleep: { _ in })
        let server = rig.server
        var pollerRecords: (@Sendable () async -> LibraryDeviceRecords?)?
        if usePollerRecords {
            pollerRecords = { try? await InMemoryLibraryTransport(deviceID: "poller", server: server).fetchDeviceRecords() }
        }
        rig.controller = WiltedMacHandoffController(
            coordinator: coordinator, player: rig.player, deviceID: macID, latestRecords: pollerRecords)
        return rig
    }

    private func macRecord(_ rig: Rig) async throws -> ObservedPlayback? {
        try await InMemoryLibraryTransport(deviceID: "reader", server: rig.server)
            .fetchDeviceRecords().nowPlaying.first { $0.record.deviceID == macID }
    }

    private func macPosition(_ rig: Rig) async throws -> DevicePlaybackPosition {
        let observed = try await macRecord(rig)
        return try XCTUnwrap(observed).record
    }

    private func phonePlays(_ rig: Rig, epoch: Int, playing: Bool = true) async throws {
        await rig.server.setClock(rig.clock.now)
        let record = try DevicePlaybackPosition(
            deviceID: phoneID, entryID: entry, revision: revision, positionSeconds: 300, isPlaying: playing,
            epoch: epoch, publishedAt: rig.clock.now)
        let phone = InMemoryLibraryTransport(deviceID: phoneID, server: rig.server)
        try await phone.publish(record, as: .nowPlaying)
        try await phone.publish(record, as: .progress)
    }

    private func macPlays(_ rig: Rig, position: Double = 10) {
        rig.player.sample = WiltedMacPlaybackSample(episodeID: entry, positionSeconds: position, rate: 1, isPlaying: true)
    }

    func testStartingPlaybackPublishesARealEpochAboveEveryDevice() async throws {
        let rig = await makeRig()
        try await phonePlays(rig, epoch: 3, playing: false)
        macPlays(rig, position: 42)

        await rig.controller.reconcile()

        let record = try await macPosition(rig)
        XCTAssertEqual(record.epoch, 4)
        XCTAssertTrue(record.isPlaying)
        XCTAssertEqual(record.positionSeconds, 42)
        XCTAssertEqual(record.revision, revision)
        XCTAssertEqual(rig.controller.takeoverCount, 1)
    }

    func testTimerRepublishesOnlyOnCadenceWhilePlaying() async throws {
        let rig = await makeRig()
        macPlays(rig, position: 10)
        await rig.controller.reconcile()
        rig.clock.advance(2)
        await rig.server.setClock(rig.clock.now)
        macPlays(rig, position: 12)
        await rig.controller.reconcile()
        let current = try await macPosition(rig)
        XCTAssertEqual(current.positionSeconds, 10, "inside the 5 s cadence")

        rig.clock.advance(4)
        await rig.server.setClock(rig.clock.now)
        macPlays(rig, position: 16)
        await rig.controller.reconcile()
        let record = try await macPosition(rig)
        XCTAssertEqual(record.positionSeconds, 16)
        XCTAssertEqual(record.epoch, 1, "cadence publishes keep the session epoch")
        XCTAssertEqual(rig.controller.takeoverCount, 1)
    }

    func testHigherEpochPausesTheMacWithACheckpointAndPublishesPaused() async throws {
        let rig = await makeRig()
        macPlays(rig, position: 100)
        await rig.controller.reconcile()
        try await phonePlays(rig, epoch: 2)
        rig.clock.advance(5)
        macPlays(rig, position: 105)

        await rig.controller.reconcile()

        XCTAssertEqual(rig.player.pauseCount, 1)
        XCTAssertEqual(rig.player.checkpointCount, 1)
        XCTAssertEqual(rig.controller.relinquishCount, 1)
        let record = try await macPosition(rig)
        XCTAssertFalse(record.isPlaying, "the coordinator does not publish paused itself; the controller does")
        XCTAssertEqual(record.positionSeconds, 105)

        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.pauseCount, 1, "a paused loser is not paused again")
    }

    func testLowerEpochDoesNotPauseTheMac() async throws {
        let rig = await makeRig()
        try await phonePlays(rig, epoch: 4, playing: false)
        macPlays(rig)
        await rig.controller.reconcile()
        let current = try await macPosition(rig)
        XCTAssertEqual(current.epoch, 5)

        try await phonePlays(rig, epoch: 2)
        rig.clock.advance(5)
        macPlays(rig, position: 15)
        await rig.controller.reconcile()

        XCTAssertEqual(rig.player.pauseCount, 0)
        XCTAssertTrue(rig.player.sample?.isPlaying ?? false)
        XCTAssertEqual(rig.controller.relinquishCount, 0)
    }

    func testFailedPauseIsRetriedAndNeverRetakesOver() async throws {
        let rig = await makeRig()
        macPlays(rig)
        await rig.controller.reconcile()
        try await phonePlays(rig, epoch: 2)
        rig.player.pauseSucceeds = false

        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.pauseCount, 1)
        XCTAssertEqual(rig.controller.relinquishCount, 0)

        rig.player.pauseSucceeds = true
        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.pauseCount, 2)
        XCTAssertEqual(rig.controller.relinquishCount, 1)
        XCTAssertEqual(rig.controller.takeoverCount, 1, "retrying the pause must not bump the epoch")
    }

    func testPollerRecordsGateTheTickFetch() async throws {
        let rig = await makeRig(usePollerRecords: true)
        macPlays(rig)
        await rig.controller.reconcile()
        rig.clock.advance(5)
        macPlays(rig, position: 15)
        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.pauseCount, 0)

        try await phonePlays(rig, epoch: 2)
        rig.clock.advance(5)
        macPlays(rig, position: 20)
        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.pauseCount, 1, "records showing a higher epoch trigger the check")
    }

    func testPauseByTheListenerPublishesPausedAndResumingIsANewEpoch() async throws {
        let rig = await makeRig()
        macPlays(rig)
        await rig.controller.reconcile()
        rig.player.sample?.isPlaying = false
        rig.player.sample?.positionSeconds = 77
        await rig.controller.reconcile()
        let paused = try await macPosition(rig)
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.positionSeconds, 77)
        XCTAssertEqual(paused.epoch, 1)

        rig.player.sample?.isPlaying = true
        await rig.controller.reconcile()
        let current = try await macPosition(rig)
        XCTAssertEqual(current.epoch, 2)
        XCTAssertEqual(rig.controller.takeoverCount, 2)
    }

    func testPlaybackWithoutARevisionPublishesNothing() async throws {
        let rig = await makeRig()
        rig.player.revision = nil
        macPlays(rig)
        await rig.controller.reconcile()
        let record = try await macRecord(rig)
        XCTAssertNil(record)
    }
}
