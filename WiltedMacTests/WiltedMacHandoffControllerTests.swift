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

/// Counts calls made from any isolation, such as the coordinator's injected sleep.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A scripted Mac player: the test sets what plays, and pausing really stops it.
@MainActor
private final class ScriptedPlayer: WiltedMacHandoffPlayer {
    var sample: WiltedMacPlaybackSample?
    var revision: RevisionID?
    var pauseSucceeds = true
    var stored: [HandoffCoordinator.StoredPosition] = []
    private(set) var storedReadCount = 0
    private(set) var pauseCount = 0
    private(set) var checkpointCount = 0

    func handoffSample() -> WiltedMacPlaybackSample? { sample }
    func handoffRevision(for entryID: ItemID) async -> RevisionID? { revision }
    func trackPlayback(onChange: @escaping @MainActor () -> Void) {}
    func storedPositions() async -> [HandoffCoordinator.StoredPosition] {
        storedReadCount += 1
        return stored
    }

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

    private func makeRig(
        usePollerRecords: Bool = false,
        journal: WiltedMacPlaybackJournal? = nil
    ) async -> Rig {
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
            coordinator: coordinator, player: rig.player, deviceID: macID, latestRecords: pollerRecords,
            journal: journal, now: { clock.now })
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

    func testPhoneCheckpointIsCorrelatedInMacJournalWithoutDeviceIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-peer-checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = WiltedMacPlaybackJournal(
            url: folder.appendingPathComponent("logs/playback-v2/playback-journal.log"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let rig = await makeRig(usePollerRecords: true, journal: journal)
        try await phonePlays(rig, epoch: 4, playing: false)

        await rig.controller.reconcile()

        let content = try String(contentsOf: folder.appendingPathComponent("logs/playback-v2/playback-journal.log"), encoding: .utf8)
        XCTAssertTrue(content.contains("source=mac event=peer-checkpoint"), content)
        XCTAssertTrue(content.contains("item=\(PlaybackJournalRecord.itemTag(entry))"), content)
        XCTAssertTrue(content.contains("position=300.0 epoch=4") || content.contains("epoch=4"), content)
        XCTAssertTrue(content.contains("playing=false"), content)
        XCTAssertFalse(content.contains(phoneID), "the journal correlates records without device identifiers")
        XCTAssertFalse(content.contains(macID), "the journal never writes local device identifiers")
        XCTAssertFalse(content.contains(entry.rawValue), "the journal never writes the raw item ID")
    }

    /// A takeover with poller records reads nothing: its epoch comes from those records (the server
    /// itself is empty here, so a fetch would give epoch 1), and no confirming fetch follows.
    func testATakeoverWithPollerRecordsIsOneWriteAndNoRead() async throws {
        let clock = TestClock()
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        await server.setClock(clock.now)
        let settles = Counter()
        let coordinator = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: macID, server: server), deviceID: macID,
            clock: { clock.now }, sleep: { _ in settles.increment() })
        let peer = try DevicePlaybackPosition(
            deviceID: phoneID, entryID: entry, revision: revision, positionSeconds: 300, isPlaying: false,
            epoch: 7, publishedAt: clock.now)
        let known = LibraryDeviceRecords(nowPlaying: [], progress: [ObservedPlayback(record: peer, serverModifiedAt: clock.now)])
        let player = ScriptedPlayer()
        player.revision = revision
        player.sample = WiltedMacPlaybackSample(episodeID: entry, positionSeconds: 10, rate: 1, isPlaying: true)
        let controller = WiltedMacHandoffController(
            coordinator: coordinator, player: player, deviceID: macID, latestRecords: { known }, now: { clock.now })

        await controller.reconcile()

