import Foundation
import WiltedDomain
import WiltedListener
import XCTest
@testable import WiltediOS

/// Records every call so a test can assert what the player asked of the engine.
private final class PlayerFakeEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTime = 0.0
    private var _isPlaying = false
    private var handler: (@Sendable (UInt64) -> Void)?
    private var generation: UInt64 = 0
    var duration = 600.0
    var rate: Float = 1
    var refusePlay = false
    var failLoad = false
    private(set) var loads: [URL] = []
    private(set) var pauseCount = 0

    var currentTime: Double {
        get { lock.withLock { _currentTime } }
        set { lock.withLock { _currentTime = newValue } }
    }
    var isPlaying: Bool {
        get { lock.withLock { _isPlaying } }
        set { lock.withLock { _isPlaying = newValue } }
    }

    func load(url: URL) throws { try load(url: url, completionGeneration: 0) }
    func load(url: URL, completionGeneration: UInt64) throws {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        loads.append(url)
        generation = completionGeneration
        currentTime = 0
    }
    func play() -> Bool {
        guard !refusePlay else { return false }
        isPlaying = true
        return true
    }
    func pause() { pauseCount += 1; isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) { self.handler = handler }

    /// The file played out: the engine stops and reports the load it finished.
    func finishNaturally(reporting reported: UInt64? = nil) {
        isPlaying = false
        currentTime = duration
        handler?(reported ?? generation)
    }
}

/// An engine with no speed control.
private final class FixedSpeedEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration = 60.0
    var currentTime = 0.0
    var isPlaying = false
    func load(url: URL) throws {}
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
}

private final class PlayerFakeSession: ListenerAudioSession, @unchecked Sendable {
    private(set) var activations = 0
    private(set) var deactivations = 0
    var failActivation = false
    func activate() throws {
        if failActivation { throw CocoaError(.featureUnsupported) }
        activations += 1
    }
    func deactivate() { deactivations += 1 }
}

private final class PlayerFakeNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    struct Update: Equatable { let title: String; let duration: Double; let position: Double; let rate: Double }
    private(set) var updates: [Update] = []
    private(set) var clears = 0
    func update(title: String, duration: Double, position: Double, rate: Double) {
        updates.append(Update(title: title, duration: duration, position: position, rate: rate))
    }
    func clear() { clears += 1 }
}

@MainActor private final class PlayerFakeRemote: LibraryRemoteCommands {
    private(set) var handler: (@MainActor (LibraryRemoteCommand) -> Bool)?
    private(set) var installs = 0
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) { installs += 1; self.handler = handler }
    func uninstall() { handler = nil }
    private(set) var skipIntervals: (back: TimeInterval, forward: TimeInterval)?
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval) { skipIntervals = (back, forward) }
}

@MainActor private final class PlayerFakeEvents: LibrarySessionEvents {
    private var handler: (@MainActor (LibrarySessionEvent) -> Void)?
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) { self.handler = handler }
    func send(_ event: LibrarySessionEvent) { handler?(event) }
}

@MainActor
final class LibraryPlayerTests: XCTestCase {
    private let item = LibraryPlayer.Item(
        entryID: try! ItemID(rawValue: "entry-1"), title: "Episode One", showTitle: "Show",
        fileURL: URL(fileURLWithPath: "/nonexistent/wilted-player-test.mp3"))

    private struct Rig {
        let player: LibraryPlayer
        let engine: PlayerFakeEngine
        let session: PlayerFakeSession
        let nowPlaying: PlayerFakeNowPlaying
        let remote: PlayerFakeRemote
        let events: PlayerFakeEvents
    }

