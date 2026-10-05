import Combine
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A `WatchSessionProtocol` the test drives: it records activations and published contexts and
/// calls the bridge's delegate directly when told.
@MainActor
private final class FakeWatchSession: WatchSessionProtocol {
    var isSupported = true
    var activationState: WatchSessionActivationState = .notActivated
    var isPaired = false
    var isWatchAppInstalled = false
    weak var delegate: (any WatchSessionDelegate)?
    private(set) var activations = 0
    private(set) var contexts: [[String: Any]] = []
    var updateError: Error?

    func activate() {
        activations += 1
        activationState = .inactive
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        if let updateError { throw updateError }
        contexts.append(context)
    }

    /// What `WCSession`'s activation callback does when it reaches the bridge.
    func completeActivation() {
        activationState = .activated
        delegate?.watchSessionDidActivate()
    }

    func watchStateChanged() { delegate?.watchSessionWatchStateDidChange() }

    func becomeInactive() {
        activationState = .inactive
        delegate?.watchSessionDidBecomeInactive()
    }

    func deactivate() {
        activationState = .notActivated
        delegate?.watchSessionDidDeactivate()
    }

    /// Delivers an encoded command the way `WCSession` delivers a message.
    func receive(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        delegate?.watchSessionDidReceiveMessage(message, replyHandler: reply)
    }
}

/// A `WatchBridgeSource` over settable values and a subject the test fires.
@MainActor
private final class FakeWatchSource: WatchBridgeSource {
    let subject = PassthroughSubject<Void, Never>()
    var nowPlayingValue: NowPlaying?
    var upNextValue: [UpNextRow] = []
    var rateValue: Double = 1
    var stopsAfterEpisodeValue = false

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    var currentNowPlaying: NowPlaying? { nowPlayingValue }
    var currentUpNext: [UpNextRow] { upNextValue }
    var currentRate: Double { rateValue }
    var stopsAfterCurrentEpisode: Bool { stopsAfterEpisodeValue }

    func notifyChange() { subject.send() }
}

/// A `VoiceCommandTarget` that records the actions it is asked to perform.
@MainActor
private final class FakeWatchTarget: VoiceCommandTarget {
    var outcome: VoiceOutcome = .done
    private(set) var performed: [VoiceAction] = []

    func voiceSnapshot() async -> VoiceSnapshot {
        VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
    }

    func perform(_ action: VoiceAction) async -> VoiceOutcome {
        performed.append(action)
        return outcome
    }
}

/// The reply dictionary a command's reply handler filled in; lock-protected so the session's
/// callback can write it whatever thread it lands on.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]

    var value: [String: Any] { lock.withLock { stored } }
    var isEmpty: Bool { value.isEmpty }
    func set(_ reply: [String: Any]) { lock.withLock { stored = reply } }
}

/// The bridge over a fake session, fake source and fake target, with a per-test sleep timer.
@MainActor
final class WatchBridgeTests: XCTestCase {
    private struct Rig {
        let bridge: WatchBridge
        let session: FakeWatchSession
        let source: FakeWatchSource
        let target: FakeWatchTarget
        let sleepTimer: SleepTimer
    }

    private func makeRig(supported: Bool = true) -> Rig {
        let session = FakeWatchSession()
        session.isSupported = supported
        let source = FakeWatchSource()
        let target = FakeWatchTarget()
        let sleepTimer = SleepTimer()
        let bridge = WatchBridge(session: session, target: target, source: source, sleepTimer: sleepTimer)
        return Rig(bridge: bridge, session: session, source: source, target: target, sleepTimer: sleepTimer)
    }

    /// A rig whose Watch is paired, has the app installed and has finished activation, so the
    /// first snapshot is already published.
    private func makeReadyRig(nowPlaying: NowPlaying? = nil, upNext: [UpNextRow] = []) async -> Rig {
        let rig = makeRig()
        rig.source.nowPlayingValue = nowPlaying
        rig.source.upNextValue = upNext
        rig.bridge.start()
        rig.session.isPaired = true
        rig.session.isWatchAppInstalled = true
        rig.session.completeActivation()
        await rig.bridge.settlePendingPublish()
        return rig
    }

    private func nowPlaying(isPlaying: Bool) -> NowPlaying {
        NowPlaying(
            episodeID: "ep-1", title: "Episode One", showTitle: "Show",
            positionSeconds: 12, durationSeconds: 600, isPlaying: isPlaying)
    }

