import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

// MARK: - Tests

/// `LibraryVoiceTarget` against a real `LibraryAppModel` and `LibraryPlayer`, on the same rig the
/// handoff and media tests use: an in-memory Mac and phone, a file media cache and a fake engine.
@MainActor
final class LibraryVoiceTargetTests: XCTestCase {
    var scratch: URL!
    let server = InMemoryLibraryServer(writerDeviceID: "mac")
    lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    lazy var phoneTransport = InMemoryLibraryTransport(deviceID: "phone", server: server)
    let sleeper = VoiceSleeper()
    let suite = "library-voice-target-tests"
    var versions: [LibraryRecordKey: UInt64] = [:]
    var localSeq: UInt64 = 0
    let payload = Data((0..<20_000).map { UInt8($0 % 251) })

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

    func testResumeAndRestartRejectMissingCachedBytesBeforePlayerEffect() async throws {
        for action in [VoiceAction.resume, .restart] {
            let rig = try await loadedRig()
            try await rig.cache.remove(entryID: id("a"))
            let outcome = await rig.target.perform(action)
            XCTAssertEqual(outcome, .failed)
            XCTAssertFalse(rig.engine.isPlaying)
            XCTAssertEqual(rig.player.position, 120, "failed restart must not seek before validation")
            rig.player.stop()
        }
    }

