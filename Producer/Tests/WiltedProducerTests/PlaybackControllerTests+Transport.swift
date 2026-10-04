import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// Transport, start and route-recovery coverage for `PlaybackController`:
/// resume on load, play/pause, seeking, rewind and restart sessions, retry
/// after a backend failure, and rebuilding after an audio route change.
/// Shared fixtures (`FakeBackend`, `storeURL`, `fixture`, `queueRevision`,
/// `waitUntil`) live in `PlaybackControllerTests.swift`.
@MainActor
extension PlaybackControllerTests {
    func testPauseThenNewControllerResumesMatchingRevision() async throws {
        let path = storeURL(); defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
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
        backend.currentTime = 18
        try await controller.checkpoint()
        let rewoundState = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        let rewoundCheckpoint = try XCTUnwrap(rewoundState)
        XCTAssertEqual(rewoundCheckpoint.intent, .rewind, "durable checkpoints retain the explicit session intent")

        backend.finish(successfully: false)
        await waitUntil { finishCount == 2 }
        try await controller.restart()
        XCTAssertNil(controller.recoverableFault)
        XCTAssertEqual(backend.loadCount, 3)
        try controller.play()
        XCTAssertEqual(backend.loadCount, 3, "restart already restored a valid backend generation")
        XCTAssertEqual(backend.currentTime, 0)
        backend.currentTime = 3
        try await controller.checkpoint()
        let restartedState = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        let restartedCheckpoint = try XCTUnwrap(restartedState)
        XCTAssertEqual(restartedCheckpoint.intent, .restart, "durable checkpoints retain the explicit session intent")
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
}
