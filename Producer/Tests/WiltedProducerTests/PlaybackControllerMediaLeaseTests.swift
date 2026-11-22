import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// A deletion of episode audio and a load of it exclude each other: whichever reaches the player's
/// main-actor step first wins, so audio can never start inside the gap before the store removes it.
@MainActor
final class PlaybackControllerMediaLeaseTests: XCTestCase {
    private func controller(_ name: String = #function) async throws
        -> (PlaybackController, PlaybackControllerTests.FakeBackend, AudioRevision, URL, URL) {
        let test = PlaybackControllerTests()
        let path = test.storeURL(name)
        let root = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try await test.storedFixture(in: store)
        let backend = PlaybackControllerTests.FakeBackend()
        let media = root.appendingPathComponent("media.m4a")
        try Data("audio".utf8).write(to: media)
        return (PlaybackController(store: store, backend: backend), backend, revision, media, root)
    }

    func testALeaseIsGrantedForAnIdleEpisodeAndRefusesALoadUntilReleased() async throws {
        let (controller, backend, revision, media, root) = try await controller()
        defer { try? FileManager.default.removeItem(at: root) }

        let lease = try XCTUnwrap(controller.leaseMediaForDeletion([revision.itemID]))
        do {
            try await controller.load(revision: revision, mediaURL: media)
            XCTFail("an episode under lease cannot start loading")
        } catch { XCTAssertEqual(error as? PlaybackControllerError, .podcastMediaUnavailable(revision.itemID)) }
        XCTAssertEqual(backend.loadCount, 0, "the audio file was never opened")
        XCTAssertNil(controller.itemID)

        controller.release(lease)
        try await controller.load(revision: revision, mediaURL: media)
        XCTAssertEqual(controller.itemID, revision.itemID)
    }

    func testALeaseIsRefusedForAnEpisodeThePlayerHasLoaded() async throws {
        let (controller, _, revision, media, root) = try await controller()
        defer { try? FileManager.default.removeItem(at: root) }
        try await controller.load(revision: revision, mediaURL: media)

        XCTAssertNil(controller.leaseMediaForDeletion([revision.itemID]))
    }

    func testALeaseIsRefusedWhileALoadIsStillInFlight() async throws {
        let (controller, backend, revision, media, root) = try await controller()
        defer { try? FileManager.default.removeItem(at: root) }

        let loading = Task { @MainActor in try await controller.load(revision: revision, mediaURL: media) }
        await Task.yield()
        // The load has begun but has not opened the file yet: a deletion's player check cannot see it,
        // the lease can.
        XCTAssertNil(controller.leaseMediaForDeletion([revision.itemID]), "the in-flight load blocks the lease")
        try await loading.value
        XCTAssertEqual(backend.loadCount, 1)
        XCTAssertTrue(controller.loadsInFlight.isEmpty, "a finished load leaves nothing counted")
    }

    func testAFailedLoadDoesNotLeaveTheEpisodeLockedOut() async throws {
        let (controller, backend, revision, media, root) = try await controller()
        defer { try? FileManager.default.removeItem(at: root) }
        backend.failingURLs = [media]

        do { try await controller.load(revision: revision, mediaURL: media); XCTFail("the load fails") } catch {}

        XCTAssertTrue(controller.loadsInFlight.isEmpty)
        XCTAssertNotNil(controller.leaseMediaForDeletion([revision.itemID]))
    }
}
