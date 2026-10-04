import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// Durable checkpoint and playback-statistics coverage for
/// `PlaybackController`: speed-savings intervals against the revision
/// high-water mark, live checkpoints that leave playback running, and the
/// terminal completed record. Shared fixtures (`FakeBackend`, `storeURL`,
/// `fixture`, `queueRevision`, `waitUntil`) live in
/// `PlaybackControllerTests.swift`.
@MainActor
extension PlaybackControllerTests {
    func testSpeedSavingsUseDurableRevisionHighWaterAcrossSeeksAndRelaunch() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        var controller = PlaybackController(store: store, backend: backend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        controller.setRate(2)
        backend.currentTime = 10
        try await controller.checkpoint()
        try await controller.checkpoint()
        try await controller.seek(to: 3)
        backend.currentTime = 8
        try await controller.checkpoint()
        let firstTotal = try await store.lifetimeStatistics().fasterPlaybackTimeSavedSeconds
        XCTAssertEqual(firstTotal, 5, accuracy: 0.0001)

        let relaunchedBackend = FakeBackend()
        controller = PlaybackController(store: store, backend: relaunchedBackend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        controller.setRate(2)
        try await controller.seek(to: 30)
        relaunchedBackend.currentTime = 40
        try await controller.checkpoint()
        let relaunchedTotal = try await store.lifetimeStatistics().fasterPlaybackTimeSavedSeconds
        XCTAssertEqual(relaunchedTotal, 10, accuracy: 0.0001)
    }

    func testListenerEquivalentNormalRateAdvancesHighWaterWithoutRecordingSavings() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        controller.setRate(1)
        backend.currentTime = 20
        try await controller.checkpoint()
        controller.setRate(2)
        backend.currentTime = 30
        try await controller.checkpoint()

        let total = try await store.lifetimeStatistics().fasterPlaybackTimeSavedSeconds
        XCTAssertEqual(total, 5, accuracy: 0.0001)
    }

    func testManualCompletionDoesNotCountUnplayedRemainderAsSpeedSavings() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        controller.setRate(2)
        backend.currentTime = 10

        try await controller.markCompleted()

