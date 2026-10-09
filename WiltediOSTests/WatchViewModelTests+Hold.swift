import Foundation
import XCTest
@testable import WiltediOS

@MainActor
private final class HoldRenewSleeper {
    var waits: [CheckedContinuation<Void, Never>] = []
    var registered: CheckedContinuation<Void, Never>?
    func sleep(_ seconds: TimeInterval) async {
        XCTAssertEqual(seconds, 0.75)
        await withCheckedContinuation { continuation in
            waits.append(continuation); registered?.resume(); registered = nil
        }
    }
    func waitForRegistration() async {
        if !waits.isEmpty { return }
        await withCheckedContinuation { registered = $0 }
    }
    func finish() { let pending = waits; waits = []; for wait in pending { wait.resume() } }
}

@MainActor
extension WatchViewModelTests {
    private func holdSnapshot(session: UUID = UUID(), load: String = "\(UUID().uuidString):1",
                              capable: Bool? = true) -> WatchSnapshot {
        WatchSnapshot(nowPlaying: NowPlaying(episodeID: "held", title: "Held", showTitle: "Show",
            positionSeconds: 100, durationSeconds: 600, isPlaying: true,
            seekSessionID: load, canSeek: capable), controlSessionID: session)
    }

    func testLegacySnapshotKeepsTapButCannotBeginHold() throws {
        var commands: [WatchCommand] = []
        let model = WatchViewModel(commandSender: { commands.append($0) })
        model.receive(context: try WatchLinkCodec.encode(WatchSnapshot(nowPlaying:
            NowPlaying(episodeID: "legacy", title: "Legacy", showTitle: "Show", positionSeconds: 0, isPlaying: true))))
        model.isPhoneReachable = true
        XCTAssertFalse(model.beginHold(.forward))
        XCTAssertTrue(model.skipForward())
        XCTAssertEqual(commands.map(\.action), [.skipForward])
    }

    func testHeldRenewalUsesExactIdentityAndEndBypassesTapPending() async throws {
        let sleeper = HoldRenewSleeper()
        var commands: [WatchCommand] = []
        let model = WatchViewModel(commandSender: { commands.append($0) }, holdSleep: { await sleeper.sleep($0) })
        let snapshot = holdSnapshot()
        model.receive(context: try WatchLinkCodec.encode(snapshot)); model.isPhoneReachable = true
        XCTAssertTrue(model.skipForward())
        XCTAssertTrue(model.beginHold(.forward), "hold/release are not hidden behind tap feedback expiry")
        await sleeper.waitForRegistration()
        let task = model.holdRenewTask
        sleeper.finish()
        await sleeper.waitForRegistration()
        model.endHold(); sleeper.finish(); await task?.value
        let seeks = commands.compactMap { command -> WatchCommand.Action? in
            if case .seek = command.action { return command.action }; return nil
        }
        XCTAssertGreaterThanOrEqual(seeks.count, 3)
        guard case let .seek(.begin, .forward, id, episode, session, load) = seeks[0] else { return XCTFail("missing begin") }
        XCTAssertEqual(episode, "held"); XCTAssertEqual(session, snapshot.controlSessionID)
        XCTAssertEqual(load, snapshot.nowPlaying?.seekSessionID)
        XCTAssertTrue(seeks.contains(.seek(phase: .renew, direction: .forward, holdID: id,
            episodeID: episode, controlSessionID: session, seekSessionID: load)))
        XCTAssertEqual(seeks.last, .seek(phase: .end, direction: .forward, holdID: id,
            episodeID: episode, controlSessionID: session, seekSessionID: load))
        XCTAssertNil(model.heldAction); XCTAssertNil(model.holdRenewTask)
    }

