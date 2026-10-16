import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

@MainActor
extension PlaybackControllerTests {
    func testRouteLossVariantsStopReentrantSpeechAndNeverPlay() async throws {
        let losses: [MacAudioRoute?] = [
            MacAudioRoute(device: 20, source: 1, jackConnected: true), // fallback output
            MacAudioRoute(device: 10, source: 2, jackConnected: true), // source changed
            MacAudioRoute(device: 10, source: 1, jackConnected: false), // jack removed
            MacAudioRoute(device: 10, source: 1, jackConnected: true, alive: false), nil
        ]
        for loss in losses {
            let rig = try await interruptionRig()
            defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
            try rig.controller.play()
            rig.backend.currentTime = 12
            rig.controller.deliverBulletin(try bulletin("loss", at: rig.wall.now))
            rig.speaker.reentrantStop = true
            let oldCompletion = try XCTUnwrap(rig.speaker.completions.first)
            rig.route.route = loss
            rig.route.changed?()
            oldCompletion()
            XCTAssertGreaterThan(rig.speaker.stopCount, 0)
            XCTAssertEqual(rig.backend.playCount, 1, "route loss adds zero play calls")
            XCTAssertFalse(rig.backend.isPlaying)
            XCTAssertFalse(rig.controller.isPlaying)
            XCTAssertEqual(rig.backend.currentTime, 12)
            XCTAssertNil(rig.controller.speakingBulletin)
        }
    }

    func testQueuedRouteLossIsQueriedBeforeSpeechCompletionAndChainedSpeech() async throws {
        let rig = try await interruptionRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.backend.currentTime = 13
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        rig.controller.deliverBulletin(try bulletin("two", at: rig.wall.now))
        // No notification delivered yet: the completion must query actual hardware.
        rig.route.route = MacAudioRoute(device: 20)
        rig.speaker.finishSpeaking()
        XCTAssertEqual(rig.speaker.spoken.count, 1)
        XCTAssertEqual(rig.backend.playCount, 1)
        XCTAssertEqual(rig.backend.currentTime, 13)
        XCTAssertFalse(rig.backend.isPlaying)
    }

    func testFailedRouteQueryAfterRestoreSuppressesResumeWhileReducerIsIdle() async throws {
        let rig = try await interruptionRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.backend.currentTime = 17
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        rig.backend.afterRestore = { rig.route.route = nil }
        rig.speaker.finishSpeaking()
        XCTAssertEqual(rig.backend.playCount, 1)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertFalse(rig.controller.isPlaying)
        XCTAssertEqual(rig.backend.currentTime, 17)
        XCTAssertNil(rig.controller.speakingBulletin)
    }

    func testChainedExtremesKeepFirstRouteAndCheckpointAndFenceOldCompletion() async throws {
        let rig = try await interruptionRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.backend.currentTime = 9
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        rig.controller.deliverBulletin(try bulletin("two", at: rig.wall.now))
        let old = try XCTUnwrap(rig.speaker.completions.first)
        let baseline = rig.controller.interruptions?.heldRoute
        rig.backend.currentTime = 9.03
        rig.speaker.finishSpeaking()
        XCTAssertEqual(rig.speaker.spoken.count, 2)
        XCTAssertEqual(rig.controller.interruptions?.heldRoute, baseline)
        XCTAssertEqual(rig.controller.interruptions?.heldCheckpoint?.positionSeconds, 9)
        old()
        XCTAssertEqual(rig.controller.speakingBulletin?.id, "two")
        XCTAssertEqual(rig.backend.playCount, 1)
        rig.route.route = MacAudioRoute(device: 20)
        rig.route.changed?()
        XCTAssertEqual(rig.backend.currentTime, 9)
        XCTAssertEqual(rig.backend.playCount, 1)
    }

