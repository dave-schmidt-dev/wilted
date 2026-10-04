import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// What every player shows for a command's pending and failed states, and
/// the speed picker's own save line. Scenario IDs refer to
/// `docs/mockups/2026-10-03-core-reliability.html`.
extension WiltedVisualSystemTests {
    // SPEED-FAIL: the live speed stays; the failure says what a restart uses.
    @MainActor
    func testSpeedSaveFailureKeepsLiveSpeedAndNamesRestartSpeed() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        model.playbackOperationStatus = "Added Quiet Machines to Larder."
        model.installSpeedSaveForTesting { _ in throw CocoaError(.fileWriteUnknown) }

        model.setPlaybackRate(1.5)
        XCTAssertEqual(model.currentSpeedSaveStatus?.phase, .saving)
        XCTAssertEqual(model.currentSpeedSaveStatus?.message, "Saving speed…")
        try await waitFor { model.currentSpeedSaveStatus?.phase == .failed }

        XCTAssertEqual(model.playbackRate, 1.5)
        XCTAssertEqual(model.playback?.playbackRate, 1.5, "the live speed is never rolled back")
        let message = try XCTUnwrap(model.currentSpeedSaveStatus?.message)
        XCTAssertTrue(message.hasPrefix("Speed save failed. Current speed 1.5×; restart uses "), message)
        XCTAssertEqual(model.playbackOperationStatus, "Added Quiet Machines to Larder.",
                       "a speed save never settles another operation's status")

        model.installSpeedSaveForTesting(nil)
        model.retrySpeedSave()
        try await waitFor { model.currentSpeedSaveStatus?.phase == .saved }
        let store = try XCTUnwrap(model.store)
        let saved = try await store.playbackSpeed(for: ItemID(rawValue: episode.id))
        XCTAssertEqual(saved?.speed, 1.5)
    }

    // SPEED-FAIL reordered: an older save finishing last cannot settle.
    @MainActor
    func testReorderedSpeedSavesSettleOnlyTheNewest() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let saves = WiltedMacSpeedSaveScript()
        model.installSpeedSaveForTesting { try await saves.save($0) }

        model.setPlaybackRate(1.5)
        model.setPlaybackRate(2)
        try await waitFor { saves.pendingCount == 2 }
        saves.finish(speed: 2, failing: false)
        try await waitFor { model.currentSpeedSaveStatus?.phase == .saved }
        saves.finish(speed: 1.5, failing: true)
        try await waitFor { model.playbackCommands.settledSpeedSaves == 2 }

        XCTAssertEqual(model.currentSpeedSaveStatus?.phase, .saved, "the stale failure did not settle")
        XCTAssertEqual(model.currentSpeedSaveStatus?.speed, 2)
        XCTAssertEqual(model.playbackRate, 2)
    }

    // PLAY-NOTREADY: an unprepared episode is not missing media.
    @MainActor
    func testUnpreparedEpisodeReportsNotReadyWhileIdle() async throws {
        let (model, backend, episode) = makePlaybackCommandModel(prepared: false)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.playbackCommands.failure?.kind, .notReady)
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertEqual(model.playbackStatusMessage, "Audio is not ready. Finish preparation first.",
                       "the failure outranks the idle line")
        XCTAssertEqual(model.playbackStatusTone, .failure)
        XCTAssertEqual(backend.loadCount, 0)
        XCTAssertFalse(model.audioRouteRecoveryAttempted)
    }

    // RACE-rail/side/full and FAIL-rail/side/full: the rail, side and full
    // players all render `playbackStatusMessage`, its tone, the answer line
    // and the retry predicate, so the states are asserted at that source,
    // idle and loaded alike.
    @MainActor
    func testCommandStatesOutrankIdleAndRestingStatusForEveryPlayer() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        XCTAssertFalse(model.showsPlaybackCommandResult)

        gate.arm()
        model.playEpisode(episode)
        XCTAssertFalse(model.hasCurrentPlayback, "the idle players are showing")
        XCTAssertTrue(model.showsPlaybackCommandResult)
        XCTAssertEqual(model.playbackStatusMessage, "Opening \(episode.title)…")
        XCTAssertFalse(model.canRetryPlayback)
        await gate.waitUntilHeld()
        gate.release()
        await model.waitForPlaybackOperationForTesting()
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playbackStatusMessage, "Paused")
        XCTAssertFalse(model.showsPlaybackCommandResult)

        gate.arm()
        model.togglePlayback()
        XCTAssertEqual(model.playbackStatusMessage, "Starting playback…")
        XCTAssertEqual(model.playbackStatusTone, .caution)
        await gate.waitUntilHeld()
        backend.refusesPlay = true
        gate.release()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playbackStatusMessage, "Playback refused. Your position is kept.")
        XCTAssertEqual(model.playbackStatusTone, .failure)
        XCTAssertTrue(model.canRetryPlayback)
        XCTAssertFalse(model.audioRouteFault, "one fault, one button: no Recover audio beside Retry")
    }

    // MARK: Helpers

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}

/// Speed saves that finish when the test says so, in any order.
@MainActor
final class WiltedMacSpeedSaveScript {
    private var pending: [(speed: Double, continuation: CheckedContinuation<Void, Error>)] = []
    var pendingCount: Int { pending.count }

    func save(_ speed: Double) async throws {
        try await withCheckedThrowingContinuation { pending.append((speed, $0)) }
    }

    func finish(speed: Double, failing: Bool) {
        guard let index = pending.firstIndex(where: { $0.speed == speed }) else { return }
        let entry = pending.remove(at: index)
        if failing {
            entry.continuation.resume(throwing: CocoaError(.fileWriteUnknown))
        } else {
            entry.continuation.resume()
        }
    }
}
