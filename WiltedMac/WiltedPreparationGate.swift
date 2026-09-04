import Foundation

/// Admits one podcast preparation at a time and queues the rest in order.
///
/// Preparation's ad pass takes exclusive hold of the shared GPU for the length
/// of a detect run. Two preparations that both want it do not politely queue:
/// each evicts the other's resident speech model and then retries, and the one
/// that loses the race fails outright when its admission budget runs out. Three
/// episodes downloaded together therefore cost two whole preparations, with the
/// journal reading `ads.model.release` / `ads.model.drain` / `ads.model.retry`
/// while they knocked each other down.
///
/// So the app admits one and makes the others wait. The waiting is explicit
/// rather than incidental: a queued caller suspends here, and its row says
/// `Queued` instead of sitting on `Preparing…` with nothing happening.
@MainActor
final class WiltedPreparationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var admitted = false
    private var waiters: [Waiter] = []

    /// True when a preparation holds the slot, so a new caller will wait.
    var isBusy: Bool { admitted }

    /// How many callers are waiting behind the admitted one.
    var queueDepth: Int { waiters.count }

    /// Suspends until this caller owns the only slot.
    ///
    /// Throws `CancellationError` if the caller is cancelled while queued, and
    /// leaves the queue at that moment rather than when the run ahead of it
    /// finishes: a cancelled row must clear now, not in ten minutes.
    func admit() async throws {
        try Task.checkCancellation()
        if !admitted {
            admitted = true
            return
        }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(id) }
        }
        guard granted else { throw CancellationError() }
        if Task.isCancelled {
            // The slot arrived for a caller that is already going away. Hand it
            // to the next in line rather than stranding it until the app quits.
            release()
            throw CancellationError()
        }
    }

    /// Gives the slot up, handing it directly to the longest-waiting caller.
    func release() {
        guard !waiters.isEmpty else {
            admitted = false
            return
        }
        // `admitted` stays true across the handover: the slot is never free
        // between these two lines, so a caller arriving now still queues.
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
