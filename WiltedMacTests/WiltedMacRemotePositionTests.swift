import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// `PlaybackController.applyRemotePosition` against a real store: a phone's position becomes
/// the Mac's stored position, without ever starting or disturbing playback.
@MainActor
final class WiltedMacRemotePositionTests: XCTestCase {
    private let episode = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let revisionID = try! RevisionID(rawValue: "rev-a")
    private let mediaURL = URL(fileURLWithPath: "/tmp/podcast-a.m4a")
    private var store: LocalLibraryStore!
    private var backend: WiltedFixturePlaybackBackend!
    private var controller: PlaybackController!
    private let base = Date().addingTimeInterval(-3_600)

    override func setUp() async throws {
        let directory = wiltedTemporaryDirectory("remote-position")
        store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        // The store keeps a checkpoint only for an item it still holds.
        try await store.saveReadyRevision(revision, mediaURL: mediaURL)
        makeController()
    }

    private func makeController() {
        backend = WiltedFixturePlaybackBackend()
        controller = PlaybackController(store: store, backend: backend, deviceID: "mac-test")
    }

    private var revision: AudioRevision {
        try! AudioRevision(
            itemID: episode, revisionID: revisionID, durationSeconds: 1_482, byteCount: 1,
            contentHash: "sha256:\(String(repeating: "a", count: 64))", mediaType: "audio/mp4",
            createdAt: Timestamp(base), schemaVersion: 1)
    }

    /// The Mac's stored checkpoint, saved `minutes` after `base`.
    private func storeMacState(
        position: Double, minutes: Double, completed: Bool = false, session: String = "session-mac", intent: PlaybackIntent = .progress
    ) async throws {
        try await store.save(playback: PlaybackState(
            itemID: episode, revisionID: revisionID, sessionID: session, sequence: 3, positionSeconds: position,
            durationSeconds: 1_482, completed: completed, intent: intent, deviceID: "mac-test",
            updatedAt: Timestamp(base.addingTimeInterval(minutes * 60))))
    }

    private func request(_ position: Double, minutes: Double) -> RemotePositionRequest {
        RemotePositionRequest(
            itemID: episode, revisionID: revisionID, positionSeconds: position, durationSeconds: 1_482,
            observedAt: base.addingTimeInterval(minutes * 60))
    }

    private func stored() async throws -> PlaybackState {
        let state = try await store.playbackState(for: episode, revisionID: revisionID)
        return try XCTUnwrap(state)
    }

    private func load() async throws {
        try await controller.load(revision: revision, mediaURL: mediaURL)
    }

    func testNotLoadedUpdatesTheStoredStateAndALaterLoadResumesThere() async throws {
        try await storeMacState(position: 100, minutes: 0)

        let outcome = try await controller.applyRemotePosition(request(540, minutes: 10))

        XCTAssertEqual(outcome, .applied)
        let state = try await stored()
        XCTAssertEqual(state.positionSeconds, 540)
        XCTAssertEqual(state.sessionID, "session-mac", "moving forward keeps the session")
        XCTAssertEqual(state.sequence, 4)
        XCTAssertEqual(state.updatedAt.date, base.addingTimeInterval(600), "stamped with when the phone saved it")
        XCTAssertNil(controller.itemID, "nothing was loaded")

        try await load()
        XCTAssertEqual(controller.positionSeconds, 540)
        XCTAssertEqual(backend.currentTime, 540)
        XCTAssertFalse(backend.isPlaying, "importing never starts playback")
    }

    func testAnEpisodeTheMacNeverPlayedGetsAProgressState() async throws {
        let outcome = try await controller.applyRemotePosition(request(75, minutes: 1))
        XCTAssertEqual(outcome, .applied)
        let state = try await stored()
        XCTAssertEqual(state.positionSeconds, 75)
        XCTAssertEqual(state.intent, .progress)
        XCTAssertEqual(state.sequence, 1)
        XCTAssertFalse(state.completed)
    }

    func testLoadedAndPausedMovesThePlayheadWithoutPlayingAndTheNextCheckpointKeepsIt() async throws {
        try await storeMacState(position: 100, minutes: 0)
        try await load()
        XCTAssertEqual(controller.positionSeconds, 100)

        let outcome = try await controller.applyRemotePosition(request(540, minutes: 10))

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(controller.positionSeconds, 540)
        XCTAssertEqual(backend.currentTime, 540)
        XCTAssertFalse(backend.isPlaying)
        XCTAssertFalse(controller.isPlaying)
        try await controller.checkpoint()
        let state = try await stored()
        XCTAssertEqual(state.positionSeconds, 540, "a later checkpoint must not overwrite the adopted position")
    }

