import Foundation
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

/// W-INV-040 (Task 38): a slider drag and a resume right after Pause are
/// answered from memory while the checkpoint write behind them is held, and
/// those writes still land in order and survive close.
@MainActor
final class WiltedMacPlaybackCheckpointLaneTests: XCTestCase {
    // The slider shows each scrub at once, the audio moves while the held
    // checkpoint write waits, and the store gets the last position after.
    func testScrubShowsAndMovesAtOnceWhileItsCheckpointWriteIsHeld() async throws {
        let (model, backend) = try await makePlayingModel()
        let gate = WiltedMacCheckpointWriteGate(on: try XCTUnwrap(model.playback))
        gate.arm()

        model.scrub(to: 120)
        XCTAssertEqual(model.playbackPositionSeconds, 120, "the slider follows the drag before any await")
        model.refreshPlaybackReadout()
        XCTAssertEqual(model.playbackPositionSeconds, 120, "the readout tick keeps the dragged position")
        await gate.waitUntilHeld()
        XCTAssertEqual(backend.currentTime, 120, "the audio moved before its checkpoint write")

        model.scrub(to: 240)
        XCTAssertEqual(model.playbackPositionSeconds, 240)
        await waitUntil("a second scrub does not queue behind the held write") { backend.currentTime == 240 }
        model.refreshPlaybackReadout()
        XCTAssertEqual(model.playbackPositionSeconds, 240)
        XCTAssertTrue(gate.isHolding)
        let beforeRelease = try await storedPosition(model)
        XCTAssertNotEqual(beforeRelease, 240, "nothing past the held write has landed")

        gate.release()
        await model.joinPlaybackCheckpoints()
        let landed = try await storedPosition(model)
        XCTAssertEqual(landed, 240)
        await model.close()
    }

    // Resume reaches the audio while the pause's checkpoint write is held,
    // and starts from the position held in memory.
    func testResumeAfterPauseStartsBeforeThePausesCheckpointWriteIsReleased() async throws {
        let (model, backend) = try await makePlayingModel()
        backend.currentTime = 90
        let gate = WiltedMacCheckpointWriteGate(on: try XCTUnwrap(model.playback))
        gate.arm()

        model.pausePlayback()
        XCTAssertFalse(backend.isPlaying, "Pause stops the audio at the press")
        await gate.waitUntilHeld()
        let plays = backend.playCount
        model.startPlayback()
        await waitUntil("resume reaches the audio while the write is held") { backend.playCount > plays }
        XCTAssertTrue(gate.isHolding, "the pause's write is still held")
        XCTAssertTrue(backend.isPlaying)
        XCTAssertEqual(backend.currentTime, 90, "resume starts from the position in memory")
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying)

        gate.release()
        await model.joinPlaybackCheckpoints()
        let landed = try await storedPosition(model)
        XCTAssertEqual(landed, 90)
        await model.close()
    }

    // One write at a time, each taken when it starts: a later checkpoint is
    // never overwritten by the earlier one that was held.
    func testHeldCheckpointWritesLandInTheOrderTheyWereTaken() async throws {
        let (model, backend) = try await makePlayingModel()
        backend.currentTime = 100
        let gate = WiltedMacCheckpointWriteGate(on: try XCTUnwrap(model.playback))
        gate.arm()

        model.pausePlayback()
        await gate.waitUntilHeld()
        model.startPlayback()
        await waitUntil("resume runs behind the held write") { backend.isPlaying }
        backend.currentTime = 200
        model.pausePlayback()
        model.scrub(to: 250)
        await waitUntil("the scrub moves the audio") { backend.currentTime == 250 }

        gate.release()
        await model.joinPlaybackCheckpoints()
        XCTAssertEqual(gate.takenPositions, [100, 250], "the second write starts only after the first lands")
        let landed = try await storedPosition(model)
        XCTAssertEqual(landed, 250, "the earlier, held write never lands last")
        await model.close()
    }

    // Close joins a held pause checkpoint and does not drop it.
    func testCloseJoinsAHeldPauseCheckpointWrite() async throws {
        let (model, backend) = try await makePlayingModel()
        backend.currentTime = 150
        let store = try XCTUnwrap(model.store)
        let playback = try XCTUnwrap(model.playback)
        let itemID = try XCTUnwrap(playback.itemID)
        let revisionID = try XCTUnwrap(playback.revisionID)
        let gate = WiltedMacCheckpointWriteGate(on: playback)
        gate.arm()

        model.pausePlayback()
        await gate.waitUntilHeld()
        let closed = WiltedMacCheckpointLaneFlag()
        let closing = Task { @MainActor in
            await model.close()
            closed.isSet = true
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed.isSet, "close waits for the held checkpoint write")

        gate.release()
        await closing.value
        XCTAssertTrue(closed.isSet)
        let saved = try await store.playbackState(for: itemID, revisionID: revisionID)
        XCTAssertEqual(saved?.positionSeconds, 150, "the pause's checkpoint is saved through close")
    }

    // MARK: Fixture

    private func makePlayingModel() async throws -> (WiltedMacModel, WiltedMacScriptedBackend) {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        await model.joinPlaybackCheckpoints()
        XCTAssertTrue(backend.isPlaying)
        XCTAssertEqual(model.playback?.itemID?.rawValue, episode.id)
        return (model, backend)
    }

    private func storedPosition(_ model: WiltedMacModel) async throws -> TimeInterval? {
        let playback = try XCTUnwrap(model.playback)
        let itemID = try XCTUnwrap(playback.itemID)
        let revisionID = try XCTUnwrap(playback.revisionID)
        return try await model.store?.playbackState(for: itemID, revisionID: revisionID)?.positionSeconds
    }

    /// Bounded, so a regression that queues behind the held write fails
    /// here instead of hanging the run.
    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message)
    }
}

@MainActor
private final class WiltedMacCheckpointLaneFlag {
    var isSet = false
}

/// Holds the first checkpoint write it is armed for, after that checkpoint's
/// state is taken, and records the position each checkpoint took.
@MainActor
final class WiltedMacCheckpointWriteGate {
    private(set) var takenPositions: [TimeInterval] = []
    private(set) var isHolding = false
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(on playback: PlaybackController) {
        playback.checkpointWriteGateForTesting = { [weak self, weak playback] in
            guard let self else { return }
            self.takenPositions.append(playback?.positionSeconds ?? -1)
            await self.holdIfArmed()
        }
    }

    func arm() {
        armed = true
        takenPositions = []
    }

    func waitUntilHeld() async {
        guard !isHolding else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        isHolding = false
        held?.resume()
        held = nil
    }

    private func holdIfArmed() async {
        guard armed else { return }
        armed = false
        isHolding = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { held = $0 }
    }
}
