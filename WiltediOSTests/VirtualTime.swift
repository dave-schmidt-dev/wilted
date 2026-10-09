import Foundation

/// A clock the test moves by hand. `sleep` suspends until `advance` reaches its wake time, so a
/// device's timer loop can be run through minutes of cadence in microseconds, in a fixed order.
final class VirtualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var waiters: [(wakeAt: Date, resume: CheckedContinuation<Void, Error>, id: Int)] = []
    private var nextID = 0

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    /// Suspends until the clock passes `seconds`; throws `CancellationError` if cancelled first.
    func sleep(_ seconds: TimeInterval, registered: (@Sendable (Date) -> Void)? = nil) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registration = lock.withLock { () -> (disposition: Int, deadline: Date?) in
                    // Cancellation may run before this continuation is registered.
                    // Checking while holding the waiter lock also makes cancellation
                    // after this check find and remove exactly the inserted waiter.
                    if Task.isCancelled { return (-1, nil) }
                    let wakeAt = current.addingTimeInterval(seconds)
                    if seconds <= 0 { return (1, nil) }
                    waiters.append((wakeAt, continuation, id))
                    return (0, wakeAt)
                }
                // A test may move time only after the sleeper actually exists.
                // Notify outside the lock so observers can safely inspect the clock.
                if let deadline = registration.deadline { registered?(deadline) }
                if registration.disposition < 0 { continuation.resume(throwing: CancellationError()) }
                else if registration.disposition > 0 { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).resume
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward, waking each sleeper at its own time and letting it run before the
    /// next one wakes.
    func advance(by seconds: TimeInterval) async {
        let target = now.addingTimeInterval(seconds)
        await settle()
        while true {
            let next = lock.withLock { () -> (Date, CheckedContinuation<Void, Error>)? in
                guard let index = waiters.indices.filter({ waiters[$0].wakeAt <= target })
                    .min(by: { waiters[$0].wakeAt < waiters[$1].wakeAt }) else { return nil }
                let waiter = waiters.remove(at: index)
                current = max(current, waiter.wakeAt)
                return (waiter.wakeAt, waiter.resume)
            }
            guard let next else { break }
            next.1.resume()
            await settle()
        }
        lock.withLock { current = target }
        await settle()
    }

    /// Lets every runnable task make progress. The short real sleep covers tasks running on other
    /// threads, which a yield alone does not wait for.
    func settle() async {
        for _ in 0..<60 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(3))
        for _ in 0..<20 { await Task.yield() }
    }
}
