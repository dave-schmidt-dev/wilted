import Foundation
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

/// What the play/pause spinner covers. Pause stops the audio at once, ahead
/// of every queued effect and store write, and shows no pending state; only
/// its durable checkpoint waits its turn. A Pause also fences any start still
/// pending, and Play makes no phone position read of its own.
@MainActor
final class WiltedMacPlaybackPendingTests: XCTestCase {
    /// The fixture episode loaded through the owner and playing.
    private func playingModel() async -> (WiltedMacModel, WiltedMacScriptedBackend) {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(backend.isPlaying)
        XCTAssertTrue(model.isPlaying)
        return (model, backend)
    }

    func testPauseAnswersAtOnceWhileItsCheckpointIsHeld() async throws {
        let (model, backend) = await playingModel()
        backend.currentTime = 90
        let playback = try XCTUnwrap(model.playback)
        let itemID = try XCTUnwrap(playback.itemID)
        let revisionID = try XCTUnwrap(playback.revisionID)
        let store = try XCTUnwrap(model.store)
        let beforePause = try await store.playbackState(for: itemID, revisionID: revisionID)
        let gate = WiltedMacCheckpointWriteGate(on: playback)
        let pauses = backend.pauseCount
        let sequence = try XCTUnwrap(model.playbackCheckpointStateForTesting()).sequence

        gate.arm()
        model.pausePlayback()
        // Synchronous: nothing has been awaited yet.
        XCTAssertFalse(backend.isPlaying, "the backend stopped before the press returned")
        XCTAssertEqual(backend.pauseCount, pauses + 1)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.playbackCommands.pending, "Pause shows no pending state")
        XCTAssertEqual(model.playbackStatusMessage, "Paused")

        await gate.waitUntilHeld()
        XCTAssertNil(model.playbackCommands.pending)
        XCTAssertGreaterThan(try XCTUnwrap(model.playbackCheckpointStateForTesting()).sequence, sequence,
                             "the checkpoint took the paused position before its write was held")
        let held = try await store.playbackState(for: itemID, revisionID: revisionID)
        XCTAssertEqual(held, beforePause, "the held write has not changed the durable checkpoint")
        gate.release()
        await model.waitForPlaybackOperationForTesting()
        await model.joinPlaybackCheckpoints()

        XCTAssertGreaterThan(try XCTUnwrap(model.playbackCheckpointStateForTesting()).sequence, sequence,
                             "the durable checkpoint still follows the Pause")
        let saved = try await store.playbackState(for: itemID, revisionID: revisionID)
        XCTAssertEqual(try XCTUnwrap(saved).positionSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(backend.pauseCount, pauses + 1, "the checkpoint does not pause again")
        XCTAssertNil(model.playbackCommands.failure)
        XCTAssertEqual(model.playbackStatusMessage, "Paused")
        await model.close()
    }

    func testPauseReachesTheBackendWhileAnEarlierEffectHoldsTheTail() async throws {
        let (model, backend) = await playingModel()
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        let plays = backend.playCount
        let loads = backend.loadCount

        gate.arm()
        model.restartPlayback()
        await gate.waitUntilHeld()
        XCTAssertTrue(backend.isPlaying, "the restart is still held on the effect tail")
        model.pausePlayback()
        XCTAssertFalse(backend.isPlaying, "Pause did not wait behind the held effect")
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.playbackCommands.pending)
        XCTAssertEqual(model.playbackStatusMessage, "Paused")

        gate.release()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(backend.isPlaying, "the superseded restart did not revive the audio")
        XCTAssertEqual(backend.playCount, plays)
        XCTAssertEqual(backend.loadCount, loads, "the superseded restart never ran")
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.playbackCommands.failure)
        await model.close()
    }

    func testPauseDuringAPendingPlayPreventsTheStart() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        let plays = backend.playCount

        gate.arm()
        model.startPlayback()
        await gate.waitUntilHeld()
        XCTAssertEqual(model.playbackCommands.pending?.command.kind, .start)
        model.pausePlayback()
        XCTAssertNil(model.playbackCommands.pending, "Pause clears the pending start at once")
        XCTAssertEqual(model.playbackStatusMessage, "Paused")

        gate.release()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(backend.playCount, plays, "the superseded start never reached the backend")
        XCTAssertFalse(backend.isPlaying)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.playbackCommands.pending)
        XCTAssertNil(model.playbackCommands.failure)
        XCTAssertEqual(model.playbackStatusMessage, "Paused")
        await model.close()
    }

    func testRapidPlayPausePlayStartsTheAudioExactlyOnce() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        let plays = backend.playCount

        gate.arm()
        model.startPlayback()
        await gate.waitUntilHeld()
        let stale = try XCTUnwrap(model.playbackCommands.pending).command.token
        model.pausePlayback()
        model.startPlayback()
        let newest = try XCTUnwrap(model.playbackCommands.pending, "a Play after the Pause is a new start")
        XCTAssertEqual(newest.command.kind, .start)
        XCTAssertGreaterThan(newest.command.token, stale)

        gate.release()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(backend.playCount, plays + 1, "only the newest start reached the backend")
        XCTAssertTrue(backend.isPlaying)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.playbackCommands.pending)

        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(backend.isPlaying, "nothing queued revives the audio after the last Pause")
        XCTAssertEqual(backend.playCount, plays + 1)
        await model.close()
    }

    /// Play and selection start from the stored position; the Larder sync's
    /// 30-second round imports newer phone positions. Fixture models cannot
    /// run the library sync (it refuses fixture mode), so the guard is on the
    /// play paths themselves: none reads the device records or calls a
    /// play-time position refresh.
    func testPlayAndSelectionMakeNoPhonePositionRead() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = ["WiltedMacModel+PlaybackCommands.swift", "WiltedMacModel+Intake.swift", "WiltedMacModel+Playlists.swift"]
        for file in files {
            let url = root.appendingPathComponent("WiltedMac/ViewModel").appendingPathComponent(file)
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.isEmpty, file)
            for call in ["fetchDeviceRecords", "refreshPhonePosition"] {
                XCTAssertFalse(source.contains(call), "\(file) still reads the phone's position on Play: \(call)")
            }
        }
    }
}
