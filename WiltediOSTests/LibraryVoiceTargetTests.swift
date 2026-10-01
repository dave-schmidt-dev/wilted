import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedListener
import XCTest
@testable import WiltediOS

// MARK: - Tests

/// `LibraryVoiceTarget` against a real `LibraryAppModel` and `LibraryPlayer`, on the same rig the
/// handoff and media tests use: an in-memory Mac and phone, a file media cache and a fake engine.
@MainActor
final class LibraryVoiceTargetTests: XCTestCase {
    private var scratch: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private lazy var phoneTransport = InMemoryLibraryTransport(deviceID: "phone", server: server)
    private let sleeper = VoiceSleeper()
    private let suite = "library-voice-target-tests"
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0
    private let payload = Data((0..<20_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        await server.setClock(Date(timeIntervalSince1970: 1_000))
    }

    override func tearDown() async throws {
        await sleeper.cancelAll()
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: fixtures

    private struct Rig {
        let target: LibraryVoiceTarget
        let model: LibraryAppModel
        let player: LibraryPlayer
        let engine: VoiceFakeEngine
        let cache: GatedMediaCache
        let cachedURLs: [ItemID: URL]
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    /// The Mac's queue: shows, episodes and their slot order.
    private func seed(shows: [ShowSpec], episodes: [EpisodeSpec]) async throws {
        var changes = shows.map { LibraryChange.source(LibrarySource(id: id($0.raw), kind: .podcastFeed, title: $0.title)) }
        for spec in episodes {
            changes.append(.entry(try LibraryEntry(
                id: id(spec.raw), kind: .podcastEpisode, sourceID: id(spec.show), title: spec.title, summary: "",
                publishedAt: Date(timeIntervalSince1970: spec.published), durationSeconds: 600)))
            changes.append(.slot(try QueueSlot(entryID: id(spec.raw), sortKey: spec.sortKey)))
        }
        try await macPush(changes)
    }

    /// The Mac's stored position for a paused episode: what marks a row as started.
    private func macPublishesProgress(_ raw: String, position: Double) async throws {
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id(raw), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: position, isPlaying: false, epoch: 1)
        try await mac.publish(record, as: .progress)
    }

    private func seedStartedEpisodeA() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        try await macPublishesProgress("a", position: 100)
    }

    /// A phone whose media cache already holds `raws`, verified against the Mac's offer for them.
    private func makeRig(cached raws: [String], sendsIntents: Bool = true) async throws -> Rig {
        let files = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let cache = GatedMediaCache(files)
        var cachedURLs: [ItemID: URL] = [:]
        for raw in raws {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            let offer = try LibraryMediaOffer(
                entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: hash(payload),
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600)
            cachedURLs[id(raw)] = try await files.adopt(verifiedFile: file, for: offer)
        }
        let engine = VoiceFakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: VoiceFakeSession(), nowPlaying: VoiceFakeNowPlaying(),
            remoteCommands: VoiceFakeRemote(), sessionEvents: VoiceFakeEvents(), tickInterval: .seconds(3600))
        let sleeper = sleeper
        let model = LibraryAppModel(
            transport: sendsIntents ? phoneTransport : SendFailingTransport(base: phoneTransport),
            deviceID: "phone", mediaCache: cache,
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { try await sleeper.sleep($0) }, settleSleep: { _ in }),
            decisionTiming: LibraryDecisionTiming(confirmationTimeout: 60, pollInterval: .seconds(3600), pendingPollInterval: .seconds(3600)),
            preferences: UserDefaults(suiteName: suite)!, now: { Date(timeIntervalSince1970: 1_000) },
            timeZone: TimeZone(identifier: "UTC")!)
        model.attachPlayer(player)
        await model.refresh()
        return Rig(
            target: LibraryVoiceTarget(model: model, player: player), model: model, player: player,
            engine: engine, cache: cache, cachedURLs: cachedURLs)
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: snapshot: downloaded