    /// Sends one command and waits for the reply the bridge must produce.
    @discardableResult
    private func send(_ action: WatchCommand.Action, on rig: Rig) async throws -> ReplyBox {
        let box = ReplyBox()
        rig.session.receive(try WatchLinkCodec.encode(WatchCommand(action: action))) { box.set($0) }
        for _ in 0..<100 where box.isEmpty { await Task.yield() }
        XCTAssertFalse(box.isEmpty, "the bridge must answer every command")
        return box
    }

    // MARK: Session lifecycle

    func testStartActivatesWithADelegateOnlyWhenSupported() {
        let supported = makeRig()
        supported.bridge.start()
        XCTAssertEqual(supported.session.activations, 1)
        XCTAssertTrue(supported.session.delegate === supported.bridge)

        let unsupported = makeRig(supported: false)
        unsupported.bridge.start()
        XCTAssertEqual(unsupported.session.activations, 0, "an unsupported session is never activated")
        XCTAssertNil(unsupported.session.delegate)
    }

    func testColdStartWithNoWatchPublishesNothing() async {
        let rig = makeRig()
        rig.bridge.start()
        XCTAssertEqual(rig.session.activations, 1, "start activates even with no Watch paired")
        rig.session.completeActivation()
        await rig.bridge.settlePendingPublish()
        XCTAssertTrue(rig.session.contexts.isEmpty)
        XCTAssertNil(rig.bridge.publishedSnapshot)
    }

    func testAWatchInstallPublishesOnTheNextWatchStateChange() async throws {
        let rig = makeRig()
        rig.source.upNextValue = [UpNextRow(episodeID: "ep-1", title: "One", showTitle: "Show")]
        rig.bridge.start()
        rig.session.completeActivation()
        await rig.bridge.settlePendingPublish()
        XCTAssertTrue(rig.session.contexts.isEmpty, "activation without a Watch publishes nothing")

        rig.session.isPaired = true
        rig.session.isWatchAppInstalled = true
        rig.session.watchStateChanged()
        await rig.bridge.settlePendingPublish()

        XCTAssertEqual(rig.session.contexts.count, 1)
        let context = try XCTUnwrap(rig.session.contexts.first)
        XCTAssertEqual(try WatchLinkCodec.decodeSnapshot(context).upNext.map(\.episodeID), ["ep-1"])
    }

    func testDidDeactivateReactivatesAndPublishesAfterTheNewActivation() async {
        let rig = await makeReadyRig()
        XCTAssertEqual(rig.session.activations, 1)
        XCTAssertEqual(rig.session.contexts.count, 1)

        rig.session.deactivate()
        XCTAssertEqual(rig.session.activations, 2, "a deactivated session is activated again")
        rig.session.completeActivation()
        await rig.bridge.settlePendingPublish()
        XCTAssertEqual(rig.session.contexts.count, 2)
    }

    func testDidBecomeInactiveReactivatesTheSession() {
        let rig = makeRig()
        rig.bridge.start()
        rig.session.becomeInactive()
        XCTAssertEqual(rig.session.activations, 2)
    }

    // MARK: Rejections

    func testUnknownEpisodeOffListRateAndOffListSleepAreRejectedWithoutPerforming() async throws {
        let rig = await makeReadyRig(upNext: [UpNextRow(episodeID: "ep-1", title: "One", showTitle: "Show")])

        let unknown = try await send(.playRow(episodeID: "ep-404"), on: rig)
        XCTAssertEqual(unknown.value[WatchBridge.okKey] as? Bool, false)
        XCTAssertEqual(unknown.value[WatchBridge.reasonKey] as? String, WatchRejection.unknownEpisode.rawValue)

        let rate = try await send(.setRate(1.1), on: rig)
        XCTAssertEqual(rate.value[WatchBridge.okKey] as? Bool, false)
        XCTAssertEqual(rate.value[WatchBridge.reasonKey] as? String, WatchRejection.unsupportedRate.rawValue)

        let sleep = try await send(.startSleep(minutes: 7), on: rig)
        XCTAssertEqual(sleep.value[WatchBridge.okKey] as? Bool, false)
        XCTAssertEqual(sleep.value[WatchBridge.reasonKey] as? String, WatchRejection.unsupportedSleepDuration.rawValue)

        XCTAssertTrue(rig.target.performed.isEmpty, "a rejected command must not reach the target")
    }

