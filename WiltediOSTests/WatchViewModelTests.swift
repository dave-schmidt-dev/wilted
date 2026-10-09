import Foundation
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A command transport fake that records every command the view model hands it.
@MainActor
private final class RecordingCommandSender {
    private(set) var commands: [WatchCommand] = []

    func send(_ command: WatchCommand) {
        commands.append(command)
    }
}

/// A cancellation-ignoring sleeper that exposes exact timeout registration.
@MainActor
private final class PendingSleeper {
    var waits: [(TimeInterval, CheckedContinuation<Void, Never>?)] = []
    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { waits.append((seconds, $0)) }
    }
    func finish(_ index: Int) {
        let continuation = waits[index].1
        waits[index].1 = nil
        continuation?.resume()
    }
    func finishAll() { for index in waits.indices { finish(index) } }
}

/// A hand-advanced clock, so age text is deterministic.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// The view model's contract: snapshot adoption, staleness while the phone is
/// unreachable, age text from the injected clock, and the command each control
/// sends to the injected sender.
@MainActor
final class WatchViewModelTests: XCTestCase {
    private struct Rig {
        let model: WatchViewModel
        let clock: TestClock
        let sender: RecordingCommandSender
    }

    private func makeRig() -> Rig {
        let clock = TestClock()
        let sender = RecordingCommandSender()
        let model = WatchViewModel(now: { clock.now }, commandSender: { sender.send($0) })
        return Rig(model: model, clock: clock, sender: sender)
    }

    private func snapshot(rate: Double = 1.25) -> WatchSnapshot {
        WatchSnapshot(
            nowPlaying: NowPlaying(
                episodeID: "ep-1", title: "Episode One", showTitle: "Show One",
                positionSeconds: 12, durationSeconds: 600, isPlaying: true),
            upNext: [UpNextRow(episodeID: "ep-2", title: "Episode Two", showTitle: "Show One")],
            rate: rate,
            sleep: .off,
            publishedAt: Date(timeIntervalSince1970: 900_000))
    }

    private func receiveSnapshot(_ rig: Rig, rate: Double = 1.25) throws {
        rig.model.receive(context: try WatchLinkCodec.encode(snapshot(rate: rate)))
    }

    // MARK: Snapshot adoption

    func testReceivingASnapshotUpdatesTheViewModel() throws {
        let rig = makeRig()
        let expected = snapshot()

        rig.model.receive(context: try WatchLinkCodec.encode(expected))

        XCTAssertEqual(rig.model.snapshot, expected)
        XCTAssertEqual(rig.model.lastReceivedAt, rig.clock.now)
    }

    func testUndecodableContextIsIgnoredAndKeepsThePreviousSnapshot() throws {
        let rig = makeRig()
        try receiveSnapshot(rig)
        let received = rig.model.lastReceivedAt
        rig.clock.advance(seconds: 300)

        rig.model.receive(context: [WatchLinkCodec.snapshotKey: Data("{not json".utf8)])
        rig.model.receive(context: [:])

        XCTAssertEqual(rig.model.snapshot, snapshot())
        XCTAssertEqual(rig.model.lastReceivedAt, received, "an ignored context must not refresh the age")
    }

    // MARK: Commands

    func testNoCommandIsSentWhileUnreachable() throws {
        let rig = makeRig()
        try receiveSnapshot(rig)
        rig.model.isPhoneReachable = false

        XCTAssertFalse(rig.model.send(.toggle))
        XCTAssertFalse(rig.model.controlsEnabled)
        XCTAssertTrue(rig.model.pendingControls.isEmpty)
        XCTAssertTrue(rig.sender.commands.isEmpty)
    }

    func testNoCommandIsSentWithoutASnapshot() {
        let rig = makeRig()
        rig.model.isPhoneReachable = true

        XCTAssertFalse(rig.model.send(.toggle))
        XCTAssertFalse(rig.model.controlsEnabled)
        XCTAssertTrue(rig.model.pendingControls.isEmpty)
        XCTAssertTrue(rig.sender.commands.isEmpty)
    }

