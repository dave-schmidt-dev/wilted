import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
extension PlaybackControllerTests {
    func testManualNextWithABCSkipsUnpreparedBAndAdvancesToC() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store, prepared: true)
        let second = try await queueRevision(index: 2, root: root, store: store, prepared: false)
        let third = try await queueRevision(index: 3, root: root, store: store, prepared: true)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertEqual(backend.loadCount, 1)

        let selected = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertTrue(selected)
        XCTAssertEqual(controller.itemID, third.revision.itemID, "manual Next must skip unprepared B and select C")
        XCTAssertEqual(backend.loadCount, 2, "unprepared B must never be loaded into the backend")
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, third.revision.itemID)
    }

    func testCompletionWithABCSkipsUnpreparedBAndAdvancesToC() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store, prepared: true)
        let second = try await queueRevision(index: 2, root: root, store: store, prepared: false)
        let third = try await queueRevision(index: 3, root: root, store: store, prepared: true)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var observations: [ItemID?] = []
        controller.podcastStateHandler = { itemID, _ in observations.append(itemID) }
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertEqual(backend.loadCount, 1)

        backend.finish(successfully: true)
        await waitUntil { observations.last == third.revision.itemID }

        XCTAssertEqual(controller.itemID, third.revision.itemID, "completion must skip unprepared B and advance to C")
        XCTAssertEqual(backend.loadCount, 2, "unprepared B must never be loaded into the backend")
        XCTAssertEqual(observations.last, third.revision.itemID)
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, third.revision.itemID)
    }

    func testCompletionWithABCSkipsRetiredReadyBAndAdvancesToC() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let feedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/feed.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "The Wilted Show",
            author: "Wilted", artworkURL: nil, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
        )
        try await store.save(feed: feed)

        let secondEnclosure = try XCTUnwrap(URL(string: "https://podcasts.example.test/audio/episode-2.mp3"))
        let secondID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-2", enclosureURL: secondEnclosure)
        let secondEpisode = try PodcastEpisode(
            itemID: secondID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-2",
            title: "Episode 2", enclosureURL: secondEnclosure, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200))
        )
        try await store.save(episode: secondEpisode)

        let first = try await queueRevision(index: 1, root: root, store: store, prepared: true)
        let second = try await queueRevision(index: 2, root: root, store: store, prepared: true, itemID: secondID)
        let third = try await queueRevision(index: 3, root: root, store: store, prepared: true)

        let retired = try await store.retireEpisode(secondID)
        XCTAssertTrue(retired)
        let retiredAtBefore = try await store.retiredAt(for: secondID)
        XCTAssertNotNil(retiredAtBefore)

        let now = Timestamp(Date())
        let playback = try PlaybackState(
            itemID: secondID,
            revisionID: second.revision.revisionID,
            sessionID: "session-2",
            sequence: 1,
            positionSeconds: 42,
            durationSeconds: 42,
            completed: true,
            intent: .progress,
            deviceID: "device-1",
            updatedAt: now
        )
        try await store.save(playback: playback, listening: PodcastListeningState(
            episodeID: secondID,
            completedAt: now,
            lastRevisionID: second.revision.revisionID,
            updatedAt: now
        ))

        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, secondID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))

        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        controller.episodeEligibilityPredicate = { _ in true }

        var observations: [ItemID?] = []
        controller.podcastStateHandler = { itemID, _ in observations.append(itemID) }
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertEqual(backend.loadCount, 1)

        backend.finish(successfully: true)
        await waitUntil { observations.last == third.revision.itemID }

        XCTAssertEqual(controller.itemID, third.revision.itemID, "completion must skip retired ready B and advance to C")
        XCTAssertEqual(backend.loadCount, 2, "retired ready B must never be loaded into the backend")
        XCTAssertEqual(observations.last, third.revision.itemID)
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, third.revision.itemID)

        do {
            try await controller.playPodcastQueueEpisodeNow(secondID)
            XCTFail("playPodcastQueueEpisodeNow must reject retired B")
        } catch {
            // Expected
        }
        do {
            try await controller.selectPodcastQueueEpisode(secondID)
            XCTFail("selectPodcastQueueEpisode must reject retired B")
        } catch {
            // Expected
        }

        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [secondID, third.revision.itemID],
            currentEpisodeID: secondID
        ))
        let controller2 = PlaybackController(store: store, backend: FakeBackend())
        controller2.episodeEligibilityPredicate = { _ in true }
        await controller2.restorePodcastQueue()
        XCTAssertNil(controller2.itemID, "queue restore must not load retired B")

        let restored = try await store.restoreEpisode(secondID)
        XCTAssertTrue(restored)
        // W-INV-025: retiring B reclaimed its audio and revision, so the
        // restored episode needs its audio downloaded again before it can load.
        _ = try await queueRevision(index: 2, root: root, store: store, prepared: true, itemID: secondID)
        let retiredAtAfter = try await store.retiredAt(for: secondID)
        XCTAssertNil(retiredAtAfter)
        let removalKindAfter = try await store.removalKind(for: secondID)
        XCTAssertNil(removalKindAfter)
        let eligibleAfterRestore = try await controller2.isEpisodeEligible(secondID)
        XCTAssertTrue(eligibleAfterRestore, "restored B must be eligible even if completedAt is set in listening history")

        try await controller2.selectPodcastQueueEpisode(secondID)
        XCTAssertEqual(controller2.itemID, secondID, "restored B must now load into controller")
    }

    func testManualNextWithABCSkipsRetiredReadyBAndAdvancesToC() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let feedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/feed.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "The Wilted Show",
            author: "Wilted", artworkURL: nil, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
        )
        try await store.save(feed: feed)

        let secondEnclosure = try XCTUnwrap(URL(string: "https://podcasts.example.test/audio/episode-2.mp3"))
        let secondID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-2", enclosureURL: secondEnclosure)
        let secondEpisode = try PodcastEpisode(
            itemID: secondID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-2",
            title: "Episode 2", enclosureURL: secondEnclosure, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200))
        )
        try await store.save(episode: secondEpisode)

        let first = try await queueRevision(index: 1, root: root, store: store, prepared: true)
        _ = try await queueRevision(index: 2, root: root, store: store, prepared: true, itemID: secondID)
        let third = try await queueRevision(index: 3, root: root, store: store, prepared: true)

        try await store.retireEpisode(secondID)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, secondID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))

        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        controller.episodeEligibilityPredicate = { _ in true }
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertEqual(backend.loadCount, 1)

        let selected = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertTrue(selected)
        XCTAssertEqual(controller.itemID, third.revision.itemID, "manual Next must skip retired B and select C")
        XCTAssertEqual(backend.loadCount, 2, "retired B must never be loaded into the backend")
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, third.revision.itemID)
    }

    func testManualPreviousWithABCSkipsUnpreparedBAndAdvancesToA() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store, prepared: true)
        let second = try await queueRevision(index: 2, root: root, store: store, prepared: false)
        let third = try await queueRevision(index: 3, root: root, store: store, prepared: true)

        let firstCheckpoint = try PlaybackState(
            itemID: first.revision.itemID, revisionID: first.revision.revisionID,
            sessionID: "session-a", sequence: 1, positionSeconds: 15, durationSeconds: 42,
            completed: false, intent: .progress, deviceID: "mac", updatedAt: Timestamp(Date())
        )
        try await store.save(playback: firstCheckpoint)

        let thirdCheckpoint = try PlaybackState(
            itemID: third.revision.itemID, revisionID: third.revision.revisionID,
            sessionID: "session-c", sequence: 1, positionSeconds: 25, durationSeconds: 42,
            completed: false, intent: .progress, deviceID: "mac", updatedAt: Timestamp(Date())
        )
        try await store.save(playback: thirdCheckpoint)

        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID, third.revision.itemID],
            currentEpisodeID: first.revision.itemID
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        XCTAssertEqual(controller.positionSeconds, 15)
        XCTAssertEqual(backend.loadCount, 1)

        let selectedNext = try await controller.selectNextPodcastQueueEpisode()
        XCTAssertTrue(selectedNext)
        XCTAssertEqual(controller.itemID, third.revision.itemID, "manual Next must skip unprepared B and select C")
        XCTAssertEqual(controller.positionSeconds, 25, "selecting C must restore its checkpoint")
        XCTAssertEqual(backend.loadCount, 2, "unprepared B must never be loaded into the backend")
        let nextQueueState = try await store.podcastQueueState()
        XCTAssertEqual(nextQueueState.currentEpisodeID, third.revision.itemID)

        let selectedPrevious = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertTrue(selectedPrevious)
        XCTAssertEqual(controller.itemID, first.revision.itemID, "manual Previous must skip unprepared B and select A")
        XCTAssertEqual(controller.positionSeconds, 15, "selecting A must restore its checkpoint")
        XCTAssertEqual(backend.loadCount, 3, "unprepared B must never be loaded into the backend")
        let previousQueueState = try await store.podcastQueueState()
        XCTAssertEqual(previousQueueState.currentEpisodeID, first.revision.itemID)

        let selectedBeforeStart = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertFalse(selectedBeforeStart, "selecting Previous when no predecessor exists must return false")
        XCTAssertEqual(controller.itemID, first.revision.itemID, "current episode must remain unchanged")
        XCTAssertEqual(backend.loadCount, 3)
    }

    func testManualPreviousWithABCSkipsRetiredReadyBAndAdvancesToA() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let feedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/feed.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "The Wilted Show",
            author: "Wilted", artworkURL: nil, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
        )
        try await store.save(feed: feed)

        let secondEnclosure = try XCTUnwrap(URL(string: "https://podcasts.example.test/audio/episode-2.mp3"))
        let secondID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-2", enclosureURL: secondEnclosure)
        let secondEpisode = try PodcastEpisode(
            itemID: secondID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-2",
            title: "Episode 2", enclosureURL: secondEnclosure, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200))
        )
        try await store.save(episode: secondEpisode)

        let first = try await queueRevision(index: 1, root: root, store: store, prepared: true)
        _ = try await queueRevision(index: 2, root: root, store: store, prepared: true, itemID: secondID)
        let third = try await queueRevision(index: 3, root: root, store: store, prepared: true)

        try await store.retireEpisode(secondID)
        let retiredAtBefore = try await store.retiredAt(for: secondID)
        XCTAssertNotNil(retiredAtBefore)

        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, secondID, third.revision.itemID],
            currentEpisodeID: third.revision.itemID
        ))

        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        controller.episodeEligibilityPredicate = { _ in true }
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, third.revision.itemID)
        XCTAssertEqual(backend.loadCount, 1)

        let selected = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertTrue(selected)
        XCTAssertEqual(controller.itemID, first.revision.itemID, "manual Previous must skip retired B and select A")
        XCTAssertEqual(backend.loadCount, 2, "retired B must never be loaded into the backend")
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, first.revision.itemID)

        // B must remain retired: Previous must not silently unretire it
        let retiredAt = try await store.retiredAt(for: secondID)
        XCTAssertNotNil(retiredAt, "Previous must not silently unretire B")

        // No eligible predecessor before first
        let selectedBeforeFirst = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertFalse(selectedBeforeFirst)
        XCTAssertEqual(controller.itemID, first.revision.itemID)

        // Explicit Restore makes B eligible again
        let restored = try await store.restoreEpisode(secondID)
        XCTAssertTrue(restored)
        // W-INV-025: retiring B reclaimed its audio and revision, so the
        // restored episode needs its audio downloaded again before it can load.
        _ = try await queueRevision(index: 2, root: root, store: store, prepared: true, itemID: secondID)
        let retiredAtAfter = try await store.retiredAt(for: secondID)
        XCTAssertNil(retiredAtAfter)

        // When navigating previous from C, restored B is now selected
        try await controller.selectPodcastQueueEpisode(third.revision.itemID)
        XCTAssertEqual(controller.itemID, third.revision.itemID)

        let selectedRestoredB = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertTrue(selectedRestoredB)
        XCTAssertEqual(controller.itemID, secondID, "manual Previous must now select restored B")
    }

    func testManualPreviousWithNoEligiblePredecessorReturnsFalseAndRetainsCurrent() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await queueRevision(index: 1, root: root, store: store, prepared: false)
        let second = try await queueRevision(index: 2, root: root, store: store, prepared: true)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.revision.itemID, second.revision.itemID],
            currentEpisodeID: second.revision.itemID
        ))

        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        XCTAssertEqual(backend.loadCount, 1)

        let selected = try await controller.selectPreviousPodcastQueueEpisode()
        XCTAssertFalse(selected, "Previous must return false when no eligible predecessor exists")
        XCTAssertEqual(controller.itemID, second.revision.itemID, "current episode must remain unchanged")
        XCTAssertEqual(backend.loadCount, 1, "ineligible predecessor must never be loaded")
        let queueState = try await store.podcastQueueState()
        XCTAssertEqual(queueState.currentEpisodeID, second.revision.itemID)
    }
}
