import Foundation

/// One sleep timer for the process: when it runs out it calls `onExpire` (the player's pause).
///
/// It is deadline-based, not one long sleep: it wakes, checks the clock, and sleeps the remainder, so
/// a wake that was delayed (the app suspended while paused) past the deadline by more than `grace` is
/// dropped instead of pausing whatever the person started in the meantime.
@MainActor
final class SleepTimer {
    static let shared = SleepTimer()

    typealias Instant = ContinuousClock.Instant

    /// How late a wake-up may be and still count; beyond it the timer is stale and silently ends.
    static let grace: Duration = .seconds(30)

    private(set) var deadline: Instant?
    private var task: Task<Void, Never>?
    /// Called after the deadline starts, fires or is cancelled, so a remote can mirror the timer
    /// without polling. Set by `WatchBridge`.
    var onChange: (@MainActor () -> Void)?
    private let now: @MainActor () -> Instant
    private let sleep: @MainActor (Duration) async -> Void

    init(
        now: @escaping @MainActor () -> Instant = { .now },
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    var isActive: Bool { deadline != nil }

    /// The running deadline as a wall-clock date, for the watch snapshot; nil when no timer runs.
    var deadlineDate: Date? {
        guard let deadline else { return nil }
        let remaining = now().duration(to: deadline).components
        return Date().addingTimeInterval(Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
    }

    /// Replaces any running timer.
    func start(minutes: Int, onExpire: @escaping @MainActor () -> Void) {
        cancel()
        let end = now().advanced(by: .seconds(minutes * 60))
        deadline = end
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                let remaining = self.now().duration(to: end)
                if remaining <= .zero {
                    // A cancel or replacement that raced this wake-up must not fire.
                    guard self.deadline == end else { return }
                    self.deadline = nil
                    self.task = nil
                    self.onChange?()
                    if remaining.components.seconds > -Int64(Self.grace.components.seconds) { onExpire() }
                    return
                }
                await self.sleep(remaining)
            }
        }
        onChange?()
    }

    /// Waits for the running timer to finish or be cancelled; tests call it before asserting.
    func settle() async { await task?.value }

    func cancel() {
        let wasActive = deadline != nil
        task?.cancel()
        task = nil
        deadline = nil
        if wasActive { onChange?() }
    }
}