        let mac = try await InMemoryLibraryTransport(deviceID: "reader", server: server)
            .fetchDeviceRecords().nowPlaying.first { $0.record.deviceID == macID }
        XCTAssertEqual(try XCTUnwrap(mac).record.epoch, 8, "the epoch comes from the poller's records, not a fetch")
        XCTAssertEqual(settles.value, 0, "no settle wait and confirming fetch after the takeover")
        XCTAssertEqual(controller.takeoverCount, 1)
    }

    /// Poller records that still predate the Mac's own last takeover must not hand out its epoch
    /// again: pausing and resuming against unchanged (empty) records raises the epoch.
    func testResumingAgainstStalePollerRecordsRaisesTheEpoch() async throws {
        let clock = TestClock()
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        await server.setClock(clock.now)
        let coordinator = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: macID, server: server), deviceID: macID,
            clock: { clock.now }, sleep: { _ in })
        let player = ScriptedPlayer()
        player.revision = revision
        let controller = WiltedMacHandoffController(
            coordinator: coordinator, player: player, deviceID: macID,
            latestRecords: { LibraryDeviceRecords() }, now: { clock.now })
        let reader = InMemoryLibraryTransport(deviceID: "reader", server: server)

        player.sample = WiltedMacPlaybackSample(episodeID: entry, positionSeconds: 10, rate: 1, isPlaying: true)
        await controller.reconcile()
        player.sample?.isPlaying = false
        await controller.reconcile()
        clock.advance(5)
        await server.setClock(clock.now)
        player.sample = WiltedMacPlaybackSample(episodeID: entry, positionSeconds: 10, rate: 1, isPlaying: true)
        await controller.reconcile()

        let mac = try await reader.fetchDeviceRecords().nowPlaying.first { $0.record.deviceID == macID }
        XCTAssertEqual(try XCTUnwrap(mac).record.epoch, 2)
        XCTAssertTrue(try XCTUnwrap(mac).record.isPlaying)
        XCTAssertEqual(controller.takeoverCount, 2)
    }

    /// A phone that took over at the same epoch a moment later wins on server date; the Mac learns
    /// it from the next round's poller records and pauses, with no confirming fetch of its own.
    func testAnEqualEpochPeerSeenInTheNextRoundPausesTheMac() async throws {
        let rig = await makeRig(usePollerRecords: true)
        macPlays(rig, position: 10)
        await rig.controller.reconcile()
        let first = try await macPosition(rig)
        XCTAssertEqual(first.epoch, 1)

        rig.clock.advance(3)
        try await phonePlays(rig, epoch: 1)
        rig.clock.advance(2)
        macPlays(rig, position: 15)
        await rig.controller.reconcile()

        XCTAssertEqual(rig.player.pauseCount, 1, "the later takeover at the same epoch wins")
    }

    func testOnlyTheSyncRoundRepublishesWhilePlaying() async throws {
        let rig = await makeRig()
        macPlays(rig, position: 10)
        await rig.controller.reconcile()
        rig.clock.advance(2)
        await rig.server.setClock(rig.clock.now)
        macPlays(rig, position: 12)
        await rig.controller.reconcile()
        let current = try await macPosition(rig)
        XCTAssertEqual(current.positionSeconds, 10, "the local 2 s tick sends nothing")

        rig.clock.advance(SyncCadence.playingPublishInterval - 2)
        await rig.server.setClock(rig.clock.now)
        macPlays(rig, position: 10 + SyncCadence.playingPublishInterval)
        await rig.controller.reconcile()
        let stillOld = try await macPosition(rig)
        XCTAssertEqual(stillOld.positionSeconds, 10, "time passing is not a reason to publish; the round is")
        await rig.controller.tickRound()
        let record = try await macPosition(rig)
        XCTAssertEqual(record.positionSeconds, 10 + SyncCadence.playingPublishInterval)
        XCTAssertEqual(record.epoch, 1, "cadence publishes keep the session epoch")
        XCTAssertEqual(rig.controller.takeoverCount, 1)
    }

    func testASeekWhilePlayingIsPublishedAtOnceNotAtTheNextCadence() async throws {
        let rig = await makeRig()
        macPlays(rig, position: 10)
        await rig.controller.reconcile()
        rig.clock.advance(2)
        await rig.server.setClock(rig.clock.now)
        macPlays(rig, position: 600)
        await rig.controller.reconcile()
        let record = try await macPosition(rig)
        XCTAssertEqual(record.positionSeconds, 600, "a scrub is an edge event")
        XCTAssertEqual(record.epoch, 1)
        XCTAssertEqual(rig.controller.takeoverCount, 1)
    }

    func testAPlayingMacWithoutPollerRecordsObservesAtMostOncePerPoll() async throws {
        let rig = await makeRig()
        macPlays(rig, position: 10)
        await rig.controller.reconcile()
        rig.clock.advance(2)
        await rig.server.setClock(rig.clock.now)
        macPlays(rig, position: 12)
        await rig.controller.reconcile()   // the one observation of this poll

        try await phonePlays(rig, epoch: 2)
        rig.clock.advance(2)
        macPlays(rig, position: 14)
        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.pauseCount, 0, "ticks inside the poll interval do not fetch")

        rig.clock.advance(SyncCadence.pollInterval)
        macPlays(rig, position: 14 + SyncCadence.pollInterval)
        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.pauseCount, 1, "the next poll interval sees the takeover; relinquishing takes up to 30 s")
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

    // MARK: - Stored positions of paused episodes

    private func progressRecords(_ rig: Rig) async throws -> [ObservedPlayback] {
        try await InMemoryLibraryTransport(deviceID: "reader", server: rig.server)
            .fetchDeviceRecords().progress.filter { $0.record.deviceID == macID }
    }

    func testAnEpisodePausedBeforeLaunchIsPublishedAsPausedProgressWithoutTakingOver() async throws {
        let rig = await makeRig()
        rig.player.stored = [.init(entryID: entry, revision: revision, positionSeconds: 1_234, updatedAt: rig.clock.now)]
        try await phonePlays(rig, epoch: 2, playing: false)

        await rig.controller.reconcile()
        let beforeRound = try await progressRecords(rig).filter { $0.record.deviceID == macID }
        XCTAssertTrue(beforeRound.isEmpty, "the local tick does not publish stored positions")
        await rig.controller.tickRound()

        let progress = try await progressRecords(rig)
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.record.positionSeconds, 1_234)
        XCTAssertEqual(progress.first?.record.revision, revision)
        XCTAssertFalse(progress.first?.record.isPlaying ?? true)
        let nowPlaying = try await macRecord(rig)
        XCTAssertNil(nowPlaying, "no NowPlaying record: publishing a stored position is not a takeover")
        XCTAssertEqual(rig.controller.takeoverCount, 0)
        XCTAssertEqual(progress.first?.record.epoch, 2, "the epoch already seen for the entry, never one higher")
    }

    func testStoredPositionsAreNotPublishedWhileTheMacPlaysAndFollowThePause() async throws {
        let rig = await makeRig()
        macPlays(rig, position: 50)
        rig.player.stored = [.init(entryID: entry, revision: revision, positionSeconds: 5, updatedAt: nil)]
        await rig.controller.tickRound()
        XCTAssertEqual(rig.player.storedReadCount, 0, "nothing is read while a session plays")

        rig.player.sample?.isPlaying = false
        rig.player.sample?.positionSeconds = 88
        rig.player.stored = [.init(entryID: entry, revision: revision, positionSeconds: 88, updatedAt: nil)]
        await rig.controller.tickRound()

        let progress = try await progressRecords(rig)
        XCTAssertEqual(progress.first?.record.positionSeconds, 88)
        XCTAssertFalse(progress.first?.record.isPlaying ?? true)
    }

    func testStoredPositionsAreReadOncePerTriggerNotOnEveryPass() async throws {
        let rig = await makeRig()
        rig.player.stored = [.init(entryID: entry, revision: revision, positionSeconds: 10, updatedAt: nil)]
        await rig.controller.tickRound()
        await rig.controller.reconcile()
        XCTAssertEqual(rig.player.storedReadCount, 1)
        let first = try await progressRecords(rig).first?.serverModifiedAt

        // A listener pause makes them due again; an unchanged list is read but not written again.
        macPlays(rig, position: 30)
        await rig.controller.reconcile()
        rig.player.sample?.isPlaying = false
        rig.player.stored = [.init(entryID: entry, revision: revision, positionSeconds: 30, updatedAt: nil)]
        await rig.controller.tickRound()
        XCTAssertEqual(rig.player.storedReadCount, 2)
        let after = try await progressRecords(rig).first
        XCTAssertEqual(after?.record.positionSeconds, 30)
        XCTAssertNotNil(first)
    }

    func testStoredPositionPublicationReadsFreshRecordsEvenWithPollerRecords() async throws {
        let clock = TestClock()
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        await server.setClock(clock.now)
        let coordinator = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: macID, server: server), deviceID: macID,
            clock: { clock.now }, sleep: { _ in })
        let player = ScriptedPlayer()
        player.revision = revision
        player.stored = [.init(entryID: entry, revision: revision, positionSeconds: 100, updatedAt: clock.now)]
        // The poller's records predate the phone's save and never show it.
        let stale = LibraryDeviceRecords(nowPlaying: [], progress: [])
        let controller = WiltedMacHandoffController(
            coordinator: coordinator, player: player, deviceID: macID, latestRecords: { stale }, now: { clock.now })

        clock.advance(60)
        await server.setClock(clock.now)
        let peer = try DevicePlaybackPosition(
            deviceID: phoneID, entryID: entry, revision: revision, positionSeconds: 500, isPlaying: false,
            epoch: 2, publishedAt: clock.now)
        try await InMemoryLibraryTransport(deviceID: phoneID, server: server).publish(peer, as: .progress)

        await controller.tickRound()

        let mac = try await InMemoryLibraryTransport(deviceID: "reader", server: server)
            .fetchDeviceRecords().progress.filter { $0.record.deviceID == macID }
        XCTAssertTrue(mac.isEmpty, "the newer peer save in the server, absent from the poller records, wins")
    }
}
