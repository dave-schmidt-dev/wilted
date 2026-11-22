import XCTest
@testable import WiltedMac

/// What happens when an offer ends: its close step runs once if nobody took it up, never after a
/// finished Undo, and an Undo that could not run yet leaves the offer in place.
@MainActor
final class WiltedMacUndoToastCloseTests: XCTestCase {
    private final class Counter { var undone = 0; var closed = 0 }

    private func center(_ clock: VirtualTime) -> WiltedMacUndoToastCenter {
        WiltedMacUndoToastCenter(now: { clock.now }, sleep: { try await clock.sleep($0) }, prefersLongOffer: { false })
    }

    @discardableResult
    private func offer(
        on center: WiltedMacUndoToastCenter, counting counter: Counter, subjects: Set<String> = [],
        result: @escaping @MainActor () -> WiltedMacUndoResult = { .done }
    ) -> UUID? {
        center.offer(
            message: "Skipped.", actionName: "Skip", subjects: subjects,
            onClose: { counter.closed += 1 },
            undo: { counter.undone += 1; return result() }
        )
    }

    func testTheCloseStepRunsOnceWhenTheOfferRunsOut() async {
        let clock = VirtualTime()
        let center = center(clock)
        let counter = Counter()
        offer(on: center, counting: counter)
        await clock.advance(by: 5)
        XCTAssertEqual([counter.undone, counter.closed], [0, 1])
        await clock.advance(by: 30)
        XCTAssertEqual(counter.closed, 1, "closing happens once")
    }

    func testAFinishedUndoNeverRunsTheCloseStep() async {
        let clock = VirtualTime()
        let center = center(clock)
        let counter = Counter()
        offer(on: center, counting: counter)
        center.undoCurrent()
        await clock.advance(by: 30)
        XCTAssertEqual([counter.undone, counter.closed], [1, 0])
    }

    func testWithdrawingAnOfferClosesIt() {
        let clock = VirtualTime()
        let center = center(clock)
        let counter = Counter()
        offer(on: center, counting: counter, subjects: ["a"])
        center.withdraw(subjects: ["a"])
        XCTAssertEqual([counter.undone, counter.closed], [0, 1])
        XCTAssertNil(center.current)

        offer(on: center, counting: counter)
        center.withdrawAll()
        XCTAssertEqual(counter.closed, 2, "closing the library closes every open offer")
    }

    func testARetryKeepsTheOfferAndAFinishedLaterUndoClearsIt() async {
        let clock = VirtualTime()
        let center = center(clock)
        let counter = Counter()
        var answers: [WiltedMacUndoResult] = [.retry, .done]
        offer(on: center, counting: counter) { answers.removeFirst() }

        center.undoCurrent()
        XCTAssertNotNil(center.current, "a busy undo leaves the offer to try again")
        XCTAssertEqual([counter.undone, counter.closed], [1, 0])
        center.undoCurrent()
        XCTAssertNil(center.current)
        XCTAssertEqual([counter.undone, counter.closed], [2, 0])
    }

    func testCommandZAfterABusyUndoStillTakesBackTheSameOfferNotAnOlderOne() async throws {
        let clock = VirtualTime()
        let center = center(clock)
        let manager = UndoManager()
        manager.groupsByEvent = false
        center.attach(manager)
        let older = Counter(), newer = Counter()
        offer(on: center, counting: older)
        var answers: [WiltedMacUndoResult] = [.retry, .done]
        offer(on: center, counting: newer) { answers.removeFirst() }

        manager.undo()
        // The stack is busy until the undo returns; the offer goes back on it right after.
        for _ in 0..<50 where !manager.canUndo { await Task.yield() }
        XCTAssertEqual([older.undone, newer.undone], [0, 1])
        XCTAssertNotNil(center.current, "the busy undo kept the newer offer")

        manager.undo()
        XCTAssertEqual([older.undone, newer.undone], [0, 2], "the second Command-Z reaches the same offer, not the older one")
        XCTAssertEqual(center.offers.count, 1, "only the older offer is still waiting")
    }

    func testAnExpiredOfferDoesNothingEvenBeforeItsTimerFires() async {
        // A clock the test moves by hand, with a timer that never wakes by itself.
        let sleeper = VirtualTime()
        var time = sleeper.now
        let center = WiltedMacUndoToastCenter(
            now: { time }, sleep: { try await sleeper.sleep($0) }, prefersLongOffer: { false })
        let counter = Counter()
        let id = offer(on: center, counting: counter)
        time = time.addingTimeInterval(6)
        if let id { center.undo(id) }
        XCTAssertEqual([counter.undone, counter.closed], [0, 1], "the late press closes the offer and runs nothing")
        XCTAssertNil(center.current)
    }

    func testWithdrawingSomeSubjectsNarrowsAnOfferThatCanNarrowAndDoesNotCloseIt() {
        let clock = VirtualTime()
        let center = center(clock)
        var narrowedBy: [Set<String>] = []
        var closed = 0
        center.offer(
            message: "Skipped 3.", actionName: "Skip", subjects: ["a", "b", "c"],
            onClose: { closed += 1 }, narrow: { narrowedBy.append($0) }, undo: { .done }
        )

        center.withdraw(subjects: ["a", "z"])
        XCTAssertEqual(narrowedBy, [["a"]], "only the subjects that left are reported")
        XCTAssertEqual(center.current?.subjects, ["b", "c"], "the rest stays on offer")
        XCTAssertEqual(closed, 0)

        center.withdraw(subjects: ["b", "c"])
        XCTAssertNil(center.current, "when nothing is left the offer closes")
        XCTAssertEqual(closed, 1)
    }

    func testALateHoverDoesNotReviveAnOfferThatAlreadyRanOut() {
        let sleeper = VirtualTime()
        var time = sleeper.now
        let center = WiltedMacUndoToastCenter(
            now: { time }, sleep: { try await sleeper.sleep($0) }, prefersLongOffer: { false })
        let counter = Counter()
        offer(on: center, counting: counter)
        time = time.addingTimeInterval(6)

        center.setHeld(true)
        XCTAssertNil(center.current, "the five seconds were up before the pointer arrived")
        XCTAssertEqual([counter.undone, counter.closed], [0, 1])
    }
}
