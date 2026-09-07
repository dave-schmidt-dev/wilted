import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
final class PlaybackControllerTests: XCTestCase {
    private final class FakeBackend: PlaybackBackend {
        var duration: TimeInterval = 42
        var currentTime: TimeInterval = 0
        var isPlaying = false
        var loadCount = 0
        var rate: Float = 1
        var volume: Float = 1
        private(set) var loadedGeneration: UInt64 = 0
        var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
        var failingURLs: Set<URL> = []
        var cancelledURLs: Set<URL> = []
        var cancelledLoadCount = 0
        var resetsTimeOnFailure = false

        func load(url: URL) throws {
            if cancelledURLs.contains(url) {
                cancelledLoadCount += 1
                throw CancellationError()
            }
            if failingURLs.contains(url) { throw CocoaError(.fileReadCorruptFile) }
            loadCount += 1; loadedGeneration += 1; currentTime = 0; isPlaying = false
        }
        func play() -> Bool { isPlaying = true; return true }
        func pause() { isPlaying = false }
        func stop() { isPlaying = false }
        func finish(generation: UInt64? = nil, successfully: Bool) {
            if !successfully && resetsTimeOnFailure { currentTime = 0 }
            completionHandler?(generation ?? loadedGeneration, successfully)
        }
    }

    private func storeURL(_ name: String = #function) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-playback-\(name)-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
    }

    private func fixture() throws -> (Article, AudioRevision) {
        let url = URL(string: "https://example.test/playback")!
        let article = try Article(itemID: ItemID.derive(from: url), canonicalURL: url,
                                  title: "Playback", source: "example.test",
                                  createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        let revision = try AudioRevision(itemID: article.itemID, revisionID: RevisionID(rawValue: "revision-one"),
                                         durationSeconds: 42, byteCount: 1,
                                         contentHash: "sha256:\(String(repeating: "a", count: 64))",
                                         mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        return (article, revision)
    }

    func testPauseThenNewControllerResumesMatchingRevision() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (article, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend, deviceID: "test-device")
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        backend.currentTime = 12
        try controller.play()
        try await controller.pause()

        let resumed = PlaybackController(store: store, backend: FakeBackend(), deviceID: "test-device")
        try await resumed.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        XCTAssertEqual(resumed.positionSeconds, 12)
        XCTAssertEqual(resumed.revisionID, revision.revisionID)
    }

    func testMismatchedRevisionResumeIsIgnored() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (article, first) = try fixture()
        let second = try AudioRevision(itemID: article.itemID, revisionID: RevisionID(rawValue: "revision-two"),
                                       durationSeconds: 42, byteCount: 1,
                                       contentHash: "sha256:\(String(repeating: "b", count: 64))",
                                       mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let state = try PlaybackState(itemID: article.itemID, revisionID: first.revisionID, sessionID: "old-session",
                                      sequence: 3, positionSeconds: 30, durationSeconds: 42, completed: false,
                                      intent: .progress, deviceID: "test-device", updatedAt: Timestamp(Date()))
        try await store.save(playback: state)
        let controller = PlaybackController(store: store, backend: FakeBackend())
        try await controller.load(revision: second, mediaURL: URL(fileURLWithPath: "/tmp/other.m4a"))
        XCTAssertEqual(controller.positionSeconds, 0)
        XCTAssertNotEqual(controller.sessionID, state.sessionID)
    }

    func testRouteRecoveryPreservesPositionAndPlayState() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        backend.currentTime = 17
        try controller.play()
        try await controller.recoverFromRouteChange()
        XCTAssertEqual(backend.currentTime, 17)
        XCTAssertTrue(backend.isPlaying)
        XCTAssertEqual(backend.loadCount, 2)
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

    func testRewindAndRestartCreateNewSessionsAndExplicitIntent() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        let initialSession = try XCTUnwrap(controller.sessionID)
        backend.currentTime = 20
        try await controller.checkpoint()
        try await controller.seekBackward(seconds: 5)
        let rewindSession = try XCTUnwrap(controller.sessionID)
        XCTAssertNotEqual(rewindSession, initialSession)
        XCTAssertEqual(controller.intent, .rewind)
        XCTAssertEqual(controller.positionSeconds, 15)
        try await controller.restart()
        XCTAssertNotEqual(controller.sessionID, rewindSession)
        XCTAssertEqual(controller.intent, .restart)
        XCTAssertEqual(controller.positionSeconds, 0)
    }

