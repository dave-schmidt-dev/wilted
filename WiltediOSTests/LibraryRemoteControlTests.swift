import Foundation
import Combine
import MediaPlayer
import WiltedDomain
import WiltedPlayback
import XCTest
@testable import WiltediOS

private final class RemoteSeekEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    var duration = 600.0
    var currentTime = 0.0
    var isPlaying = false
    var rate: Float = 1
    var refusePlay = false
    var failLoad = false
    private var generation: UInt64 = 0
    private var completion: (@Sendable (UInt64) -> Void)?
    func load(url: URL) throws { try load(url: url, completionGeneration: 0) }
    func load(url: URL, completionGeneration: UInt64) throws {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        generation = completionGeneration
        currentTime = 0
    }
    func play() -> Bool { isPlaying = !refusePlay; return isPlaying }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) { completion = handler }
    func finish() { currentTime = duration; isPlaying = false; completion?(generation) }
}

@MainActor
final class LibraryRemoteControlTests: XCTestCase {
    private struct Rig {
        let player: LibraryPlayer
        let engine: RemoteSeekEngine
        let adapter: MediaPlayerLibraryRemoteCommands
    }
    private func item(_ id: String = "remote-a") -> LibraryPlayer.Item {
        LibraryPlayer.Item(entryID: try! ItemID(rawValue: id), title: id, showTitle: "Show",
                           fileURL: URL(fileURLWithPath: "/nonexistent/remote-test.mp3"))
    }
    private func rig(playing: Bool = true) -> Rig {
        let engine = RemoteSeekEngine(), adapter = MediaPlayerLibraryRemoteCommands()
        let player = LibraryPlayer(engine: engine, session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
                                   remoteCommands: adapter, sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        XCTAssertTrue(player.start(item(), at: 100, autoplay: playing))
        return Rig(player: player, engine: engine, adapter: adapter)
    }

    func testImmediatePauseCancelsRemoteBeforeAuthorizationCanTakeCommandOwnership() async {
        let r = rig(playing: false); defer { r.player.stop() }
        var calls = 0
        r.player.authorizePlayback = { _ in calls += 1; return true }
        XCTAssertTrue(r.player.handle(.play))
        r.player.pause()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(r.engine.isPlaying)
    }

    func testReleaseCancelsHoldWhileAuthorizationIsSuspended() async {
        let r = rig(playing: false); defer { r.player.stop() }
        var waiter: CheckedContinuation<Bool, Never>?
        r.player.authorizePlayback = { _ in await withCheckedContinuation { waiter = $0 } }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        for _ in 0..<200 where waiter == nil { await Task.yield() }
        XCTAssertNotNil(waiter)
        XCTAssertFalse(r.player.handle(.endSeeking(.forward)))
        waiter?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(r.player.isRemoteSeeking)
        XCTAssertFalse(r.engine.isPlaying)
    }

    func testSkipCannotResumeAnActiveHoldAfterAdmissionIsWithdrawn() async {
        let r = rig(); defer { r.player.stop() }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        r.player.authorizePlayback = { _ in false }
        XCTAssertTrue(r.player.handle(.skipForward(30)))
        for _ in 0..<200 where r.player.item != nil { await Task.yield() }
        XCTAssertNil(r.player.item)
        XCTAssertFalse(r.engine.isPlaying)
        XCTAssertFalse(r.player.isRemoteSeeking)
    }

    func testHoldReleaseCannotResumeAfterAdmissionIsWithdrawn() async {
        let r = rig(); defer { r.player.stop() }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        r.player.authorizePlayback = { _ in false }
        XCTAssertTrue(r.player.handle(.endSeeking(.forward)))
        for _ in 0..<200 where r.player.item != nil { await Task.yield() }
        XCTAssertNil(r.player.item)
        XCTAssertFalse(r.engine.isPlaying)
        XCTAssertFalse(r.player.isRemoteSeeking)
    }

    func testProductionAdapterRegistersSteeringAndHoldCommands() {
        let r = rig(); defer { r.player.stop() }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.nextTrackCommand, center.previousTrackCommand, center.seekForwardCommand, center.seekBackwardCommand] {
            XCTAssertTrue(r.adapter.registeredCommands.contains { $0 === command }, "Actual production target must be installed")
        }
        XCTAssertTrue(r.adapter.dispatchTransport(center.seekForwardCommand, phase: .beginSeeking))
        XCTAssertTrue(r.player.isRemoteSeeking)
        XCTAssertTrue(r.adapter.dispatchTransport(center.seekForwardCommand, phase: .endSeeking))
        XCTAssertFalse(r.player.isRemoteSeeking)
        XCTAssertFalse(r.adapter.dispatchTransport(center.seekForwardCommand, phase: MPSeekCommandEventType(rawValue: 99)))
        r.adapter.uninstall()
        XCTAssertTrue(r.adapter.registeredCommands.isEmpty)
    }

