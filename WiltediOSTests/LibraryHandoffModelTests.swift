import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

// MARK: - Doubles

/// Shared controllable wall clock; the in-memory server's clock is kept equal to it.
private final class HandoffClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func set(_ value: TimeInterval) { lock.withLock { time = value } }
}

/// The observe cadence's sleep: records each requested delay and returns only when a test releases it.
private actor TickSleeper {
    private(set) var requested: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(_ seconds: TimeInterval) async throws {
        requested.append(seconds)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func release() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func cancelAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private final class HandoffFakeEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTime = 0.0
    private var _isPlaying = false
    var duration = 3_600.0
    var rate: Float = 1
    private(set) var pauseCount = 0

    var currentTime: Double {
        get { lock.withLock { _currentTime } }
        set { lock.withLock { _currentTime = newValue } }
    }
    var isPlaying: Bool {
        get { lock.withLock { _isPlaying } }
        set { lock.withLock { _isPlaying = newValue } }
    }
    func load(url: URL) throws {}
    func load(url: URL, completionGeneration: UInt64) throws { currentTime = 0 }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { pauseCount += 1; isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

private final class HandoffFakeSession: ListenerAudioSession, @unchecked Sendable {
    func activate() throws {}
    func deactivate() {}
}

private final class HandoffFakeNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}

@MainActor private final class HandoffFakeRemote: LibraryRemoteCommands {
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    func uninstall() {}
}

@MainActor private final class HandoffFakeEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

/// The in-memory transport with a switch that takes every playback-record read and write offline.
private struct OfflineSwitchTransport: LibraryTransport {
    final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var offline: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    let inner: InMemoryLibraryTransport
    let offlineSwitch: Switch

    private func check() throws {
        if offlineSwitch.offline { throw LibraryTransportError.transport("offline") }
    }

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try check()
        try await inner.publish(record, as: channel)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        try check()
        return try await inner.fetchDeviceRecords()
    }
}

// MARK: - Tests

@MainActor
final class LibraryHandoffModelTests: XCTestCase {
    private var scratch: URL!
    private let clock = HandoffClock()
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private lazy var phoneTransport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
    private let sleeper = TickSleeper()
    private let entryID = try! ItemID(rawValue: "item-a")
    private let rev1 = try! RevisionID(rawValue: "rev-1")
    private let rev2 = try! RevisionID(rawValue: "rev-2")
    private let payload = Data((0..<50_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-handoff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        await setTime(1_000)
    }

    override func tearDown() async throws {
        await sleeper.cancelAll()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: fixtures

    private struct Rig {
        let model: LibraryAppModel
        let player: LibraryPlayer
        let engine: HandoffFakeEngine
        let cache: FileMediaCache
    }

    private func setTime(_ value: TimeInterval) async {
        clock.set(value)
        await server.setClock(Date(timeIntervalSince1970: value))
    }

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func offer(_ revision: RevisionID) throws -> LibraryMediaOffer {
        try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: revision, contentHash: hash(payload), byteCount: Int64(payload.count),
            mediaType: "audio/mp4", durationSeconds: 3_600))
    }

    private func macPublishMedia(_ revision: RevisionID) async throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        try await mac.publishMedia(offer: offer(revision), fileURL: file)
    }

    /// A phone whose cache already holds `cachedRevision` (nil for an empty cache).
    private func makeRig(cached cachedRevision: RevisionID? = nil, transport: (any LibraryTransport)? = nil) async throws -> Rig {
        let entry = try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: entryID, title: "Episode", summary: "",
            publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 3_600)
        let slot = try QueueSlot(entryID: entryID, sortKey: 0)
        let seeded = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .slot(slot), baseVersion: 0),
        ])
        XCTAssertTrue(seeded.failures.isEmpty)
        let actualTransport = transport ?? phoneTransport
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror-" + UUID().uuidString + ".json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: actualTransport)
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        if let cachedRevision {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: offer(cachedRevision), owner: "fixture-owner")
        }
        let engine = HandoffFakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: HandoffFakeSession(), nowPlaying: HandoffFakeNowPlaying(),
            remoteCommands: HandoffFakeRemote(), sessionEvents: HandoffFakeEvents(), tickInterval: .seconds(3600))
        let sleeper = sleeper
        let clock = clock
        let model = LibraryAppModel(
            transport: actualTransport, store: mirror, deviceID: "phone", mediaCache: cache,
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { try await sleeper.sleep($0) }, settleSleep: { _ in }),
            now: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        model.attachPlayer(player)
        await model.refresh()
        return Rig(model: model, player: player, engine: engine, cache: cache)
    }

    private func item(_ rig: Rig) async throws -> LibraryPlayer.Item {
        let entries = await rig.cache.cachedEntries()
        let cached = try XCTUnwrap(entries[entryID])
        return LibraryPlayer.Item(entryID: entryID, title: "Episode", showTitle: "Show", fileURL: cached.url)
    }

    private func row() throws -> LibraryRow {
        LibraryRow(
            id: entryID, title: "Episode", showTitle: "Show", durationText: nil, removal: .none,
            publishedAt: Date(timeIntervalSince1970: 0), removalText: nil, checkpointText: nil)
    }

    /// The Mac publishing its own playback record, as its handoff controller would.
    private func macPublishes(epoch: Int, playing: Bool, position: Double, revision: RevisionID? = nil, at time: TimeInterval? = nil) async throws {
        if let time { await setTime(time) }
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: entryID, revision: revision ?? rev1, positionSeconds: position, rate: 1,
            isPlaying: playing, epoch: epoch, publishedAt: clock.now)
        try await mac.publish(record, as: .nowPlaying)
        try await mac.publish(record, as: .progress)
    }

    /// The phone's published now-playing record, read as another device would.
    private func phoneRecord() async throws -> DevicePlaybackPosition {
        let records = try await mac.fetchDeviceRecords()
        return try XCTUnwrap(records.nowPlaying.first { $0.record.deviceID == "phone" }?.record)
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: takeover and publishing

    func testStartingPlaybackTakesOverWithNextEpochAndPublishesBothChannels() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macPublishes(epoch: 3, playing: false, position: 500)
        rig.player.start(try await item(rig), at: 30)
        await rig.model.waitForHandoff()

        let record = try await phoneRecord()
        XCTAssertEqual(record.epoch, 4)
        XCTAssertTrue(record.isPlaying)
        XCTAssertEqual(record.positionSeconds, 30)
        XCTAssertEqual(record.revision, rev1)
        let progress = try await mac.fetchDeviceRecords().progress.first { $0.record.deviceID == "phone" }
        XCTAssertEqual(progress?.record.epoch, 4)
        let epoch = await rig.model.coordinator.epoch
        XCTAssertEqual(epoch, 4)
    }

    func testResumingAfterAPauseIsANewTakeover() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig))
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let paused = try await phoneRecord()
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.epoch, 1)

        rig.player.play()
        await rig.model.waitForHandoff()
        let resumed = try await phoneRecord()
        XCTAssertTrue(resumed.isPlaying)
        XCTAssertEqual(resumed.epoch, 2)
    }

    func testProgressPublishesOnTheSyncRoundAndOnPauseAndSeek() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig))
        await rig.model.waitForHandoff()
        try await eventually("tick sleeping") { await self.sleeper.requested == [SyncCadence.tickInterval] }

        await setTime(1_002)
        rig.engine.currentTime = 3
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        let early = try await phoneRecord()
        XCTAssertEqual(early.positionSeconds, 0, "between rounds nothing is published")

        await setTime(1_000 + SyncCadence.playingPublishInterval + 1)
        rig.engine.currentTime = 3 + SyncCadence.playingPublishInterval - 1
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        let still = try await phoneRecord()
        XCTAssertEqual(still.positionSeconds, 0, "the position moving is not a reason to write")

        await sleeper.release()
        let expected = 3 + SyncCadence.playingPublishInterval - 1
        try await eventually("checkpoint in the round") { (try? await self.phoneRecord().positionSeconds) == expected }
        let cadence = try await phoneRecord()
        XCTAssertEqual(cadence.positionSeconds, expected)

        await setTime(1_000 + SyncCadence.playingPublishInterval + 2)
        rig.player.seek(to: 900)
        await rig.model.waitForHandoff()
        let seeked = try await phoneRecord()
        XCTAssertEqual(seeked.positionSeconds, 900, "a seek publishes at once")
        XCTAssertTrue(seeked.isPlaying)

        rig.player.pause()
        await rig.model.waitForHandoff()
        let paused = try await phoneRecord()
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.positionSeconds, 900)

        rig.player.seek(to: 100)
        await rig.model.waitForHandoff()
        let pausedSeek = try await phoneRecord()
        XCTAssertEqual(pausedSeek.positionSeconds, 100)
        XCTAssertFalse(pausedSeek.isPlaying)
    }

    func testEnteringTheBackgroundPublishesTheCurrentPosition() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig))
        await rig.model.waitForHandoff()
        await setTime(1_001)
        rig.engine.currentTime = 2
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        let beforeBackground = try await phoneRecord()
        XCTAssertEqual(beforeBackground.positionSeconds, 0)

        await rig.model.sceneEnteredBackground()
        let record = try await phoneRecord()
        XCTAssertEqual(record.positionSeconds, 2)
        XCTAssertTrue(record.isPlaying)
    }

    func testTappingACachedRowPlaysItAndTakesOver() async throws {
        let rig = try await makeRig(cached: rev1)
        await rig.model.playCached(try row())
        await rig.model.waitForHandoff()
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.item?.entryID, entryID)
        let first = try await phoneRecord()
        XCTAssertEqual(first.epoch, 1)
    }

    // MARK: relinquish

    func testAPlayingPhoneRelinquishesOnTheObserveCadence() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig), at: 60)
        await rig.model.waitForHandoff()
        try await eventually("observe loop sleeping") { await self.sleeper.requested == [SyncCadence.phoneObserveInterval] }

        // The Mac takes over at the next epoch; the phone notices only when its cadence fires.
        try await macPublishes(epoch: 2, playing: true, position: 61, at: 1_003)
        XCTAssertTrue(rig.player.isPlaying, "nothing is observed before the cadence fires")

        await sleeper.release()
        try await eventually("relinquish") { rig.player.status == .paused }
        await rig.model.waitForHandoff()

        XCTAssertGreaterThanOrEqual(rig.engine.pauseCount, 1)
        let record = try await phoneRecord()
        XCTAssertFalse(record.isPlaying, "the loser publishes a paused record itself")
        XCTAssertEqual(record.epoch, 1)
        XCTAssertNotNil(rig.model.handoffMessage)
        let stillHolds = await rig.model.coordinator.hasRelinquished
        XCTAssertTrue(stillHolds)
        // Never restarts: the loop is gone, so no further sleep is requested.
        let requested = await sleeper.requested
        XCTAssertEqual(requested, [SyncCadence.phoneObserveInterval])
    }

    func testALowerEpochElsewhereDoesNotPauseThePhone() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macPublishes(epoch: 1, playing: false, position: 10)
        rig.player.start(try await item(rig))   // phone epoch 2
        await rig.model.waitForHandoff()
        try await eventually("observe loop sleeping") { await self.sleeper.requested == [SyncCadence.phoneObserveInterval] }

        try await macPublishes(epoch: 1, playing: true, position: 20, at: 1_002)
        await sleeper.release()
        try await eventually("second cycle") { rig.model.handoffState.observeCycles == 1 }
        XCTAssertTrue(rig.player.isPlaying)
        try await eventually("loop sleeping again") { await self.sleeper.requested == [SyncCadence.phoneObserveInterval, SyncCadence.phoneObserveInterval] }
    }

    func testPlayingAgainAfterRelinquishingTakesOverWithAHigherEpoch() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig))
        await rig.model.waitForHandoff()
        try await eventually("observe loop sleeping") { await self.sleeper.requested.count == 1 }
        try await macPublishes(epoch: 2, playing: true, position: 5, at: 1_002)
        await sleeper.release()
        try await eventually("relinquish") { rig.player.status == .paused }
        await rig.model.waitForHandoff()

        await setTime(1_010)
        rig.player.play()
        await rig.model.waitForHandoff()
        let again = try await phoneRecord()
        XCTAssertEqual(again.epoch, 3)
        XCTAssertTrue(again.isPlaying)
    }

    // MARK: Continue from Mac

    func testContinueKeepsMacRateInsteadOfThePhoneDefault() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.apply(LibraryPlaybackPreferences(defaultSpeed: 1.5, skipBackSeconds: 15, skipForwardSeconds: 30))
        try await macPublishes(epoch: 1, playing: true, position: 100, at: 1_000)
        await rig.model.refresh()
        await rig.model.continueFromMac()
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.player.rate, 1)
        XCTAssertEqual(rig.engine.rate, 1)
    }

    func testContinueRejectsSameSizeCorruptedReadyAudio() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macPublishes(epoch: 1, playing: true, position: 100, at: 1_000)
        await rig.model.refresh()
        let entries = await rig.cache.cachedEntries()
        let file = try XCTUnwrap(entries[entryID]?.url)
        try Data(repeating: 42, count: payload.count).write(to: file)
        await rig.model.continueFromMac()
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertNil(rig.player.item)
    }

    func testContinueFromMacWithCachedMediaResumesAtTheRateAwarePosition() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macPublishes(epoch: 1, playing: true, position: 100, at: 1_000)
        await setTime(1_010)
        await rig.model.refresh()

        let records = try await mac.fetchDeviceRecords()
        let source = try XCTUnwrap(records.nowPlaying.first { $0.record.deviceID == "mac" })
        XCTAssertEqual(
            rig.model.continuation,
            .ready(entryID: entryID, positionSeconds: 110, rate: 1, wasPlaying: true, sourceDeviceID: "mac", source: source))
        await rig.model.continueFromMac()
        await rig.model.waitForHandoff()

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 110)
        XCTAssertNil(rig.model.continuation)
        let record = try await phoneRecord()
        XCTAssertEqual(record.epoch, 2, "continuing is a takeover")
        XCTAssertEqual(record.positionSeconds, 110)
    }

    func testContinueFromMacWithUncachedMediaRequestsItThenResumes() async throws {
        let rig = try await makeRig()
        try await macPublishes(epoch: 1, playing: false, position: 240, at: 1_000)
        await rig.model.refresh()
        let records = try await mac.fetchDeviceRecords()
        let source = try XCTUnwrap(records.nowPlaying.first { $0.record.deviceID == "mac" })
        XCTAssertEqual(rig.model.continuation, .needsAudio(entryID: entryID, revision: rev1, source: source))

        let resumed = Task { await rig.model.continueFromMac() }
        try await eventually("media request") {
            ((try? await self.mac.listIntents()) ?? []).contains { $0.action == .requestMedia(entryID: self.entryID) }
        }
        try await macPublishMedia(rev1)
        await resumed.value
        await rig.model.waitForHandoff()

        let cached = await rig.cache.cachedEntries()
        XCTAssertEqual(cached[entryID]?.revisionID, rev1)
        XCTAssertEqual(rig.player.item?.entryID, entryID)
        XCTAssertEqual(rig.player.position, 240)
        XCTAssertEqual(rig.player.status, .playing)
    }

    func testContinueFromMacRefusesAMismatchedCachedRevision() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macPublishes(epoch: 1, playing: true, position: 100, revision: rev2, at: 1_000)
        await rig.model.refresh()

        guard case let .refused(refusedEntry, reason, source) = rig.model.continuation else {
            return XCTFail("expected refused, got \(String(describing: rig.model.continuation))")
        }
        XCTAssertEqual(refusedEntry, entryID)
        XCTAssertTrue(reason.contains("different version"))
        XCTAssertNil(LibraryContinueBanner.actionTitle(.refused(entryID: entryID, reason: reason, source: source), media: .onPhone))

        await rig.model.continueFromMac()
        XCTAssertNil(rig.player.item, "a mismatched revision is never played")
        XCTAssertEqual(rig.player.status, .idle)
        XCTAssertNotNil(rig.model.handoffMessage)
        let intents = try await mac.listIntents()
        XCTAssertTrue(intents.isEmpty, "no audio is requested for a mismatched revision")
    }

    func testContinueFromMacRefusesWhenTheMacOffersADifferentRevisionWithoutDownloading() async throws {
        let rig = try await makeRig()
        try await macPublishes(epoch: 1, playing: true, position: 100, revision: rev1, at: 1_000)
        try await macPublishMedia(rev2)
        await rig.model.refresh()
        let records = try await mac.fetchDeviceRecords()
        let source = try XCTUnwrap(records.nowPlaying.first { $0.record.deviceID == "mac" })
        XCTAssertEqual(rig.model.continuation, .needsAudio(entryID: entryID, revision: rev1, source: source))

        await rig.model.continueFromMac()
        guard case .refused = rig.model.continuation else {
            return XCTFail("expected refused, got \(String(describing: rig.model.continuation))")
        }
        XCTAssertNil(rig.player.item)
        let cached = await rig.cache.cachedEntries()
        XCTAssertTrue(cached.isEmpty)
        let intents = try await mac.listIntents()
        XCTAssertTrue(intents.isEmpty)
        // A later refresh keeps the refusal instead of offering the same doomed download.
        await rig.model.refresh()
        guard case .refused = rig.model.continuation else { return XCTFail("refusal must persist across refresh") }
    }

    func testNoContinueOfferWhenThePhonePlayedMostRecently() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macPublishes(epoch: 1, playing: false, position: 10, at: 1_000)
        rig.player.start(try await item(rig))   // phone epoch 2
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()

        await rig.model.refresh()
        XCTAssertNil(rig.model.continuation, "the Mac's older checkpoint is not something to continue")
    }

    func testAPlayingPhoneHidesContinue() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig))
        await rig.model.waitForHandoff()
        // Paused, so the round does not hand playback over (a playing Mac at a higher epoch would pause the phone).
        try await macPublishes(epoch: 5, playing: false, position: 10, at: 1_001)
        await rig.model.refresh()
        XCTAssertNil(rig.model.continuation)
    }

    // MARK: planner

    func testPlannerTreatsAStalePlayingRecordAsPausedAtItsRecordedPosition() throws {
        let observed = ObservedPlayback(
            record: try DevicePlaybackPosition(
                deviceID: "mac", entryID: entryID, revision: rev1, positionSeconds: 300, rate: 1.5, isPlaying: true, epoch: 2),
            serverModifiedAt: Date(timeIntervalSince1970: 1_000))
        let plan = LibraryContinuationPlanner.plan(
            records: LibraryDeviceRecords(nowPlaying: [observed]), deviceID: "phone", cachedRevisions: [entryID: rev1],
            durations: [:], now: Date(timeIntervalSince1970: 1_600), clockOffset: 0)
        XCTAssertEqual(plan, .ready(entryID: entryID, positionSeconds: 300, rate: 1.5, wasPlaying: false, sourceDeviceID: "mac", source: observed))
    }

    // MARK: Play resumes at the last position

    /// The Mac's stored position for a paused episode, on the Progress channel only, as
    /// `HandoffCoordinator.publishStoredPositions` writes it.
    private func macStoredPosition(_ position: Double, revision: RevisionID? = nil, epoch: Int = 0) async throws {
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: entryID, revision: revision ?? rev1, positionSeconds: position, rate: 1,
            isPlaying: false, epoch: epoch, publishedAt: clock.now)
        try await mac.publish(record, as: .progress)
    }

    func testPlayResumesAtTheMacsStoredPausedPosition() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macStoredPosition(754)
        await rig.model.refresh()

        await rig.model.playCached(try row())
        await rig.model.waitForHandoff()

        XCTAssertEqual(rig.player.position, 754)
        XCTAssertEqual(rig.player.status, .playing)
    }

    func testPlayStartsOverWhenTheStoredPositionIsForADifferentRevision() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macStoredPosition(754, revision: rev2)
        await rig.model.refresh()

        await rig.model.playCached(try row())
        await rig.model.waitForHandoff()

        XCTAssertEqual(rig.player.position, 0)
    }

    func testPlayResumesWhereThePhoneLeftOffWhenTheMacRecordIsOlder() async throws {
        let rig = try await makeRig(cached: rev1)
        try await macStoredPosition(50, epoch: 0)
        rig.player.start(try await item(rig), at: 10)   // the phone takes over at epoch 1
        await rig.model.waitForHandoff()
        await setTime(1_010)
        rig.engine.currentTime = 200
        rig.player.seek(to: 200)
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()

        // Without a fetch: the phone's own pause is remembered.
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 200)
        // And after a fetch, from its own progress record on the server.
        await rig.model.refresh()
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 200)

        // A later Mac takeover outranks it.
        try await macPublishes(epoch: 5, playing: false, position: 900, at: 1_020)
        await rig.model.refresh()
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 900)
    }
    // MARK: positions the Mac adopts

    private func phoneProgress() async throws -> DevicePlaybackPosition? {
        try await mac.fetchDeviceRecords().progress.first { $0.record.deviceID == "phone" }?.record
    }

    func testAPauseThatCouldNotBePublishedIsRepublishedOnTheNextSync() async throws {
        let offline = OfflineSwitchTransport.Switch()
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 10)
        await rig.model.waitForHandoff()
        offline.offline = true
        await setTime(1_030)
        rig.engine.currentTime = 300
        rig.player.seek(to: 300)
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let stale = try await phoneRecord()
        XCTAssertTrue(stale.isPlaying, "the pause never reached the server")
        XCTAssertLessThan(stale.positionSeconds, 300)

        offline.offline = false
        await setTime(1_040)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.isPlaying, false)
        XCTAssertEqual(progress?.positionSeconds, 300)
        XCTAssertEqual(progress?.revision, rev1)
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 300)
    }

    func testAListenWithNoSessionAtAllIsPublishedOnceBackOnline() async throws {
        let offline = OfflineSwitchTransport.Switch()
        offline.offline = true
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 30)
        await rig.model.waitForHandoff()
        await setTime(1_060)
        rig.engine.currentTime = 200
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let nothing = try await phoneProgress()
        XCTAssertNil(nothing, "takeover failed offline, so nothing was published")

        offline.offline = false
        await setTime(1_070)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.positionSeconds, 200)
        XCTAssertEqual(progress?.isPlaying, false)
        XCTAssertEqual(progress?.revision, rev1)
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 200)
    }

    func testAnOfflineListenAfterAMacTakeoverIsPublishedAtTheMacsEpochSoTheMacAdoptsIt() async throws {
        let offline = OfflineSwitchTransport.Switch()
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 10)   // the phone's session, epoch 1
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        try await macPublishes(epoch: 2, playing: false, position: 600, at: 1_020)
        await rig.model.refresh()

        offline.offline = true
        await setTime(1_030)
        rig.player.start(try await item(rig), at: 700)
        await rig.model.waitForHandoff()
        await setTime(1_060)
        rig.engine.currentTime = 900
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()

        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 900, "offline, the phone's newer listen beats the Mac's older record")

        offline.offline = false
        await setTime(1_070)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.positionSeconds, 900)
        XCTAssertGreaterThanOrEqual(progress?.epoch ?? 0, 2, "published at the entry's highest epoch")
        let records = try await mac.fetchDeviceRecords()
        let candidates = HandoffPositionImport.candidates(records: records, localDeviceID: "mac")
        XCTAssertEqual(candidates.map(\.positionSeconds), [900], "the Mac would adopt the phone's listen")
        XCTAssertEqual(rig.model.resumeStart(for: entryID, cachedRevision: rev1), 900)
    }

    func testAnOfflineListenAfterAnEarlierStopIsStillPublished() async throws {
        let offline = OfflineSwitchTransport.Switch()
        let rig = try await makeRig(cached: rev1, transport: OfflineSwitchTransport(inner: phoneTransport, offlineSwitch: offline))
        rig.player.start(try await item(rig), at: 10)
        await rig.model.waitForHandoff()
        rig.player.stop()   // the session ends with the item gone
        await rig.model.waitForHandoff()

        offline.offline = true
        await setTime(1_030)
        rig.player.start(try await item(rig), at: 300)
        await rig.model.waitForHandoff()
        await setTime(1_060)
        rig.engine.currentTime = 450
        rig.player.refreshPosition()
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()

        offline.offline = false
        await setTime(1_070)
        await rig.model.refresh()

        let progress = try await phoneProgress()
        XCTAssertEqual(progress?.positionSeconds, 450)
        XCTAssertEqual(progress?.isPlaying, false)
    }

    func testAPublishedPauseIsNotRepublishedAndProgressStaysAtThePause() async throws {
        let rig = try await makeRig(cached: rev1)
        rig.player.start(try await item(rig), at: 10)
        await rig.model.waitForHandoff()
        await setTime(1_030)
        rig.engine.currentTime = 400
        rig.player.seek(to: 400)
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        let before = try await mac.fetchDeviceRecords().progress.first { $0.record.deviceID == "phone" }

        await setTime(1_100)
        await rig.model.refresh()

        let after = try await mac.fetchDeviceRecords().progress.first { $0.record.deviceID == "phone" }
        XCTAssertEqual(after?.serverModifiedAt, before?.serverModifiedAt, "nothing pending, nothing written")
        XCTAssertEqual(after?.record.positionSeconds, 400)
    }
}