    func testMalformedCommandIsRejectedWithoutPerforming() async {
        let rig = await makeReadyRig()
        let box = ReplyBox()
        rig.session.receive([WatchLinkCodec.commandKey: Data("{not json".utf8)]) { box.set($0) }
        XCTAssertEqual(box.value[WatchBridge.okKey] as? Bool, false)
        XCTAssertEqual(box.value[WatchBridge.reasonKey] as? String, WatchRejection.invalidCommand.rawValue)
        XCTAssertTrue(rig.target.performed.isEmpty)
    }

    // MARK: Command mapping

    func testEveryValidCommandMapsToItsVoiceAction() async throws {
        let paused = await makeReadyRig(
            nowPlaying: nowPlaying(isPlaying: false),
            upNext: [UpNextRow(episodeID: "ep-1", title: "One", showTitle: "Show")])
        let entryID = try ItemID(rawValue: "ep-1")
        try await send(.playRow(episodeID: "ep-1"), on: paused)
        try await send(.toggle, on: paused)
        try await send(.skipForward, on: paused)
        try await send(.skipBack, on: paused)
        try await send(.setRate(1.25), on: paused)
        try await send(.startSleep(minutes: 20), on: paused)
        try await send(.startSleepEndOfEpisode, on: paused)
        try await send(.cancelSleep, on: paused)
        XCTAssertEqual(paused.target.performed, [
            .play(entryID), .resume, .skipForward, .skipBack, .setSpeed(1.25),
            .startSleepTimer(minutes: 20), .stopAfterEpisode, .cancelSleepTimer,
        ])

        let playing = await makeReadyRig(nowPlaying: nowPlaying(isPlaying: true))
        try await send(.toggle, on: playing)
        XCTAssertEqual(playing.target.performed, [.pause], "a toggle of playing audio pauses")
    }

    // MARK: Publishing

    func testStartingASleepTimerRepublishesUntilDate() async throws {
        let rig = await makeReadyRig()
        let published = rig.session.contexts.count

        rig.sleepTimer.start(minutes: 5) {}
        await rig.bridge.settlePendingPublish()

        XCTAssertEqual(rig.session.contexts.count, published + 1)
        guard case let .untilDate(date) = try XCTUnwrap(rig.bridge.publishedSnapshot?.sleep) else {
            return XCTFail("the snapshot must carry the running deadline")
        }
        XCTAssertEqual(date.timeIntervalSinceNow, 300, accuracy: 5)
        rig.sleepTimer.cancel()
    }

    func testCancellingASleepTimerWhilePausedRepublishesOff() async {
        let rig = await makeReadyRig(nowPlaying: nowPlaying(isPlaying: false))
        rig.sleepTimer.start(minutes: 15) {}
        await rig.bridge.settlePendingPublish()
        let started = rig.session.contexts.count

        rig.sleepTimer.cancel()
        await rig.bridge.settlePendingPublish()

        XCTAssertEqual(rig.session.contexts.count, started + 1)
        XCTAssertEqual(rig.bridge.publishedSnapshot?.sleep, SleepState.off)
    }

    func testSeveralChangesCoalesceIntoOnePublish() async {
        let rig = await makeReadyRig()
        let published = rig.session.contexts.count

        rig.source.rateValue = 1.25
        rig.source.notifyChange()
        rig.source.upNextValue = [UpNextRow(episodeID: "ep-2", title: "Two", showTitle: "Show")]
        rig.source.notifyChange()
        rig.source.nowPlayingValue = nowPlaying(isPlaying: true)
        rig.source.notifyChange()

        await rig.bridge.settlePendingPublish()
        XCTAssertEqual(rig.session.contexts.count, published + 1, "bursts collapse into one context write")
    }

    func testAFailedUpdatePublishesNothingAndRejectsItsRows() async throws {
        let rig = makeRig()
        rig.source.upNextValue = [UpNextRow(episodeID: "ep-1", title: "One", showTitle: "Show")]
        rig.bridge.start()
        rig.session.isPaired = true
        rig.session.isWatchAppInstalled = true
        rig.session.updateError = NSError(domain: "test", code: 1)
        rig.session.completeActivation()
        await rig.bridge.settlePendingPublish()
        XCTAssertTrue(rig.session.contexts.isEmpty)
        XCTAssertNil(rig.bridge.publishedSnapshot)

        let row = try await send(.playRow(episodeID: "ep-1"), on: rig)
        XCTAssertEqual(row.value[WatchBridge.reasonKey] as? String, WatchRejection.unknownEpisode.rawValue)
        XCTAssertTrue(rig.target.performed.isEmpty, "a row from a snapshot that never published is foreign")
    }
}