    func testSteeringPressSkipsThirtyForwardAndFifteenBackWithoutChangingEpisode() {
        let r = rig(); defer { r.player.stop() }
        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(r.adapter.dispatchTransport(center.nextTrackCommand))
        XCTAssertEqual(r.player.position, 130)
        XCTAssertTrue(r.adapter.dispatchTransport(center.previousTrackCommand))
        XCTAssertEqual(r.player.position, 115)
        XCTAssertEqual(r.player.item?.entryID, item().entryID)
        r.adapter.setSkipIntervals(back: 5, forward: 45)
        XCTAssertEqual(center.skipBackwardCommand.preferredIntervals, [5])
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals, [45])
    }

    func testForwardHoldMovesAtEightTimesThenRestoresUserRateAndPlayingState() {
        let r = rig(); defer { r.player.stop() }
        r.player.setRate(1.25)
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        XCTAssertFalse(r.engine.isPlaying, "Paused engine cannot naturally advance to another episode during a hold")
        XCTAssertTrue(r.player.remoteSeekStep(elapsed: 2))
        XCTAssertEqual(r.player.position, 116)
        XCTAssertTrue(r.player.handle(.endSeeking(.forward)))
        XCTAssertTrue(r.engine.isPlaying)
        XCTAssertEqual(r.player.rate, 1.25)
        XCTAssertEqual(r.engine.rate, 1.25)
        XCTAssertFalse(r.player.isRemoteSeeking)
    }

    func testBackwardHoldPreservesAnOriginallyPausedPlayerOnRelease() {
        let r = rig(playing: false); defer { r.player.stop() }
        XCTAssertTrue(r.player.handle(.beginSeeking(.backward)))
        XCTAssertTrue(r.player.remoteSeekStep(elapsed: 3))
        XCTAssertEqual(r.player.position, 76)
        XCTAssertTrue(r.player.handle(.endSeeking(.backward)))
        XCTAssertEqual(r.player.status, .paused)
        XCTAssertFalse(r.engine.isPlaying)
    }

    func testHoldClampsAtBothBoundariesWithoutNaturalCompletionOrNextEpisode() {
        let r = rig(); defer { r.player.stop() }
        var finished = 0
        r.player.onFinished = { _, _ in finished += 1 }
        r.player.seek(to: 599)
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        XCTAssertFalse(r.player.remoteSeekStep(elapsed: 1))
        XCTAssertEqual(r.player.position, 600)
        XCTAssertFalse(r.player.isRemoteSeeking)
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(r.player.item?.entryID, item().entryID)
        r.player.seek(to: 1)
        XCTAssertTrue(r.player.handle(.beginSeeking(.backward)))
        XCTAssertFalse(r.player.remoteSeekStep(elapsed: 1))
        XCTAssertEqual(r.player.position, 0)
        XCTAssertFalse(r.engine.isPlaying)
    }

    func testRepeatedBeginAndDirectionSwitchKeepOneHoldAndIgnoreOldRelease() {
        let r = rig(); defer { r.player.stop() }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        XCTAssertTrue(r.player.remoteSeekStep(elapsed: 1))
        XCTAssertEqual(r.player.position, 108)
        XCTAssertTrue(r.player.handle(.beginSeeking(.backward)))
        XCTAssertFalse(r.player.handle(.endSeeking(.forward)))
        XCTAssertTrue(r.player.remoteSeekStep(elapsed: 1))
        XCTAssertEqual(r.player.position, 100)
        XCTAssertTrue(r.player.handle(.endSeeking(.backward)))
        XCTAssertTrue(r.engine.isPlaying)
    }

    func testPauseStopAndEligibilityUnloadCancelHeldSeeking() {
        for action in 0...2 {
            let r = rig(); defer { r.player.stop() }
            XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
            if action == 0 { r.player.pause() }
            else if action == 1 { r.player.stop() }
            else { r.player.invalidateLoadedItem() }
            let position = r.player.position
            XCTAssertFalse(r.player.isRemoteSeeking)
            XCTAssertFalse(r.player.remoteSeekStep(elapsed: 100))
            XCTAssertEqual(r.player.position, position)
            XCTAssertFalse(r.player.handle(.endSeeking(.forward)))
            XCTAssertFalse(r.engine.isPlaying)
        }
    }

    func testNewItemAndFailedLoadCannotReceiveTheOldHold() {
        let r = rig(); defer { r.player.stop() }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        XCTAssertTrue(r.player.start(item("remote-b"), at: 25, autoplay: false))
        XCTAssertFalse(r.player.remoteSeekStep(elapsed: 20))
        XCTAssertEqual(r.player.position, 25)
        XCTAssertFalse(r.player.handle(.endSeeking(.forward)))
        XCTAssertTrue(r.player.handle(.beginSeeking(.backward)))
        r.engine.failLoad = true
        XCTAssertFalse(r.player.start(item("remote-c")))
        XCTAssertFalse(r.player.isRemoteSeeking)
        XCTAssertFalse(r.player.remoteSeekStep(elapsed: 20))
        XCTAssertNil(r.player.item)
    }

    func testInterruptionRouteLossAndEngineFailureCancelHolds() {
        for event in [LibrarySessionEvent.interruptionBegan, .routeLost] {
            let r = rig(); defer { r.player.stop() }
            XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
            r.player.handle(event)
            XCTAssertFalse(r.player.isRemoteSeeking)
            XCTAssertFalse(r.player.remoteSeekStep(elapsed: 10))
            XCTAssertFalse(r.engine.isPlaying)
        }
        let r = rig(); defer { r.player.stop() }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        r.engine.refusePlay = true
        XCTAssertFalse(r.player.handle(.endSeeking(.forward)))
        XCTAssertFalse(r.player.isRemoteSeeking)
        XCTAssertFalse(r.engine.isPlaying)
    }

    func testEngineCompletionDuringHoldDoesNotStartAutomaticSuccessor() async {
        let r = rig(); defer { r.player.stop() }
        var finished = 0
        r.player.onFinished = { _, _ in finished += 1 }
        let changed = expectation(description: "completion processed")
        let observation = r.player.$status.dropFirst().sink { status in
            if status == .paused || status == .ended { changed.fulfill() }
        }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        r.engine.finish()
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(r.player.status, .paused)
        XCTAssertFalse(r.player.isRemoteSeeking)
        withExtendedLifetime(observation) {}
    }

    func testActualHoldTimerUsesInjectedClockAndStopsAfterRelease() async {
        let clock = VirtualTime(), installed = expectation(description: "seek sleeper registered")
        let signal = FirstSeekSleep(installed)
        let engine = RemoteSeekEngine(), adapter = MediaPlayerLibraryRemoteCommands()
        let player = LibraryPlayer(engine: engine, session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: adapter, sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600),
            remoteSeekSleep: { _ in try await clock.sleep(0.1, registered: { _ in signal.fire() }) },
            remoteSeekNow: { clock.now.timeIntervalSince1970 })
        defer { player.stop() }
        XCTAssertTrue(player.start(item(), at: 100))
        XCTAssertTrue(player.handle(.beginSeeking(.forward)))
        await fulfillment(of: [installed], timeout: 5)
        let moved = expectation(description: "actual timer moved position")
        let observation = player.$position.dropFirst().sink { value in
            if value > 100 { moved.fulfill() }
        }
        await clock.advance(by: 0.1)
        await fulfillment(of: [moved], timeout: 5)
        XCTAssertEqual(player.position, 100.8, accuracy: 0.001)
        XCTAssertTrue(player.handle(.endSeeking(.forward)))
        let released = player.position
        await clock.advance(by: 1)
        XCTAssertEqual(player.position, released)
        XCTAssertFalse(player.isRemoteSeeking)
        withExtendedLifetime(observation) {}
    }

    func testNoItemAndInvalidTickRefuseSeekingWithoutRevivingPlayback() {
        let r = rig(); defer { r.player.stop() }
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        XCTAssertFalse(r.player.remoteSeekStep(elapsed: .nan))
        XCTAssertEqual(r.player.position, 100)
        r.player.stop()
        XCTAssertFalse(r.player.handle(.beginSeeking(.forward)))
        XCTAssertFalse(r.player.handle(.endSeeking(.backward)))
        XCTAssertFalse(r.adapter.dispatchTransport(MPRemoteCommandCenter.shared().nextTrackCommand))
        XCTAssertFalse(r.engine.isPlaying)
    }
    func testOwnedHoldSameEntryReloadAndOtherPlayerIdentityRejectStaleEnd() async throws {
        let r = rig(); defer { r.player.stop() }
        let first = try XCTUnwrap(r.player.seekSessionID), oldID = UUID()
        let ownedResult1 = await r.player.beginOwnedSeeking(.forward, holdID: oldID, sessionID: first)
        XCTAssertTrue(ownedResult1)
        XCTAssertTrue(r.player.start(item(), at: 100))
        let second = try XCTUnwrap(r.player.seekSessionID), newID = UUID()
        XCTAssertNotEqual(first, second)
        let ownedResult2 = await r.player.beginOwnedSeeking(.forward, holdID: newID, sessionID: second)
        XCTAssertTrue(ownedResult2)
        let ownedResult3 = await r.player.endOwnedSeeking(.forward, holdID: oldID, sessionID: first)
        XCTAssertFalse(ownedResult3)
        XCTAssertTrue(r.player.isRemoteSeeking)
        let other = rig(); defer { other.player.stop() }
        XCTAssertNotEqual(other.player.seekSessionID, second)
        let ownedResult4 = await other.player.beginOwnedSeeking(.forward, holdID: newID, sessionID: second)
        XCTAssertFalse(ownedResult4)
    }

    func testCarSameDirectionHoldSupersedesExternalOwnerWithoutChangingCarAPI() async throws {
        let r = rig(); defer { r.player.stop() }
        let session = try XCTUnwrap(r.player.seekSessionID), id = UUID()
        let ownedResult5 = await r.player.beginOwnedSeeking(.forward, holdID: id, sessionID: session)
        XCTAssertTrue(ownedResult5)
        XCTAssertTrue(r.player.handle(.beginSeeking(.forward)))
        let ownedResult6 = await r.player.endOwnedSeeking(.forward, holdID: id, sessionID: session)
        XCTAssertFalse(ownedResult6)
        XCTAssertTrue(r.player.isRemoteSeeking)
        XCTAssertTrue(r.player.handle(.endSeeking(.forward)))
        XCTAssertFalse(r.player.isRemoteSeeking)
    }

    func testMatchingReleaseCancelsPendingOwnedAdmissionBeforeLateBegin() async throws {
        let r = rig(); defer { r.player.stop() }
        let session = try XCTUnwrap(r.player.seekSessionID), id = UUID()
        var gate: CheckedContinuation<Bool, Never>?
        r.player.authorizePlayback = { _ in await withCheckedContinuation { gate = $0 } }
        let begin = Task { @MainActor in await r.player.beginOwnedSeeking(.forward, holdID: id, sessionID: session) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let waiting = try XCTUnwrap(gate)
        gate = nil
        let ownedResult7 = await r.player.endOwnedSeeking(.forward, holdID: id, sessionID: session)
        XCTAssertTrue(ownedResult7)
        waiting.resume(returning: true)
        let ownedResult8 = await begin.value
        XCTAssertFalse(ownedResult8)
        XCTAssertFalse(r.player.isRemoteSeeking)
    }

    func testPendingDirectionReplacementReleaseStopsItsTransferredHold() async throws {
        let r = rig(); defer { r.player.stop() }
        let session = try XCTUnwrap(r.player.seekSessionID), firstID = UUID(), secondID = UUID()
        let first = await r.player.beginOwnedSeeking(.backward, holdID: firstID, sessionID: session)
        XCTAssertTrue(first)
        var gate: CheckedContinuation<Bool, Never>?
        r.player.authorizePlayback = { _ in await withCheckedContinuation { gate = $0 } }
        let begin = Task { @MainActor in await r.player.beginOwnedSeeking(.forward, holdID: secondID, sessionID: session) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let waiting = try XCTUnwrap(gate); gate = nil
        // Restore via the normal player admission path without blocking a second continuation.
        r.player.authorizePlayback = { _ in true }
        let released = await r.player.endOwnedSeeking(.forward, holdID: secondID, sessionID: session)
        XCTAssertTrue(released); XCTAssertFalse(r.player.isRemoteSeeking)
        waiting.resume(returning: true)
        let late = await begin.value
        XCTAssertFalse(late); XCTAssertTrue(r.player.isPlaying)
    }

}

/// Signals actual waiter insertion once, rather than guessing scheduler readiness.
private final class FirstSeekSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let expectation: XCTestExpectation
    init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func fire() {
        let first = lock.withLock { if fired { return false }; fired = true; return true }
        if first { expectation.fulfill() }
    }

}