    func testNaturalCompletionAdvancesExactlyOnceAndInterruptionDoesNotAdvance() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store)
        let second = try await queueRevision(index: 2, root: root, store: store)
        let third = try await queueRevision(index: 6, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var observations: [(ItemID?, PlaybackControllerError?)] = []
        controller.podcastStateHandler = { observations.append(($0, $1)) }
        var finishCount = 0
        controller.playbackDidFinishHandler = { finishCount += 1 }
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        let firstGeneration = backend.loadedGeneration
        try controller.play()
        backend.currentTime = 12
        try await controller.checkpoint()
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(backend.isPlaying)
        backend.currentTime = 19

        backend.finish(successfully: false)
        await waitUntil { finishCount == 1 }
        // An unsuccessful callback for the loaded generation stops both the
        // controller and the backend, reports one recoverable stop observation,
        // exposes a recoverable fault, preserves the current queue item, and
        // does not mark the revision complete.
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertFalse(controller.isPlaying, "the controller must stop on a failed callback")
        XCTAssertFalse(backend.isPlaying, "the backend must be paused on a failed callback")
        XCTAssertEqual(controller.recoverableFault, .playbackFailed(first.revision.itemID))
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.last?.0, first.revision.itemID)
        XCTAssertEqual(observations.last?.1, .playbackFailed(first.revision.itemID))
        XCTAssertEqual(finishCount, 1, "the failed callback must announce one stop observation")
        XCTAssertFalse(controller.completed, "a failed callback must not mark the revision complete")
        let retainedQueueState = try await store.podcastQueueState()
        XCTAssertEqual(retainedQueueState.currentEpisodeID, first.revision.itemID,
                       "a failed callback must not advance the queue")
        let retainedPlaybackState = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        let retainedPlayback = try XCTUnwrap(retainedPlaybackState)
        XCTAssertFalse(retainedPlayback.completed)
        XCTAssertEqual(retainedPlayback.positionSeconds, 19)
        // A repeated failure for the same generation is a duplicate and silent.
        backend.finish(successfully: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(finishCount, 1, "a duplicate failed callback must not announce again")

        backend.finish(successfully: true)
        backend.finish(successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, first.revision.itemID,
                       "a contradictory success must not advance a failed generation")
        XCTAssertFalse(controller.completed)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(finishCount, 1)

        backend.currentTime = 0 // A failed player may reset after its stop checkpoint.
        try controller.play()
        XCTAssertNotEqual(backend.loadedGeneration, firstGeneration)
        XCTAssertEqual(backend.currentTime, 19)
        XCTAssertNil(controller.recoverableFault)
        XCTAssertTrue(controller.isPlaying)
        backend.finish(generation: firstGeneration, successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertTrue(controller.isPlaying)
        backend.finish(successfully: true)
        backend.finish(successfully: true)
        await waitUntil { controller.itemID == second.revision.itemID }
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        XCTAssertEqual(backend.loadCount, 3, "retry reloads once and duplicate completion must not load again")
        let advancedState = try await store.podcastQueueState()
        XCTAssertEqual(advancedState.currentEpisodeID, second.revision.itemID)
        let storedCompletedState = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        let completedState = try XCTUnwrap(storedCompletedState)
        XCTAssertTrue(completedState.completed)
        XCTAssertEqual(completedState.positionSeconds, completedState.durationSeconds)
        XCTAssertEqual(observations.last?.0, second.revision.itemID)
        XCTAssertNil(observations.last?.1)

        backend.finish(generation: firstGeneration, successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        XCTAssertEqual(backend.loadCount, 3, "a delayed old-player callback must not advance the replacement")
        backend.finish(generation: firstGeneration, successfully: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.isPlaying, "a stale failure must not pause the replacement")
        XCTAssertTrue(backend.isPlaying)
        XCTAssertNil(controller.recoverableFault)
        XCTAssertEqual(finishCount, 1, "a stale failure must not announce another stop")

        let relaunched = PlaybackController(store: store, backend: FakeBackend())
        await relaunched.restorePodcastQueue()
        XCTAssertEqual(relaunched.itemID, second.revision.itemID)
        let relaunchedCompletedState = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        XCTAssertTrue(try XCTUnwrap(relaunchedCompletedState).completed)
    }

    func testArticleFailureAtEndStaysIncompleteAndPlayRetryRearmsCompletion() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var finishCount = 0
        var podcastObservationCount = 0
        controller.playbackDidFinishHandler = { finishCount += 1 }
        controller.podcastStateHandler = { _, _ in podcastObservationCount += 1 }
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/fake.m4a"))
        try controller.play()
        let failedGeneration = backend.loadedGeneration
        backend.currentTime = backend.duration
        backend.finish(successfully: false)
        await waitUntil { finishCount == 1 }
        try await controller.checkpoint()
        let failedState = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(try XCTUnwrap(failedState).positionSeconds, backend.duration)
        XCTAssertFalse(try XCTUnwrap(failedState).completed)
        XCTAssertFalse(controller.completed)
        XCTAssertEqual(podcastObservationCount, 0, "an article failure must preserve the UI's article identity")

        backend.currentTime = 0
        try controller.play()
        XCTAssertNotEqual(backend.loadedGeneration, failedGeneration)
        XCTAssertNil(controller.recoverableFault)
        XCTAssertEqual(backend.currentTime, backend.duration,
                       "retry must restore the stop checkpoint even if the failed player reset")
        backend.finish(generation: failedGeneration, successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(finishCount, 1)

        backend.finish(successfully: true)
        await waitUntil { finishCount == 2 }
        backend.finish(successfully: false)
        backend.finish(successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.completed)
        XCTAssertNil(controller.recoverableFault, "failure after success is a contradictory duplicate")
        XCTAssertEqual(finishCount, 2)
        XCTAssertEqual(podcastObservationCount, 0)
    }

    func testFailureWithResetBackendRetainsCheckpointForRetry() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        backend.resetsTimeOnFailure = true
        let controller = PlaybackController(store: store, backend: backend)
        var finishCount = 0
        controller.playbackDidFinishHandler = { finishCount += 1 }
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/fake.m4a"))
        try controller.play()
        backend.currentTime = 19
        try await controller.checkpoint()
        backend.currentTime = 25
        backend.finish(successfully: false)
        await waitUntil { finishCount == 1 }
        XCTAssertEqual(backend.currentTime, 0, "the fake resets before delivering the failure callback")
        XCTAssertEqual(controller.livePositionSeconds, 19,
                       "the readout must retain progress when the failed backend clock resets")
        try await controller.checkpoint()
        XCTAssertEqual(controller.livePositionSeconds, 19)
        let saved = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(try XCTUnwrap(saved).positionSeconds, 19)
        XCTAssertFalse(try XCTUnwrap(saved).completed)
        try controller.play()
        XCTAssertEqual(backend.currentTime, 19)
        XCTAssertEqual(controller.positionSeconds, 19)

        backend.finish(successfully: false)
        await waitUntil { finishCount == 2 }
        XCTAssertEqual(backend.currentTime, 0)
        try await controller.recoverFromRouteChange()
        XCTAssertEqual(backend.currentTime, 19, "route recovery must also retain the stop checkpoint")
        XCTAssertEqual(controller.livePositionSeconds, 19)
        XCTAssertNil(controller.recoverableFault)
    }

    func testReloadDuringCompletionCheckpointCannotAdvanceOrStopReplacement() async throws {
        let path = storeURL()
        let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store)
        let next = try await queueRevision(index: 2, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, next.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var finishCount = 0
        var observationCount = 0
        controller.playbackDidFinishHandler = { finishCount += 1 }
        controller.podcastStateHandler = { _, _ in observationCount += 1 }
        await controller.restorePodcastQueue()
        try controller.play()

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            Task {
                await store.holdPlaybackStoreForTesting(entered: { entered.resume() }, release: release)
            }
        }
        backend.finish(successfully: true)
        // Completion sets this synchronously before awaiting its blocked save.
        await waitUntil { controller.completed }
        XCTAssertTrue(controller.completed)
        try await controller.recoverFromRouteChange()
        try controller.play()
        let replacementGeneration = backend.loadedGeneration
        release.signal()
        _ = try await store.playbackState(for: first.revision.itemID, revisionID: first.revision.revisionID)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(backend.loadedGeneration, replacementGeneration)
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(observationCount, 0)
        let state = try await store.podcastQueueState()
        XCTAssertEqual(state.currentEpisodeID, first.revision.itemID)
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

    func testRewindAndRestartClearFailureWithoutAnotherPlayReload() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = FakeBackend()
        backend.resetsTimeOnFailure = true
        let controller = PlaybackController(store: store, backend: backend)
        var finishCount = 0
        controller.playbackDidFinishHandler = { finishCount += 1 }
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/fake.m4a"))
        try controller.play()
        backend.currentTime = 20
        try await controller.checkpoint()
        let interruptedSession = controller.sessionID
        backend.finish(successfully: false)
        await waitUntil { finishCount == 1 }
        XCTAssertEqual(backend.currentTime, 0)
        XCTAssertEqual(controller.livePositionSeconds, 20)

        try await controller.seekBackward(seconds: 5)
        XCTAssertEqual(controller.positionSeconds, 15)
        XCTAssertEqual(controller.intent, .rewind)
        XCTAssertNotEqual(controller.sessionID, interruptedSession)
        XCTAssertNil(controller.recoverableFault)
        XCTAssertEqual(backend.loadCount, 2)
        try controller.play()
        XCTAssertEqual(backend.loadCount, 2, "rewind already restored a valid backend generation")
        XCTAssertEqual(backend.currentTime, 15)

        backend.finish(successfully: false)
        await waitUntil { finishCount == 2 }
        try await controller.restart()
        XCTAssertNil(controller.recoverableFault)
        XCTAssertEqual(backend.loadCount, 3)
        try controller.play()
        XCTAssertEqual(backend.loadCount, 3, "restart already restored a valid backend generation")
        XCTAssertEqual(backend.currentTime, 0)
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

        backend.finish(successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, first.revision.itemID,
                       "a resume that runs out at the end it was already marked at must not pull in the next episode")
        XCTAssertEqual(backend.loadCount, 1)
    }

    func testSelectingPodcastWithAutoplayStartsBackend() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let episode = try await queueRevision(index: 7, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [episode.revision.itemID], currentEpisodeID: nil
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)

        try await controller.selectPodcastQueueEpisode(episode.revision.itemID, autoplay: true)

        XCTAssertTrue(backend.isPlaying)
        XCTAssertTrue(controller.isPlaying)
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, episode.revision.itemID)
    }

    func testArticleCompletionEmitsNoPodcastObservationWhilePodcastNoNextDoes() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (_, articleRevision) = try fixture()
        let articleBackend = FakeBackend()
        let articleController = PlaybackController(store: store, backend: articleBackend)
        var articleObservations: [ItemID?] = []
        articleController.podcastStateHandler = { itemID, _ in articleObservations.append(itemID) }
        try await articleController.load(
            revision: articleRevision, mediaURL: root.appendingPathComponent("article.m4a")
        )

        articleBackend.finish(successfully: true)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(articleObservations.isEmpty)
        XCTAssertTrue(articleController.completed)

        let podcast = try await queueRevision(index: 9, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [podcast.revision.itemID], currentEpisodeID: podcast.revision.itemID
        ))
        let podcastBackend = FakeBackend()
        let podcastController = PlaybackController(store: store, backend: podcastBackend)
        var podcastObservations: [ItemID?] = []
        podcastController.podcastStateHandler = { itemID, _ in podcastObservations.append(itemID) }
        await podcastController.restorePodcastQueue()

        podcastBackend.finish(successfully: true)
        await waitUntil { podcastObservations.last == podcast.revision.itemID }

        XCTAssertEqual(podcastObservations, [podcast.revision.itemID])
    }

    /// A surface that only watches `podcastStateHandler` never hears about the
    /// two completions that advance nothing, so anything mirroring playback
    /// outside the app would keep claiming to be playing after the audio ended.
    func testCompletionWithNothingBehindItIsAnnouncedSeparately() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (_, articleRevision) = try fixture()
        let articleBackend = FakeBackend()
        let articleController = PlaybackController(store: store, backend: articleBackend)
        var articleFinishes = 0
        articleController.playbackDidFinishHandler = { articleFinishes += 1 }
        try await articleController.load(
            revision: articleRevision, mediaURL: root.appendingPathComponent("article.m4a")
        )

        articleBackend.finish(successfully: true)
        await waitUntil { articleFinishes == 1 }
        articleBackend.finish(successfully: true)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(articleFinishes, 1, "a repeated completion for the same item announces once")

        let podcast = try await queueRevision(index: 11, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [podcast.revision.itemID], currentEpisodeID: podcast.revision.itemID
        ))
        let podcastBackend = FakeBackend()
        let podcastController = PlaybackController(store: store, backend: podcastBackend)
        var podcastFinishes = 0
        var podcastObservations: [ItemID?] = []
        podcastController.playbackDidFinishHandler = { podcastFinishes += 1 }
        podcastController.podcastStateHandler = { itemID, _ in podcastObservations.append(itemID) }
        await podcastController.restorePodcastQueue()

        podcastBackend.finish(successfully: true)
        await waitUntil { podcastFinishes == 1 }

        XCTAssertEqual(podcastObservations, [podcast.revision.itemID],
                       "the end of the queue still reports which episode stopped")
        XCTAssertFalse(podcastController.isPlaying)
    }

    func testMissingOrCorruptNextMediaPausesAndRetainsDeterministicQueue() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 3, root: root, store: store)
        let missing = try await queueRevision(index: 4, root: root, store: store)
        try FileManager.default.removeItem(at: missing.mediaURL)
        let state = try PodcastQueueState(
            episodeIDs: [first.revision.itemID, missing.revision.itemID],
            currentEpisodeID: first.revision.itemID
        )
        try await store.replacePodcastQueue(state)
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var observedFault: PlaybackControllerError?
        var observedItem: ItemID?
        var finishCount = 0
        controller.podcastStateHandler = { item, fault in observedItem = item; observedFault = fault }
        controller.playbackDidFinishHandler = { finishCount += 1 }
        await controller.restorePodcastQueue()
        backend.finish(successfully: true)
        await waitUntil { finishCount == 1 }
        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.recoverableFault, .podcastMediaUnavailable(missing.revision.itemID))
        XCTAssertEqual(observedFault, controller.recoverableFault)
        XCTAssertEqual(observedItem, first.revision.itemID,
                       "a next-media fault must retain the completed item's UI identity")
        let retainedState = try await store.podcastQueueState()
        XCTAssertEqual(retainedState, state)

        _ = FileManager.default.createFile(atPath: missing.mediaURL.path, contents: Data([4]))
        let corruptBackend = FakeBackend()
        corruptBackend.failingURLs.insert(missing.mediaURL)
        let corruptController = PlaybackController(store: store, backend: corruptBackend)
        var corruptObservedItem: ItemID?
        var corruptObservedFault: PlaybackControllerError?
        var corruptFinishCount = 0
        corruptController.playbackDidFinishHandler = { corruptFinishCount += 1 }
        corruptController.podcastStateHandler = { item, fault in
            corruptObservedItem = item; corruptObservedFault = fault
        }
        await corruptController.restorePodcastQueue()
        corruptBackend.finish(successfully: true)
        await waitUntil { corruptFinishCount == 1 }
        XCTAssertEqual(corruptFinishCount, 1)
        XCTAssertFalse(corruptController.isPlaying)
        XCTAssertEqual(corruptController.recoverableFault, .podcastMediaUnreadable(missing.revision.itemID))
        XCTAssertEqual(corruptObservedItem, first.revision.itemID)
        XCTAssertEqual(corruptObservedFault, .podcastMediaUnreadable(missing.revision.itemID))
        let corruptRetainedState = try await store.podcastQueueState()
        XCTAssertEqual(corruptRetainedState, state)
    }

    func testCancelledNextLoadDoesNotPublishSuccessFaultOrStop() async throws {
        let path = storeURL()
        let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store)
        let next = try await queueRevision(index: 2, root: root, store: store)
        let queue = try PodcastQueueState(
            episodeIDs: [first.revision.itemID, next.revision.itemID],
            currentEpisodeID: first.revision.itemID
        )
        try await store.replacePodcastQueue(queue)
        let backend = FakeBackend()
        backend.cancelledURLs.insert(next.mediaURL)
        let controller = PlaybackController(store: store, backend: backend)
        var observationCount = 0
        var finishCount = 0
        controller.podcastStateHandler = { _, _ in observationCount += 1 }
        controller.playbackDidFinishHandler = { finishCount += 1 }
        await controller.restorePodcastQueue()
        backend.finish(successfully: true)
        await waitUntil { backend.cancelledLoadCount == 1 }
        XCTAssertEqual(backend.cancelledLoadCount, 1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(observationCount, 0)
        XCTAssertEqual(finishCount, 0)
        XCTAssertNil(controller.recoverableFault)
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertTrue(controller.completed)
        let retainedQueue = try await store.podcastQueueState()
        XCTAssertEqual(retainedQueue, queue)
    }

    func testCorruptSelectionPreservesActivePlaybackAndCurrentQueueIdentity() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let playing = try await queueRevision(index: 1, root: root, store: store)
        let corrupt = try await queueRevision(index: 2, root: root, store: store)
        let queue = try PodcastQueueState(
            episodeIDs: [playing.revision.itemID, corrupt.revision.itemID],
            currentEpisodeID: playing.revision.itemID
        )
        try await store.replacePodcastQueue(queue)
        let backend = FakeBackend()
        backend.failingURLs.insert(corrupt.mediaURL)
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        try controller.play()

        do {
            try await controller.selectPodcastQueueEpisode(corrupt.revision.itemID, autoplay: true)
            XCTFail("expected corrupt media selection to fail")
        } catch {
            XCTAssertEqual(error as? PlaybackControllerError, .podcastMediaUnreadable(corrupt.revision.itemID))
        }

        XCTAssertEqual(controller.itemID, playing.revision.itemID)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(backend.isPlaying)
        let retainedQueue = try await store.podcastQueueState()
        XCTAssertEqual(retainedQueue, queue)
    }

    func testRestorePublishesMissingCurrentMediaFault() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let missing = try await queueRevision(index: 8, root: root, store: store)
        try FileManager.default.removeItem(at: missing.mediaURL)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [missing.revision.itemID], currentEpisodeID: missing.revision.itemID
        ))
        let controller = PlaybackController(store: store, backend: FakeBackend())
        var observation: (ItemID?, PlaybackControllerError?)?
        controller.podcastStateHandler = { observation = ($0, $1) }

        await controller.restorePodcastQueue()

        XCTAssertEqual(observation?.0, missing.revision.itemID)
        XCTAssertEqual(observation?.1, .podcastMediaUnavailable(missing.revision.itemID))
        XCTAssertEqual(controller.recoverableFault, observation?.1)
    }

    func testRateAndVolumeUseDeterministicBackendSeams() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let backend = FakeBackend()
        let controller = PlaybackController(store: try LocalLibraryStore(url: path), backend: backend)
        controller.setRate(1.5)
        controller.setVolume(0.4)
        XCTAssertEqual(backend.rate, 1.5)
        XCTAssertEqual(backend.volume, 0.4)
    }

    func testPodcastSpeedRestoresAppliesAndDefaultsPerEpisode() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store)
        let second = try await queueRevision(index: 2, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        try await store.save(playbackSpeed: PodcastPlaybackSpeed(
            itemID: first.revision.itemID, speed: 1.75, updatedAt: Timestamp(Date())
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)

        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.playbackRate, 1.75)
        XCTAssertEqual(backend.rate, 1.75)

        try await controller.selectPodcastQueueEpisode(second.revision.itemID)
        XCTAssertEqual(controller.playbackRate, 1, "an episode without a preference must not inherit another episode's speed")
        controller.setRate(.infinity)
        XCTAssertEqual(controller.playbackRate, 1)
        controller.setRate(4)
        XCTAssertEqual(controller.playbackRate, 2)
        controller.setRate(0.1)
        XCTAssertEqual(controller.playbackRate, 0.5)
    }

    func testDefaultRateAppliesWhereNoEpisodeSpeedIsSaved() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let remembered = try await queueRevision(index: 1, root: root, store: store)
        let fresh = try await queueRevision(index: 2, root: root, store: store)
        try await store.save(playbackSpeed: PodcastPlaybackSpeed(
            itemID: remembered.revision.itemID, speed: 1.75, updatedAt: Timestamp(Date())
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        controller.defaultRate = 1.25

        try await controller.selectPodcastQueueEpisode(fresh.revision.itemID)
        XCTAssertEqual(controller.playbackRate, 1.25, "a first play starts at the owner's default, not 1×")
        try await controller.selectPodcastQueueEpisode(remembered.revision.itemID)
        XCTAssertEqual(controller.playbackRate, 1.75, "an episode's own saved speed still wins")

        let (_, article) = try fixture()
        try await controller.load(revision: article, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        XCTAssertEqual(controller.playbackRate, 1.25, "articles start at the default too")

        controller.defaultRate = 9
        XCTAssertEqual(controller.defaultRate, 2, "the default is clamped like any other rate")
    }

    func testDirectSeekClampsUsesLivePositionAndFencesOldRunCompletion() async throws {
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
        await controller.restorePodcastQueue()
        backend.currentTime = 10

        try await controller.seekForward(seconds: 30)
        XCTAssertEqual(controller.positionSeconds, 40, "relative seeks must use the live engine position")
        let oldGeneration = backend.loadedGeneration
        let oldSession = controller.sessionID
        try await controller.seek(to: -100)
        XCTAssertEqual(controller.positionSeconds, 0)
        XCTAssertNotEqual(controller.sessionID, oldSession)
        XCTAssertGreaterThan(backend.loadedGeneration, oldGeneration)

        backend.finish(generation: oldGeneration, successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertFalse(controller.completed)

        try await controller.seek(to: 500)
        XCTAssertEqual(controller.positionSeconds, 42)
        await XCTAssertThrowsErrorAsync(try await controller.seek(to: .nan)) { error in
            guard case .invalidSeek = error as? PlaybackControllerError else {
                return XCTFail("expected invalid seek, got \(error)")
            }
        }
    }

    func testDefaultForwardSeekAdvancesThirtySeconds() async throws {
        let path = storeURL()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let backend = FakeBackend()
        let controller = PlaybackController(store: try LocalLibraryStore(url: path), backend: backend)
        let (_, revision) = try fixture()
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        backend.currentTime = 5

        try await controller.seekForward()

        XCTAssertEqual(controller.positionSeconds, 35)
    }

    func testExplicitRestartAllowsSecondExactlyOnceCompletionAndRejectsOldCallbacks() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 5, root: root, store: store)
        let second = try await queueRevision(index: 6, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID], currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()

        let firstRunGeneration = backend.loadedGeneration
        backend.finish(successfully: true)
        await waitUntil { controller.completed }
        XCTAssertEqual(controller.itemID, first.revision.itemID)

        try await controller.restart()
        let restartedGeneration = backend.loadedGeneration
        XCTAssertGreaterThan(restartedGeneration, firstRunGeneration)
        XCTAssertFalse(controller.completed)
        XCTAssertEqual(controller.positionSeconds, 0)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))

        backend.finish(generation: firstRunGeneration, successfully: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, first.revision.itemID)

        backend.finish(generation: restartedGeneration, successfully: true)
        backend.finish(generation: restartedGeneration, successfully: true)
        await waitUntil { controller.itemID == second.revision.itemID }
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        XCTAssertEqual(backend.loadCount, 3, "the restarted run may advance only once")
    }

    func testPreviousAndNextQueueSelectionPreserveCurrentIdentity() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 7, root: root, store: store)
        let second = try await queueRevision(index: 8, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID],
            currentEpisodeID: second.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()

        let selectedPrevious = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertTrue(selectedPrevious)
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertTrue(backend.isPlaying)
        let previousState = try await store.podcastQueueState()
        XCTAssertEqual(previousState.currentEpisodeID, first.revision.itemID)

        let selectedNext = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertTrue(selectedNext)
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        let nextState = try await store.podcastQueueState()
        XCTAssertEqual(nextState.currentEpisodeID, second.revision.itemID)
        let selectedPastEnd = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertFalse(selectedPastEnd)
        XCTAssertEqual(controller.itemID, second.revision.itemID)
    }

    func testQueueRelaunchRestoresCurrentIdentityWithoutDuplicateSession() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let revision = try await queueRevision(index: 5, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [revision.revision.itemID], currentEpisodeID: revision.revision.itemID
        ))
        let prior = try PlaybackState(
            itemID: revision.revision.itemID, revisionID: revision.revision.revisionID,
            sessionID: "podcast-session", sequence: 2, positionSeconds: 9, durationSeconds: 42,
            completed: false, intent: .progress, deviceID: "mac", updatedAt: Timestamp(Date())
        )
        try await store.save(playback: prior)
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, revision.revision.itemID)
        XCTAssertEqual(controller.sessionID, prior.sessionID)
        XCTAssertEqual(controller.positionSeconds, 9)
        XCTAssertEqual(backend.loadCount, 1)
    }

    private func queueRevision(index: Int, root: URL, store: LocalLibraryStore) async throws -> StoredAudioRevision {
        // Truncated, because the digits of a two-digit index repeated 64 times
        // is a 128-character identifier the store rejects. Single-digit indexes
        // are unchanged by the truncation.
        let seed = String(String(repeating: String(index), count: 64).prefix(64))
        let itemID = try ItemID(rawValue: "item-" + seed)
        let revision = try AudioRevision(
            itemID: itemID, revisionID: RevisionID(rawValue: "podcast-\(index)"), durationSeconds: 42,
            byteCount: 1, contentHash: "sha256:" + seed,
            mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1
        )
        let url = root.appendingPathComponent("podcast-\(index).mp3")
        _ = FileManager.default.createFile(atPath: url.path, contents: Data([UInt8(index % 256)]))
        try await store.saveReadyRevision(revision, mediaURL: url)
        return StoredAudioRevision(revision: revision, mediaURL: url)
    }

    /// `AVAudioPlayerBackend` keys its generation map on `ObjectIdentifier`, which
    /// is the player's address, so an entry that outlives its player can be matched
    /// by a later player allocated at the same address and report a superseded
    /// generation. Only natural completion used to prune, which left an entry behind
    /// for every superseded load and every explicit stop.
    func testBackendDoesNotRetainGenerationKeysForPlayersItNoLongerOwns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-generation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makePlayableAudio(at: directory.appendingPathComponent("first.m4a"))
        let second = try makePlayableAudio(at: directory.appendingPathComponent("second.m4a"))

        let backend = AVAudioPlayerBackend()
        XCTAssertEqual(backend.trackedGenerationCount, 0)

        try backend.load(url: first)
        XCTAssertEqual(backend.trackedGenerationCount, 1)
        XCTAssertEqual(backend.loadedGeneration, 1)

        try backend.load(url: second)
        XCTAssertEqual(backend.trackedGenerationCount, 1, "superseded player must not keep its generation entry")
        XCTAssertEqual(backend.loadedGeneration, 2, "generations stay monotonic across loads")

        backend.stop()
        XCTAssertEqual(backend.trackedGenerationCount, 0, "stop must not leave the stopped player's entry behind")

        try backend.load(url: first)
        backend.stop()
        try backend.load(url: second)
        backend.stop()
        XCTAssertEqual(backend.trackedGenerationCount, 0, "repeated load/stop cycles must not accumulate entries")
        XCTAssertEqual(backend.loadedGeneration, 4)
    }

    /// A load failure leaves the backend owning the player it already had, so its
    /// generation entry has to survive.
    func testFailedLoadKeepsTheExistingPlayersGenerationEntry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-generation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playable = try makePlayableAudio(at: directory.appendingPathComponent("playable.m4a"))
        let unreadable = directory.appendingPathComponent("missing.m4a")

        let backend = AVAudioPlayerBackend()
        try backend.load(url: playable)
        XCTAssertEqual(backend.trackedGenerationCount, 1)
        XCTAssertThrowsError(try backend.load(url: unreadable))
        XCTAssertEqual(backend.trackedGenerationCount, 1, "a throwing load must not drop the live player's entry")
        XCTAssertEqual(backend.loadedGeneration, 1, "a throwing load must not consume a generation")
    }

    private func makePlayableAudio(at url: URL) throws -> URL {
        let samples = (0..<4_410).map { index in
            Float(0.2 * sin(2 * Double.pi * 220 * Double(index) / 44_100))
        }
        _ = try AudioAssembler().assemble(
            pcm: samples,
            itemID: try ItemID(rawValue: "item-" + String(repeating: "9", count: 64)),
            destinationURL: url,
            extractedTextSHA256: String(repeating: "a", count: 64),
            voiceID: "voice-test",
            synthesisSettingsCanonicalJSON: "{}"
        )
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: @autoclosure () async throws -> Void,
        _ errorHandler: (Error) -> Void
    ) async {
        do {
            try await expression()
            XCTFail("expected error")
        } catch {
            errorHandler(error)
        }
    }
}

private extension LocalLibraryStore {
    /// Holds the store actor so completion must suspend at its checkpoint.
    func holdPlaybackStoreForTesting(entered: @Sendable () -> Void, release: DispatchSemaphore) {
        entered()
        release.wait()
    }
}