    func testDownloadedListsWithOnlyOnPhoneEpisodesInQueueOrder() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Zebra", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Apple", show: "show", sortKey: 1),
            EpisodeSpec(raw: "c", title: "Mango", show: "show", sortKey: 2),
        ])
        let rig = try await makeRig(cached: ["a", "c"])

        let snapshot = await rig.target.voiceSnapshot()
        XCTAssertEqual(snapshot.downloaded.map(\.id.rawValue), ["a", "c"], "only cached episodes, in the Mac's queue order")
        XCTAssertEqual(snapshot.downloaded.map(\.title), ["Zebra", "Mango"])
        XCTAssertEqual(snapshot.downloaded.map(\.showTitle), ["The Show", "The Show"])
    }

    func testDownloadedEpisodesCarryTheirPublishedDateForPlayLatest() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Old", show: "show", sortKey: 0, published: 1_600_000_000),
            EpisodeSpec(raw: "b", title: "New", show: "show", sortKey: 1, published: 1_700_000_000),
        ])
        let rig = try await makeRig(cached: ["a", "b"])

        let snapshot = await rig.target.voiceSnapshot()
        XCTAssertEqual(snapshot.downloaded.map(\.publishedAt.timeIntervalSince1970), [1_600_000_000, 1_700_000_000])
        let plan = VoiceCommandPlanner.plan(.playLatest(show: nil), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(id("b")), "newest published wins over Larder order")
    }

    func testDownloadedFollowsTheLarderSort() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Zebra", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Apple", show: "show", sortKey: 1),
            EpisodeSpec(raw: "c", title: "Mango", show: "show", sortKey: 2),
        ])
        let rig = try await makeRig(cached: ["a", "c"])

        let custom = await rig.target.voiceSnapshot()
        XCTAssertEqual(custom.downloaded.map(\.id.rawValue), ["a", "c"], "custom keeps the Mac's queue order")

        rig.model.sort = .title
        let byTitle = await rig.target.voiceSnapshot()
        XCTAssertEqual(byTitle.downloaded.map(\.id.rawValue), ["c", "a"], "title order: Mango before Zebra")
    }

    func testTheSnapshotIgnoresTheLardersFilterAndSearch() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Zebra", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Apple", show: "show", sortKey: 1),
        ])
        let rig = try await makeRig(cached: ["a"])
        let plain = await rig.target.voiceSnapshot()

        rig.model.filter = .available
        rig.model.searchText = "nothing matches this"
        XCTAssertTrue(rig.model.visibleRows.isEmpty, "the Larder itself is narrowed to nothing")

        let narrowed = await rig.target.voiceSnapshot()
        XCTAssertEqual(narrowed.downloaded, plain.downloaded, "a spoken command must not depend on the screen's narrowing")
        XCTAssertEqual(narrowed.downloaded.map(\.id.rawValue), ["a"])
    }

    // MARK: snapshot: shows

    func testKnownShowTitlesAreUniqueIgnoringCaseAndIncludeShowsWithNothingDownloaded() async throws {
        try await seed(shows: [
            ShowSpec(raw: "one", title: "Show One"),
            ShowSpec(raw: "two", title: "show one"),
            ShowSpec(raw: "solo", title: "Solo"),
        ], episodes: [
            EpisodeSpec(raw: "a", title: "A", show: "one", sortKey: 0),
            EpisodeSpec(raw: "b", title: "B", show: "two", sortKey: 1),
            EpisodeSpec(raw: "c", title: "C", show: "solo", sortKey: 2),
        ])
        let rig = try await makeRig(cached: ["a"])

        let snapshot = await rig.target.voiceSnapshot()
        XCTAssertEqual(snapshot.knownShowTitles, ["Show One", "Solo"], "the first spelling is kept; Solo has nothing on the phone")
    }

    // MARK: snapshot: now playing

    func testNowPlayingIsNilWhileThePlayerIsIdle() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])

        let snapshot = await rig.target.voiceSnapshot()
        XCTAssertNil(snapshot.nowPlaying)
        XCTAssertEqual(rig.player.status, .idle)
    }

    func testNowPlayingCarriesAStartedEpisodeAndItsMarkCompletedAvailability() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        try await macPublishesProgress("a", position: 100)
        let rig = try await makeRig(cached: ["a"])

        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()

        let snapshot = await rig.target.voiceSnapshot()
        let nowPlaying = try XCTUnwrap(snapshot.nowPlaying)
        XCTAssertEqual(nowPlaying.episode, VoiceEpisode(id: id("a"), title: "Episode A", showTitle: "The Show"))
        XCTAssertTrue(nowPlaying.isPlaying)
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id("a") })
        XCTAssertEqual(
            nowPlaying.canMarkCompleted, rig.model.decisionActions(for: row).contains(.markDone),
            "canMarkCompleted mirrors the Larder's own buttons for the row")
        XCTAssertTrue(nowPlaying.canMarkCompleted, "a started episode offers Mark completed")
    }

    func testNowPlayingReportsNoMarkCompletedForAnUnstartedEpisode() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])

        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()

        let snapshot = await rig.target.voiceSnapshot()
        let nowPlaying = try XCTUnwrap(snapshot.nowPlaying)
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id("a") })
        XCTAssertEqual(
            nowPlaying.canMarkCompleted, rig.model.decisionActions(for: row).contains(.markDone),
            "canMarkCompleted mirrors the Larder's own buttons for the row")
        XCTAssertFalse(nowPlaying.canMarkCompleted, "an unstarted episode offers no Mark completed")
    }

    // MARK: perform: transport

    func testPlayStartsTheCachedFileInThePlayer() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        XCTAssertEqual(rig.player.status, .idle)

        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
        let file = try XCTUnwrap(rig.cachedURLs[id("a")])
        XCTAssertEqual(rig.player.item?.fileURL, file)
        XCTAssertEqual(rig.engine.loadedURLs, [file])
    }

    func testPauseAndResumeChangeThePlayer() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()

        await rig.target.perform(.pause)
        await rig.model.waitForHandoff()
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.engine.isPlaying)
        let paused = await rig.target.voiceSnapshot()
        XCTAssertEqual(paused.nowPlaying?.isPlaying, false)

        await rig.target.perform(.resume)
        await rig.model.waitForHandoff()
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testSkipForwardAndSkipBackMoveByThePlayersSkipLengths() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()
        XCTAssertEqual(rig.player.position, 0)

        await rig.target.perform(.skipForward)
        XCTAssertEqual(rig.player.position, LibraryPlayer.skipForwardSeconds)
        XCTAssertEqual(rig.engine.currentTime, LibraryPlayer.skipForwardSeconds)

        await rig.target.perform(.skipBack)
        XCTAssertEqual(rig.player.position, LibraryPlayer.skipForwardSeconds - LibraryPlayer.skipBackSeconds)
        XCTAssertEqual(rig.engine.currentTime, LibraryPlayer.skipForwardSeconds - LibraryPlayer.skipBackSeconds)
    }

    func testRestartFromPausedSeeksToZeroAndPlays() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()
        await rig.target.perform(.pause)
        await rig.model.waitForHandoff()

        rig.player.seek(to: 100)
        XCTAssertEqual(rig.player.position, 100)

        await rig.target.perform(.restart)
        XCTAssertEqual(rig.player.position, 0)
        XCTAssertEqual(rig.engine.currentTime, 0)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testRestartFromEndedSeeksToZeroAndPlays() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()

        rig.engine.finishNaturally()
        try await eventually("the engine's completion") { rig.player.status == .ended }
        await rig.model.waitForHandoff()
        XCTAssertEqual(rig.player.position, rig.engine.duration)

        await rig.target.perform(.restart)
        XCTAssertEqual(rig.player.position, 0)
        XCTAssertEqual(rig.engine.currentTime, 0)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
    }

    // MARK: perform: decisions

    func testMarkCompletedForAStartedEpisodeSendsAMarkDoneIntent() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Episode B", show: "show", sortKey: 1),
        ])
        try await macPublishesProgress("a", position: 100)
        let rig = try await makeRig(cached: ["a", "b"])

        await rig.target.perform(.markCompleted(id("a")))

        let intents = try await mac.listIntents()
        XCTAssertTrue(
            intents.contains { $0.action == .markDone(entryID: id("a")) && $0.deviceID == "phone" },
            "the decision travels as a markDone intent from this phone")
    }

    func testMarkCompletedForAnUnstartedEpisodeSendsNothing() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Episode B", show: "show", sortKey: 1),
        ])
        try await macPublishesProgress("a", position: 100)
        let rig = try await makeRig(cached: ["a", "b"])

        await rig.target.perform(.markCompleted(id("b")))

        let intents = try await mac.listIntents()
        XCTAssertFalse(intents.contains { if case .markDone = $0.action { true } else { false } })
        XCTAssertTrue(rig.model.decisions.isEmpty, "a row that offers no Mark completed starts no decision")
    }

    func testMarkCompletedSaysDoneOnlyOnceTheMacHasBeenSentTheIntent() async throws {
        try await seedStartedEpisodeA()
        let rig = try await makeRig(cached: ["a"])

        let outcome = await rig.target.perform(.markCompleted(id("a")))
        XCTAssertEqual(outcome, .done)
        let again = await rig.target.perform(.markCompleted(id("a")))
        XCTAssertEqual(again, .done, "a second ask while the first is in flight reports it, and sends nothing new")
        let sent = try await mac.listIntents().filter { $0.action == .markDone(entryID: id("a")) }
        XCTAssertEqual(sent.count, 1)
    }

    func testMarkCompletedIsQueuedNotDoneWhenTheSendFails() async throws {
        try await seedStartedEpisodeA()
        let rig = try await makeRig(cached: ["a"], sendsIntents: false)

        let outcome = await rig.target.perform(.markCompleted(id("a")))
        XCTAssertEqual(outcome, .queued, "the decision exists and will be retried, but the Mac has not been told")
    }

    func testMarkCompletedFailsWhenAnotherActionOwnsTheRow() async throws {
        try await seedStartedEpisodeA()
        let rig = try await makeRig(cached: ["a"])
        await rig.model.decide(.removeFromLarder, entryID: id("a"))
        XCTAssertNotNil(rig.model.pendingDecision(for: id("a")))

        let outcome = await rig.target.perform(.markCompleted(id("a")))
        XCTAssertEqual(outcome, .failed, "a pending remove is not a completed mark")
    }

    func testPlayDoesNotUndoAStartThatHappensWhileTheCacheIsBeingRead() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id("a") })

        await rig.cache.arm()
        let spoken = Task { @MainActor in await rig.target.perform(.play(self.id("a"))) }
        try await eventually("Siri to be inside the cache read") { await rig.cache.isHeld }
        XCTAssertNil(rig.player.item, "nothing is loaded yet when Siri looked")

        await rig.model.playCached(row)   // CarPlay (or the phone) starts the same episode meanwhile
        XCTAssertTrue(rig.player.isPlaying)
        await rig.cache.release()

        let outcome = await spoken.value
        XCTAssertEqual(outcome, .done)
        XCTAssertTrue(rig.player.isPlaying, "the spoken play resumed the loaded episode instead of toggling it off")
    }

    func testPlayingTheLoadedEpisodeNeverPausesIt() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])

        let first = await rig.target.perform(.play(id("a")))
        let again = await rig.target.perform(.play(id("a")))
        XCTAssertEqual([first, again], [.done, .done])
        XCTAssertTrue(rig.player.isPlaying, "a second spoken play must not toggle it to paused")

        await rig.target.perform(.pause)
        let resumed = await rig.target.perform(.play(id("a")))
        XCTAssertEqual(resumed, .done)
        XCTAssertTrue(rig.player.isPlaying, "play on the paused loaded episode resumes it")
    }

    func testPerformReportsFailureForAnEpisodeThatIsNotQueuedOrNotStarted() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])

        let played = await rig.target.perform(.play(id("missing")))
        XCTAssertEqual(played, .failed)
        let marked = await rig.target.perform(.markCompleted(id("a")))
        XCTAssertEqual(marked, .failed, "an unstarted row offers no Mark completed, so nothing was accepted")
    }

    // MARK: perform: none
    func testPerformNoneChangesNothing() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        await rig.target.perform(.play(id("a")))
        await rig.model.waitForHandoff()

        let before = await rig.target.voiceSnapshot()
        let intentsBefore = try await mac.listIntents()
        let statusBefore = rig.player.status
        let rowsBefore = rig.model.queued

        await rig.target.perform(.none)

        let after = await rig.target.voiceSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(rig.player.status, statusBefore)
        XCTAssertEqual(rig.model.queued, rowsBefore)
        let intentsAfter = try await mac.listIntents()
        XCTAssertEqual(intentsAfter, intentsBefore)
    }
}
