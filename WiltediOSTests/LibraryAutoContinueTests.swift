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

/// Holds cache lookups so a test can act between two of them deterministically, without sleeping.
/// The wrapper captures the entries before it holds, so what the caller receives was decided
/// before the hold began and the test's mutation lands strictly after it.
private actor LookupGate {
    private enum WaitError: Error { case timedOut }
    private var armed = false
    private var heldCount = 0
    private var heldLookups: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var heldOrder: [UUID] = []
    private var observers: [UUID: CheckedContinuation<Void, Error>] = [:]

    func arm() { armed = true }

    /// Called by the cache wrapper after it captured the entries: wakes the test, then waits.
    func hold() async {
        guard armed else { return }
        heldCount += 1
        observers.values.forEach { $0.resume() }
        observers.removeAll()
        let id = UUID()
        await withCheckedContinuation { continuation in
            heldLookups[id] = continuation
            heldOrder.append(id)
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.releaseHeld(id)
            }
        }
    }

    /// Waits until a lookup is held right now.
    func waitForHold() async throws {
        if heldCount > 0 { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            observers[id] = continuation
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.timeoutWait(id)
            }
        }
    }

    private func timeoutWait(_ id: UUID) {
        observers.removeValue(forKey: id)?.resume(throwing: WaitError.timedOut)
    }

    private func releaseHeld(_ id: UUID) {
        guard let continuation = heldLookups.removeValue(forKey: id) else { return }
        heldOrder.removeAll { $0 == id }
        heldCount -= 1
        continuation.resume()
    }

    /// Lets the oldest held lookup return, keeping the gate armed.
    func releaseNext() {
        guard let id = heldOrder.first else { return }
        releaseHeld(id)
    }

    /// Lets every held lookup return and stops holding new ones.
    func disarm() {
        armed = false
        heldOrder.forEach { heldLookups.removeValue(forKey: $0)?.resume() }
        heldLookups.removeAll()
        heldOrder.removeAll()
        heldCount = 0
    }
}