    func testAPlayingEpisodeIsNeverTouched() async throws {
        try await storeMacState(position: 100, minutes: 0)
        try await load()
        backend.currentTime = 130
        try controller.play()

        let outcome = try await controller.applyRemotePosition(request(540, minutes: 10))

        XCTAssertEqual(outcome, .playing)
        XCTAssertTrue(backend.isPlaying)
        XCTAssertEqual(backend.currentTime, 130)
        let state = try await stored()
        XCTAssertEqual(state.positionSeconds, 100)
        XCTAssertEqual(state.sequence, 3)
    }

    func testARecordNotNewerThanTheStoredPositionIsIgnoredEvenWhenItIsFurtherAlong() async throws {
        try await storeMacState(position: 100, minutes: 20)
        let outcome = try await controller.applyRemotePosition(request(900, minutes: 10))
        XCTAssertEqual(outcome, .notNewer)
        let state = try await stored()
        XCTAssertEqual(state.positionSeconds, 100)
        XCTAssertEqual(state.sequence, 3)
    }

    func testTheSameRecordTwiceIsANoOp() async throws {
        try await storeMacState(position: 100, minutes: 0)
        let first = try await controller.applyRemotePosition(request(540, minutes: 10))
        let second = try await controller.applyRemotePosition(request(540, minutes: 10))
        XCTAssertEqual(first, .applied)
        XCTAssertEqual(second, .notNewer)
        let sequence = try await stored().sequence
        XCTAssertEqual(sequence, 4)
    }

    func testACompletedEpisodeIsNotResurrected() async throws {
        try await storeMacState(position: 1_482, minutes: 0, completed: true)
        let outcome = try await controller.applyRemotePosition(request(300, minutes: 10))
        XCTAssertEqual(outcome, .completed)
        let state = try await stored()
        XCTAssertTrue(state.completed)
        XCTAssertEqual(state.positionSeconds, 1_482)
    }

    func testAPositionAtTheEndOrAtZeroIsNotAdopted() async throws {
        try await storeMacState(position: 100, minutes: 0)
        let atEnd = try await controller.applyRemotePosition(request(1_481.5, minutes: 10))
        let atZero = try await controller.applyRemotePosition(request(0, minutes: 10))
        XCTAssertEqual(atEnd, .unusable)
        XCTAssertEqual(atZero, .unusable)
        let position = try await stored().positionSeconds
        XCTAssertEqual(position, 100)
    }

    func testAnIntentionalRewindOnThePhoneStartsARewindSession() async throws {
        try await storeMacState(position: 900, minutes: 0)
        let outcome = try await controller.applyRemotePosition(request(120, minutes: 10))
        XCTAssertEqual(outcome, .applied)
        let state = try await stored()
        XCTAssertEqual(state.positionSeconds, 120)
        XCTAssertEqual(state.intent, .rewind)
        XCTAssertNotEqual(state.sessionID, "session-mac")
        XCTAssertEqual(state.sequence, 1)
    }

    func testAnIdleCheckpointDoesNotMakeThePositionLookNewer() async throws {
        // The app going to the background checkpoints a paused episode. That must not stamp the
        // unchanged position with the current time, or a phone record saved earlier would lose.
        try await storeMacState(position: 100, minutes: 0)
        try await load()
        try await controller.manualCheckpoint()
        let afterIdle = try await stored()
        XCTAssertEqual(afterIdle.updatedAt.date, base, "an unchanged paused checkpoint keeps its time")

        let outcome = try await controller.applyRemotePosition(request(540, minutes: 10))
        XCTAssertEqual(outcome, .applied)
    }

    func testACheckpointThatMovedThePlayheadIsStampedNow() async throws {
        try await storeMacState(position: 100, minutes: 0)
        try await load()
        backend.currentTime = 250
        try await controller.manualCheckpoint()
        let state = try await stored()
        XCTAssertGreaterThan(state.updatedAt.date, base.addingTimeInterval(3_000))
        XCTAssertEqual(state.positionSeconds, 250)
    }
}