    func testReachabilityLossCancelsRenewalAndAttemptsMatchingEnd() async throws {
        let sleeper = HoldRenewSleeper(); var commands: [WatchCommand] = []
        let model = WatchViewModel(commandSender: { commands.append($0) }, holdSleep: { await sleeper.sleep($0) })
        model.receive(context: try WatchLinkCodec.encode(holdSnapshot())); model.isPhoneReachable = true
        XCTAssertTrue(model.beginHold(.backward)); await sleeper.waitForRegistration()
        let task = model.holdRenewTask; model.isPhoneReachable = false
        sleeper.finish(); await task?.value
        XCTAssertEqual(commands.count, 2)
        if case .seek(.end, .backward, _, _, _, _) = commands.last?.action {} else { XCTFail("missing backward end") }
        XCTAssertNil(model.heldAction)
    }

    func testSameEpisodeReloadAndSessionChangeCancelHeldIdentity() async throws {
        for changeSession in [false, true] {
            let sleeper = HoldRenewSleeper(); var commands: [WatchCommand] = []
            let model = WatchViewModel(commandSender: { commands.append($0) }, holdSleep: { await sleeper.sleep($0) })
            let first = holdSnapshot(); model.receive(context: try WatchLinkCodec.encode(first)); model.isPhoneReachable = true
            XCTAssertTrue(model.beginHold(.forward)); await sleeper.waitForRegistration()
            let task = model.holdRenewTask
            let second = holdSnapshot(session: changeSession ? UUID() : first.controlSessionID!,
                load: changeSession ? first.nowPlaying!.seekSessionID! : "\(UUID().uuidString):2")
            model.receive(context: try WatchLinkCodec.encode(second)); sleeper.finish(); await task?.value
            XCTAssertNil(model.heldAction)
            XCTAssertEqual(commands.count, 2)
        }
    }

    func testLateFailureForOldHoldCannotCancelReplacement() async throws {
        let sleeper = HoldRenewSleeper(); var commands: [WatchCommand] = []
        let model = WatchViewModel(commandSender: { commands.append($0) }, holdSleep: { await sleeper.sleep($0) })
        model.receive(context: try WatchLinkCodec.encode(holdSnapshot())); model.isPhoneReachable = true
        XCTAssertTrue(model.beginHold(.forward)); await sleeper.waitForRegistration()
        let oldTask = model.holdRenewTask
        guard case let .seek(_, _, oldID, _, _, _) = model.heldAction else { return XCTFail("missing old hold") }
        XCTAssertTrue(model.beginHold(.backward))
        let newTask = model.holdRenewTask
        model.holdCommandFailed(oldID)
        XCTAssertNotNil(model.heldAction)
        model.endHold(); sleeper.finish(); await oldTask?.value; await newTask?.value
        XCTAssertNil(model.heldAction)
    }
    func testSynchronousRejectionDoesNotLeaveAReplacementRenewalTask() throws {
        var model: WatchViewModel!
        model = WatchViewModel(commandSender: { command in
            if case let .seek(.begin, _, id, _, _, _) = command.action { model.holdCommandFailed(id) }
        })
        model.receive(context: try WatchLinkCodec.encode(holdSnapshot())); model.isPhoneReachable = true
        XCTAssertFalse(model.beginHold(.forward))
        XCTAssertNil(model.heldAction); XCTAssertNil(model.holdRenewTask)
        model.commandSender = nil
    }

    func testDisappearingOldControlCannotEndTheReplacementHold() async throws {
        let sleeper = HoldRenewSleeper()
        let model = WatchViewModel(commandSender: { _ in }, holdSleep: { await sleeper.sleep($0) })
        model.receive(context: try WatchLinkCodec.encode(holdSnapshot())); model.isPhoneReachable = true
        XCTAssertTrue(model.beginHold(.forward)); await sleeper.waitForRegistration()
        let firstTask = model.holdRenewTask
        guard case let .seek(_, _, firstID, _, _, _) = model.heldAction else { return XCTFail("missing first") }
        XCTAssertTrue(model.beginHold(.backward))
        let replacement = model.heldAction, secondTask = model.holdRenewTask
        model.endHold(holdID: firstID)
        XCTAssertEqual(model.heldAction, replacement)
        model.endHold(); sleeper.finish(); await firstTask?.value; await secondTask?.value
    }

}