    func testEachControlSendsTheRightCommandWhenReachable() throws {
        let rig = makeRig()
        try receiveSnapshot(rig)
        rig.model.isPhoneReachable = true

        XCTAssertTrue(rig.model.togglePlayPause())
        XCTAssertTrue(rig.model.skipBack())
        XCTAssertTrue(rig.model.skipForward())
        XCTAssertTrue(rig.model.setSpeed(1.25))
        XCTAssertTrue(rig.model.startSleep(minutes: 20))
        XCTAssertTrue(rig.model.sleepAtEndOfEpisode())
        XCTAssertTrue(rig.model.cancelSleep())
        XCTAssertTrue(rig.model.play(episodeID: "ep-2"))

        XCTAssertEqual(rig.sender.commands.map(\.action), [
            .toggle,
            .skipBack,
            .skipForward,
            .setRate(1.25),
            .startSleep(minutes: 20),
            .startSleepEndOfEpisode,
            .cancelSleep,
            .playRow(episodeID: "ep-2"),
        ])
    }

    func testReachabilityChangeReenablesControls() throws {
        let rig = makeRig()
        try receiveSnapshot(rig)
        rig.model.isPhoneReachable = false

        XCTAssertFalse(rig.model.controlsEnabled)
        XCTAssertFalse(rig.model.send(.toggle))
        XCTAssertNotNil(rig.model.unreachableNote)

        rig.model.isPhoneReachable = true

        XCTAssertTrue(rig.model.controlsEnabled)
        XCTAssertNil(rig.model.unreachableNote)
        XCTAssertTrue(rig.model.send(.toggle))
        XCTAssertEqual(rig.sender.commands.last?.action, WatchCommand.Action.toggle)
    }

    // MARK: Speed and sleep lists

    func testSpeedChoicesMatchThePhoneList() {
        XCTAssertEqual(WatchSpeeds.all, PlaybackSpeeds.all)
        XCTAssertEqual(WatchSpeeds.step, PlaybackSpeeds.step)
        XCTAssertEqual(WatchSpeeds.range, PlaybackSpeeds.range)
    }

    func testSpeedSteppingStaysOnThePhoneList() throws {
        let rig = makeRig()
        try receiveSnapshot(rig, rate: 1.75)
        rig.model.isPhoneReachable = true

        XCTAssertTrue(rig.model.stepSpeed(forward: true))
        XCTAssertEqual(rig.sender.commands.last?.action, WatchCommand.Action.setRate(2.0))

        XCTAssertTrue(rig.model.stepSpeed(forward: false))
        XCTAssertEqual(rig.sender.commands.last?.action, WatchCommand.Action.setRate(1.5))

        XCTAssertFalse(rig.model.setSpeed(1.1))
        XCTAssertEqual(rig.sender.commands.count, 2, "an off-list rate is never sent")

        let fastest = makeRig()
        try receiveSnapshot(fastest, rate: 2.0)
        fastest.model.isPhoneReachable = true
        XCTAssertTrue(fastest.model.stepSpeed(forward: true))
        XCTAssertEqual(fastest.sender.commands.last?.action, WatchCommand.Action.setRate(0.5))

        let slowest = makeRig()
        try receiveSnapshot(slowest, rate: 0.5)
        slowest.model.isPhoneReachable = true
        XCTAssertTrue(slowest.model.stepSpeed(forward: false))
        XCTAssertEqual(slowest.sender.commands.last?.action, WatchCommand.Action.setRate(2.0))
    }

    func testSleepPresetsMatchThePhone() throws {
        XCTAssertEqual(WatchViewModel.sleepMinutes, WatchBridge.allowedSleepMinutes)

        let rig = makeRig()
        try receiveSnapshot(rig)
        rig.model.isPhoneReachable = true

        XCTAssertFalse(rig.model.startSleep(minutes: 7))
        XCTAssertTrue(rig.sender.commands.isEmpty)

        XCTAssertTrue(rig.model.startSleep(minutes: 5))
        XCTAssertEqual(rig.sender.commands.last?.action, WatchCommand.Action.startSleep(minutes: 5))
    }

    // MARK: Staleness

