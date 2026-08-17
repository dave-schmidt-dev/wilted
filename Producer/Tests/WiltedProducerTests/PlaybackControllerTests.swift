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

        func load(url: URL) throws { loadCount += 1; currentTime = 0 }
        func play() -> Bool { isPlaying = true; return true }
        func pause() { isPlaying = false }
        func stop() { isPlaying = false }
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
}
