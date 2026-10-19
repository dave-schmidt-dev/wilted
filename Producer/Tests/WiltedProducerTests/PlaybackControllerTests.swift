import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

@MainActor
final class PlaybackControllerTests: XCTestCase {
    final class FakeBackend: PlaybackBackend {
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

    func storeURL(_ name: String = #function) -> URL {
        OwnedTestTemp.root
            .appendingPathComponent("wilted-playback-\(name)-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
    }

    func fixture() throws -> (Article, AudioRevision) {
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

    /// `fixture()` with its article saved, as every playable article is in
    /// production: the store skips a first checkpoint for an item with no row.
    func storedFixture(in store: LocalLibraryStore) async throws -> (Article, AudioRevision) {
        let (article, revision) = try fixture()
        try await store.save(article: article)
        return (article, revision)
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

    func queueRevision(
        index: Int, root: URL, store: LocalLibraryStore, prepared: Bool = true, itemID: ItemID? = nil
    ) async throws -> StoredAudioRevision {
        // Truncated, because the digits of a two-digit index repeated 64 times
        // is a 128-character identifier the store rejects. Single-digit indexes
        // are unchanged by the truncation.
        let seed = String(String(repeating: String(index), count: 64).prefix(64))
        let effectiveItemID = try itemID ?? ItemID(rawValue: "item-" + seed)
        let revision = try AudioRevision(
            itemID: effectiveItemID, revisionID: RevisionID(rawValue: "podcast-\(index)"), durationSeconds: 42,
            byteCount: 1, contentHash: "sha256:" + seed,
            mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1
        )
        let url = root.appendingPathComponent("podcast-\(index).mp3")
        _ = FileManager.default.createFile(atPath: url.path, contents: Data([UInt8(index % 256)]))
        try await store.saveReadyRevision(revision, mediaURL: url)
        if prepared {
            try await store.savePreparationOutcome(PodcastPreparationOutcome(
                episodeID: effectiveItemID, revisionID: revision.revisionID, policyDigest: "d",
                pipelineFingerprint: "f", semanticVersion: "v", producedAt: Timestamp(Date())
            ))
        }
        return StoredAudioRevision(revision: revision, mediaURL: url)
    }

    /// `AVAudioPlayerBackend` keys its generation map on `ObjectIdentifier`, which
    /// is the player's address, so an entry that outlives its player can be matched
    /// by a later player allocated at the same address and report a superseded
    /// generation. Only natural completion used to prune, which left an entry behind
    /// for every superseded load and every explicit stop.
    func testBackendDoesNotRetainGenerationKeysForPlayersItNoLongerOwns() throws {
        let directory = OwnedTestTemp.root
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
        let directory = OwnedTestTemp.root
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

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { XCTFail("condition was not met within 5 seconds") }
    }

    func XCTAssertThrowsErrorAsync(
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
