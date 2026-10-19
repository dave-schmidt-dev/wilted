import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
extension PlaybackControllerTests {
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
        var completionCalls: [ItemID] = []
        controller.podcastStateHandler = { item, fault in observedItem = item; observedFault = fault }
        controller.playbackDidFinishHandler = { finishCount += 1 }
        controller.podcastCompletionHandler = { completionCalls.append($0) }
        await controller.restorePodcastQueue()
        backend.finish(successfully: true)
        await waitUntil { finishCount == 1 }
        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.recoverableFault, .podcastMediaUnavailable(missing.revision.itemID))
        XCTAssertEqual(observedFault, controller.recoverableFault)
        XCTAssertEqual(observedItem, first.revision.itemID,
                       "a next-media fault must retain the completed item's UI identity")
        XCTAssertEqual(completionCalls, [first.revision.itemID],
                       "a successor-load throw must not skip retirement of the item that actually finished")
        let retainedState = try await store.podcastQueueState()
        XCTAssertEqual(retainedState, state)

        _ = FileManager.default.createFile(atPath: missing.mediaURL.path, contents: Data([4]))
        let corruptBackend = FakeBackend()
        corruptBackend.failingURLs.insert(missing.mediaURL)
        let corruptController = PlaybackController(store: store, backend: corruptBackend)
        var corruptObservedItem: ItemID?
        var corruptObservedFault: PlaybackControllerError?
        var corruptFinishCount = 0
        var corruptCompletionCalls: [ItemID] = []
        corruptController.playbackDidFinishHandler = { corruptFinishCount += 1 }
        corruptController.podcastStateHandler = { item, fault in
            corruptObservedItem = item; corruptObservedFault = fault
        }
        corruptController.podcastCompletionHandler = { corruptCompletionCalls.append($0) }
        await corruptController.restorePodcastQueue()
        corruptBackend.finish(successfully: true)
        await waitUntil { corruptFinishCount == 1 }
        XCTAssertEqual(corruptFinishCount, 1)
        XCTAssertFalse(corruptController.isPlaying)
        XCTAssertEqual(corruptController.recoverableFault, .podcastMediaUnreadable(missing.revision.itemID))
        XCTAssertEqual(corruptObservedItem, first.revision.itemID)
        XCTAssertEqual(corruptObservedFault, .podcastMediaUnreadable(missing.revision.itemID))
        XCTAssertEqual(corruptCompletionCalls, [first.revision.itemID],
                       "retirement must still fire on the second successor-load throw")
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

    func testCompletionWithABCSkipsUnpreparedBAndFailsDeterministicallyWhenCMediaMissing() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store, prepared: true)
        let second = try await queueRevision(index: 2, root: root, store: store, prepared: false)
        let third = try await queueRevision(index: 3, root: root, store: store, prepared: true)
        try FileManager.default.removeItem(at: third.mediaURL)
        let initialQueue = try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        )
        try await store.replacePodcastQueue(initialQueue)
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var finishCount = 0
        var observedItem: ItemID?
        var observedFault: PlaybackControllerError?
        controller.playbackDidFinishHandler = { finishCount += 1 }
        controller.podcastStateHandler = { item, fault in
            observedItem = item
            observedFault = fault
        }
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertEqual(backend.loadCount, 1)

        backend.finish(successfully: true)
        await waitUntil { finishCount == 1 }

        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(backend.loadCount, 1, "neither B nor C was loaded into the backend")
        XCTAssertEqual(controller.recoverableFault, .podcastMediaUnavailable(third.revision.itemID))
        XCTAssertEqual(observedFault, .podcastMediaUnavailable(third.revision.itemID))
        XCTAssertEqual(observedItem, first.revision.itemID, "completed item identity retained on fault")
        let retainedQueue = try await store.podcastQueueState()
        XCTAssertEqual(retainedQueue, initialQueue)
    }
}
