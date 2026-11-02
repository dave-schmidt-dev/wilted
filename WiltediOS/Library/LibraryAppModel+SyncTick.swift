import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let tickLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibrarySyncTick")

/// What one refresh reads. Defined in WiltedKit as `SyncTick.RoundPlan`.
typealias LibraryRefreshPlan = SyncTick.RoundPlan

/// The phone's tick bookkeeping. A class so the model's extension can keep state without stored
/// properties of its own; touched only on the main actor.
@MainActor
final class LibraryTickState {
    /// Running while the app is in front or audio plays from this phone.
    var tick: SyncTick?
    var sceneActive = false
    /// Rounds the timer or a push has run, to space the state and offer reads.
    var rounds = 0
    /// The next round reads everything: set by a foreground, a push and a first sync.
    var forceFull = false
    /// The offers as of the last read, with when they were read.
    var offers: [ItemID: LibraryMediaOffer] = [:]
    var offersReadAt: Date?
}

/// The phone's side of the cadence rule (`SyncCadence`): one `SyncTick`, running only while the phone
/// is in front or plays audio. Everything periodic rides its rounds: the
/// playback records, the offers, the Mac's outcomes for pending decisions, the playing checkpoint.
/// A user action sends its own write at once; any read that confirms it waits for the next round.
extension LibraryAppModel {
    /// Pull to refresh, a retry after a rate limit and the first sync: a full round now, the 30 s timer
    /// restarted from it. While iCloud is rate limiting it sends nothing; the throttle banner already
    /// shows the retry time. Pulls made while a round runs share it.
    func pullToRefresh() async {
        guard let tick = tickState.tick else { await refresh(); return }
        if case let .throttled(state) = await tick.refreshNow() {
            tickLog.info("Pull to refresh held until \(state.retryAt, privacy: .public)")
        }
    }

    /// The app came to the front. The first sync (`start()`) runs the first round; later ones run a round
    /// only when one is due.
    func sceneBecameActive() async {
        tickState.sceneActive = true
        resumeSuspendedDirectRuns()
        handoffState.interruptions?.appBecameActive()
        guard started else { return }
        tickState.forceFull = true
        await updateSyncTick()
        _ = await tickState.tick?.requestSoon()
    }

    func sceneBecameBackground() async {
        tickState.sceneActive = false
        await updateSyncTick()
    }

    /// Starts or adjusts the tick to match the phone's cadence: 30 s while playing, a request is
    /// pending, or the app is in front; otherwise 5 minutes.
    func updateSyncTick() async {
        let activeCadence = tickState.sceneActive || handoffState.reportedPlaying || media.values.contains { $0.isInFlight }
        let interval = activeCadence ? handoffTiming.observeInterval : SyncCadence.phoneIdleInterval
        if let tick = tickState.tick {
            await tick.setInterval(interval)
        } else {
            let tick = SyncTick(
                interval: interval, gate: throttleGate, clock: now, sleep: handoffTiming.sleep,
                round: { [weak self] trigger in await self?.syncRound(trigger) })
            tickState.tick = tick
            // Whoever starts the tick has just read, or runs the first round themselves.
            await tick.start(immediately: false)
        }
    }

    /// One round of the tick. A pull is a full refresh; the timer and an event read what is due.
    func syncRound(_ trigger: SyncTick.Trigger) async {
        switch trigger {
        case .refresh:
            await refresh(.full)
        case .timer, .event:
            await refresh(nextPlan(for: trigger))
        }
        await handoffState.interruptions?.syncTick()
    }

    private func nextPlan(for trigger: SyncTick.Trigger = .timer) -> LibraryRefreshPlan {
        let state = tickState
        state.rounds += 1
        let forced = state.forceFull
        state.forceFull = false
        return .plan(for: trigger, round: state.rounds, forceFull: forced, hasDecisions: !decisions.isEmpty)
    }

    /// Keeps the offers a round read, for a request that waits for the Mac's.
    func noteOffers(_ offers: [LibraryMediaOffer]) {
        tickState.offers = Dictionary(offers.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        tickState.offersReadAt = now()
        rememberDirectOffers(offers)
    }

    /// Entries any device, this one included, has played past the start.
    static func startedEntries(from records: LibraryDeviceRecords) -> Set<ItemID> {
        Set((records.nowPlaying + records.progress).filter { $0.record.positionSeconds > 0 }.map(\.record.entryID))
    }

    // MARK: - Handoff, inside the round

    /// What the round does for a playing phone: another device that outranks it pauses it, otherwise the
    /// position is published as the checkpoint. The records are the round's own, so there is no second read.
    func observeHandoff(_ records: LibraryDeviceRecords) async {
        guard handoffState.reportedPlaying else { return }
        defer { handoffState.observeCycles += 1 }
        if case let .relinquish(winner) = await coordinator.decision(from: records) {
            await relinquish(to: winner, records: records)
            return
        }
        guard let player = handoffState.player else { return }
        do { try await coordinator.checkpoint(player.position, rate: player.rate) } catch {
            tickLog.error("Could not publish the checkpoint: \(String(describing: error), privacy: .public)")
        }
    }
}