    func testStaleSnapshotStaysVisibleWhileUnreachable() throws {
        let rig = makeRig()
        try receiveSnapshot(rig)
        rig.model.isPhoneReachable = false

        XCTAssertEqual(rig.model.snapshot, snapshot())
        XCTAssertFalse(rig.model.controlsEnabled)
        XCTAssertEqual(rig.model.unreachableNote, "iPhone not reachable. Showing the last update.")
    }

    func testAgeTextFollowsTheInjectedClock() throws {
        let rig = makeRig()
        XCTAssertEqual(rig.model.ageText, "No update yet")

        try receiveSnapshot(rig)
        XCTAssertEqual(rig.model.ageText, "Updated just now")

        rig.clock.advance(seconds: 59)
        XCTAssertEqual(rig.model.ageText, "Updated just now")

        rig.clock.advance(seconds: 1)
        XCTAssertEqual(rig.model.ageText, "Updated 1 min ago")

        rig.clock.advance(seconds: 240)
        XCTAssertEqual(rig.model.ageText, "Updated 5 min ago")
    }

    func testUnreachableNoteIsNilWhenReachable() throws {
        let rig = makeRig()
        try receiveSnapshot(rig)
        rig.model.isPhoneReachable = true

        XCTAssertNil(rig.model.unreachableNote)
    }

