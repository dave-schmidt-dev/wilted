import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
extension PlaybackControllerTests {
    func testPlayNowMovesFarTargetBeforeCurrentPreservesCheckpointAndKeepsPreviousNextSemantics() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store)
        let second = try await queueRevision(index: 2, root: root, store: store)
        let third = try await queueRevision(index: 3, root: root, store: store)
        let fourth = try await queueRevision(index: 9, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID, third.revision.itemID, fourth.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        try controller.play()
        backend.currentTime = 17

        try await controller.playPodcastQueueEpisodeNow(fourth.revision.itemID)

        let reordered = try await store.podcastQueueState()
        XCTAssertEqual(reordered.episodeIDs, [
            fourth.revision.itemID, first.revision.itemID, second.revision.itemID, third.revision.itemID,
        ])
        XCTAssertEqual(reordered.currentEpisodeID, fourth.revision.itemID)
        XCTAssertEqual(controller.itemID, fourth.revision.itemID)
        XCTAssertTrue(backend.isPlaying)
        let firstCheckpoint = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        XCTAssertEqual(firstCheckpoint?.positionSeconds, 17, "Play Now must retain the displaced episode's live checkpoint")

        let selectedNext = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertTrue(selectedNext)
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        let selectedPrevious = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertTrue(selectedPrevious)
        XCTAssertEqual(controller.itemID, fourth.revision.itemID)
        let orderBeforeCurrentSelection = try await store.podcastQueueState()
        try await controller.playPodcastQueueEpisodeNow(fourth.revision.itemID)
        let orderAfterCurrentSelection = try await store.podcastQueueState()
        XCTAssertEqual(orderAfterCurrentSelection, orderBeforeCurrentSelection,
                       "playing the current episode now must not reorder the queue")
    }

    func testPlayNowForUnqueuedEpisodeInsertsBeforeCurrent() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 4, root: root, store: store)
        let second = try await queueRevision(index: 5, root: root, store: store)
        let third = try await queueRevision(index: 6, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let controller = PlaybackController(store: store, backend: FakeBackend())
        await controller.restorePodcastQueue()

        try await controller.playPodcastQueueEpisodeNow(second.revision.itemID)

        let state = try await store.podcastQueueState()
        XCTAssertEqual(state.episodeIDs, [second.revision.itemID, first.revision.itemID, third.revision.itemID])
        XCTAssertEqual(state.currentEpisodeID, second.revision.itemID)
        XCTAssertTrue(state.episodeIDs.contains(first.revision.itemID), "the displaced current episode stays queued")
    }

    func testPlayNowLoadFailureLeavesDurableQueueAndCurrentUnchanged() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 7, root: root, store: store)
        let missing = try await queueRevision(index: 8, root: root, store: store)
        let original = try PodcastQueueState(
            episodeIDs: [first.revision.itemID, missing.revision.itemID],
            currentEpisodeID: first.revision.itemID
        )
        try await store.replacePodcastQueue(original)
        try FileManager.default.removeItem(at: missing.mediaURL)
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        try controller.play()

        await XCTAssertThrowsErrorAsync(
            try await controller.playPodcastQueueEpisodeNow(missing.revision.itemID)
        ) { error in
            XCTAssertEqual(error as? PlaybackControllerError, .podcastMediaUnavailable(missing.revision.itemID))
        }

        let retained = try await store.podcastQueueState()
        XCTAssertEqual(retained, original)
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertTrue(backend.isPlaying)
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

    func testManualNextAtNinetyFivePercentCompletesOutgoingPodcastAfterAdvancing() async throws {
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
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var completedEpisodes: [ItemID] = []
        controller.podcastCompletionHandler = { completedEpisodes.append($0) }
        await controller.restorePodcastQueue()
        backend.currentTime = 42 * 0.95

        let selected = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertTrue(selected)
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.currentEpisodeID, second.revision.itemID)
        let playback = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        XCTAssertEqual(playback?.positionSeconds, 42)
        XCTAssertTrue(playback?.completed == true)
        let listening = try await store.listeningState(for: first.revision.itemID)
        XCTAssertNotNil(listening?.completedAt)
        XCTAssertEqual(listening?.lastRevisionID, first.revision.revisionID)
        XCTAssertEqual(completedEpisodes, [first.revision.itemID],
                       "retirement is requested only after the successor is durable")
    }

    func testManualNextBelowNinetyFivePercentKeepsOutgoingPodcastResumable() async throws {
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
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        backend.currentTime = 42 * 0.949

        let selected = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertTrue(selected)
        let playback = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        XCTAssertEqual(try XCTUnwrap(playback?.positionSeconds), 42 * 0.949, accuracy: 0.0001)
        XCTAssertFalse(playback?.completed == true)
        let listening = try await store.listeningState(for: first.revision.itemID)
        XCTAssertNil(listening)
    }

    func testManualNextAtNinetyFivePercentWithNoSuccessorDoesNotComplete() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let only = try await queueRevision(index: 1, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [only.revision.itemID], currentEpisodeID: only.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var completionCalls = 0
        controller.podcastCompletionHandler = { _ in completionCalls += 1 }
        await controller.restorePodcastQueue()
        backend.currentTime = 42 * 0.95

        let selected = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertFalse(selected)
        XCTAssertEqual(controller.itemID, only.revision.itemID)
        let listening = try await store.listeningState(for: only.revision.itemID)
        XCTAssertNil(listening)
        XCTAssertEqual(completionCalls, 0)
    }

    func testManualNextFailedSuccessorPreservesOutgoingProgressWithoutCompletion() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store)
        let second = try await queueRevision(index: 2, root: root, store: store)
        let queue = try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID],
            currentEpisodeID: first.revision.itemID
        )
        try await store.replacePodcastQueue(queue)
        let backend = FakeBackend()
        backend.failingURLs.insert(second.mediaURL)
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        backend.currentTime = 42 * 0.95

        do {
            _ = try await controller.selectNextPodcastQueueEpisode()
            XCTFail("expected corrupt successor selection to fail")
        } catch {
            XCTAssertEqual(error as? PlaybackControllerError, .podcastMediaUnreadable(second.revision.itemID))
        }
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        let retainedQueue = try await store.podcastQueueState()
        XCTAssertEqual(retainedQueue, queue)
        let playback = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        XCTAssertEqual(try XCTUnwrap(playback?.positionSeconds), 42 * 0.95, accuracy: 0.0001)
        XCTAssertFalse(playback?.completed == true)
        let listening = try await store.listeningState(for: first.revision.itemID)
        XCTAssertNil(listening)
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
}
