import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedListener
import XCTest
@testable import WiltediOS

private final class AutoEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTime = 0.0
    private var _isPlaying = false
    private var handler: (@Sendable (UInt64) -> Void)?
    private var generation: UInt64 = 0
    var duration = 600.0
    var rate: Float = 1
    private(set) var loadedStarts: [Double] = []

    var currentTime: Double {
        get { lock.withLock { _currentTime } }
        set { lock.withLock { _currentTime = newValue } }
    }
    var isPlaying: Bool {
        get { lock.withLock { _isPlaying } }
        set { lock.withLock { _isPlaying = newValue } }
    }
    func load(url: URL) throws { try load(url: url, completionGeneration: 0) }
    func load(url: URL, completionGeneration: UInt64) throws { generation = completionGeneration; currentTime = 0 }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) { self.handler = handler }

    func finishNaturally(reporting reported: UInt64? = nil) {
        isPlaying = false
        currentTime = duration
        handler?(reported ?? generation)
    }
}

private final class AutoSession: ListenerAudioSession, @unchecked Sendable {
    func activate() throws {}
    func deactivate() {}
}

private final class AutoNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}

@MainActor private final class AutoRemote: LibraryRemoteCommands {
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    func uninstall() {}
}

@MainActor private final class AutoEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

/// Auto-continue: a finished episode is followed by the next one of the shared play order, on the
/// real model, player and file cache with an in-memory server standing in for the Mac.
@MainActor
final class LibraryAutoContinueTests: XCTestCase {
    private var scratch: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private let revision = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-autocontinue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private struct Rig {
        let model: LibraryAppModel
        let player: LibraryPlayer
        let engine: AutoEngine
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    /// Entries "a" to "d", published a first and d last, queued in the order given, all on the phone.
    private func makeRig(
        queue: [String] = ["a", "b", "c", "d"], autoPlayNext: Bool = true, feedDuration: Double = 600
    ) async throws -> Rig {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        var changes: [LibraryChange] = [.source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))]
        for (offset, raw) in ["a", "b", "c", "d"].enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Title \(raw)", summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(offset) * 86_400), durationSeconds: feedDuration,
                removal: .none, removedAt: nil)))
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            _ = try await cache.adopt(
                verifiedFile: file,
                for: LibraryMediaOffer(
                    entryID: id(raw), revisionID: revision,
                    contentHash: MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                    byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
        }
        for (position, raw) in queue.enumerated() { changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(position)))) }
        try await macPush(changes)
        let engine = AutoEngine()
        let player = LibraryPlayer(
            engine: engine, session: AutoSession(), nowPlaying: AutoNowPlaying(), remoteCommands: AutoRemote(),
            sessionEvents: AutoEvents(), tickInterval: .seconds(3600))
        player.apply(LibraryPlaybackPreferences(
            defaultSpeed: 1.25, skipBackSeconds: 15, skipForwardSeconds: 30, autoPlayNext: autoPlayNext))
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                settleSleep: { _ in }),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }, timeZone: TimeZone(identifier: "UTC")!)
        model.attachPlayer(player)
        await model.refresh()
        for raw in ["a", "b", "c", "d"] { model.media[id(raw)] = .onPhone }
        return Rig(model: model, player: player, engine: engine)
    }

    private func inProgressOnMac(_ raw: String, position: Double = 100, at seconds: TimeInterval = 1_650_000_000) async throws {
        await server.setClock(Date(timeIntervalSince1970: seconds))
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id(raw), revision: revision, positionSeconds: position, rate: 1, isPlaying: false, epoch: 1,
            publishedAt: Date(timeIntervalSince1970: seconds))
        try await mac.publish(record, as: .progress)
    }

    private func complete(_ raw: String, at seconds: TimeInterval) async throws {
        try await macPush([.listening(ListeningRecord(
            itemID: id(raw), completedAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds),
            deviceID: "mac"))])
    }

    private func start(_ rig: Rig, _ raw: String) async {
        let row = try! XCTUnwrap(rig.model.queued.first { $0.id == id(raw) })
        await rig.model.playCached(row)
    }

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle() async { for _ in 0..<40 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(100)) }

    /// One fixture, four views of the order: the phone's list, CarPlay's list, Siri's list and what
    /// auto-continue plays, which must all be the same sequence.
    func testPhoneListCarPlaySiriAndAutoContinueAgree() async throws {
        let rig = try await makeRig()
        try await inProgressOnMac("c")
        try await complete("b", at: 1_690_000_000)
        await rig.model.refresh()
        for raw in ["a", "b", "c", "d"] { rig.model.media[id(raw)] = .onPhone }
        let phone = rig.model.visibleRows.map(\.id.rawValue)
        XCTAssertEqual(phone, ["c", "a", "d", "b"], "in progress, oldest not-started, completed last")
        let car = CarEpisodeList.make(model: rig.model, playingID: nil)
        guard case let .episodes(carRows) = car.content else { return XCTFail("no car list") }
        XCTAssertEqual(carRows.map(\.id.rawValue), phone)
        let macPosition = try XCTUnwrap(rig.model.progress[id("c")], "the Mac's position reaches the phone row")
        XCTAssertEqual(macPosition.positionSeconds, 100)
        XCTAssertNotNil(CarEpisodeList.fraction(macPosition, duration: try XCTUnwrap(rig.model.queued.first { $0.id == id("c") }?.durationSeconds)))
        XCTAssertEqual(
            carRows.first?.detail.components(separatedBy: " · ").last,
            LibraryRowView.detail(row: carRows[0].row, progress: macPosition, completed: false).components(separatedBy: " · ").first,
            "the phone row and the car row read the same time left")
        let siri = await LibraryVoiceTarget(model: rig.model, player: rig.player).voiceSnapshot()
        XCTAssertEqual(siri.downloaded.map(\.id.rawValue), phone)
        await start(rig, "c")
        var played = ["c"]
        for _ in 0..<5 {
            let current = try XCTUnwrap(rig.player.item?.entryID)
            rig.engine.finishNaturally()
            await settle()
            guard let next = rig.player.item?.entryID, next != current else { break }
            played.append(next.rawValue)
        }
        XCTAssertEqual(played, phone.filter { $0 != "b" }, "auto-continue walks the list, skipping the completed one")
    }

    func testAFinishedEpisodeIsFollowedByTheNextOneAtTheListenersSpeed() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.player.setRate(1.5)
        rig.engine.finishNaturally()
        try await eventually("the next episode") { rig.player.item?.entryID == self.id("b") && rig.player.isPlaying }
        XCTAssertEqual(rig.player.rate, 1.5, "the speed the listener chose carries over")
    }

    func testInProgressComesFirstThenOldestNotStartedAndItStopsWhenNoneRemain() async throws {
        let rig = try await makeRig()
        try await inProgressOnMac("c")
        await rig.model.refresh()
        for raw in ["a", "b", "c", "d"] { rig.model.media[id(raw)] = .onPhone }
        let listed = rig.model.playOrderRows.map(\.id.rawValue)
        XCTAssertEqual(listed, ["c", "a", "b", "d"], "in progress first, then oldest published first")
        await start(rig, "b")
        var played = ["b"]
        for _ in 0..<5 {
            let current = try XCTUnwrap(rig.player.item?.entryID)
            rig.engine.finishNaturally()
            await settle()
            guard let next = rig.player.item?.entryID, next != current else { break }
            played.append(next.rawValue)
        }
        XCTAssertEqual(played, ["b", "c", "a", "d"], "the chain follows the list order, minus the one started with")
        XCTAssertEqual(rig.player.status, .ended, "after the last one, playback stops cleanly")
        XCTAssertEqual(rig.player.item?.entryID, id("d"))
    }

    func testCompletedEpisodesAreSkippedAndListedLastMostRecentFirst() async throws {
        let rig = try await makeRig()
        try await complete("b", at: 1_690_000_000)
        try await complete("a", at: 1_695_000_000)
        await rig.model.refresh()
        for raw in ["a", "b", "c", "d"] { rig.model.media[id(raw)] = .onPhone }
        XCTAssertEqual(rig.model.playOrderRows.map(\.id.rawValue), ["c", "d", "a", "b"])
        await start(rig, "c")
        rig.engine.finishNaturally()
        try await eventually("d after c") { rig.player.item?.entryID == self.id("d") }
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("d"), "only completed episodes are left, so it stops")
        XCTAssertEqual(rig.player.status, .ended)
    }

    func testAnEpisodePlayedToItsEndEarlierIsNotPickedUpAgain() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.engine.finishNaturally()
        try await eventually("b") { rig.player.item?.entryID == self.id("b") }
        rig.engine.finishNaturally()
        try await eventually("c") { rig.player.item?.entryID == self.id("c") }
        XCTAssertNotNil(rig.model.finished[id("a")], "an episode played out counts as completed for ordering")
        XCTAssertEqual(rig.model.playOrderRows.map(\.id.rawValue).suffix(2).sorted(), ["a", "b"])
    }

    func testTheSettingOffLeavesTheEpisodeEnded() async throws {
        let rig = try await makeRig(autoPlayNext: false)
        await start(rig, "a")
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
        XCTAssertEqual(rig.player.status, .ended)
    }

    /// The feed says 900 s, the file is 600 s: a position at the file's end is not at the feed's end.
    func testAFeedLengthThatDiffersFromTheFilesDoesNotBringBackAFinishedEpisode() async throws {
        let rig = try await makeRig(feedDuration: 900)
        await start(rig, "a")
        var played = ["a"]
        for _ in 0..<6 {
            let current = try XCTUnwrap(rig.player.item?.entryID)
            rig.engine.finishNaturally()
            await settle()
            guard let next = rig.player.item?.entryID, next != current else { break }
            played.append(next.rawValue)
        }
        XCTAssertEqual(played, ["a", "b", "c", "d"], "no episode comes round twice")
    }

    func testTheEndedEpisodesFinalPositionIsKeptEvenThoughThePlayerMovedOn() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.engine.finishNaturally()
        try await eventually("b") { rig.player.item?.entryID == self.id("b") }
        XCTAssertEqual(rig.model.handoffState.ownPositions[id("a")]?.record.positionSeconds, 600)
    }

    func testPlayingAnEndedEpisodeAgainTakesItOutOfCompletedAndPutsItFirst() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.engine.finishNaturally()
        try await eventually("b") { rig.player.item?.entryID == self.id("b") }
        XCTAssertNotNil(rig.model.finished[id("a")])
        await start(rig, "a")
        try await eventually("a no longer finished") { rig.model.finished[self.id("a")] == nil }
        rig.player.seek(to: 30)
        try await eventually("a leads the list") { rig.model.playOrderRows.first?.id == self.id("a") }
    }

    func testAPauseAfterTheEndAndBeforeTheLookupCancelsTheContinuation() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.engine.finishNaturally()
        rig.player.pause()   // commanded before the continuation has run
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
    }

    func testASpeedChosenByAnotherStartIsNotOverwritten() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.player.setRate(1.5)
        rig.engine.finishNaturally()
        await start(rig, "b")   // another start, same target as the continuation, at the default speed
        rig.player.setRate(1.0)
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        XCTAssertEqual(rig.player.rate, 1.0)
    }

    func testAPauseNearTheEndNeverAdvances() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.player.seek(to: 595)
        rig.player.pause()
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
        XCTAssertEqual(rig.player.status, .paused)
    }

    func testAStaleLoadsFinishNeverAdvances() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        await start(rig, "b")
        rig.engine.finishNaturally(reporting: 1)
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        XCTAssertEqual(rig.player.status, .playing)
    }

    func testAStartMadeWhileTheNextWasLookedUpIsNotOverridden() async throws {
        let rig = try await makeRig()
        await start(rig, "a")
        rig.engine.finishNaturally()
        await start(rig, "d")   // the driver picks something else right away
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("d"))
    }

    func testTheSettingDefaultsOnPersistsAndReachesThePlayer() {
        let suite = "autoplay-settings-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertTrue(store.autoPlayNext)
        XCTAssertTrue(store.playback.autoPlayNext)
        store.autoPlayNext = false
        XCTAssertFalse(LibrarySettingsStore(defaults: defaults).autoPlayNext)
        XCTAssertFalse(store.playback.autoPlayNext)
        defaults.removePersistentDomain(forName: suite)
    }
}