    func testResumeAndRestartRejectDeletedURLCapturedBeforeHeldLookupReturns() async throws {
        for action in [VoiceAction.resume, .restart] {
            let rig = try await loadedRig()
            let original = try XCTUnwrap(rig.player.item?.fileURL)
            XCTAssertEqual(try Data(contentsOf: original), payload)
            await rig.cache.arm()
            let spoken = Task { @MainActor in await rig.target.perform(action) }
            try await eventually("loaded voice command held after capturing cached URL") { await rig.cache.isHeld }
            try await rig.cache.remove(entryID: id("a"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
            await rig.cache.release()
            let outcome = await spoken.value
            XCTAssertEqual(outcome, .failed)
            XCTAssertFalse(rig.engine.isPlaying, "a stale cache answer cannot resume the retained engine")
            XCTAssertEqual(rig.player.position, 120, "failed restart must not seek")
            XCTAssertEqual(rig.engine.loadedURLs, [original])
            rig.player.stop()
        }
    }

    func testResumeAndRestartLoadActualReplacementRevisionURL() async throws {
        for action in [VoiceAction.resume, .restart] {
            let rig = try await loadedRig()
            let original = try XCTUnwrap(rig.player.item?.fileURL)
            let replacement = try await replaceCachedA(rig)
            XCTAssertNotEqual(replacement, original)
            let outcome = await rig.target.perform(action)
            XCTAssertEqual(outcome, .done)
            XCTAssertEqual(rig.player.item?.fileURL, replacement)
            XCTAssertEqual(rig.engine.loadedURLs, [original, replacement])
            XCTAssertTrue(rig.engine.isPlaying)
            if action == .restart { XCTAssertEqual(rig.player.position, 0) }
            rig.player.stop()
        }
    }

    func testRestartSupersededByDifferentSelectionDoesNotSeekNewItem() async throws {
        let rig = try await loadedRig(twoEpisodes: true)
        defer { rig.player.stop() }
        await rig.cache.arm()
        var finished = false
        let restart = Task { @MainActor in
            defer { finished = true }
            return await rig.target.perform(.restart)
        }
        try await eventually("restart validates cache or finishes") { await rig.cache.isHeld || finished }
        guard await rig.cache.isHeld else {
            _ = await restart.value
            return XCTFail("restart must await shared cached-play validation")
        }
        let selected = await rig.target.perform(.play(id("b")))
        XCTAssertEqual(selected, .done)
        rig.player.seek(to: 75)
        await rig.cache.release()
        let outcome = await restart.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        XCTAssertEqual(rig.player.position, 75)
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testFailedExplicitPlayDoesNotClaimSuccessFromAlreadyPlayingStaleEngine() async throws {
        let rig = try await loadedRig()
        defer { rig.player.stop() }
        rig.player.play()
        await settleVoiceRig(rig)
        try await rig.cache.remove(entryID: id("a"))
        let outcome = await rig.target.perform(.play(id("a")))
        XCTAssertEqual(outcome, .failed, "missing-cache outcome is not success because old same-ID engine plays")
    }

    func testDeclinedExplicitPlayDoesNotClaimSuccessFromRemovedPlayingItem() async throws {
        let rig = try await loadedRig()
        let originalFile = try XCTUnwrap(rig.cachedURLs[id("a")])
        defer { rig.player.stop() }
        rig.player.play()
        await settleVoiceRig(rig)
        await rig.cache.arm()
        let spoken = Task { @MainActor in await rig.target.perform(.play(self.id("a"))) }
        try await eventually("explicit play inside cache") { await rig.cache.isHeld }
        try await macPush([.slotRemoved(entryID: id("a"))])
        await rig.model.refresh()
        await rig.cache.release()
        let outcome = await spoken.value
        XCTAssertEqual(outcome, .failed, "declined removed entry must not succeed through same-ID playing fallback")
        let cached = await rig.cache.cachedEntries()
        XCTAssertNil(cached[id("a")], "confirmed removal revokes admitted inventory")
        XCTAssertEqual(rig.model.media[id("a")], .notPrepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
        XCTAssertEqual(try Data(contentsOf: originalFile), payload)
        XCTAssertNil(rig.player.item)
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

    func testDownloadedEpisodesCarryTheirPublishedDateAndPlayFirstFollowsPlayOrder() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Old", show: "show", sortKey: 0, published: 1_600_000_000),
            EpisodeSpec(raw: "b", title: "New", show: "show", sortKey: 1, published: 1_700_000_000),
        ])
        let rig = try await makeRig(cached: ["a", "b"])

        let snapshot = await rig.target.voiceSnapshot()
        XCTAssertEqual(snapshot.downloaded.map(\.publishedAt.timeIntervalSince1970), [1_600_000_000, 1_700_000_000])
        let plan = VoiceCommandPlanner.plan(.playLatest(show: nil), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(id("b")), "playLatest (the car's \"newest\") is still the newest published")
        let first = VoiceCommandPlanner.plan(.playFirst(show: nil), snapshot: snapshot)
        XCTAssertEqual(first.action, .play(id("a")), "playFirst takes the head of the play order: the oldest not-started episode")
    }

    /// Siri uses the shared play order: ties on the published date keep the Mac's queue order.
    func testDownloadedKeepsLarderOrderOnPublishDateTies() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Zebra", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Apple", show: "show", sortKey: 1),
            EpisodeSpec(raw: "c", title: "Mango", show: "show", sortKey: 2),
        ])
        let rig = try await makeRig(cached: ["a", "c"])

        let custom = await rig.target.voiceSnapshot()
        XCTAssertEqual(custom.downloaded.map(\.id.rawValue), ["a", "c"], "equal publish dates keep the Mac's queue order")
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
        XCTAssertTrue(nowPlaying.canMarkCompleted, "an episode on the phone offers Mark completed even before it is started")
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

    /// Characterizes retained cached playback, not Siri routing or playback on an owner device.
    func testRemovedCachedLoadedEpisodeCannotResumeAfterConfirmedRemovalFromLarder() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        let file = try XCTUnwrap(rig.cachedURLs[id("a")])
        let runtime = LibraryRuntime(
            model: rig.model, player: rig.player,
            settings: LibrarySettingsStore(defaults: UserDefaults(suiteName: suite)!))
        defer { runtime.player.stop() }
        await runtime.prepare()
        // Drain the serial queue that delivers the production runtime's media observer.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let played = await rig.target.perform(.play(id("a")))
        XCTAssertEqual(played, .done)
        await rig.target.perform(.pause)
        await rig.model.waitForHandoff()
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.engine.isPlaying)

        await rig.model.decide(.removeFromLarder, entryID: id("a"))
        let sent = try await mac.listIntents().filter { $0.action == .removeFromLarder(entryID: id("a")) }
        XCTAssertEqual(sent.count, 1)
        let intent = try XCTUnwrap(sent.first)
        try await mac.publishIntentOutcome(IntentOutcome.applied(for: intent, at: Date(timeIntervalSince1970: 1_000)))
        await rig.model.refresh()
        XCTAssertEqual(rig.model.decisionStatus(for: id("a")), .confirming)
        try await macPush([.slotRemoved(entryID: id("a"))])
        await rig.model.refresh()
        await rig.model.waitForHandoff()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(rig.model.pendingDecision(for: id("a")), "the Mac's publish confirmed removal")
        XCTAssertTrue(rig.model.queued.isEmpty)
        XCTAssertTrue(rig.model.visibleRows.isEmpty)
        let snapshot = await rig.target.voiceSnapshot()
        XCTAssertTrue(snapshot.downloaded.isEmpty)
        XCTAssertNil(snapshot.nowPlaying)
        XCTAssertEqual(rig.model.media[id("a")], .notPrepared)
        let cached = await rig.cache.cachedEntries()
        XCTAssertNil(cached[id("a")], "confirmed removal revokes admitted inventory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), payload, "verified cached bytes remain despite list absence")
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.player.status, .idle, "queue invalidation cleared loaded audio, retaining inert bytes")
        XCTAssertFalse(rig.player.handle(.play), "system remote resume cannot reanimate the invalidated item")

        let dialog = try await VoiceCommandRunner.run(.resume, on: rig.target, confirm: { _ in XCTFail("resume needs no confirmation") })
        await rig.model.waitForHandoff()
        XCTAssertEqual(dialog, "Nothing to resume.")
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.player.status, .idle)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.loadedURLs, [file], "refused resume made no second load")
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

    func testMarkCompletedForAnUnstartedEpisodeNotOnThePhoneSendsNothing() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
            EpisodeSpec(raw: "b", title: "Episode B", show: "show", sortKey: 1),
        ])
        try await macPublishesProgress("a", position: 100)
        let rig = try await makeRig(cached: ["a"])

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

    func testExplicitVoicePlayRefusesSlotRemovedDuringItsCacheLookup() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "Garden Radio")], episodes: [
            EpisodeSpec(raw: "a", title: "Garden Morning", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        let originalFile = try XCTUnwrap(rig.cachedURLs[id("a")])
        await rig.cache.arm()
        let spoken = Task { @MainActor in await rig.target.perform(.play(self.id("a"))) }
        try await eventually("Siri inside cache read") { await rig.cache.isHeld }
        try await macPush([.slotRemoved(entryID: id("a"))])
        await rig.model.refresh()
        let cached = await rig.cache.cachedEntries()
        XCTAssertNil(cached[id("a")], "confirmed removal revokes admitted inventory")
        XCTAssertEqual(rig.model.media[id("a")], .notPrepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
        XCTAssertEqual(try Data(contentsOf: originalFile), payload)
        XCTAssertNil(rig.player.item)
        XCTAssertTrue(rig.model.queued.isEmpty)
        await rig.cache.release()
        let outcome = await spoken.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(rig.player.item)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertTrue(rig.engine.loadedURLs.isEmpty)
    }

    func testExplicitVoicePlayRefusesQueuedButNotOnPhoneEvenWithRetainedCache() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "Garden Radio")], episodes: [
            EpisodeSpec(raw: "a", title: "Garden Morning", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        rig.model.media[id("a")] = .available
        let snapshot = await rig.target.voiceSnapshot()
        XCTAssertTrue(snapshot.downloaded.isEmpty)
        let cached = await rig.cache.cachedEntries()
        XCTAssertNotNil(cached[id("a")])
        let outcome = await rig.target.perform(.play(id("a")))
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(rig.player.item)
        XCTAssertTrue(rig.engine.loadedURLs.isEmpty)
    }

    func testFailedNamedRequestLeavesPreviouslyPlayingUnrelatedAudioAlone() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "Garden Radio")], episodes: [
            EpisodeSpec(raw: "a", title: "Garden Morning", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: ["a"])
        await rig.target.perform(.play(id("a")))
        let dialog = try await VoiceCommandRunner.run(.playNext(show: "Unknown Radio"), on: rig.target, confirm: { _ in XCTFail("play needs no confirmation") })
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
        XCTAssertTrue(rig.engine.isPlaying, "a named miss does not pause existing unrelated audio")
        XCTAssertEqual(rig.engine.loadedURLs.count, 1)
        XCTAssertFalse(dialog.hasPrefix("Playing"))
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

    func testPerformReportsFailureForAnEpisodeThatIsNotQueuedOrNotOnThePhone() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        let rig = try await makeRig(cached: [])

        let played = await rig.target.perform(.play(id("missing")))
        XCTAssertEqual(played, .failed)
        let marked = await rig.target.perform(.markCompleted(id("a")))
        XCTAssertEqual(marked, .failed, "an unstarted row that is not on the phone offers no Mark completed, so nothing was accepted")
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
