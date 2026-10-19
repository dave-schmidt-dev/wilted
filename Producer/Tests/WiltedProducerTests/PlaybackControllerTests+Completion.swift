import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
extension PlaybackControllerTests {
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
        var completionCalls: [ItemID] = []
        controller.podcastCompletionHandler = { completionCalls.append($0) }
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
        XCTAssertTrue(completionCalls.isEmpty, "a failed callback must not write a listening completion either")
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
        XCTAssertEqual(completionCalls, [first.revision.itemID],
                       "the auto-advance path writes the listening completion exactly once, for the episode that finished")
        let firstListening = try await store.listeningState(for: first.revision.itemID)
        XCTAssertNotNil(firstListening?.completedAt)
        XCTAssertEqual(firstListening?.lastRevisionID, first.revision.revisionID)
        let firstRetiredAt = try await store.retiredAt(for: first.revision.itemID)
        XCTAssertNil(firstRetiredAt, "the controller writes the listening fact only -- retirement is the model's job")

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

    func testArticleCompletionEmitsNoPodcastObservationWhilePodcastNoNextDoes() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (_, articleRevision) = try fixture()
        let articleBackend = FakeBackend()
        let articleController = PlaybackController(store: store, backend: articleBackend)
        var articleObservations: [ItemID?] = []
        var articleCompletionCalls: [ItemID] = []
        articleController.podcastStateHandler = { itemID, _ in articleObservations.append(itemID) }
        articleController.podcastCompletionHandler = { articleCompletionCalls.append($0) }
        try await articleController.load(
            revision: articleRevision, mediaURL: root.appendingPathComponent("article.m4a")
        )

        articleBackend.finish(successfully: true)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(articleObservations.isEmpty)
        XCTAssertTrue(articleController.completed)
        XCTAssertTrue(articleCompletionCalls.isEmpty, "an article completion must never write a podcast listening fact")
        let articleListening = try await store.listeningState(for: articleRevision.itemID)
        XCTAssertNil(articleListening)

        let podcast = try await queueRevision(index: 9, root: root, store: store)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [podcast.revision.itemID], currentEpisodeID: podcast.revision.itemID
        ))
        let podcastBackend = FakeBackend()
        let podcastController = PlaybackController(store: store, backend: podcastBackend)
        var podcastObservations: [ItemID?] = []
        var podcastCompletionCalls: [ItemID] = []
        podcastController.podcastStateHandler = { itemID, _ in podcastObservations.append(itemID) }
        podcastController.podcastCompletionHandler = { podcastCompletionCalls.append($0) }
        await podcastController.restorePodcastQueue()

        podcastBackend.finish(successfully: true)
        await waitUntil { podcastObservations.last == podcast.revision.itemID }

        XCTAssertEqual(podcastObservations, [podcast.revision.itemID])
        XCTAssertEqual(podcastCompletionCalls, [podcast.revision.itemID],
                       "a podcast completion with nothing behind it still writes the listening fact")
        let podcastListening = try await store.listeningState(for: podcast.revision.itemID)
        XCTAssertNotNil(podcastListening?.completedAt)
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
}

private extension LocalLibraryStore {
    /// Holds the store actor so completion must suspend at its checkpoint.
    func holdPlaybackStoreForTesting(entered: @Sendable () -> Void, release: DispatchSemaphore) {
        entered()
        release.wait()
    }
}
