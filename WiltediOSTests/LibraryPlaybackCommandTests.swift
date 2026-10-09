import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// An engine that counts loads and can refuse to play, like a route the system will not open.
private final class CommandEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration = 600.0
    var currentTime = 0.0
    var isPlaying = false
    var refusesPlay = false
    private(set) var loads = 0
    func load(url: URL) throws { loads += 1 }
    func load(url: URL, completionGeneration: UInt64) throws { loads += 1 }
    func play() -> Bool {
        guard !refusesPlay else { return false }
        isPlaying = true
        return true
    }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

/// The phone's start ownership (Task 3.2): pending, duplicate and supersession rules applied before
/// the cache lookup, and an explicit outcome for every start. Each test names its
/// scenario ID from the retired Batch 1 prototype.
@MainActor
final class LibraryPlaybackCommandTests: XCTestCase {
    private struct Rig {
        let model: LibraryAppModel
        let player: LibraryPlayer
        let engine: CommandEngine
        let cache: GatedMediaCache
        let mac: InMemoryLibraryTransport
        let slotVersions: [ItemID: UInt64]

        @MainActor func row(_ raw: String) throws -> LibraryRow {
            let row = model.queued.first { $0.id.rawValue == raw }
            return try XCTUnwrap(row)
        }
    }

    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("playback-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    /// Episodes "a" and "b" queued and both on the phone; the cache can hold its next lookup.
    private func makeRig() async throws -> Rig {
        let suite = "wilted.command.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let show = LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")
        var changes: [LibraryChange] = [.source(show)]
        let files = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let payload = Data((0..<2_000).map { UInt8($0 % 251) })
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        for (offset, raw) in ["a", "b"].enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(raw), kind: .podcastEpisode, sourceID: show.id, title: "Episode \(raw.uppercased())", summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(offset) * 86_400), durationSeconds: 600)))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(offset))))

        }
        let pushed = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror-" + UUID().uuidString + ".json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: phone)
        for raw in ["a", "b"] {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            _ = try await PreparedMediaFixture.adopt(into: files, verifiedFile: file, for: try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: try RevisionID(rawValue: "rev-1"), contentHash: hash,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600)), owner: "fixture-owner")
        }
        let cache = GatedMediaCache(files)
        let engine = CommandEngine()
        let player = LibraryPlayer(
            engine: engine, session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let model = LibraryAppModel(
            transport: phone, store: mirror, deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                settleSleep: { _ in }),
            preferences: defaults, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        model.attachPlayer(player)
        await model.refresh()
        let slotVersions = Dictionary(uniqueKeysWithValues: pushed.acknowledged.filter { $0.key.kind == .slot }.map { ($0.key.id, $0.version) })
        return Rig(model: model, player: player, engine: engine, cache: cache, mac: mac, slotVersions: slotVersions)
    }

    private func eventually(_ what: String, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets queued main-actor work (handoff syncs, position saves) finish, so the next armed
    /// lookup is the start's own.
    private func settle(_ rig: Rig) async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
        await rig.model.waitForHandoff()
    }

    func testSameSizeCorruptionDuringLookupFailsBeforeLoad() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let entries = await rig.cache.cachedEntries()
        let file = try XCTUnwrap(entries[row.id]?.url)
        let start = try await heldStart(rig) { await rig.model.startCached(row, kind: .select) }
        try Data(repeating: 42, count: 2_000).write(to: file)
        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .failed(.missingMedia))
        XCTAssertEqual(rig.engine.loads, 0)
        XCTAssertFalse(rig.engine.isPlaying)
    }

    func testDeletedURLCapturedDuringManualStartFailsBeforeEngineEffect() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let cached = await rig.cache.cachedEntries()
        let file = try XCTUnwrap(cached[row.id]?.url)
        let start = try await heldStart(rig) { await rig.model.startCached(row, kind: .select) }
        try await rig.cache.remove(entryID: row.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .failed(.missingMedia))
        XCTAssertEqual(rig.model.playbackCommand, .failed(entryID: row.id, title: row.title, failure: .missingMedia))
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.engine.loads, 0)
        XCTAssertFalse(rig.engine.isPlaying)
    }

    func testUnreadableCapturedMediaURLFailsBeforeEngineEffect() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let cached = await rig.cache.cachedEntries()
        let file = try XCTUnwrap(cached[row.id]?.url)
        let start = try await heldStart(rig) { await rig.model.startCached(row, kind: .select) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: file.path), "the fixture is actually unreadable")
        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .failed(.missingMedia))
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.engine.loads, 0)
        XCTAssertFalse(rig.engine.isPlaying)
    }

    func testDirectoryAtCapturedMediaURLFailsBeforeEngineEffect() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let cached = await rig.cache.cachedEntries()
        let file = try XCTUnwrap(cached[row.id]?.url)
        let start = try await heldStart(rig) { await rig.model.startCached(row, kind: .select) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .failed(.missingMedia))
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.engine.loads, 0)
        XCTAssertFalse(rig.engine.isPlaying)
    }

    /// Starts `row` with its cache lookup held, and returns once the start is pending.
    private func heldStart(
        _ rig: Rig, _ start: @escaping @MainActor () async -> LibraryStartOutcome
    ) async throws -> Task<LibraryStartOutcome, Never> {
        await rig.cache.arm()
        let task = Task { @MainActor in await start() }
        try await eventually("the start to be inside its cache lookup") { await rig.cache.isHeld }
        return task
    }

    // MARK: Pending (PLAY-DELAY)

    func testAStartIsPendingBeforeItsCacheLookupReturnsAndClearsWhenItPlays() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let start = try await heldStart(rig) { await rig.model.playCached(row) }
        XCTAssertEqual(rig.model.playbackCommand, .starting(entryID: id("a"), title: "Episode A"))
        XCTAssertEqual(rig.model.playbackCommand?.text, "Starting playback…")
        XCTAssertNil(rig.player.item, "nothing reaches the player while the file is looked up")

        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .started)
        XCTAssertNil(rig.model.playbackCommand)
        XCTAssertTrue(rig.player.isPlaying)
    }

    // MARK: Duplicate and supersession (RACE phone/carplay)

    func testASecondPressWhileStartingJoinsTheOneAttemptInsteadOfTogglingItOff() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let first = try await heldStart(rig) { await rig.model.playCached(row) }
        let second = Task { @MainActor in await rig.model.playCached(row) }
        try await Task.sleep(for: .milliseconds(50))
        await rig.cache.release()

        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes, [.started, .started], "both presses report the one start")
        XCTAssertEqual(rig.engine.loads, 1, "a duplicate press makes no second attempt")
        XCTAssertTrue(rig.player.isPlaying, "the second press did not toggle the new start off")
    }

    func testANewerSelectionSupersedesThePendingStart() async throws {
        let rig = try await makeRig()
        let (a, b) = (try rig.row("a"), try rig.row("b"))
        let older = try await heldStart(rig) { await rig.model.playCached(a) }

        let newer = await rig.model.playCached(b)
        XCTAssertEqual(newer, .started)
        await rig.cache.release()

        let outcome = await older.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(rig.player.item?.entryID, id("b"), "the superseded start never replaced the newer one")
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.engine.loads, 1)
    }

    func testASystemPauseCancelsThePendingStart() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let start = try await heldStart(rig) { await rig.model.playCachedWithoutToggling(row) }
        rig.player.pause()   // the lock screen or a headset, while the file is looked up
        XCTAssertNil(rig.model.playbackCommand, "the pause ends the pending state at once")
        await rig.cache.release()

        let outcome = await start.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertNil(rig.player.item)
        XCTAssertFalse(rig.player.isPlaying)
    }

    func testASeekOnTheLoadedEpisodeSupersedesAPendingStartAndKeepsItPaused() async throws {
        let rig = try await makeRig()
        let (a, b) = (try rig.row("a"), try rig.row("b"))
        await rig.model.playCached(b)
        rig.player.pause()
        await settle(rig)

        let start = try await heldStart(rig) { await rig.model.playCachedWithoutToggling(a) }
        rig.player.seek(to: 120)
        await rig.cache.release()

        let outcome = await start.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertEqual(rig.player.position, 120)
    }

    func testAnAutomaticStartNeverSupersedesThePendingManualOne() async throws {
        let rig = try await makeRig()
        let (a, b) = (try rig.row("a"), try rig.row("b"))
        let manual = try await heldStart(rig) { await rig.model.playCached(a) }

        let automatic = await rig.model.startCached(b, kind: .automatic)
        XCTAssertEqual(automatic, .superseded, "auto-continue yields to the listener's pending command")
        await rig.cache.release()

        let outcome = await manual.value
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
    }

    func testQueueRemovalDuringLookupDeclinesANewLoad() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let before = await rig.cache.cachedEntries()
        let originalFile = try XCTUnwrap(before[id("a")]?.url)
        let originalBytes = try Data(contentsOf: originalFile)
        let start = try await heldStart(rig) { await rig.model.playCachedWithoutToggling(row) }
        try await removeSlot("a", in: rig)
        let cached = await rig.cache.cachedEntries()
        XCTAssertNil(cached[id("a")], "queue removal revokes admitted inventory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
        XCTAssertEqual(try Data(contentsOf: originalFile), originalBytes, "retained bytes do not grant playback permission")
        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .declined)
        XCTAssertNil(rig.player.item)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.loads, 0)
        XCTAssertNil(rig.model.playbackCommand)
    }

    func testQueueRemovalDuringLookupDeclinesLoadedPausedResume() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        await rig.model.playCachedWithoutToggling(row)
        rig.player.pause()
        await settle(rig)
        let suffix = rig.model.handoffState.forwardSequenceIDs
        let originalFile = try XCTUnwrap(rig.player.item?.fileURL)
        let originalBytes = try Data(contentsOf: originalFile)
        let start = try await heldStart(rig) { await rig.model.playCachedWithoutToggling(row) }
        try await removeSlot("a", in: rig)
        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .superseded, "confirmed removal invalidated the pending loaded resume")
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.player.status, .idle)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.loads, 1)
        XCTAssertEqual(rig.model.handoffState.forwardSequenceIDs, suffix)
        let cached = await rig.cache.cachedEntries()
        XCTAssertNil(cached[id("a")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
        XCTAssertEqual(try Data(contentsOf: originalFile), originalBytes)
    }

    func testEligibleLoadedPausedResumeAfterHeldLookupKeepsManualSuffix() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        await rig.model.playCachedWithoutToggling(row)
        rig.player.pause()
        await settle(rig)
        let suffix = rig.model.handoffState.forwardSequenceIDs
        let start = try await heldStart(rig) { await rig.model.playCachedWithoutToggling(row) }
        await rig.cache.release()
        let outcome = await start.value
        XCTAssertEqual(outcome, .resumed)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.loads, 1)
        XCTAssertEqual(rig.model.handoffState.forwardSequenceIDs, suffix)
    }

    private func removeSlot(_ raw: String, in rig: Rig) async throws {
        let entryID = id(raw)
        let version = try XCTUnwrap(rig.slotVersions[entryID])
        let result = try await rig.mac.push(changes: [PendingLibraryChange(
            localSeq: 100, change: .slotRemoved(entryID: entryID), baseVersion: version)])
        XCTAssertTrue(result.failures.isEmpty)
        await rig.model.refresh()
        XCTAssertFalse(rig.model.queued.contains { $0.id == entryID })
        XCTAssertEqual(rig.model.media[entryID], .notPrepared)
        let inventory = await rig.cache.cachedEntries()
        XCTAssertNil(inventory[entryID], "removed media cannot retain admitted inventory")
    }

    // MARK: Primary toggle stays separate

    func testThePrimaryToggleStillPausesAndAnExplicitPlayNeverDoes() async throws {
        let rig = try await makeRig()
        let row = try rig.row("a")
        let started = await rig.model.playCached(row)
        let again = await rig.model.playCachedWithoutToggling(row)
        let paused = await rig.model.playCached(row)
        XCTAssertEqual(rig.player.status, .paused)
        let resumed = await rig.model.playCached(row)
        XCTAssertEqual([started, again, paused, resumed], [.started, .alreadyPlaying, .paused, .resumed])
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.engine.loads, 1)
    }

    // MARK: Failures (PLAY-FAIL, PLAY-MISSING, FAIL phone)

    func testARefusedEngineReportsTheFailureAndRetryPlaysOnceItIsAccepted() async throws {
        let rig = try await makeRig()
        rig.engine.refusesPlay = true
        let outcome = await rig.model.playCached(try rig.row("a"))
        XCTAssertEqual(outcome, .failed(.engineRefused))
        XCTAssertEqual(rig.model.playbackCommand, .failed(entryID: id("a"), title: "Episode A", failure: .engineRefused))
        XCTAssertEqual(rig.model.playbackCommand?.text, "Playback refused. Your position is kept.")
        XCTAssertEqual(rig.player.status, .failed("The audio engine refused to play"))

        let refusedAgain = await rig.model.retryFailedStart()
        XCTAssertEqual(refusedAgain, .failed(.engineRefused))
        XCTAssertEqual(rig.model.playbackCommand?.isFailure, true, "the failure stays until something plays")

        rig.engine.refusesPlay = false
        let retried = await rig.model.retryFailedStart()
        XCTAssertEqual(retried, .resumed)
        XCTAssertNil(rig.model.playbackCommand)
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.engine.loads, 1, "Retry plays the loaded file; it is not loaded again")
    }

    func testMissingAudioFailsWithItsOwnMessageAndLeavesThePlayerAlone() async throws {
        let rig = try await makeRig()
        try await rig.cache.remove(entryID: id("a"))
        let outcome = await rig.model.playCached(try rig.row("a"))
        XCTAssertEqual(outcome, .failed(.missingMedia))
        XCTAssertEqual(rig.model.playbackCommand?.text, "Audio missing. Download it before playing.")
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.engine.loads, 0)
    }
}
