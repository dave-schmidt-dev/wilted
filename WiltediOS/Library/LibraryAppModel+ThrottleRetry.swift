import Foundation
import WiltedLibrary

/// The phone's retry after iCloud pushes back. The gate only refuses calls while it is closed; it never
/// retries by itself, so without this the Larder waited for the next launch, foreground or pull, and the
/// banner kept showing a retry time that had already passed.
///
/// While the gate is closed exactly one task is pending. It sleeps to the retry time, runs the refresh
/// (the probe), and ends one of three ways: the call succeeds and the gate reopens (the banner clears), iCloud
/// refuses again (the gate closes with a new, later time and a new task replaces this one), or the probe
/// failed for another reason (offline) and the gate stays as it was, so the next attempt is set a fixed
/// wait ahead. Either way the banner shows a time in the future, or "Retrying now…" with an indicator.
extension LibraryAppModel {
    /// The wait before trying again when a retry failed without iCloud saying why.
    static let throttleFallbackWait = SyncCadence.phoneObserveInterval
    /// Added to the sleep so a wake a hair before the gate's time does not meet a closed gate.
    static let throttleWakeMargin: TimeInterval = 0.05

    /// Called by the shared gate when iCloud pushes back (state set) and when a call succeeds again (nil).
    func throttleChanged(_ state: TransportGateState?) {
        guard throttleState != state else { return }
        throttleState = state
        throttleAttemptAt = nil
        throttleRetrying = false
        scheduleThrottleRetry()
    }

    /// Whether the time the next attempt was due has passed, so a refresh now is the retry.
    var throttleIsDue: Bool {
        guard let state = throttleState else { return false }
        return max(state.retryAt, throttleAttemptAt ?? state.retryAt) <= now()
    }

    /// Replaces the pending retry: none while the gate is open, one at its time while it is closed.
    func scheduleThrottleRetry() {
        throttleRetryTask?.cancel()
        throttleRetryTask = nil
        guard let state = throttleState else { return }
        let due = max(state.retryAt, throttleAttemptAt ?? state.retryAt)
        // Weak across the wait, so a model that was replaced is not kept alive to retry later.
        let (sleep, clock) = (throttleSleep, now)
        throttleRetryTask = Task { [weak self] in
            let wait = due.timeIntervalSince(clock())
            if wait > 0 {
                do { try await sleep(wait + Self.throttleWakeMargin) } catch { return }
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.refresh()
            guard !Task.isCancelled, self.throttleState == state else { return }
            // Still closed with the same state: nothing reopened it and nothing closed it again.
            self.throttleAttemptAt = self.now().addingTimeInterval(Self.throttleFallbackWait)
            self.scheduleThrottleRetry()
        }
    }
}