    private func makeRig(engine: PlayerFakeEngine = PlayerFakeEngine(), tick: Duration = .seconds(3600)) -> Rig {
        let session = PlayerFakeSession(), nowPlaying = PlayerFakeNowPlaying(), remote = PlayerFakeRemote(), events = PlayerFakeEvents()
        let player = LibraryPlayer(
            engine: engine, session: session, nowPlaying: nowPlaying, remoteCommands: remote,
            sessionEvents: events, tickInterval: tick)
        return Rig(player: player, engine: engine, session: session, nowPlaying: nowPlaying, remote: remote, events: events)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    // MARK: Play, pause, seek

    func testPlayLoadsActivatesSessionAndPublishesNowPlaying() {
        let rig = makeRig()
        XCTAssertTrue(rig.player.start(item, at: 90))
        XCTAssertEqual(rig.engine.loads, [item.fileURL])
        XCTAssertEqual(rig.session.activations, 1)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.duration, 600)
        XCTAssertEqual(rig.player.position, 90)
        XCTAssertEqual(rig.remote.installs, 1)
        XCTAssertEqual(rig.nowPlaying.updates.last, .init(title: "Episode One", duration: 600, position: 90, rate: 1))
    }

    func testStartPastTheEndIsClamped() {
        let rig = makeRig()
        rig.player.start(item, at: 9_999, autoplay: false)
        XCTAssertEqual(rig.player.position, 600)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.engine.isPlaying)
    }

    func testPauseStopsTheEngineAndReportsZeroRate() {
        let rig = makeRig()
        rig.player.start(item)
        rig.engine.currentTime = 42
        rig.player.pause()
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42)
        XCTAssertEqual(rig.nowPlaying.updates.last, .init(title: "Episode One", duration: 600, position: 42, rate: 0))
    }

    func testTogglePlayPauseAlternates() {
        let rig = makeRig()
        rig.player.start(item)
        rig.player.togglePlayPause()
        XCTAssertEqual(rig.player.status, .paused)
        rig.player.togglePlayPause()
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.session.activations, 2, "resuming re-activates the session")
    }

    func testSeekMovesTheEngineClampsAndUpdatesNowPlaying() {
        let rig = makeRig()
        rig.player.start(item)
        rig.player.seek(to: 300)
        XCTAssertEqual(rig.engine.currentTime, 300)
        XCTAssertEqual(rig.nowPlaying.updates.last?.position, 300)
        rig.player.seek(to: -5)
        XCTAssertEqual(rig.player.position, 0)
        rig.player.seek(to: 10_000)
        XCTAssertEqual(rig.engine.currentTime, 600)
    }

    func testSkipBackFifteenAndForwardThirty() {
        let rig = makeRig()
        rig.player.start(item, at: 100)
        rig.player.skipForward()
        XCTAssertEqual(rig.engine.currentTime, 130)
        rig.player.skipBack()
        XCTAssertEqual(rig.engine.currentTime, 115)
        rig.player.seek(to: 5)
        rig.player.skipBack()
        XCTAssertEqual(rig.engine.currentTime, 0, "skipping back never goes below the start")
    }

    func testRateReachesTheEngineAndNowPlaying() {
        let rig = makeRig()
        rig.player.start(item)
        rig.player.setRate(1.5)
        XCTAssertEqual(rig.engine.rate, 1.5)
        XCTAssertEqual(rig.nowPlaying.updates.last?.rate, 1.5)
        rig.player.setRate(9)
        XCTAssertEqual(rig.player.rate, 2, "speed is limited to what the engine accepts")
        rig.player.pause()
        XCTAssertEqual(rig.nowPlaying.updates.last?.rate, 0)
    }

    func testRateSurvivesLoadingAnotherFile() {
        let rig = makeRig()
        rig.player.setRate(1.25)
        rig.player.start(item)
        XCTAssertEqual(rig.engine.rate, 1.25)
    }

    func testEngineWithoutSpeedControlIgnoresRate() {
        let session = PlayerFakeSession()
        let player = LibraryPlayer(
            engine: FixedSpeedEngine(), session: session, nowPlaying: PlayerFakeNowPlaying(), remoteCommands: PlayerFakeRemote(),
            sessionEvents: PlayerFakeEvents())
        XCTAssertFalse(player.supportsRate)
        player.setRate(1.5)
        XCTAssertEqual(player.rate, 1)
    }

    // MARK: Failure

    func testEngineRefusalFailsInsteadOfClaimingToPlay() {
        let engine = PlayerFakeEngine()
        engine.refusePlay = true
        let rig = makeRig(engine: engine)
        XCTAssertFalse(rig.player.start(item))
        guard case .failed = rig.player.status else { return XCTFail("expected failure, got \(rig.player.status)") }
        XCTAssertFalse(rig.player.isPlaying)
    }

    func testSessionActivationFailureDoesNotStartTheEngine() {
        let rig = makeRig()
        rig.session.failActivation = true
        XCTAssertFalse(rig.player.start(item))
        XCTAssertFalse(rig.engine.isPlaying)
        guard case .failed = rig.player.status else { return XCTFail("expected failure") }
    }

    func testUnreadableFileFailsAndClearsTheItem() {
        let engine = PlayerFakeEngine()
        engine.failLoad = true
        let rig = makeRig(engine: engine)
        XCTAssertFalse(rig.player.start(item))
        XCTAssertNil(rig.player.item)
        XCTAssertFalse(rig.player.play(), "nothing is loaded to play")
        guard case .failed = rig.player.status else { return XCTFail("expected failure") }
    }

    // MARK: Interruptions and routes

    func testInterruptionBeganPausesAndEndedWithHintResumes() {
        let rig = makeRig()
        rig.player.start(item)
        rig.engine.currentTime = 200
        rig.events.send(.interruptionBegan)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.engine.isPlaying)
        rig.events.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.currentTime, 200, "resumes where it stopped")
    }

    func testInterruptionEndedWithoutHintStaysPaused() {
        let rig = makeRig()
        rig.player.start(item)
        rig.events.send(.interruptionBegan)
        rig.events.send(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(rig.player.status, .paused)
    }

    func testInterruptionDuringPauseDoesNotResumeAfterwards() {
        let rig = makeRig()
        rig.player.start(item)
        rig.player.pause()
        rig.events.send(.interruptionBegan)
        rig.events.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(rig.player.status, .paused, "a person paused it; an interruption must not restart it")
    }

    func testManualPauseDuringInterruptionCancelsAutoResume() {
        let rig = makeRig()
        rig.player.start(item)
        rig.events.send(.interruptionBegan)
        rig.player.pause()
        rig.events.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(rig.player.status, .paused)
    }

    func testRouteLossPausesAndNeverResumesByItself() {
        let rig = makeRig()
        rig.player.start(item)
        rig.events.send(.routeLost)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertEqual(rig.nowPlaying.updates.last?.rate, 0)
        rig.events.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(rig.player.status, .paused)
    }

    // MARK: Remote commands, completion, stop

    func testRemoteCommandsDriveTheTransport() throws {
        let rig = makeRig()
        rig.player.start(item, at: 100)
        let handler = try XCTUnwrap(rig.remote.handler)
        XCTAssertTrue(handler(.pause))
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertTrue(handler(.play))
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(handler(.togglePlayPause))
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertTrue(handler(.skipForward(30)))
        XCTAssertEqual(rig.engine.currentTime, 130)
        XCTAssertTrue(handler(.skipBackward(15)))
        XCTAssertEqual(rig.engine.currentTime, 115)
        XCTAssertTrue(handler(.seek(to: 500)))
        XCTAssertEqual(rig.engine.currentTime, 500)
    }

    func testRemoteCommandsDoNothingWithoutAnItem() {
        let rig = makeRig()
        XCTAssertFalse(rig.player.handle(.play))
        XCTAssertEqual(rig.player.status, .idle)
    }

    func testNaturalCompletionEndsAndPlayAgainStartsOver() async {
        let rig = makeRig()
        rig.player.start(item, at: 590)
        rig.engine.finishNaturally()
        await waitUntil { rig.player.status == .ended }
        XCTAssertEqual(rig.player.position, 600)
        XCTAssertEqual(rig.nowPlaying.updates.last?.rate, 0)
        rig.player.play()
        XCTAssertEqual(rig.engine.currentTime, 0)
        XCTAssertEqual(rig.player.status, .playing)
    }

    func testCompletionFromAnEarlierLoadIsIgnored() async {
        let rig = makeRig()
        rig.player.start(item)
        let second = LibraryPlayer.Item(entryID: item.entryID, title: "Two", showTitle: "Show", fileURL: item.fileURL)
        rig.player.start(second)
        rig.engine.isPlaying = true
        rig.engine.finishNaturally(reporting: 1)  // the first load's generation
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.item?.title, "Two")
    }

    func testStopClearsEverythingAndReleasesTheSession() throws {
        let rig = makeRig()
        rig.player.start(item)
        rig.player.stop()
        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.player.status, .idle)
        XCTAssertEqual(rig.nowPlaying.clears, 1)
        XCTAssertEqual(rig.session.deactivations, 1)
        XCTAssertNil(rig.remote.handler)
        XCTAssertFalse(rig.engine.isPlaying)
    }

    func testTimerRefreshesPositionWhilePlaying() async {
        let rig = makeRig(tick: .milliseconds(10))
        rig.player.start(item)
        rig.engine.currentTime = 77
        await waitUntil { rig.player.position == 77 }
        rig.player.pause()
    }

    func testRefreshNoticesAnEngineThatStoppedOnItsOwn() {
        let rig = makeRig()
        rig.player.start(item)
        rig.engine.isPlaying = false
        rig.player.refreshPosition()
        XCTAssertEqual(rig.player.status, .paused)
    }

    func testStatusWordingNeverDependsOnColor() {
        XCTAssertEqual(LibraryPlayerText.statusLine(for: .playing), "Playing")
        XCTAssertEqual(LibraryPlayerText.statusLine(for: .paused), "Paused")
        XCTAssertEqual(LibraryPlayerText.statusLine(for: .ended), "Finished")
        XCTAssertEqual(LibraryPlayerText.statusLine(for: .failed("x")), "Could not play: x")
        XCTAssertEqual(LibraryPlayerText.rate(1.5), "1.5x")
        XCTAssertEqual(LibraryPlayerText.rate(2), "2x")
    }

    // MARK: Settings

    func testDefaultSpeedAppliesWhenAnItemStartsAndIsClampedToTheEngine() {
        let rig = makeRig()
        rig.player.apply(LibraryPlaybackPreferences(defaultSpeed: 1.25, skipBackSeconds: 15, skipForwardSeconds: 30))
        rig.player.start(item)
        XCTAssertEqual(rig.player.rate, 1.25)
        XCTAssertEqual(rig.engine.rate, 1.25)

        rig.player.apply(LibraryPlaybackPreferences(defaultSpeed: 3, skipBackSeconds: 15, skipForwardSeconds: 30))
        XCTAssertEqual(rig.player.rate, 1.25, "a running item keeps its own speed")
        rig.player.start(item)
        XCTAssertEqual(rig.player.rate, 2, "the player never exceeds what its engine accepts")
    }

    func testWithoutSettingsAStartLeavesTheSpeedAlone() {
        let rig = makeRig()
        rig.player.start(item)
        XCTAssertEqual(rig.player.rate, 1)
    }

    func testSkipLengthsFromSettingsDriveTheButtonsAndCommands() {
        let rig = makeRig()
        rig.player.apply(LibraryPlaybackPreferences(defaultSpeed: 1, skipBackSeconds: 10, skipForwardSeconds: 45))
        rig.player.start(item, at: 100)
        rig.player.skipBack()
        XCTAssertEqual(rig.player.position, 90)
        rig.player.skipForward()
        XCTAssertEqual(rig.player.position, 135)
        XCTAssertEqual(rig.remote.skipIntervals?.back, 10)
        XCTAssertEqual(rig.remote.skipIntervals?.forward, 45)
    }
}