    private func readyModel(sleeper: PendingSleeper, sender: @escaping @MainActor (WatchCommand) -> Void = { _ in }) throws -> WatchViewModel {
        let model = WatchViewModel(commandSender: sender, pendingSleep: { await sleeper.sleep($0) })
        model.receive(context: try WatchLinkCodec.encode(snapshot()))
        model.isPhoneReachable = true
        return model
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate())
    }

    func testPendingIsImmediateAndRepeatDropsOnlyTheMatchingControl() throws {
        let sleeper = PendingSleeper()
        let sender = RecordingCommandSender()
        var model: WatchViewModel!
        defer { model?.commandSender = nil }
        model = try readyModel(sleeper: sleeper) { command in
            XCTAssertTrue(model.isPending(command.action), "pending precedes synchronous delivery")
            sender.send(command)
        }
        XCTAssertTrue(model.togglePlayPause())
        XCTAssertFalse(model.togglePlayPause())
        XCTAssertFalse(model.canSend(.toggle))
        XCTAssertTrue(model.canSend(.skipBack))
        XCTAssertTrue(model.skipBack())
        XCTAssertEqual(sender.commands.map(\.action), [.toggle, .skipBack])
        XCTAssertEqual(model.snapshot?.nowPlaying?.isPlaying, true, "pending never invents confirmed playback")
        model.receive(context: try WatchLinkCodec.encode(snapshot()))
    }

    func testRowsRatesAndSleepChoicesHaveIndependentPendingKeys() throws {
        let sleeper = PendingSleeper()
        let model = try readyModel(sleeper: sleeper)
        let actions: [WatchCommand.Action] = [.playRow(episodeID: "ep-2"), .playRow(episodeID: "ep-3"),
            .setRate(1.25), .setRate(1.5), .startSleep(minutes: 5), .startSleep(minutes: 10),
            .startSleepEndOfEpisode, .cancelSleep]
        for action in actions {
            XCTAssertTrue(model.canSend(action))
            XCTAssertTrue(model.send(action))
            XCTAssertTrue(model.isPending(action))
            XCTAssertFalse(model.send(action))
        }
        XCTAssertTrue(model.hasPendingSpeed)
        XCTAssertTrue(model.hasPendingSleep)
        model.receive(context: try WatchLinkCodec.encode(snapshot()))
        XCTAssertTrue(model.pendingControls.isEmpty)
    }

    func testRejectedCommandsNeverBecomePending() throws {
        let sleeper = PendingSleeper()
        let model = try readyModel(sleeper: sleeper)
        XCTAssertFalse(model.send(.setRate(1.1)))
        XCTAssertFalse(model.send(.setRate(.nan)))
        XCTAssertFalse(model.send(.startSleep(minutes: 7)))
        model.commandSender = nil
        XCTAssertFalse(model.send(.toggle))
        XCTAssertFalse(model.canSend(.toggle))
        XCTAssertTrue(model.pendingControls.isEmpty)
    }

    func testOnlyAValidSnapshotClearsPending() throws {
        let sleeper = PendingSleeper()
        let model = try readyModel(sleeper: sleeper)
        XCTAssertTrue(model.send(.toggle))
        model.receive(context: [:])
        XCTAssertTrue(model.isPending(.toggle))
        model.receive(context: try WatchLinkCodec.encode(snapshot()))
        XCTAssertTrue(model.pendingControls.isEmpty)
    }

    func testThreeSecondExpiryClearsOnlyItsMatchingControl() async throws {
        let sleeper = PendingSleeper()
        let model = try readyModel(sleeper: sleeper)
        defer { sleeper.finishAll() }
        XCTAssertTrue(model.send(.toggle))
        await waitUntil { sleeper.waits.count == 1 }
        XCTAssertEqual(sleeper.waits[0].0, 3)
        XCTAssertTrue(model.send(.skipBack))
        await waitUntil { sleeper.waits.count == 2 }
        XCTAssertTrue(model.isPending(.toggle))
        sleeper.finish(0)
        await waitUntil { !model.isPending(.toggle) }
        XCTAssertTrue(model.isPending(.skipBack))
        let remaining = Array(model.pendingExpiryTasks.values)
        model.receive(context: try WatchLinkCodec.encode(snapshot()))
        sleeper.finishAll()
        for expiry in remaining { await expiry.value }
    }

    func testCancelledOldExpiryCannotClearANewerGeneration() async throws {
        let sleeper = PendingSleeper()
        let model = try readyModel(sleeper: sleeper)
        defer { sleeper.finishAll() }
        XCTAssertTrue(model.send(.toggle))
        await waitUntil { sleeper.waits.count == 1 }
        let oldExpiry = try XCTUnwrap(model.pendingExpiryTasks[.toggle])
        model.receive(context: try WatchLinkCodec.encode(snapshot()))
        XCTAssertTrue(model.send(.toggle))
        await waitUntil { sleeper.waits.count == 2 }
        sleeper.finish(0)
        await oldExpiry.value
        XCTAssertTrue(model.isPending(.toggle))
        sleeper.finish(1)
        await waitUntil { !model.isPending(.toggle) }
    }

    func testSynchronousSnapshotDeliveryDoesNotRemarkPending() throws {
        let sleeper = PendingSleeper()
        let context = try WatchLinkCodec.encode(snapshot())
        var model: WatchViewModel!
        model = try readyModel(sleeper: sleeper) { _ in model.receive(context: context) }
        defer { model.commandSender = nil }
        XCTAssertTrue(model.send(.toggle))
        XCTAssertTrue(model.pendingControls.isEmpty)
        XCTAssertTrue(model.send(.toggle))
        XCTAssertTrue(model.pendingControls.isEmpty)
    }

    func testAllSpeedTextMatchesBothPhoneFormatters() {
        let expected = ["0.5x", "0.75x", "1x", "1.25x", "1.5x", "1.75x", "2x"]
        XCTAssertEqual(WatchSpeeds.all.map(PlaybackSpeedText.rate), expected)
        for rate in WatchSpeeds.all {
            XCTAssertEqual(PlaybackSpeedText.rate(rate), LibraryPlayerText.rate(rate))
            XCTAssertEqual(PlaybackSpeedText.rate(rate), LibrarySettingsFormat.speed(rate))
        }
    }

    func testSleepCountdownIsActiveOnlyForAFutureDeadline() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let model = WatchViewModel(now: { date })
        let states: [(SleepState, Date?)] = [(SleepState.untilDate(date.addingTimeInterval(600)), date.addingTimeInterval(600)),
                                 (.untilDate(date), nil), (.untilDate(date.addingTimeInterval(-1)), nil),
                                 (.off, nil), (.endOfEpisode, nil)]
        for (sleep, expected) in states {
            model.receive(context: try WatchLinkCodec.encode(WatchSnapshot(sleep: sleep)))
            XCTAssertEqual(model.activeSleepDeadline(at: date), expected)
        }
    }
}
