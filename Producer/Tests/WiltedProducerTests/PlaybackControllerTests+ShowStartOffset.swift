import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
extension PlaybackControllerTests {
    func testQueuedFreshEpisodeStartsAtItsShowOffset() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (episodeID, feedID, _) = try await storeShowStartOffsetEpisode(in: store, root: root, index: 81)
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var requestedFeed: ItemID?
        controller.freshStartOffsetProvider = { requestedFeed = $0; return 15 }

        try await controller.selectPodcastQueueEpisode(episodeID, autoplay: true)

        XCTAssertEqual(requestedFeed, feedID)
        XCTAssertEqual(controller.positionSeconds, 15)
        XCTAssertEqual(backend.currentTime, 15)
        XCTAssertTrue(backend.isPlaying)
        XCTAssertFalse(controller.completed)
    }

    func testQueuedZeroPositionResumeDoesNotUseShowOffset() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (episodeID, _, stored) = try await storeShowStartOffsetEpisode(in: store, root: root, index: 82)
        try await store.save(playback: PlaybackState(
            itemID: episodeID, revisionID: stored.revision.revisionID, sessionID: "zero-resume",
            sequence: 1, positionSeconds: 0, durationSeconds: 42, completed: false,
            intent: .progress, deviceID: "test-device", updatedAt: Timestamp(Date())
        ))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        var providerCalls = 0
        controller.freshStartOffsetProvider = { _ in providerCalls += 1; return 15 }

        try await controller.selectPodcastQueueEpisode(episodeID, autoplay: true)

        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(controller.sessionID, "zero-resume")
        XCTAssertEqual(controller.positionSeconds, 0)
        XCTAssertEqual(backend.currentTime, 0)
        XCTAssertFalse(controller.completed)
    }

    func testOffsetAtPlayableDurationStartsAtZeroWithoutCompleting() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (episodeID, _, _) = try await storeShowStartOffsetEpisode(in: store, root: root, index: 83)
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        controller.freshStartOffsetProvider = { _ in 42 }

        try await controller.selectPodcastQueueEpisode(episodeID, autoplay: true)

        XCTAssertEqual(controller.positionSeconds, 0)
        XCTAssertEqual(backend.currentTime, 0)
        XCTAssertTrue(backend.isPlaying)
        XCTAssertFalse(controller.completed)
    }

    func testDirectRevisionLoadDoesNotUseQueuedShowOffset() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (episodeID, _, stored) = try await storeShowStartOffsetEpisode(in: store, root: root, index: 84)
        let controller = PlaybackController(store: store, backend: FakeBackend())
        var providerCalls = 0
        controller.freshStartOffsetProvider = { _ in providerCalls += 1; return 15 }

        try await controller.load(revision: stored.revision, mediaURL: stored.mediaURL)

        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(controller.itemID, episodeID)
        XCTAssertEqual(controller.positionSeconds, 0)
    }

    func testAutomaticAdvanceUsesDestinationShowSpeedInsteadOfOutgoingEpisodeSpeed() async throws {
        let path = storeURL(); let root = path.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let first = try await storePodcastEpisode(in: store, root: root, index: 85)
        let second = try await storePodcastEpisode(in: store, root: root, index: 86)
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [first.episodeID, second.episodeID], currentEpisodeID: first.episodeID))
        try await store.save(playbackSpeed: PodcastPlaybackSpeed(
            itemID: first.episodeID, speed: 1.75, updatedAt: Timestamp(Date())))
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend)
        controller.defaultRate = 1
        var requestedFeeds: [ItemID] = []
        controller.showPlaybackSpeedProvider = { feedID in
            requestedFeeds.append(feedID)
            return feedID == second.feedID ? 1.25 : 0.75
        }

        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.playbackRate, 1.75, "the outgoing episode's own choice still applies to it")
        backend.finish(successfully: true)
        await waitUntil { controller.itemID == second.episodeID }

        XCTAssertEqual(requestedFeeds.last, second.feedID)
        XCTAssertEqual(controller.playbackRate, 1.25, "automatic advance resolves the destination show")
        XCTAssertEqual(backend.rate, 1.25)
        XCTAssertTrue(backend.isPlaying)
    }

    private func storeShowStartOffsetEpisode(
        in store: LocalLibraryStore, root: URL, index: Int
    ) async throws -> (episodeID: ItemID, feedID: ItemID, stored: StoredAudioRevision) {
        let feedURL = URL(string: "https://offset-(index).example.test/feed.xml")!
        let enclosureURL = URL(string: "https://offset-(index).example.test/episode.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "episode-(index)", enclosureURL: enclosureURL)
        let stamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Offset Show", createdAt: stamp))
        try await store.save(episode: PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-(index)",
            title: "Offset Episode", enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            durationSeconds: 42, createdAt: stamp
        ))
        let stored = try await queueRevision(index: index, root: root, store: store, itemID: episodeID)
        return (episodeID, feedID, stored)
    }

    private func storePodcastEpisode(
        in store: LocalLibraryStore, root: URL, index: Int
    ) async throws -> (episodeID: ItemID, feedID: ItemID) {
        let feedURL = URL(string: "https://speed-\(index).example.test/feed.xml")!
        let enclosureURL = URL(string: "https://speed-\(index).example.test/episode.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-\(index)", enclosureURL: enclosureURL)
        let stamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Speed Show \(index)", createdAt: stamp))
        try await store.save(episode: PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-\(index)",
            title: "Speed Episode \(index)", enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            durationSeconds: 42, createdAt: stamp))
        _ = try await queueRevision(index: index, root: root, store: store, itemID: episodeID)
        return (episodeID, feedID)
    }
}