/// A `LibraryMediaCache` whose lookups a `LookupGate` can hold.
private actor AutoContinueGatedMediaCache: LibraryMediaCache {
    let base: FileMediaCache
    let gate: LookupGate

    init(base: FileMediaCache, gate: LookupGate) {
        self.base = base
        self.gate = gate
    }

    func cachedEntries() async -> [ItemID: CachedMedia] {
        let entries = await base.cachedEntries()
        await gate.hold()
        return entries
    }

    func cachedFile(for offer: LibraryMediaOffer) async -> URL? { await base.cachedFile(for: offer) }
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer) async throws -> URL {
        try await base.adopt(verifiedFile: verifiedFile, for: offer)
    }
    func remove(entryID: ItemID) async throws { try await base.remove(entryID: entryID) }
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
        await base.cachedTranscript(entryID: entryID, revisionID: revisionID)
    }
    func storeTranscript(_ transcript: LibraryTranscript) async { await base.storeTranscript(transcript) }
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

    /// Entries in the order given, published first to last, queued in the order given, all on the phone.
    /// `gate` wraps the media cache so a test can hold a cache lookup at a chosen moment.
    private func makeRig(
        entries: [String] = ["a", "b", "c", "d"],
        queue: [String]? = nil, autoPlayNext: Bool = true, feedDuration: Double = 600,
        gate: LookupGate? = nil
    ) async throws -> Rig {
        let q = queue ?? entries
        let baseCache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let cache: any LibraryMediaCache = gate.map { AutoContinueGatedMediaCache(base: baseCache, gate: $0) } ?? baseCache
        var changes: [LibraryChange] = [.source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))]
        for (offset, raw) in entries.enumerated() {
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
        for (position, raw) in q.enumerated() { changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(position)))) }
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
        for raw in entries { model.media[id(raw)] = .onPhone }
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
            "08:20 left",
            "the car row reads the time left")
        let phoneDate = carRows[0].row.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())
        XCTAssertEqual(
            LibraryRowView.detail(row: carRows[0].row, progress: macPosition, completed: false),
            "The Show - 10:00 - \(phoneDate)",
            "the phone row retains feed, total duration, and date")
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

    func testTheCapturedForwardSuffixDecidesWhatPlaysNextAndItStopsWhenNoneRemain() async throws {
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
        XCTAssertEqual(played, ["b", "d"], "the chain follows the forward suffix, minus the one started with")
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

    func testPlayingAnEpisodeToItsEndSendsTheMacOneMarkCompleted() async throws {
        let rig = try await makeRig(autoPlayNext: false)
        await start(rig, "a")
        rig.engine.finishNaturally()
        try await eventually("the intent") { rig.model.decisions.contains { $0.entryID == self.id("a") && $0.isSilent } }
        let sent = try await mac.listIntents()
        XCTAssertEqual(sent.map(\.action), [.markDone(entryID: id("a"))], "the Mac is told, not left to guess from a position")
        XCTAssertEqual(sent.first?.deviceID, "phone")
        XCTAssertNotNil(rig.model.queued.first { $0.id == id("a") }, "the row stays until the Mac takes it off the Larder")
        XCTAssertNil(rig.model.decisionStatus(for: id("a")), "and says nothing about a request the listener did not make")
        // Starting it again and letting it finish again does not stack a second request.
        await start(rig, "a")
        rig.engine.finishNaturally()
        await settle()
        let again = try await mac.listIntents()
        XCTAssertEqual(again.count, 1)
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id("a") })
        XCTAssertTrue(rig.model.decisionActions(for: row).contains(.markDone), "the row's own buttons stay while the Mac has not answered")
        await rig.model.decide(.markDone, entryID: id("a"))
        XCTAssertNotNil(rig.model.pendingDecision(for: id("a")), "the listener's own decision is not blocked by the silent one")
    }

    func testAPendingRemoveDoesNotDropTheCompletionWhenTheEpisodePlaysOut() async throws {
        let rig = try await makeRig(autoPlayNext: false)
        await start(rig, "a")
        await rig.model.decide(.removeFromLarder, entryID: id("a"))
        rig.engine.finishNaturally()
        try await eventually("the completion") { rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("a") } }
        let sent = try await mac.listIntents().map(\.action)
        XCTAssertTrue(sent.contains(.removeFromLarder(entryID: id("a"))))
        XCTAssertTrue(sent.contains(.markDone(entryID: id("a"))))
    }

    func testAnEpisodeTheMacAlreadyCompletedSendsNothingWhenItPlaysOut() async throws {
        let rig = try await makeRig(autoPlayNext: false)
        try await complete("a", at: 1_690_000_000)
        await rig.model.refresh()
        await start(rig, "a")
        rig.engine.finishNaturally()
        await settle()
        let sent = try await mac.listIntents()
        XCTAssertTrue(sent.isEmpty)
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

    func testMiddle19AdvancesThrough20And21AndStopsWithoutRestartingEarlierUnfinished() async throws {
        let rig = try await makeRig(entries: ["18", "19", "20", "21"])
        try await inProgressOnMac("18", position: 50)
        await rig.model.refresh()
        for raw in ["18", "19", "20", "21"] { rig.model.media[id(raw)] = .onPhone }
        let listed = rig.model.playOrderRows.map(\.id.rawValue)
        XCTAssertEqual(listed, ["18", "19", "20", "21"])

        await start(rig, "19")
        var played = ["19"]
        for _ in 0..<5 {
            let current = try XCTUnwrap(rig.player.item?.entryID)
            rig.engine.finishNaturally()
            await settle()
            guard let next = rig.player.item?.entryID, next != current else { break }
            played.append(next.rawValue)
        }
        XCTAssertEqual(played, ["19", "20", "21"], "walks 19 -> 20 -> 21 and stops at end without restarting 18")
        XCTAssertEqual(rig.player.status, .ended)
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
    }

    func testMissingLaterCacheSkipAdvancesPastMissingCandidate() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        try await rig.model.mediaCache.remove(entryID: id("20"))
        await start(rig, "19")
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "skips cache-missing 20 and advances to 21")
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.status, .ended)
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
    }

    func testCompletionRemovalAndReorderingDoesNotJumpBackwards() async throws {
        let rig = try await makeRig(entries: ["18", "19", "20", "21"])
        await start(rig, "19")
        try await complete("20", at: 1_695_000_000)
        try await inProgressOnMac("18", position: 200)
        await rig.model.refresh()
        for raw in ["18", "19", "20", "21"] { rig.model.media[id(raw)] = .onPhone }

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "completion of 20 and earlier progress does not jump back to 18")
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.status, .ended)
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
    }

    func testSupersedingManualCommandWinsOverAutoContinue() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        await start(rig, "19")
        rig.engine.finishNaturally()
        rig.player.pause()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("19"))
        XCTAssertEqual(rig.player.status, .paused)

        await start(rig, "19")
        rig.engine.finishNaturally()
        await start(rig, "21")
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
        XCTAssertEqual(rig.player.status, .playing)
    }

    /// A command given while the final position is being remembered (the cache and coordinator
    /// lookups inside it) must not lose the completion: it was accepted before the first await,
    /// so the Mac is still told the episode played out. Only the advance is cancelled.
    func testACommandDuringTheFinalPositionLookupStillSendsTheCompletionAndStartsNothing() async throws {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], gate: gate)
        await start(rig, "19")
        await gate.arm()
        rig.engine.finishNaturally()
        // Hold the lookups one at a time until the completion has been accepted; the held
        // lookup is then inside the final-position remember, before the completion is sent.
        while true {
            try await gate.waitForHold()
            if rig.model.playedOut[id("19")] != nil { break }
            await gate.releaseNext()
        }
        rig.player.pause()   // the intervening command, given while the lookup is held
        await gate.disarm()
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        let sent = try await mac.listIntents().map(\.action)
        XCTAssertTrue(sent.contains(.markDone(entryID: id("19"))), "the durable completion still reaches the Mac")
        XCTAssertEqual(rig.model.handoffState.ownPositions[id("19")]?.record.positionSeconds, 600,
                       "the end position is still recorded")
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("19"), "no unintended audio start")
        XCTAssertEqual(rig.player.status, .ended)
    }

    /// A file can disappear between the continuation's snapshot and the candidate's own start
    /// lookup. The walk has to try the next candidate instead of stopping: 20 vanishes between
    /// the two lookups, 21 plays.
    func testACandidateThatDisappearsBetweenTheLookupsIsSkippedForTheNextOne() async throws {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], autoPlayNext: false, gate: gate)
        await start(rig, "19")
        rig.engine.finishNaturally()
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        await rig.model.waitForHandoff()
        await settle()
        // Drive the continuation directly so its snapshot and the start's lookup are the only
        // lookups in flight; the gate holds the snapshot after it captured the entries.
        await gate.arm()
        let advance = Task { await rig.model.autoContinue(after: self.id("19")) }
        try await gate.waitForHold()
        try await rig.model.mediaCache.remove(entryID: id("20"))
        await gate.disarm()
        await advance.value
        XCTAssertEqual(rig.player.item?.entryID, id("21"),
                       "20 disappeared between the lookups; the walk reaches 21")
        XCTAssertTrue(rig.player.isPlaying)
    }

    func testRemovedCachedCandidateDuringStartLookupIsSkippedForTheNextOne() async throws {
        try await assertDecisionDuringCandidateLookupSkipsToNext(.removeFromLarder)
    }

    func testCompletedCachedCandidateDuringStartLookupIsSkippedForTheNextOne() async throws {
        try await assertDecisionDuringCandidateLookupSkipsToNext(.markDone)
    }

    private func assertDecisionDuringCandidateLookupSkipsToNext(_ action: LibraryDecisionAction) async throws {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], autoPlayNext: false, gate: gate)
        await start(rig, "19")
        rig.engine.finishNaturally()
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        await rig.model.waitForHandoff()
        await settle()

        await gate.arm()
        let advance = Task { await rig.model.autoContinue(after: self.id("19")) }
        try await gate.waitForHold() // initial candidate snapshot
        await gate.releaseNext()
        try await gate.waitForHold() // candidate 20's start lookup
        await rig.model.decide(action, entryID: id("20"))
        await gate.disarm()
        await advance.value

        let cached = await rig.model.mediaCache.cachedEntries()
        XCTAssertNotNil(cached[id("20")], "the decision does not remove the cached audio")
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "an ineligible cached candidate is skipped")
        XCTAssertTrue(rig.player.isPlaying)
    }

    /// An item the player already holds (a restored session) has no captured suffix. A manual
    /// resume of its row establishes the row's forward suffix, so the natural end advances within
    /// it instead of stopping, and never falls back to the global list order at completion.
    func testAManualResumeOfAnAlreadyLoadedRowAdoptsTheForwardSuffixForItsNaturalEnd() async throws {
        let rig = try await makeRig(entries: ["19", "20", "21"])
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id("20") })
        let cachedEntries = await rig.model.mediaCache.cachedEntries()
        let cached = try XCTUnwrap(cachedEntries[id("20")])
        let preloaded = LibraryPlayer.Item(
            entryID: row.id, title: row.title, showTitle: row.showTitle,
            fileURL: cached.url, artworkURL: row.artworkURL)
        XCTAssertTrue(rig.player.start(preloaded, autoplay: false))
        await settle()
        XCTAssertTrue(rig.model.handoffState.forwardSequenceIDs.isEmpty, "the preload captured no suffix")

        await start(rig, "20")   // a manual resume of the row that is already loaded
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.model.handoffState.forwardSequenceIDs, [id("20"), id("21")],
                       "the resume establishes the row's forward suffix")

        rig.engine.finishNaturally()
        try await eventually("21 after 20") { rig.player.item?.entryID == self.id("21") }
        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.status, .ended, "the suffix runs out and playback stops")
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "no wrap backwards to 19")
    }

    /// A continuation still in its candidate's start lookup is superseded by the listener's command:
    /// it never starts its candidate over a reselected episode, and never resumes a paused one.
    func testASupersededContinuationNeverStartsOverAReselectedItem() async throws {
        let rig = try await continuationHeldInItsStartLookup()
        let pick = Task { await self.start(rig, "21") }   // the listener reselects meanwhile
        try await eventually("the pick to own playback") { rig.model.playbackCommand?.entryID == self.id("21") }
        try await finishHeldContinuation(rig)
        await pick.value
        XCTAssertEqual(rig.player.item?.entryID, id("21"), "the superseded continuation never started 20")
        rig.player.pause()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("21"))
        XCTAssertEqual(rig.player.status, .paused, "nothing resumes the reselected episode after its pause")
    }

    func testASupersededContinuationNeverResumesAfterAPause() async throws {
        let rig = try await continuationHeldInItsStartLookup()
        rig.player.pause()   // the lock screen, while candidate 20's file is looked up
        try await finishHeldContinuation(rig)
        XCTAssertEqual(rig.player.item?.entryID, id("19"))
        XCTAssertEqual(rig.player.status, .ended, "the paused, finished episode stays where it was")
    }

    private var heldAdvance: Task<Void, Never>?
    private var heldGate: LookupGate?

    /// 19 played out; the continuation's start for 20 is pending inside its own cache lookup.
    private func continuationHeldInItsStartLookup() async throws -> Rig {
        let gate = LookupGate()
        let rig = try await makeRig(entries: ["19", "20", "21"], autoPlayNext: false, gate: gate)
        await start(rig, "19")
        rig.engine.finishNaturally()
        try await eventually("the completion") {
            rig.model.decisions.contains { $0.isSilent && $0.entryID == self.id("19") }
        }
        await rig.model.waitForHandoff()
        await settle()
        await gate.arm()
        heldAdvance = Task { await rig.model.autoContinue(after: self.id("19")) }
        heldGate = gate
        try await gate.waitForHold()   // the candidate snapshot
        await gate.releaseNext()
        try await eventually("20's start to be pending") { rig.model.playbackCommand?.entryID == self.id("20") }
        return rig
    }

    private func finishHeldContinuation(_ rig: Rig) async throws {
        await heldGate?.disarm()
        await heldAdvance?.value
        await settle()
    }
}
