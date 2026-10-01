import Foundation

/// A device's one sync timer: every background request the device makes happens inside a round
/// of this tick, so the device never talks to the server more than once per `interval` on its own.
///
/// What a round holds is up to the app (reads of intents and playback records, the publish of
/// changes and position checkpoints, pending-decision checks); the tick only decides when it runs:
///
/// - **Timer.** A round starts `interval` after the previous one started, whoever started that one.
/// - **Back-off.** While the shared `TransportGate` is closed no round starts before its retry time:
///   a rate limit pauses the whole tick, not one request. The first round after the time is the probe.
/// - **Refresh.** `refreshNow()` (pull to refresh) runs a round at once and restarts the timer. While
///   the gate is closed it sends nothing and returns `.throttled` so the caller can show the retry
///   state. A call made while a round runs joins that round instead of queueing another.
/// - **Event.** `requestSoon()` (a silent push, the app coming forward) runs a round now only when one
///   is already due; otherwise the next timer round covers it.
///
/// A user's own action (a decision, a media request, a play start) is not a round: it may send its
/// single write immediately, and any read that confirms it waits for the next round.
public actor SyncTick {
    public enum Trigger: Sendable, Equatable { case timer, refresh, event }

    public enum RefreshOutcome: Sendable, Equatable {
        /// A round ran for this call.
        case ran
        /// A round was already running; this call waited for it.
        case joined
        /// The gate is closed; nothing was sent. The state says when the retry is due.
        case throttled(TransportGateState)
    }

    private let interval: TimeInterval
    private let gate: TransportGate?
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let round: @Sendable (Trigger) async -> Void
    private var loop: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var nap: Task<Void, Error>?
    private var lastStartedAt: Date?
    private var startsImmediately = true

    /// Rounds started since creation, in order.
    public private(set) var roundCount = 0
    public private(set) var triggers: [Trigger] = []

    /// - Parameters:
    ///   - gate: the device's shared gate; a closed gate delays the next round to its retry time.
    ///   - round: one batched round. It handles its own failures.
    public init(
        interval: TimeInterval = SyncCadence.tickInterval,
        gate: TransportGate? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        round: @escaping @Sendable (Trigger) async -> Void
    ) {
        self.interval = interval
        self.gate = gate
        self.clock = clock
        self.sleep = sleep
        self.round = round
    }

    /// Starts the timer. The first round runs at once, unless `immediately` is false (the caller just
    /// read everything itself, so the first round is one `interval` away) or one ran less than
    /// `interval` ago. Calling it again while running does nothing.
    public func start(immediately: Bool = true) {
        guard loop == nil else { return }
        startsImmediately = immediately
        loop = Task { await self.runLoop() }
    }

    /// Stops the timer. A round in flight finishes.
    public func stop() {
        loop?.cancel()
        nap?.cancel()
        loop = nil
    }

    public var isRunning: Bool { loop != nil }

    /// Pull to refresh: a round now, and the timer restarts from it.
    @discardableResult
    public func refreshNow() async -> RefreshOutcome {
        // The gate is read first: nothing below suspends before the round starts, so two callers
        // cannot both find the tick idle.
        let closed = await gate?.state
        if let running {
            await running.value
            return .joined
        }
        if let closed, clock() < closed.retryAt { return .throttled(closed) }
        await perform(.refresh)
        return .ran
    }

    /// A reason to look sooner (a push, the app coming forward): a round now if one is due, else
    /// nothing, since the timer round will come within `interval`. Returns whether a round ran.
    @discardableResult
    public func requestSoon() async -> Bool {
        let closed = await gate?.state
        guard running == nil, isDue(), closed.map({ clock() >= $0.retryAt }) ?? true else { return false }
        await perform(.event)
        return true
    }

    // MARK: - Timer

    private func runLoop() async {
        while !Task.isCancelled {
            let wait = await secondsToWait()
            if wait > 0 {
                let napping = Task { try await self.sleep(wait) }
                nap = napping
                let outcome = await withTaskCancellationHandler { await napping.result } onCancel: { napping.cancel() }
                nap = nil
                if Task.isCancelled { return }
                // A refresh ended the nap early: wait a whole interval from its round instead.
                if case .failure = outcome { continue }
            }
            startsImmediately = false
            if let running { await running.value; continue }
            await perform(.timer)
        }
    }

    private func secondsToWait() async -> TimeInterval {
        let now = clock()
        var wait: TimeInterval = 0
        if let last = lastStartedAt {
            // A round that started a moment ago (a push, a pull) already covered this one.
            wait = max(0, interval - now.timeIntervalSince(last))
            if running == nil, !startsImmediately { wait = interval }
        } else if !startsImmediately {
            wait = interval
        }
        if let state = await gate?.state { wait = max(wait, state.retryAt.timeIntervalSince(now)) }
        return wait
    }

    private func isDue() -> Bool {
        guard let last = lastStartedAt else { return true }
        return clock().timeIntervalSince(last) >= interval
    }

    private func perform(_ trigger: Trigger) async {
        lastStartedAt = clock()
        roundCount += 1
        triggers.append(trigger)
        let round = round
        let task = Task { await round(trigger) }
        running = task
        // Whoever is napping until the next timer round starts over from this one.
        nap?.cancel()
        await task.value
        running = nil
        lastStartedAt = clock()
    }
}
