import Foundation
import Observation
import OSLog
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer

// MARK: - Controller

/// Republishes when the queue or removals change: it watches the model with
/// `withObservationTracking`, coalesces bursts, and runs one publisher pass at a time. A user's
/// edit publishes its state at once (debounced); everything else, statistics and the playing
/// checkpoint included, waits for the next sync round (`tickRound`, 30 s), which is also what
/// retries a failed pass. Owned by the model through an associated object, so it ends with the model.
@MainActor
final class WiltedMacLibrarySyncController {
    let publisher: WiltedMacLibraryPublisher
    let sink: WiltedMacLibraryIntentSink
    private(set) var lastReport: LibraryPublishReport?
    private(set) var lastFailure: String?
    private(set) var passCount = 0
    /// The media service, inbound poller and intent ledger; stopped with the controller.
    var inbound: WiltedMacInboundRuntime?
    /// The only writer of the Mac's playback records; stopped with the controller.
    var handoff: WiltedMacHandoffController?
    /// The iCloud account binding that gates every server call; nil when unmanaged (Task 5.0).
    var account: WiltedMacLibraryAccountController?
    private weak var model: WiltedMacModel?
    private let triggers: AsyncStream<Void>.Continuation
    private var loop: Task<Void, Never>?
    var publicationHydration: Task<Void, Never>?
    private var offerReconcile: Task<Void, Never>?
    private var offerReconcileRequested = false
    private var passTail: Task<Bool, Never>?
    private var syncNowTask: Task<Void, Never>?
    private(set) var syncNowRuns = 0
    private var stopped = false
    private var observedInputs: WiltedMacLibraryPublicationInputs?
    private(set) var observedChangeCount = 0
    /// Injected lifecycle observation for deterministic shutdown tests.
    var onShutdownDrain: (@MainActor () async -> Void)?

    init(
        model: WiltedMacModel, publisher: WiltedMacLibraryPublisher, sink: WiltedMacLibraryIntentSink,
        debounce: Duration
    ) {
        self.model = model
        self.publisher = publisher
        self.sink = sink
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        triggers = continuation
        loop = Task { [weak self] in
            for await _ in stream {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled, let self else { return }
                // A failed edit waits for the next sync round instead of running its own retry timer.
                _ = await self.runPass(includesStats: false)
            }
        }
        continuation.yield()
        observe()
    }

    /// Asks for a publisher pass now (still coalesced and debounced), e.g. after a phone decision.
    func requestPublish() { triggers.yield() }

    /// Sync now: one round at once (the reads, then this Mac's sends), or one publisher pass while
    /// the poller is not running. A press while one runs joins it, so a burst costs one round.
    func syncNow() -> Task<Void, Never> {
        if let syncNowTask { return syncNowTask }
        syncNowRuns += 1
        model?.librarySyncActivity.isSyncing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let poller = self.inbound?.poller, await poller.isRunning {
                // The round's own `publishRound` runs the pass; a closed gate shows as the throttle.
                _ = await poller.refreshNow()
            } else {
                _ = await self.runPass(includesStats: false)
            }
            // A stopped owner's activity was already cleared; a successor's must not be touched.
            if !self.stopped { self.model?.librarySyncActivity.isSyncing = false }
            self.syncNowTask = nil
        }
        syncNowTask = task
        return task
    }

    /// The Mac's own work in one sync round, after the round's reads: the library state and
    /// statistics (a request only when one changed), then the playing checkpoint and the stored positions.
    func tickRound() async {
        guard !stopped else { return }
        _ = await runPass(includesStats: true)
        await handoff?.tickRound()
    }

    func stop() {
        stopped = true
        account?.stop()
        inbound?.stop()
        handoff?.stop()
        loop?.cancel()
        publicationHydration?.cancel()
        offerReconcile?.cancel()
        triggers.finish()
    }

    /// Stops accepting work and drains finite writers before their directory can go away.
    func close() async {
        stop()
        await onShutdownDrain?()
        await account?.close()
        await inbound?.close()
        await loop?.value
        await publicationHydration?.value
        await offerReconcile?.value
        await syncNowTask?.value
        _ = await passTail?.value
    }

    isolated deinit { stop() }

    private func observe() {
        guard !stopped, let model else { return }
        let previous = observedInputs
        let current = withObservationTracking {
            model.librarySyncPublicationInputs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                // Observation is one-shot even when only normalized byte counts changed.
                self.observe()
                self.observedChangeCount += 1
            }
        }
        observedInputs = current
        if let previous, previous != current { triggers.yield() }
    }

    /// Publishes `available` offers, one run at a time; a request that arrives during a run makes
    /// it repeat, so bursts coalesce. A run that could not publish everything is repeated by the
    /// next sync round.
    private func scheduleOfferReconcile() {
        guard !stopped, let service = inbound?.service else { return }
        guard offerReconcile == nil else {
            offerReconcileRequested = true
            return
        }
        offerReconcile = Task { [weak self] in
            repeat {
                self?.offerReconcileRequested = false
                _ = await service.reconcileAvailable()
            } while self?.offerReconcileRequested == true && !Task.isCancelled
            self?.offerReconcile = nil
        }
    }

    /// One pass at a time: an edit and a sync round never publish the same diff twice.
    private func runPass(includesStats: Bool) async -> Bool {
        guard !stopped else { return true }
        let previous = passTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            return await self?.performPass(includesStats: includesStats) ?? true
        }
        passTail = task
        return await task.value
    }

    private func performPass(includesStats: Bool) async -> Bool {
        guard !stopped, let model, !model.isClosingTemporaryState else { return true }
        // Paused for the account: nothing to send, and nothing to report as a failure.
        if let account, !account.gate.isOpen { return true }
        do {
            let report = try await publisher.sync(includesStats: includesStats)
            lastReport = report
            // What this pass diffed but iCloud did not acknowledge (conflicts and retries).
            let unsent = max(0, report.pushed - report.acknowledged)
            updateActivity {
                $0.recordSend(acknowledged: report.acknowledged, unsent: unsent,
                              publicationCompleted: report.publicationCompleted, at: Date())
                $0.publication = report.publication
                $0.publicationOwner = account?.approvedPublicationOwner
            }
            // Offers follow the same triggers as state (the queue and the prepared set) but run on
            // their own task: the media service serializes behind an upload in flight, and a long
            // upload must not hold up state publishing.
            scheduleOfferReconcile()
            lastFailure = nil
            passCount += 1
            return true
        } catch {
            lastFailure = String(describing: error)
            // A closed gate reports itself (the Sync card); only a new kind of failure is an error.
            if !Self.isPause(error) {
                librarySyncLog.error("Library publish failed: \(String(describing: error), privacy: .public)")
                // A thrown pass reports no count, so the card names none.
                updateActivity { $0.recordSendFailure(unsent: nil) }
            }
            return false
        }
    }

    /// Writes the model's activity only when it changed, so an idle round wakes no view.
    private func updateActivity(_ change: (inout WiltedMacLibrarySyncActivity) -> Void) {
        guard let model else { return }
        var next = model.librarySyncActivity
        change(&next)
        if next != model.librarySyncActivity { model.librarySyncActivity = next }
    }

    /// A rate limit or an account hold: each has its own status, so neither is a send failure.
    static func isPause(_ error: any Error) -> Bool {
        error is TransportThrottled || isAccountPause(error)
    }

    /// A call refused or superseded by the account gate; the account status reports it.
    static func isAccountPause(_ error: any Error) -> Bool {
        error is WiltedMacLibraryAccountError || (error as? LibraryTransportError) == .superseded
    }
}
#endif
