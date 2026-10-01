import XCTest
@testable import WiltediOS

/// A clock the test moves, and a sleep that moves it instead of waiting.
@MainActor
private final class FakeClock {
    var current = ContinuousClock.now
    func advance(_ duration: Duration) { current = current.advanced(by: duration) }
}

/// A sleep that returns only when released, so a test can cancel or replace the timer first.
private actor SleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class SleepTimerTests: XCTestCase {
    private let clock = FakeClock()
    private var fired = 0

    private func timer(lateBy late: Duration = .zero) -> SleepTimer {
        SleepTimer(now: { [clock] in clock.current }, sleep: { [clock] in clock.advance($0 + late) })
    }

    func testExpiresOnceAfterTheMinutes() async {
        let timer = timer()
        timer.start(minutes: 30) { self.fired += 1 }
        XCTAssertTrue(timer.isActive)
        await timer.settle()
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(timer.isActive)
    }

    func testDeadlineIsMinutesFromNow() {
        let timer = timer()
        let before = clock.current
        timer.start(minutes: 5) {}
        XCTAssertEqual(timer.deadline, before.advanced(by: .seconds(300)))
        timer.cancel()
    }

    func testCancelPreventsTheExpiry() async {
        let gate = SleepGate()
        let timer = SleepTimer(now: { [clock] in clock.current }, sleep: { _ in await gate.wait() })
        timer.start(minutes: 10) { self.fired += 1 }
        timer.cancel()
        XCTAssertFalse(timer.isActive)
        clock.advance(.seconds(3600))
        await gate.release()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(fired, 0)
    }

    func testStartingAgainReplacesTheEarlierTimer() async {
        // The sleep yields first, so the replaced timer's task is cancelled before its first look at the clock.
        let timer = SleepTimer(now: { [clock] in clock.current }, sleep: { [clock] in
            await Task.yield()
            clock.advance($0)
        })
        var firstFired = 0
        timer.start(minutes: 5) { firstFired += 1 }
        timer.start(minutes: 20) { self.fired += 1 }
        await timer.settle()
        XCTAssertEqual(firstFired, 0, "the replaced timer must not fire")
        XCTAssertEqual(fired, 1)
    }

    func testAWakeLongPastTheDeadlineIsStaleAndDoesNothing() async {
        let timer = timer(lateBy: .seconds(60))
        timer.start(minutes: 1) { self.fired += 1 }
        await timer.settle()
        XCTAssertEqual(fired, 0, "a timer woken a minute late must not pause what was started since")
        XCTAssertFalse(timer.isActive)
    }

    func testAWakeJustLateStillFires() async {
        let timer = timer(lateBy: .seconds(5))
        timer.start(minutes: 1) { self.fired += 1 }
        await timer.settle()
        XCTAssertEqual(fired, 1)
    }
}
