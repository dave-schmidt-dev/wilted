import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

private final class ReplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_700_000_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// An episode the listener finished on the phone (Mark completed, Remove from Larder, or played to its
/// end) never starts again by itself: not when another episode ends, and not from the car's play button.
/// The Mac's answer and the phone's copy of the library can both lag, and the app can be relaunched in
/// between; none of that may bring the episode back (2026-11-18: one marked completed while driving
/// started again after a stop).
@MainActor
final class LibraryCompletedNeverReplaysTests: XCTestCase {
    private var scratch: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let revision = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })
    private let clock = ReplayClock()
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0
    private var cache: FileMediaCache!
    private var mirrorURL: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-no-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        mirrorURL = scratch.appendingPathComponent("mirror.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

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

    private func entry(_ raw: String, removal: LibraryRemoval = .none) throws -> LibraryEntry {
        try LibraryEntry(
            id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Title \(raw)", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 600, removal: removal,
            removedAt: removal == .none ? nil : clock.now)
    }

    /// The Larder holds a, b, c in that order, all downloaded.
    private func seed() async throws {
        var changes: [LibraryChange] = [.source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))]
        for (offset, raw) in ["a", "b", "c"].enumerated() {
            changes.append(.entry(try entry(raw)))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(offset))))
        }
        try await macPush(changes)
        let bootstrap = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        try await PreparedMediaFixture.bootstrap(FileLibraryStore(url: mirrorURL), transport: bootstrap)
        for raw in ["a", "b", "c"] {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            let digest = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: revision, contentHash: digest,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
            try await mac.publishMedia(offer: offer, fileURL: file)
            _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: offer, owner: "fixture-owner")
        }
    }

    /// One run of the app: a new model and player over the same saved library, audio and local files.
    private func launch(listOrder: LibraryListOrder = .mac) async -> Rig {
        let clock = clock
        let engine = AutoEngine()
        let player = LibraryPlayer(
            engine: engine, session: AutoSession(), nowPlaying: AutoNowPlaying(),
            remoteCommands: AutoRemote(), sessionEvents: AutoEvents(), tickInterval: .seconds(3600))
        player.apply(LibraryPlaybackPreferences(
            defaultSpeed: 1.0, skipBackSeconds: 15, skipForwardSeconds: 30, autoPlayNext: true))
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            store: FileLibraryStore(url: mirrorURL), deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval,
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                settleSleep: { _ in }),
            ownPositionsURL: scratch.appendingPathComponent("own-positions.json"),
            outboxURL: scratch.appendingPathComponent("pending-intents.json"),
            finishedHereURL: scratch.appendingPathComponent("finished-here.json"),
            now: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        model.listOrder = listOrder
        model.attachPlayer(player)
        return Rig(model: model, player: player, engine: engine)
    }

    private func start(_ rig: Rig, _ raw: String) async throws {
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id(raw) })
        await rig.model.playCached(row)
        XCTAssertEqual(rig.player.item?.entryID, id(raw))
    }

    private func macAnswersApplied(to raw: String) async throws {
        let sent = try await mac.listIntents()
        let intent = try XCTUnwrap(sent.first { $0.action.entryID == id(raw) })
        try await mac.publishIntentOutcome(try IntentOutcome.applied(for: intent, at: clock.now))
    }

    /// The Mac takes `raw` off the Larder, as it does when it applies a completion.
    private func macRetires(_ raw: String) async throws {
        try await macPush([.entry(try entry(raw, removal: .retired)), .slotRemoved(entryID: id(raw))])
    }

    /// The hazard itself: `raw` is listed, downloaded and not completed, so only the phone's own
    /// memory of the finish keeps it from starting.
    private func assertStillListedAndDownloaded(_ rig: Rig, _ raw: String, line: UInt = #line) {
        XCTAssertNotNil(rig.model.queued.first { $0.id == id(raw) }, "listed", line: line)
        XCTAssertEqual(rig.model.mediaState(for: id(raw)), .onPhone, "downloaded", line: line)
        XCTAssertTrue(rig.model.playOrderRows.contains { $0.id == id(raw) }, "in the play order", line: line)
        XCTAssertNil(rig.model.finished[id(raw)], "not listed as completed", line: line)
    }

    /// Sync rounds as the tick runs them: the first reverts or forgets the decision, and a later one
    /// reads the audio already on the phone for the row that is listed again. Stops once `a` is
    /// downloaded again, or after a few rounds for a test in which it never is.
    private func syncRounds(_ rig: Rig) async {
        await rig.model.refresh()
        for _ in 0..<5 {
            await rig.model.refresh()
            if rig.model.mediaState(for: id("a")) == .onPhone { return }
        }
    }

    /// `c` plays to its end; returns what plays next.
    private func whatFollowsC(_ rig: Rig) async throws -> String? {
        try await start(rig, "c")
        rig.engine.finishNaturally()
        await settleOnClock()
        let loaded = rig.player.item?.entryID
        return loaded == id("c") ? nil : loaded?.rawValue
    }

    // MARK: - The Mac has not answered

    func testAnEpisodeMarkedCompletedIsNotContinuedIntoWhileTheMacHasNotAnswered() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        try await start(rig, "a")
        await rig.model.decide(.markDone, entryID: id("a"))
        XCTAssertNil(rig.player.item, "marking it completed stops it")

        clock.advance(600) // well past the wait for the Mac's answer
        await syncRounds(rig)
        XCTAssertEqual(rig.model.decisionStatus(for: id("a")), .pendingOnMac)
        assertStillListedAndDownloaded(rig, "a")

        let next = try await whatFollowsC(rig)
        XCTAssertEqual(next, "b", "the completed episode is first in the Mac's order, and is still not started")
    }

    func testTheCarsPlayButtonNeverResumesAnEpisodeMarkedCompletedWhileTheMacHasNotAnswered() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        try await start(rig, "a")
        await rig.model.decide(.markDone, entryID: id("a"))
        clock.advance(600)
        await syncRounds(rig)
        assertStillListedAndDownloaded(rig, "a")

        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("b"))
    }

    func testSiriPlaySomethingNeverPicksAnEpisodeMarkedCompletedWhileTheMacHasNotAnswered() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        try await start(rig, "a")
        await rig.model.decide(.markDone, entryID: id("a"))
        clock.advance(600)
        await syncRounds(rig)
        assertStillListedAndDownloaded(rig, "a")

        // An unnamed "play something" starts the first downloaded episode of the snapshot.
        let siri = await LibraryVoiceTarget(model: rig.model, player: rig.player).voiceSnapshot()
        XCTAssertEqual(siri.downloaded.map(\.id.rawValue), ["b", "c", "a"], "still there to ask for by name, and last")
    }

    func testSiriPlaySomethingInPlayOrderNeverPicksAnEpisodeMarkedCompletedWhileTheMacHasNotAnswered() async throws {
        try await seed()
        let rig = await launch(listOrder: .playOrder)
        await rig.model.refresh()
        try await start(rig, "a")
        await rig.model.decide(.markDone, entryID: id("a"))
        clock.advance(600)
        await syncRounds(rig)
        assertStillListedAndDownloaded(rig, "a")

        let siri = await LibraryVoiceTarget(model: rig.model, player: rig.player).voiceSnapshot()
        XCTAssertEqual(siri.downloaded.count, 3)
        XCTAssertEqual(siri.downloaded.last?.id, id("a"))
        XCTAssertEqual(rig.model.remoteResumeRow.map { $0.id == id("a") }, false, "nor does the car's play button")
    }

    func testAnEpisodeRemovedFromTheLarderIsNotContinuedIntoWhileTheMacHasNotAnswered() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        await rig.model.decide(.removeFromLarder, entryID: id("a"))
        clock.advance(600)
        await syncRounds(rig)
        assertStillListedAndDownloaded(rig, "a")

        let next = try await whatFollowsC(rig)
        XCTAssertEqual(next, "b")
        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("b"))
    }

    // MARK: - The Mac answered, the phone's copy of the library is behind

    func testAnEpisodeTheMacCompletedIsNotContinuedIntoWhileThePhonesLibraryIsBehind() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        try await start(rig, "a")
        await rig.model.decide(.markDone, entryID: id("a"))
        try await macAnswersApplied(to: "a") // the answer arrives; the library that shows it does not
        await rig.model.refresh()
        XCTAssertEqual(rig.model.decisionStatus(for: id("a")), .confirming)

        clock.advance(600)
        await syncRounds(rig)
        XCTAssertNil(rig.model.decisionStatus(for: id("a")), "the phone stops tracking an applied decision")
        assertStillListedAndDownloaded(rig, "a")

        let next = try await whatFollowsC(rig)
        XCTAssertEqual(next, "b")
        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("b"))
    }

    // MARK: - A relaunch

    func testAnEpisodeMarkedCompletedStaysOutAfterARelaunchBeforeTheLibraryCatchesUp() async throws {
        try await seed()
        let first = await launch()
        await first.model.refresh()
        try await start(first, "a")
        await first.model.decide(.markDone, entryID: id("a"))
        try await macAnswersApplied(to: "a")

        // A new process: the sent decision is not in the outbox, and the saved library still lists `a`.
        let second = await launch()
        await second.model.loadLocalState()
        XCTAssertTrue(second.model.decisions.isEmpty)
        assertStillListedAndDownloaded(second, "a")
        XCTAssertEqual(second.model.remoteResumeRow?.id, id("b"), "the car's play button, before the first sync")

        let next = try await whatFollowsC(second)
        XCTAssertEqual(next, "b")
    }

    func testAnEpisodeThatPlayedOutStaysOutAfterARelaunchWhenItsFileIsShorterThanTheFeedSays() async throws {
        try await seed()
        let first = await launch()
        await first.model.refresh()
        first.engine.duration = 540 // the feed says 600
        try await start(first, "a")
        first.engine.finishNaturally()
        await settleOnClock()
        await first.model.waitForHandoff()

        let second = await launch()
        await second.model.loadLocalState()
        XCTAssertNotNil(second.model.queued.first { $0.id == id("a") })
        XCTAssertEqual(second.model.mediaState(for: id("a")), .onPhone)
        XCTAssertNil(second.model.finished[id("a")], "540 of the feed's 600 seconds does not read as finished")
        XCTAssertEqual(second.model.remoteResumeRow?.id, id("b"))
    }

    // MARK: - An episode that ended and stayed loaded

    /// `a` plays to its end with "play the next one" off, so it stays loaded, ended. Returns the runtime
    /// that routes the car's commands.
    private func endedAndStillLoaded(_ rig: Rig, pausedAtTheEnd: Bool = false) async throws -> LibraryRuntime {
        let suite = "library-no-replay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = LibrarySettingsStore(defaults: defaults)
        settings.autoPlayNext = false
        let runtime = LibraryRuntime(model: rig.model, player: rig.player, settings: settings)
        await runtime.prepare()
        await rig.model.refresh()
        try await start(rig, "a")
        if pausedAtTheEnd {
            // A pause that lands after the audio ended and before the model takes the finish up.
            let takeUp = rig.player.onFinished
            rig.player.onFinished = { [player = rig.player] ended, autoPlayNext in
                player.pause()
                takeUp?(ended, autoPlayNext)
            }
        }
        rig.engine.finishNaturally()
        await settleOnClock()
        XCTAssertEqual(rig.player.item?.entryID, id("a"), "it stays loaded")
        XCTAssertEqual(rig.player.status, .ended)
        return runtime
    }

    private func settled(_ rig: Rig, on raw: String) async {
        for _ in 0..<400 where rig.player.item?.entryID != id(raw) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testTheCarsPlayButtonAfterAnEpisodeEndedStartsTheNextOneNotTheSameOneAgain() async throws {
        try await seed()
        let rig = await launch()
        let runtime = try await endedAndStillLoaded(rig)

        XCTAssertTrue(rig.player.handleRemote(.play))
        await settled(rig, on: "b")
        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        XCTAssertTrue(rig.player.isPlaying)
        withExtendedLifetime(runtime) {}
    }

    func testTheCarsPlayButtonSkipsAnEndedEpisodeWhoseFinishAPauseKeptFromBeingRecorded() async throws {
        try await seed()
        let rig = await launch()
        rig.engine.duration = 540 // shorter than the feed's 600, so its position does not read as finished
        let runtime = try await endedAndStillLoaded(rig, pausedAtTheEnd: true)
        XCTAssertFalse(rig.model.isFinishedHere(id("a")), "the pause right at the end withdrew the finish")
        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("a"), "so the library would pick the same episode")

        XCTAssertTrue(rig.player.handleRemote(.play))
        await settled(rig, on: "b")
        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        withExtendedLifetime(runtime) {}
    }

    func testTheCarsPlayPauseButtonAfterAnEpisodeEndedStartsTheNextOneToo() async throws {
        try await seed()
        let rig = await launch()
        let runtime = try await endedAndStillLoaded(rig)

        XCTAssertTrue(rig.player.handleRemote(.togglePlayPause))
        await settled(rig, on: "b")
        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        withExtendedLifetime(runtime) {}
    }

    func testTheCarsPlayButtonDoesNothingWhenTheEndedEpisodeIsTheOnlyOneLeft() async throws {
        try await seed()
        let rig = await launch()
        let runtime = try await endedAndStillLoaded(rig)
        await rig.model.decide(.markDone, entryID: id("b"))
        await rig.model.decide(.markDone, entryID: id("c"))
        XCTAssertNil(rig.model.remoteResumeRow)

        XCTAssertFalse(rig.player.handleRemote(.play), "nothing to resume: the finished episode is not started again")
        await settleOnClock()
        XCTAssertEqual(rig.player.status, .ended)
        XCTAssertFalse(rig.engine.isPlaying)
        withExtendedLifetime(runtime) {}
    }

    func testPlayOnThePhoneItselfStillPlaysAnEndedEpisodeAgain() async throws {
        try await seed()
        let rig = await launch()
        let runtime = try await endedAndStillLoaded(rig)

        rig.player.play() // the player screen's own button, pressed on the episode it shows as finished
        for _ in 0..<400 where !rig.player.isPlaying { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
        XCTAssertTrue(rig.player.isPlaying)
        withExtendedLifetime(runtime) {}
    }

    // MARK: - What brings it back

    func testTheListenerPlayingItAgainMakesItAnOrdinaryEpisodeAgain() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        await rig.model.decide(.markDone, entryID: id("a"))
        clock.advance(600)
        await syncRounds(rig)

        try await start(rig, "a") // their own press on the row
        rig.player.pause()
        let next = try await whatFollowsC(rig)
        XCTAssertEqual(next, "a", "an episode they chose to play again is in progress like any other")
    }

    func testStopWaitingMakesItAnOrdinaryEpisodeAgain() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        await rig.model.decide(.markDone, entryID: id("a"))
        clock.advance(600)
        await syncRounds(rig)

        rig.model.cancelDecision(entryID: id("a"))
        await rig.model.refresh()
        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("a"))
    }

    func testTheMacDecliningTheCompletionMakesItAnOrdinaryEpisodeAgain() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        await rig.model.decide(.markDone, entryID: id("a"))
        let sent = try await mac.listIntents()
        let intent = try XCTUnwrap(sent.first)
        try await mac.publishIntentOutcome(
            try IntentOutcome.rejected(for: intent, reason: IntentOutcome.reasonNotApplicable, at: clock.now))
        await syncRounds(rig)

        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("a"))
    }

    func testAnEpisodeTheMacPutBackAfterCompletingItIsAnOrdinaryEpisodeAgain() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        await rig.model.decide(.markDone, entryID: id("a"))
        try await macAnswersApplied(to: "a")
        try await macRetires("a")
        await rig.model.refresh()
        XCTAssertNil(rig.model.queued.first { $0.id == id("a") })
        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("b"))

        // Restored on the Mac: the library the phone reads lists it again.
        try await macPush([.entry(try entry("a")), .slot(try QueueSlot(entryID: id("a"), sortKey: 0))])
        clock.advance(600)
        await syncRounds(rig)
        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("a"))
    }

    func testACompletionTheMacCanNoLongerApplyStopsHoldingTheEpisodeBack() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        await rig.model.decide(.markDone, entryID: id("a"))
        clock.advance(IntentRetention.maximumAge + 60)
        await syncRounds(rig)

        XCTAssertEqual(rig.model.remoteResumeRow?.id, id("a"))
    }
}
