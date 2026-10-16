import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

@MainActor
private final class SeekBackend: PlaybackBackend {
    var duration: TimeInterval = 42
    var currentTime: TimeInterval = 0 {
        didSet { trace.append("time:\(currentTime)"); onTime?(currentTime) }
    }
    var onTime: (@MainActor (Double) -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onLoad: (@MainActor () -> Void)?
    var loadError: Error?
    var isPlaying = false
    var rate: Float = 1
    var volume: Float = 1
    var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    var trace: [String] = []
    var playPositions: [Double] = []
    func load(url: URL) throws {
        if let loadError { throw loadError }
        loadedGeneration &+= 1
        currentTime = 0
        isPlaying = false
        onLoad?()
    }
    func play() -> Bool { trace.append("play"); playPositions.append(currentTime); isPlaying = true; return true }
    func pause() { trace.append("pause"); isPlaying = false }
    func stop() { trace.append("stop"); isPlaying = false; onStop?() }
}

private extension LocalLibraryStore {
    func holdSeekStore(entered: @Sendable () -> Void, release: DispatchSemaphore) {
        entered()
        release.wait()
    }
}

@MainActor
extension PlaybackControllerTests {
    private struct SeekRig {
        let controller: PlaybackController
        let backend: SeekBackend
        let speaker: StubSpeaker
        let route: InterruptionRoute
        let store: LocalLibraryStore
        let revision: AudioRevision
        let root: URL
    }

    private func seekRig(playing: Bool = true, speaking: Bool = true, deviceID: String = "test-device") async throws -> SeekRig {
        let path = storeURL()
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try await storedFixture(in: store)
        let backend = SeekBackend()
        let controller = PlaybackController(store: store, backend: backend, deviceID: deviceID)
        try await controller.load(revision: revision, mediaURL: path.deletingLastPathComponent().appendingPathComponent("fake.m4a"))
        let speaker = StubSpeaker()
        let route = InterruptionRoute()
        let wall = TestWallClock()
        controller.enableInterruptions(speaker: speaker, waitLimit: 60, clock: wall.clock, cues: nil, routeSource: route)
        backend.currentTime = 12
        if playing { try controller.play() }
        if speaking { controller.deliverBulletin(try bulletin("seek", at: wall.now)) }
        backend.trace.removeAll()
        backend.playPositions.removeAll()
        return SeekRig(controller: controller, backend: backend, speaker: speaker, route: route,
                       store: store, revision: revision, root: path.deletingLastPathComponent())
    }

    func testSpeechSeekForwardAndBackwardRestoreBeforeTargetAndResumeOnlyAtTarget() async throws {
        for target in [30.0, 4.0] {
            let rig = try await seekRig()
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            let session = rig.controller.sessionID
            let hold = rig.controller.explicitHoldSerial
            rig.speaker.reentrantStop = true
            let late = rig.speaker.completions.first
            try await rig.controller.seek(to: target)
            late?()
            XCTAssertEqual(rig.backend.currentTime, target)
            XCTAssertEqual(rig.backend.playPositions, [target])
            XCTAssertEqual(rig.backend.trace.last, "play")
            XCTAssertEqual(rig.backend.trace.filter { $0 == "time:12.0" }.count, 1)
            XCTAssertNil(rig.controller.speakingBulletin)
            XCTAssertTrue(rig.controller.isPlaying)
            XCTAssertEqual(rig.controller.explicitHoldSerial, hold, "seek is not listener Pause")
            XCTAssertEqual(rig.controller.intent, target < 12 ? .rewind : .progress)
            XCTAssertEqual(rig.controller.sessionID == session, target >= 12)
            let saved = try await rig.store.playbackState(for: rig.revision.itemID, revisionID: rig.revision.revisionID)
            XCTAssertEqual(saved?.positionSeconds, target)
            XCTAssertEqual(rig.controller.lifetimeMeter.skippedSeconds, target >= 12 ? 18 : 0)
        }
    }

    func testPausedSeekForwardAndBackwardKeepPriorPausedIntent() async throws {
        for target in [30.0, 4.0] {
            let rig = try await seekRig(playing: false, speaking: false)
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            try await rig.controller.seek(to: target)
            XCTAssertEqual(rig.backend.currentTime, target)
            XCTAssertTrue(rig.backend.playPositions.isEmpty)
            XCTAssertFalse(rig.controller.liveIsPlaying)
        }
    }

