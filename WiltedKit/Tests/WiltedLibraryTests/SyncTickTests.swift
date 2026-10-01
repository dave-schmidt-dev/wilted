import Foundation
import XCTest
@testable import WiltedLibrary

/// The cadence rule: a device has one sync tick, a round starts at most every 30 s, and a rate
/// limit pauses the whole tick. The clock is virtual; a round only records when it ran.
final class SyncTickTests: XCTestCase {
    private final class Rounds: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [(at: Date, trigger: SyncTick.Trigger)] = []
        private var hold: CheckedContinuation<Void, Never>?
        var holding = false
        func record(_ at: Date, _ trigger: SyncTick.Trigger) { lock.withLock { starts.append((at, trigger)) } }
        var all: [(at: Date, trigger: SyncTick.Trigger)] { lock.withLock { starts } }
        func gaps() -> [TimeInterval] {
            let times = all.map(\.at)
            return zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        }
        func park() async { await withCheckedContinuation { hold = $0 } }
        func release() { let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { hold = nil }; return hold }; waiting?.resume() }
    }

    private func makeTick(_ time: VirtualTime, _ rounds: Rounds, gate: TransportGate? = nil, parking: Bool = false) -> SyncTick {
        SyncTick(interval: 30, gate: gate, clock: { time.now }, sleep: { try await time.sleep($0) }) { trigger in
            rounds.record(time.now, trigger)
            if parking && trigger != .timer { await rounds.park() }
        }
    }

    func testARoundStartsAtOnceThenOnlyEveryThirtySeconds() async {
        let time = VirtualTime(), rounds = Rounds()
        let tick = makeTick(time, rounds)
        await tick.start()
        await time.settle()
        XCTAssertEqual(rounds.all.count, 1)
        await time.advance(by: 29)
        XCTAssertEqual(rounds.all.count, 1, "nothing runs faster than the tick")
        await time.advance(by: 1)
        XCTAssertEqual(rounds.all.count, 2)
        await time.advance(by: 600)
        XCTAssertEqual(rounds.all.count, 22)
        XCTAssertTrue(rounds.gaps().allSatisfy { $0 >= 30 })
        await tick.stop()
    }

    func testPullToRefreshRunsNowAndRestartsTheTimer() async {
        let time = VirtualTime(), rounds = Rounds()
        let tick = makeTick(time, rounds)
        await tick.start()
        await time.advance(by: 20)
        let outcome = await tick.refreshNow()
        XCTAssertEqual(outcome, .ran)
        XCTAssertEqual(rounds.all.map(\.trigger), [.timer, .refresh])
        await time.advance(by: 29)
        XCTAssertEqual(rounds.all.count, 2, "the timer restarted from the pull")
        await time.advance(by: 1)
        XCTAssertEqual(rounds.all.map(\.trigger), [.timer, .refresh, .timer])
        await tick.stop()
    }

    func testRepeatedPullsWhileARoundRunsJoinThatRound() async {
        let time = VirtualTime(), rounds = Rounds()
        let tick = makeTick(time, rounds, parking: true)
        await tick.start()
        await time.advance(by: 10)
        async let first = tick.refreshNow()
        await time.settle()
        async let second = tick.refreshNow()
        async let third = tick.refreshNow()
        await time.settle()
        rounds.release()
        let outcomes = await [first, second, third]
        XCTAssertEqual(outcomes.filter { $0 == .ran }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .joined }.count, 2)
        XCTAssertEqual(rounds.all.filter { $0.trigger == .refresh }.count, 1, "one round served all three pulls")
        await tick.stop()
    }

    func testPullDuringARateLimitSendsNothingAndReportsTheRetryState() async {
        let time = VirtualTime(), rounds = Rounds()
        let gate = TransportGate(clock: { time.now })
        struct Limited: Error, CustomStringConvertible { var description: String { "cloudKit(code: 7, message: \"Retry after 90 seconds\")" } }
        _ = try? await gate.run { throw Limited() }
        let tick = makeTick(time, rounds, gate: gate)
        await tick.start()
        await time.settle()
        XCTAssertTrue(rounds.all.isEmpty, "the timer waits out the Retry-After")
        let outcome = await tick.refreshNow()
        guard case let .throttled(state) = outcome else { return XCTFail("expected throttled, got \(outcome)") }
        XCTAssertEqual(state.kind, .rateLimited)
        XCTAssertTrue(rounds.all.isEmpty, "a pull does not fire into a closed gate")
        await time.advance(by: 89)
        XCTAssertTrue(rounds.all.isEmpty)
        await time.advance(by: 2)
        XCTAssertEqual(rounds.all.count, 1, "the first round after the wait is the probe")
        await tick.stop()
    }

    func testAPushOrForegroundRunsARoundOnlyWhenOneIsDue() async {
        let time = VirtualTime(), rounds = Rounds()
        let tick = makeTick(time, rounds)
        await tick.start()
        await time.advance(by: 5)
        await tick.requestSoon()
        XCTAssertEqual(rounds.all.count, 1, "not due: the timer round covers it")
        await tick.stop()
        let late = makeTick(time, rounds)
        await late.requestSoon()
        XCTAssertEqual(rounds.all.map(\.trigger), [.timer, .event], "never ran, so one is due")
    }

    func testAnHourOfTheTickIsOneRoundPerHalfMinuteAtMost() async {
        let time = VirtualTime(), rounds = Rounds()
        let tick = makeTick(time, rounds)
        await tick.start()
        await time.advance(by: 3_600)
        XCTAssertLessThanOrEqual(rounds.all.count, 3_600 / 30 + 1)
        await tick.stop()
    }
}
