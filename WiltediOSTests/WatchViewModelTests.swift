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
        XCTAssertTrue(rig.sender.commands.isEmpty)
    }

    func testNoCommandIsSentWithoutASnapshot() {
        let rig = makeRig()
        rig.model.isPhoneReachable = true

        XCTAssertFalse(rig.model.send(.toggle))
        XCTAssertFalse(rig.model.controlsEnabled)
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
}