    func testUnchangedNotificationsAndHealthyChangesOutsideHoldAreHarmless() async throws {
        let rig = try await interruptionRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.route.route = MacAudioRoute(device: 20)
        rig.route.changed?()
        XCTAssertTrue(rig.backend.isPlaying)
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        rig.route.changed?()
        XCTAssertEqual(rig.speaker.stopCount, 0)
        rig.speaker.finishSpeaking()
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.playCount, 2)
    }

    func testNonResumingDisableBalancesSourceAndFencesStaleListenerAndSpeaker() async throws {
        let rig = try await interruptionRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.backend.currentTime = 8
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        let staleRoute = rig.route.changed
        let staleSpeech = rig.speaker.completions.first
        rig.speaker.reentrantStop = true
        rig.controller.disableInterruptions(resuming: false)
        XCTAssertEqual(rig.route.starts, rig.route.stops)
        XCTAssertNil(rig.route.changed)
        XCTAssertEqual(rig.backend.playCount, 1)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.currentTime, 8)
        rig.controller.enableInterruptions(speaker: rig.speaker, waitLimit: 60, clock: rig.wall.clock,
                                           cues: nil, routeSource: rig.route)
        try rig.controller.play()
        rig.controller.deliverBulletin(try bulletin("two", at: rig.wall.now))
        staleRoute?()
        staleSpeech?()
        XCTAssertEqual(rig.controller.speakingBulletin?.id, "two")
        XCTAssertEqual(rig.backend.playCount, 2)
    }

    func testRouteLossStopCannotRestoreOverANewerReentrantCommand() async throws {
        let rig = try await interruptionRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.backend.currentTime = 8
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        rig.speaker.onStop = {
            // A newer command claims the same item while the old stop is on the stack.
            rig.controller.commandGeneration &+= 1
            rig.backend.currentTime = 30
        }
        rig.route.route = nil
        rig.route.changed?()
        XCTAssertEqual(rig.backend.currentTime, 30)
        XCTAssertEqual(rig.backend.playCount, 1)
        rig.speaker.onStop = nil
    }

    func testReleasedInterruptionOwnerUnregistersItsSource() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        weak var engine = rig.controller.interruptions
        rig.controller.interruptions = nil
        XCTAssertNil(engine)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(rig.route.changed)
        XCTAssertEqual(rig.route.stops, 1)
    }

    func testRouteChangesBetweenCompletionQueryAndChainedSpeakAreRejected() async throws {
        let rig = try await interruptionRig()
        defer {
            rig.route.beforeRead = nil
            rig.controller.disableInterruptions(resuming: false)
            try? FileManager.default.removeItem(at: rig.root)
        }
        try rig.controller.play()
        rig.backend.currentTime = 11
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        rig.controller.deliverBulletin(try bulletin("two", at: rig.wall.now))
        let beforeChainedSpeak = rig.route.reads + 2
        rig.route.beforeRead = {
            if rig.route.reads == beforeChainedSpeak { rig.route.route = MacAudioRoute(device: 20) }
        }
        rig.speaker.finishSpeaking()
        XCTAssertEqual(rig.speaker.spoken.count, 1)
        XCTAssertEqual(rig.backend.playCount, 1)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.currentTime, 11)
        XCTAssertNil(rig.controller.speakingBulletin)
    }

    func testDisableCancelsTickerRestartedForPendingBulletins() async throws {
        for resuming in [true, false] {
            let rig = try await interruptionRig()
            defer { try? FileManager.default.removeItem(at: rig.root) }
            try rig.controller.play()
            rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
            rig.controller.deliverBulletin(try bulletin("pending", .headline, .unknown, at: rig.wall.now))
            let engine = try XCTUnwrap(rig.controller.interruptions)
            XCTAssertFalse(engine.reducer.pending.isEmpty)
            XCTAssertNotNil(engine.tickTask)
            rig.controller.disableInterruptions(resuming: resuming)
            XCTAssertNil(engine.tickTask, "ending a hold must not leave a replacement pending ticker")
            XCTAssertNil(engine.watchdog)
            XCTAssertNil(engine.pausePointTask)
            XCTAssertFalse(rig.controller.interruptionsEnabled)
        }
    }

    func testRuntimeMonitoringFailureDisablesSpeechStopsSourceAndReportsWithoutPlay() async throws {
        let rig = try await interruptionRig()
        defer { rig.controller.disableInterruptions(resuming: false); try? FileManager.default.removeItem(at: rig.root) }
        var reports = 0
        rig.controller.interruptions?.protectionFailed = { reports += 1 }
        try rig.controller.play()
        rig.backend.currentTime = 14
        rig.controller.deliverBulletin(try bulletin("one", at: rig.wall.now))
        let late = try XCTUnwrap(rig.speaker.completions.first)
        rig.route.monitoringAvailable = false
        rig.route.changed?()
        late()
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(rig.route.stops, 1)
        XCTAssertNil(rig.route.changed)
        XCTAssertFalse(rig.controller.interruptionsEnabled)
        XCTAssertNil(rig.controller.speakingBulletin)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertFalse(rig.controller.isPlaying)
        XCTAssertEqual(rig.backend.currentTime, 14)
        XCTAssertEqual(rig.backend.playCount, 1)
        XCTAssertGreaterThan(rig.speaker.stopCount, 0)
    }
}
