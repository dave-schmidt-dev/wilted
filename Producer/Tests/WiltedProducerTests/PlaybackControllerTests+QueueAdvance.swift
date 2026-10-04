import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// The natural-completion queue advance in `PlaybackController`: an explicit
/// pause issued after the end holds it, and a successor removed after the
/// lookup is skipped without wrapping. Shared fixtures (`FakeBackend`,
/// `storeURL`, `queueRevision`, `waitUntil`) live in
/// `PlaybackControllerTests.swift`.
@MainActor
extension PlaybackControllerTests {
    /// A Pause after the end, before the queue advance loads, drops the
    /// advance: the finished episode stays loaded, paused and current. One
    /// issued while the successor loads leaves it loaded but not started.
    func testAPauseAfterTheEndHoldsTheQueueAdvance() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (ids, backend, controller, log) = try await advanceRig([31, 32, 33], root: root, store: store)
        backend.finish(successfully: true)
        try await controller.pause()
        await waitUntil { log.completions == [ids[0]] }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.itemID, ids[0], "the advance is dropped before it loads")
        XCTAssertFalse(backend.isPlaying)
        XCTAssertTrue(log.observed.isEmpty && log.finishes == 0, "nothing is announced")
        var held = try await store.podcastQueueState()
        XCTAssertEqual(held.currentEpisodeID, ids[0])

        let (later, laterBackend, laterController, laterLog) = try await advanceRig(
            [34, 35, 36], root: root, store: store)
        var asks = 0
        laterController.episodeEligibilityPredicate = { [unowned laterController] id in
            if id == later[1] { asks += 1; if asks == 2 { try? await laterController.pause() } }
            return true
        }
        laterBackend.finish(successfully: true)
        await waitUntil { !laterLog.observed.isEmpty }
        XCTAssertEqual(laterController.itemID, later[1], "a pause during the load keeps the successor loaded")
        XCTAssertFalse(laterBackend.isPlaying, "but does not start it")
        held = try await store.podcastQueueState()
        XCTAssertEqual(held.currentEpisodeID, later[1])
        XCTAssertEqual(laterLog.completions, [later[0]])
    }

    /// A successor removed after the lookup chose it is skipped for the next
    /// eligible entry; with none after it the run stops rather than wrapping,
    /// and an explicit play of the removed entry still reports it.
    func testAnEntryRemovedAfterTheLookupIsSkippedAndTheRunNeverWraps() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        for (indices, removed, expected) in [([41, 42, 43], 1, 2), ([44, 45, 46], 2, 1)] {
            let current = indices.count - expected == 1 ? 0 : 1
            let (ids, backend, controller, log) = try await advanceRig(
                indices, current: current, root: root, store: store)
            var dismissed = false
            controller.episodeEligibilityPredicate = { id in
                if id == ids[removed], !dismissed { dismissed = true; _ = try? await store.dismissPodcastEpisode(id) }
                return true
            }
            backend.finish(successfully: true)
            await waitUntil { !log.observed.isEmpty }
            XCTAssertTrue(dismissed)
            XCTAssertEqual(controller.itemID, ids[expected])
            XCTAssertEqual(backend.isPlaying, expected != current, "plays the skipped-to entry, nothing at the end")
            XCTAssertEqual(log.completions, [ids[current]])
            if expected == current {
                XCTAssertEqual(log.observed, [ids[current]], "no wrap to the entry before it")
                XCTAssertEqual(log.faults, [.podcastMediaUnavailable(ids[removed])])
                XCTAssertEqual(log.finishes, 1)
            } else {
                XCTAssertEqual(log.observed, [ids[expected]])
                XCTAssertEqual(log.finishes, 0)
            }
            await XCTAssertThrowsErrorAsync(try await controller.playPodcastQueueEpisodeNow(ids[removed])) {
                XCTAssertEqual($0 as? PlaybackControllerError, .podcastMediaUnavailable(ids[removed]))
            }
        }
    }

    private func advanceRig(
        _ indices: [Int], current: Int = 0, root: URL, store: LocalLibraryStore
    ) async throws -> ([ItemID], FakeBackend, PlaybackController, AdvanceLog) {
        var ids: [ItemID] = []
        for index in indices { ids.append(try await queueRevision(index: index, root: root, store: store).revision.itemID) }
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: ids, currentEpisodeID: ids[current]))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        let log = AdvanceLog()
        controller.podcastStateHandler = { id, fault in log.observed.append(id); if let fault { log.faults.append(fault) } }
        controller.playbackDidFinishHandler = { log.finishes += 1 }
        controller.podcastCompletionHandler = { log.completions.append($0) }
        await controller.restorePodcastQueue()
        try controller.play()
        return (ids, backend, controller, log)
    }
}

/// What a queue advance announced, in order.
@MainActor
final class AdvanceLog {
    var observed: [ItemID?] = []
    var faults: [PlaybackControllerError] = []
    var finishes = 0
    var completions: [ItemID] = []
}
