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

        func load(url: URL) throws {
            if failingURLs.contains(url) { throw CocoaError(.fileReadCorruptFile) }
            loadCount += 1; loadedGeneration += 1; currentTime = 0; isPlaying = false
        }
        func play() -> Bool { isPlaying = true; return true }
        func pause() { isPlaying = false }
        func stop() { isPlaying = false }
        func finish(generation: UInt64? = nil, successfully: Bool) {
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
        await controller.restorePodcastQueue()
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        let firstGeneration = backend.loadedGeneration

        backend.finish(successfully: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.itemID, first.revision.itemID)
        backend.finish(successfully: true)
        backend.finish(successfully: true)
        await waitUntil { controller.itemID == second.revision.itemID }
        XCTAssertEqual(controller.itemID, second.revision.itemID)
        XCTAssertEqual(backend.loadCount, 2, "duplicate completion must not create another playback session")
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
        XCTAssertEqual(backend.loadCount, 2, "a delayed old-player callback must not advance the replacement")

        let relaunched = PlaybackController(store: store, backend: FakeBackend())
        await relaunched.restorePodcastQueue()
        XCTAssertEqual(relaunched.itemID, second.revision.itemID)
        let relaunchedCompletedState = try await store.playbackState(
            for: first.revision.itemID, revisionID: first.revision.revisionID
        )
        XCTAssertTrue(try XCTUnwrap(relaunchedCompletedState).completed)
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
        controller.podcastStateHandler = { _, fault in observedFault = fault }
        await controller.restorePodcastQueue()
        backend.finish(successfully: true)
        await waitUntil { controller.recoverableFault != nil }
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.recoverableFault, .podcastMediaUnavailable(missing.revision.itemID))
        XCTAssertEqual(observedFault, controller.recoverableFault)
        let retainedState = try await store.podcastQueueState()
        XCTAssertEqual(retainedState, state)

        _ = FileManager.default.createFile(atPath: missing.mediaURL.path, contents: Data([4]))
        let corruptBackend = FakeBackend()
        corruptBackend.failingURLs.insert(missing.mediaURL)
        let corruptController = PlaybackController(store: store, backend: corruptBackend)
        await corruptController.restorePodcastQueue()
        corruptBackend.finish(successfully: true)
        await waitUntil { corruptController.recoverableFault != nil }
        XCTAssertFalse(corruptController.isPlaying)
        XCTAssertEqual(corruptController.recoverableFault, .podcastMediaUnreadable(missing.revision.itemID))
        let corruptRetainedState = try await store.podcastQueueState()
        XCTAssertEqual(corruptRetainedState, state)
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
        let itemID = try ItemID(rawValue: "item-" + String(repeating: String(index), count: 64))
        let revision = try AudioRevision(
            itemID: itemID, revisionID: RevisionID(rawValue: "podcast-\(index)"), durationSeconds: 42,
            byteCount: 1, contentHash: "sha256:" + String(repeating: String(index), count: 64),
            mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1
        )
        let url = root.appendingPathComponent("podcast-\(index).mp3")
        _ = FileManager.default.createFile(atPath: url.path, contents: Data([UInt8(index)]))
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