    func testSynchronousPauseDuringSpeechStopWinsBeforeSeekTarget() async throws {
        let rig = try await seekRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        rig.speaker.onStop = { try? rig.controller.pauseAudio() }
        try await rig.controller.seek(to: 30)
        rig.speaker.onStop = nil
        XCTAssertEqual(rig.backend.currentTime, 12)
        XCTAssertFalse(rig.backend.trace.contains("time:30.0"))
        XCTAssertTrue(rig.backend.playPositions.isEmpty)
        XCTAssertFalse(rig.controller.liveIsPlaying)
    }

    func testNewerCommandDuringRestoreCannotBeOverwrittenBySeek() async throws {
        let rig = try await seekRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        rig.backend.onTime = { time in
            guard time == 12 else { return }
            rig.backend.onTime = nil
            rig.controller.commandGeneration &+= 1
            rig.backend.currentTime = 25
        }
        try await rig.controller.seek(to: 30)
        XCTAssertEqual(rig.backend.currentTime, 25)
        XCTAssertTrue(rig.backend.playPositions.isEmpty)
    }

    /// The actor is held before seek starts; target application is the causal signal that
    /// the seek reached persistence. Early completion also releases the waiter, so a
    /// pre-target error cannot strand the actor gate. No audio or polling is needed.
    private func blockedSeek(
        _ rig: SeekRig, target: Double,
        whileBlocked: @MainActor () async throws -> Void
    ) async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            Task { await rig.store.holdSeekStore(entered: { entered.resume() }, release: release) }
        }
        var seek: Task<Void, Error>?
        var reachedTarget = false
        await withCheckedContinuation { (targetOrCompletion: CheckedContinuation<Void, Never>) in
            var signal: (@MainActor () -> Void)? = { targetOrCompletion.resume() }
            rig.backend.onTime = { time in
                guard time == target else { return }
                reachedTarget = true
                rig.backend.onTime = nil
                let done = signal
                signal = nil
                done?()
            }
            seek = Task {
                defer {
                    rig.backend.onTime = nil
                    let done = signal
                    signal = nil
                    done?()
                }
                try await rig.controller.seek(to: target)
            }
        }
        do {
            if reachedTarget { try await whileBlocked() }
        } catch {
            release.signal()
            _ = try? await seek?.value
            throw error
        }
        release.signal()
        try await seek?.value
    }

    func testNewerPauseOrStopDuringSeekPersistencePreventsResume() async throws {
        for target in [30.0, 4.0] {
            for stop in [false, true] {
                let rig = try await seekRig()
                defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
                try await blockedSeek(rig, target: target) {
                    XCTAssertTrue(rig.backend.playPositions.isEmpty)
                    if stop {
                        // Stop's synchronous authority is the same hold serial; durable work follows later.
                        rig.controller.explicitHoldSerial &+= 1
                        rig.backend.stop()
                    } else { try rig.controller.pauseAudio() }
                }
                XCTAssertEqual(rig.backend.currentTime, target)
                XCTAssertTrue(rig.backend.playPositions.isEmpty)
                XCTAssertFalse(rig.controller.liveIsPlaying)
            }
        }
    }

    func testRouteAwayAndBackDuringSeekPersistenceNeverRevivesResume() async throws {
        for target in [30.0, 4.0] {
            let rig = try await seekRig()
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            let original = rig.route.route
            try await blockedSeek(rig, target: target) {
                XCTAssertTrue(rig.backend.playPositions.isEmpty)
                rig.route.route = MacAudioRoute(device: 20)
                rig.route.changed?()
                rig.route.route = original
                rig.route.changed?()
            }
            XCTAssertEqual(rig.backend.currentTime, target)
            XCTAssertTrue(rig.backend.playPositions.isEmpty)
            XCTAssertFalse(rig.controller.liveIsPlaying)
        }
    }

    func testUnchangedRouteDuringSeekPersistencePermitsResumeAtTarget() async throws {
        let rig = try await seekRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try await blockedSeek(rig, target: 30) { rig.route.changed?() }
        XCTAssertEqual(rig.backend.playPositions, [30])
    }

    func testNewerSeekDuringPersistenceOwnsTargetAndOldSeekCannotResume() async throws {
        for (first, target) in [(30.0, 35.0), (4.0, 2.0)] {
            let rig = try await seekRig()
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            var newer: Task<Void, Error>?
            try await blockedSeek(rig, target: first) {
                XCTAssertTrue(rig.backend.playPositions.isEmpty)
                await withCheckedContinuation { (applied: CheckedContinuation<Void, Never>) in
                    rig.backend.onTime = { time in
                        guard time == target else { return }
                        rig.backend.onTime = nil
                        applied.resume()
                    }
                    newer = Task { try await rig.controller.seek(to: target) }
                }
            }
            try await newer?.value
            XCTAssertEqual(rig.backend.currentTime, target)
            XCTAssertEqual(rig.backend.playPositions, [target])
        }
    }

    func testItemChangeDuringSeekPersistencePreventsOldResume() async throws {
        let rig = try await seekRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try await blockedSeek(rig, target: 30) {
            // Item admission bumps this generation synchronously before its interruption hook.
            rig.controller.loadedBackendGeneration = (rig.controller.loadedBackendGeneration ?? 0) &+ 1
            rig.controller.interruptionItemChanged()
            rig.backend.currentTime = 0
        }
        XCTAssertEqual(rig.backend.currentTime, 0)
        XCTAssertTrue(rig.backend.playPositions.isEmpty)
    }

    func testRouteFailureOnFinalReadAndNewerPauseInsideReadPreventSeekResume() async throws {
        for newerPause in [false, true] {
            let rig = try await seekRig()
            defer {
                rig.route.beforeRead = nil
                rig.controller.disableInterruptions(resuming: false)
                try? FileManager.default.removeItem(at: rig.root)
            }
            try await blockedSeek(rig, target: 30) {
                rig.route.beforeRead = {
                    rig.route.beforeRead = nil
                    if newerPause { try? rig.controller.pauseAudio() } else { rig.route.route = nil }
                }
            }
            XCTAssertEqual(rig.backend.currentTime, 30)
            XCTAssertTrue(rig.backend.playPositions.isEmpty)
        }
    }

    func testBackwardBackendStopCannotOverrideNewerPause() async throws {
        let rig = try await seekRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        rig.backend.onStop = { try? rig.controller.pauseAudio() }
        try await rig.controller.seek(to: 4)
        rig.backend.onStop = nil
        XCTAssertEqual(rig.backend.currentTime, 12)
        XCTAssertTrue(rig.backend.playPositions.isEmpty)
    }

    func testWatchdogStopCannotConsumeSpeechOwnedByANewerCommand() async throws {
        let rig = try await seekRig(speaking: false)
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        let wall = TestWallClock()
        wall.firesWatchdog = true
        rig.controller.enableInterruptions(speaker: rig.speaker, waitLimit: 60, clock: wall.clock,
                                           cues: nil, routeSource: rig.route)
        let first = try bulletin("first", at: wall.now)
        let next = try bulletin("next", at: wall.now)
        await withCheckedContinuation { (stopped: CheckedContinuation<Void, Never>) in
            rig.speaker.onStop = {
                rig.speaker.onStop = nil
                try? rig.controller.pauseAudio()
                try? rig.controller.play()
                // The successor stays live so an old snapshot must not consume its reducer state.
                wall.firesWatchdog = false
                rig.controller.deliverBulletin(next)
                stopped.resume()
            }
            rig.controller.deliverBulletin(first)
        }
        XCTAssertEqual(rig.controller.speakingBulletin?.id, "next")
        guard let engine = rig.controller.interruptions, case .speaking = engine.reducer.state else {
            return XCTFail("old timeout consumed the newer speech")
        }
    }

    func testPlainPlayingRewindPlaysImmediatelyBeforeBlockedPersistence() async throws {
        let rig = try await seekRig(speaking: false)
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        rig.controller.disableInterruptions(resuming: false)
        try await blockedSeek(rig, target: 4) {
            XCTAssertEqual(rig.backend.playPositions, [4])
            XCTAssertTrue(rig.controller.isPlaying)
        }
        XCTAssertEqual(rig.backend.playPositions, [4])
    }

    func testCheckpointValidationFailureResumesSpeechSeekAtTargetAndRethrows() async throws {
        for target in [30.0, 4.0] {
            // The supported device identity constructor reaches PlaybackState's actual
            // validation error without corrupting or deleting a store to simulate failure.
            let rig = try await seekRig(deviceID: "")
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            do {
                try await rig.controller.seek(to: target)
                XCTFail("invalid checkpoint identity must be reported")
            } catch let error as DomainError {
                guard case let .invalidValue(field, _) = error else { return XCTFail("unexpected error: \(error)") }
                XCTAssertEqual(field, "deviceID")
            }
            XCTAssertEqual(rig.backend.currentTime, target)
            XCTAssertEqual(rig.backend.playPositions, [target])
            XCTAssertTrue(rig.controller.isPlaying)
        }
    }

    func testDisableOrMonitoringFailureDuringPersistenceNeverResumesSeek() async throws {
        for monitoringFailure in [false, true] {
            let rig = try await seekRig()
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            try await blockedSeek(rig, target: 30) {
                if monitoringFailure {
                    rig.route.monitoringAvailable = false
                    rig.route.changed?()
                } else { rig.controller.disableInterruptions(resuming: false) }
            }
            XCTAssertEqual(rig.backend.currentTime, 30)
            XCTAssertTrue(rig.backend.playPositions.isEmpty)
            XCTAssertFalse(rig.controller.interruptionsEnabled)
        }
    }

    func testRewindReloadOwnsExactlyOneCommandIncrementAndFencesLoadCallback() async throws {
        for newerPause in [false, true] {
            let rig = try await seekRig()
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            let before = rig.controller.commandGeneration
            let backendGeneration = rig.backend.loadedGeneration
            rig.backend.onLoad = { if newerPause { try? rig.controller.pauseAudio() } }
            try await rig.controller.seek(to: 4)
            rig.backend.onLoad = nil
            XCTAssertEqual(rig.backend.loadedGeneration, backendGeneration &+ 1)
            XCTAssertEqual(rig.controller.commandGeneration, before &+ (newerPause ? 3 : 2),
                           "seek claims one command and loadedBackendGeneration.didSet claims exactly one")
            XCTAssertEqual(rig.backend.playPositions, newerPause ? [] : [4])
            if newerPause { XCTAssertFalse(rig.backend.trace.contains("time:4.0")) }
        }
    }

    func testBlockedSeekCompletesWhenLoadFailsBeforeTarget() async throws {
        let rig = try await seekRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        rig.backend.loadError = CancellationError()
        do {
            try await blockedSeek(rig, target: 4) { XCTFail("target was not applied") }
            XCTFail("an unsuperseded backend cancellation remains an error")
        } catch is CancellationError {} catch { throw error }
        XCTAssertTrue(rig.backend.playPositions.isEmpty)
    }


    func testNewerPauseOrPositionDuringSeekTargetWriteWinsWithoutResume() async throws {
        for target in [30.0, 4.0] {
            for movesPosition in [false, true] {
                let rig = try await seekRig()
                defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
                let staleSpeech = rig.speaker.completions.first
                rig.backend.onTime = { time in
                    guard time == target else { return }
                    rig.backend.onTime = nil
                    try? rig.controller.pauseAudio()
                    if movesPosition { rig.backend.currentTime = 25 }
                }
                try await rig.controller.seek(to: target)
                staleSpeech?()
                XCTAssertEqual(rig.backend.currentTime, movesPosition ? 25 : target)
                XCTAssertEqual(rig.controller.livePositionSeconds, movesPosition ? 25 : target)
                XCTAssertTrue(rig.backend.playPositions.isEmpty)
                XCTAssertFalse(rig.backend.isPlaying)
                XCTAssertFalse(rig.controller.isPlaying)
                XCTAssertFalse(rig.controller.liveIsPlaying)
                XCTAssertEqual(rig.backend.trace.filter { $0 == "time:12.0" }.count, 1,
                               "the canceled hold restores only before the target write")
            }
        }
    }

    func testBackwardLoadFailureReportsRouteUnavailableAndTruthfulStoppedState() async throws {
        for speaking in [false, true] {
            let rig = try await seekRig(speaking: speaking)
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            rig.backend.loadError = CocoaError(.fileReadCorruptFile)
            do {
                try await rig.controller.seek(to: 4)
                XCTFail("failed backend load must propagate")
            } catch let error as PlaybackTransportError {
                XCTAssertEqual(error, .routeUnavailable(rig.revision.itemID))
            }
            XCTAssertFalse(rig.backend.trace.contains("time:4.0"), "failed reload never applies the seek target")
            XCTAssertTrue(rig.backend.playPositions.isEmpty, "no route recovery or target resume")
            XCTAssertFalse(rig.backend.isPlaying)
            XCTAssertFalse(rig.controller.isPlaying)
            XCTAssertFalse(rig.controller.liveIsPlaying)
        }
    }

}
