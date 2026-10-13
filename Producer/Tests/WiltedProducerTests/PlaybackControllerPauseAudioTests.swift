import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// `pauseAudio()` answers Pause at once: it stops the backend synchronously
/// and leaves every durable write to the checkpoint that `pause()` adds.
@MainActor
final class PlaybackControllerPauseAudioTests: XCTestCase {
    private typealias FakeBackend = PlaybackControllerTests.FakeBackend

    private var root: URL?

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    /// A store holding one saved article (the store skips a first checkpoint
    /// for an item with no row) and a controller with that article loaded and
    /// playing at 12 seconds.
    private func playingController() async throws -> (PlaybackController, FakeBackend, LocalLibraryStore, AudioRevision) {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-pause-audio-\(UUID().uuidString)")
        root = directory
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let url = URL(string: "https://example.test/pause-audio")!
        let article = try Article(itemID: ItemID.derive(from: url), canonicalURL: url,
                                  title: "Pause audio", source: "example.test",
                                  createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        try await store.save(article: article)
        let revision = try AudioRevision(itemID: article.itemID, revisionID: RevisionID(rawValue: "revision-one"),
                                         durationSeconds: 42, byteCount: 1,
                                         contentHash: "sha256:\(String(repeating: "a", count: 64))",
                                         mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let backend = FakeBackend()
        let controller = PlaybackController(store: store, backend: backend, deviceID: "test-device")
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/pause-audio.m4a"))
        backend.currentTime = 12
        try controller.play()
        return (controller, backend, store, revision)
    }

    func testPauseAudioStopsTheBackendSynchronouslyAndWritesNothing() async throws {
        let (controller, backend, store, revision) = try await playingController()
        let stored = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        let sequence = controller.sequence
        let position = controller.positionSeconds
        let hold = controller.explicitHoldSerial

        // Not awaited: the backend has stopped before this call returns.
        try controller.pauseAudio()
        XCTAssertFalse(backend.isPlaying)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.liveIsPlaying)
        XCTAssertEqual(controller.explicitHoldSerial, hold &+ 1, "a Pause still cancels an owed queue advance")

        XCTAssertEqual(controller.sequence, sequence, "no checkpoint was taken")
        XCTAssertEqual(controller.positionSeconds, position, "the checkpointed playhead did not move")
        let after = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(after, stored, "the store was not written")
        XCTAssertNotEqual(after?.positionSeconds, 12)
    }

    func testPauseAudioWithNothingLoadedStillRecordsTheHold() throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-pause-audio-\(UUID().uuidString)")
        root = directory
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let controller = PlaybackController(store: store, backend: FakeBackend())
        let hold = controller.explicitHoldSerial
        XCTAssertThrowsError(try controller.pauseAudio()) { error in
            XCTAssertEqual(error as? PlaybackControllerError, .noLoadedRevision)
        }
        XCTAssertEqual(controller.explicitHoldSerial, hold &+ 1)
    }

    func testPauseStillStopsTheAudioAndCheckpoints() async throws {
        let (controller, backend, store, revision) = try await playingController()
        let sequence = controller.sequence

        try await controller.pause()

        XCTAssertFalse(backend.isPlaying)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertGreaterThan(controller.sequence, sequence, "pause() checkpoints")
        let stored = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.positionSeconds, 12)
        XCTAssertEqual(saved.sequence, controller.sequence)
    }
}
