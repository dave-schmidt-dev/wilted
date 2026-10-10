import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
extension PlaybackControllerTests {
    /// An item loaded with `load` (a playlist entry, an article) is outside the queue even when the
    /// queue's current item is the same episode: finishing it announces the stop and leaves the
    /// durable queue untouched instead of advancing it.
    func testCompletionOfANonPodcastLoadNeverAdvancesTheQueue() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 61, root: root, store: store)
        let second = try await queueRevision(index: 62, root: root, store: store)
        let queue = try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID], currentEpisodeID: first.revision.itemID)
        try await store.replacePodcastQueue(queue)

        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var finishes = 0
        var observed: [ItemID?] = []
        controller.playbackDidFinishHandler = { finishes += 1 }
        controller.podcastStateHandler = { id, _ in observed.append(id) }
        try await controller.load(first)

        backend.finish(successfully: true)
        await waitUntil { finishes == 1 }

        XCTAssertEqual(finishes, 1, "the stop is announced")
        XCTAssertTrue(observed.isEmpty, "no queue advance is observed")
        XCTAssertEqual(controller.itemID, first.revision.itemID, "the successor is not loaded")
        let after = try await store.podcastQueueState()
        XCTAssertEqual(after.episodeIDs, queue.episodeIDs)
        XCTAssertEqual(after.currentEpisodeID, queue.currentEpisodeID)
    }
}