        let total = try await store.lifetimeStatistics().fasterPlaybackTimeSavedSeconds
        XCTAssertEqual(total, 5, accuracy: 0.0001)
    }

    func testRateChangesSplitUncheckpointedPlaybackAtTheirExactBoundary() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        controller.setRate(2)
        backend.currentTime = 10
        controller.setRate(1)
        backend.currentTime = 20
        controller.setRate(2)
        backend.currentTime = 30

        try await controller.checkpoint()

        let total = try await store.lifetimeStatistics().fasterPlaybackTimeSavedSeconds
        XCTAssertEqual(total, 10, accuracy: 0.0001)
    }

    /// Progress reached the store only on a transport press or a clean quit,
    /// so a process that ended without one -- an installer replacing the app,
    /// a force quit, a crash -- resumed from wherever the listener last
    /// pressed a button rather than where the audio actually was. A checkpoint
    /// taken while the engine is still running has to persist the live
    /// playhead and leave playback alone.
    func testACheckpointTakenMidPlaybackPersistsWithoutStopping() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend, deviceID: "test-device")
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        try controller.play()
        backend.currentTime = 31

        try await controller.checkpoint()

        XCTAssertTrue(backend.isPlaying, "checkpointing is not a transport action")
        XCTAssertTrue(controller.isPlaying)
        let itemID = try XCTUnwrap(controller.itemID)
        let revisionID = try XCTUnwrap(controller.revisionID)
        let stored = try await store.playbackState(for: itemID, revisionID: revisionID)
        let persisted = try XCTUnwrap(stored)
        XCTAssertEqual(persisted.positionSeconds, 31, "a relaunch resumes from here")
        XCTAssertFalse(persisted.completed)

        // The playhead keeps moving; the next tick has to overtake the last one
        // rather than lose to its sequence number.
        backend.currentTime = 44
        try await controller.checkpoint()
        let storedLater = try await store.playbackState(for: itemID, revisionID: revisionID)
        let later = try XCTUnwrap(storedLater)
        XCTAssertEqual(later.positionSeconds, 42, "clamped to the revision duration")
        XCTAssertGreaterThan(later.sequence, persisted.sequence)
    }

    func testMarkCompletedAfterFailureSurvivesLaterCheckpoints() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var finishCount = 0
        controller.playbackDidFinishHandler = { finishCount += 1 }
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/fake.m4a"))
        try controller.play()
        backend.currentTime = 19
        backend.finish(successfully: false)
        await waitUntil { finishCount == 1 }
        XCTAssertEqual(controller.recoverableFault, .playbackFailed(revision.itemID))

        try await controller.markCompleted()
        XCTAssertNil(controller.recoverableFault)
        try await controller.checkpoint()
        try await controller.pause()
        try await controller.handlePauseOrQuit()
        let saved = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        XCTAssertTrue(try XCTUnwrap(saved).completed)
        XCTAssertEqual(try XCTUnwrap(saved).positionSeconds, backend.duration)
        XCTAssertTrue(controller.completed)
        XCTAssertNil(controller.recoverableFault)
    }

    /// Progress is written from where the audio is, so an episode the listener
    /// is finished with at 91% stays at 91% and the Larder goes on offering it.
    /// Marking it writes the same terminal record a natural finish writes, and
    /// deliberately does not advance: the press says "done with this", not
    /// "play the next thing". The queue must also stay put afterwards, because
    /// the backend's clock now sits at the end of the file and a later resume
    /// would otherwise fire a completion nobody asked for.
    func testMarkingCompletedWritesTheTerminalRecordWithoutAdvancing() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 3, root: root, store: store)
        let second = try await queueRevision(index: 4, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var completionCalls: [ItemID] = []
        controller.podcastCompletionHandler = { completionCalls.append($0) }
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        backend.currentTime = 20
        try await controller.checkpoint()
        XCTAssertFalse(controller.completed)

        try await controller.markCompleted()
        XCTAssertTrue(controller.completed)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(backend.isPlaying)
        XCTAssertEqual(controller.positionSeconds, controller.durationSeconds)
        XCTAssertEqual(controller.itemID, first.revision.itemID, "marking completed advances nothing")
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, first.revision.itemID)

        let storedState = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        let stored = try XCTUnwrap(storedState)
        XCTAssertTrue(stored.completed)
        XCTAssertEqual(stored.positionSeconds, stored.durationSeconds)

        let listening = try await store.listeningState(for: first.revision.itemID)
        XCTAssertNotNil(listening?.completedAt, "the manual mark-completed path writes the listening fact too")
        XCTAssertEqual(listening?.lastRevisionID, first.revision.revisionID)
        XCTAssertTrue(completionCalls.isEmpty,
                      "markCompleted() bypasses handleBackendCompletion, so retirement is the caller's job, not the controller's")

        backend.finish(successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, first.revision.itemID,
                       "a resume that runs out at the end it was already marked at must not pull in the next episode")
        XCTAssertEqual(backend.loadCount, 1)
    }

    // MARK: - Measured lifetime totals

    func testPlayedTimeCountsActiveListeningAcrossPauseRateReplayAndRepeatedCheckpoints() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend(), clock = ListeningTestClock()
        let controller = PlaybackController(store: store, backend: backend)
        controller.listeningClock = { clock.now }
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))

        try controller.play(); clock.now += 5; backend.currentTime = 5
        try await controller.pause()
        clock.now += 100 // paused time is not listening
        controller.setRate(2) // wall time, not program time
        try controller.play(); clock.now += 4; backend.currentTime = 13
        try await controller.checkpoint()
        try await controller.checkpoint()
        let afterRepeat = try await measured(store)
        XCTAssertEqual(afterRepeat.playedMilliseconds, 9_000, "a repeated checkpoint admits nothing new")
        try await controller.seek(to: 3) // replay counts again
        clock.now += 6; backend.currentTime = 9
        try await controller.seek(to: 30) // a jump adds no listening time
        clock.now += 2
        try await controller.pause()
        let eventsBeforeIdle = try measureEventCount(store, .playedTime)
        try await controller.checkpoint()
        try await controller.handlePauseOrQuit()
        let totals = try await measured(store)
        XCTAssertEqual(totals.playedMilliseconds, 17_000)
        XCTAssertEqual(try measureEventCount(store, .playedTime), eventsBeforeIdle, "idle checkpoints write no event")
    }

    func testPlayedTimeAcrossRestartCompletionAdvanceAndHandoffCountsEachSecondOnce() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store)
        let second = try await queueRevision(index: 2, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID], currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend(), clock = ListeningTestClock()
        let controller = PlaybackController(store: store, backend: backend)
        controller.listeningClock = { clock.now }
        await controller.restorePodcastQueue()

        try controller.play(); clock.now += 7
        try await controller.restart(); clock.now += 3
        backend.finish(successfully: true)
        await waitUntil { controller.itemID == second.revision.itemID && controller.isPlaying }
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        let atCompletion = try await measured(store)
        XCTAssertEqual(atCompletion.playedMilliseconds, 10_000, "completion admits the finished item's time")
        clock.now += 2
        try await controller.pause()
        let handoff = RemotePositionRequest(
            itemID: second.revision.itemID, revisionID: second.revision.revisionID,
            positionSeconds: 30, durationSeconds: 42, observedAt: Date().addingTimeInterval(60))
        _ = try await controller.applyRemotePosition(handoff)
        clock.now += 50
        try await controller.flushLifetimeMeasures()
        let totals = try await measured(store)
        XCTAssertEqual(totals.playedMilliseconds, 12_000)
        XCTAssertEqual(totals.manuallySkippedMilliseconds, 0, "completion, restart and handoff are not skips")
    }

    func testRelaunchCountsTheNewProcessInFullAndLosesAtMostTheUnflushedTail() async throws {
        XCTAssertEqual(PlaybackController.playedTimeCheckpointInterval, 10)
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let clock = ListeningTestClock()
        var controller: PlaybackController? = PlaybackController(store: store, backend: FakeBackend())
        controller?.listeningClock = { clock.now }
        try await controller?.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        try controller?.play()
        for _ in 0..<2 { clock.now += 10; try await controller?.checkpoint() }
        clock.now += 5 // played, then the process dies without a terminal flush
        let session = controller?.sessionID
        controller = nil
        let crashed = try await measured(store)
        XCTAssertEqual(crashed.playedMilliseconds, 20_000, "the lost tail is under one checkpoint interval")

        let relaunched = PlaybackController(store: store, backend: FakeBackend())
        relaunched.listeningClock = { clock.now }
        try await relaunched.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        XCTAssertEqual(relaunched.sessionID, session, "the relaunch resumes the persisted session")
        try relaunched.play(); clock.now += 4
        let readers = (0..<8).map { _ in
            Task.detached { try await store.lifetimeStatisticsSummary().measured.playedMilliseconds }
        }
        try await relaunched.flushLifetimeMeasures()
        var reads: [Int64] = []
        for reader in readers { reads.append(try await reader.value) }
        XCTAssertTrue(reads.allSatisfy { $0 == 20_000 || $0 == 24_000 }, "a concurrent read sees one whole total")
        try await relaunched.flushLifetimeMeasures()
        let totals = try await measured(store)
        XCTAssertEqual(totals.playedMilliseconds, 24_000, "the new process is not hidden by the old high-water mark")
    }

    func testManualSkipCountsBoundedForwardSeekAndNextRemainderOnly() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let episodes = [try await queueRevision(index: 1, root: root, store: store),
                        try await queueRevision(index: 2, root: root, store: store),
                        try await queueRevision(index: 3, root: root, store: store)]
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: episodes.map(\.revision.itemID), currentEpisodeID: episodes[0].revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()

        backend.currentTime = 10
        try await controller.seekForward(seconds: 30) // 10 -> 40: 30s
        try await controller.seek(to: 500) // clamped to the 42s item: 2s
        try await controller.seekBackward(seconds: 15) // backward: nothing
        XCTAssertEqual(backend.currentTime, 27)
        let advanced = try await controller.selectNextPodcastQueueEpisode(autoplay: false) // remainder 15s
        XCTAssertTrue(advanced)
        try await controller.selectPodcastQueueEpisode(episodes[2].revision.itemID) // a row choice
        try await controller.markCompleted() // finishing is not skipping
        try await controller.flushLifetimeMeasures()
        try await controller.flushLifetimeMeasures()
        let totals = try await measured(store)
        XCTAssertEqual(totals.manuallySkippedMilliseconds, 47_000)
        XCTAssertEqual(totals.playedMilliseconds, 0, "nothing was playing")
    }

    private func measured(_ store: LocalLibraryStore) async throws -> LifetimeMeasuredTotals {
        let summary = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.state, .ready)
        return summary.measured
    }

    private func measureEventCount(_ store: LocalLibraryStore, _ kind: LifetimeMeasureKind) throws -> Int {
        let raw = kind.rawValue
        return try ModelContext(store.container).fetchCount(FetchDescriptor<LocalLibrarySchemaV14Models.LifetimeMeasureEventRecord>(
            predicate: #Predicate { $0.kind == raw }))
    }
}

/// A listening clock the test advances by hand.
@MainActor
private final class ListeningTestClock {
    var now: TimeInterval = 1_000
}
