import Foundation
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedPreparationGateTests: XCTestCase {
    func testOneCallerIsAdmittedAndTheRestQueueInOrder() async throws {
        // Three episodes downloaded together used to start three preparations,
        // which fought over the GPU until two of them failed. Now two wait.
        let gate = WiltedPreparationGate()
        var admitted: [String] = []

        try await gate.admit()
        admitted.append("first")

        let second = Task { @MainActor in
            try await gate.admit()
            admitted.append("second")
        }
        let third = Task { @MainActor in
            try await gate.admit()
            admitted.append("third")
        }
        await settle()

        XCTAssertEqual(admitted, ["first"])
        XCTAssertTrue(gate.isBusy)
        XCTAssertEqual(gate.queueDepth, 2)

        gate.release()
        try await second.value
        XCTAssertEqual(admitted, ["first", "second"])
        XCTAssertEqual(gate.queueDepth, 1)
        // The slot is never free between holders, so a caller arriving during
        // the handover queues rather than running alongside the one admitted.
        XCTAssertTrue(gate.isBusy)

        gate.release()
        try await third.value
        XCTAssertEqual(admitted, ["first", "second", "third"])

        gate.release()
        XCTAssertFalse(gate.isBusy)
        XCTAssertEqual(gate.queueDepth, 0)
    }

    func testCancellingAQueuedCallerLeavesTheQueueWithoutWaitingForTheRunAhead() async throws {
        // A cancelled row has to clear now. Chaining each waiter onto the task
        // ahead of it would be FIFO for free and would leave this row saying
        // `Queued` until a ten-minute preparation it no longer cares about is
        // finished, so the waiter is removed from the queue instead.
        let gate = WiltedPreparationGate()
        try await gate.admit()

        let queued = Task { @MainActor () -> Bool in
            do {
                try await gate.admit()
                return false
            } catch {
                return error is CancellationError
            }
        }
        await settle()
        XCTAssertEqual(gate.queueDepth, 1)

        queued.cancel()
        let cancelled = await queued.value

        XCTAssertTrue(cancelled)
        XCTAssertEqual(gate.queueDepth, 0)
        // The holder still holds: cancelling a waiter must not free the slot.
        XCTAssertTrue(gate.isBusy)
        gate.release()
        XCTAssertFalse(gate.isBusy)
    }

    func testAnAlreadyCancelledCallerNeverTakesTheSlot() async {
        let gate = WiltedPreparationGate()
        let task = Task { @MainActor () -> Bool in
            // Cancelled before it ever suspends; the free slot must survive it.
            while !Task.isCancelled { await Task.yield() }
            do {
                try await gate.admit()
                return false
            } catch {
                return error is CancellationError
            }
        }
        task.cancel()
        let cancelled = await task.value

        XCTAssertTrue(cancelled)
        XCTAssertFalse(gate.isBusy)
    }

    func testTheSlotIsHandedOnWhenItsWinnerHasAlreadyBeenCancelled() async throws {
        // The slot arrives for a caller that is going away. Handing it to the
        // next in line is the difference between one lost preparation and
        // every remaining one stranded at `Queued` until the app quits.
        let gate = WiltedPreparationGate()
        try await gate.admit()

        var reached: [String] = []
        let doomed = Task { @MainActor () -> Bool in
            do {
                try await gate.admit()
                reached.append("doomed")
                return false
            } catch {
                return error is CancellationError
            }
        }
        let next = Task { @MainActor in
            try await gate.admit()
            reached.append("next")
        }
        await settle()
        XCTAssertEqual(gate.queueDepth, 2)

        // Cancel and release in the same turn, so the doomed waiter is resumed
        // with the slot it can no longer use.
        doomed.cancel()
        gate.release()

        _ = await doomed.value
        try await next.value
        XCTAssertEqual(reached, ["next"])
        gate.release()
        XCTAssertFalse(gate.isBusy)
    }

    /// Lets every already-spawned task reach its suspension point.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
