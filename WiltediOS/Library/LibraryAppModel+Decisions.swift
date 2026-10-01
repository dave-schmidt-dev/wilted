import Foundation
import WiltedDomain
import WiltedLibrary

/// A decision a person can make about an episode from the phone. Each one becomes an intent
/// for the Mac; the phone itself never changes a slot or a removal.
enum LibraryDecisionAction: Equatable, Sendable {
    case removeFromLarder, markDone
    /// Move to just after `afterEntryID`; nil moves to the front of the Larder.
    case reorder(afterEntryID: ItemID?)

    var title: String {
        switch self {
        case .removeFromLarder: "Remove from Larder"
        case .markDone: "Mark completed"
        case .reorder: "Move"
        }
    }

    var systemImage: String {
        switch self {
        case .removeFromLarder: "minus.circle"
        case .markDone: "checkmark.circle"
        case .reorder: "arrow.up.arrow.down"
        }
    }

    /// Short word used in accessibility identifiers.
    var identifier: String {
        switch self {
        case .removeFromLarder: "remove"
        case .markDone: "done"
        case .reorder: "move"
        }
    }

    func intentAction(for entryID: ItemID) -> LibraryIntent.Action {
        switch self {
        case .removeFromLarder: .removeFromLarder(entryID: entryID)
        case .markDone: .markDone(entryID: entryID)
        case let .reorder(after): .reorder(entryID: entryID, afterEntryID: after)
        }
    }
}

/// The buttons a Larder row offers. The phone decides nothing about New or removed episodes;
/// those stay on the Mac, and a Larder row never repeats Feeds' Keep or Skip. Remove from Larder is
/// always available; Mark done needs a started, unfinished episode.
enum LibraryRowActions {
    static func actions(for row: LibraryRow) -> [LibraryDecisionAction] {
        row.isStarted ? [.removeFromLarder, .markDone] : [.removeFromLarder]
    }
}

/// Waiting limits for a decision.
struct LibraryDecisionTiming: Sendable {
    /// How long an unacknowledged decision shows as waiting before it reverts to "Pending on Mac".
    var confirmationTimeout: TimeInterval = 60
    /// How often to look for the Mac's answer while one is expected.
    var pollInterval: Duration = .seconds(5)
    /// How often to keep looking once every decision is pending, so a stale intent costs little.
    var pendingPollInterval: Duration = .seconds(30)
}

/// Where an entry sits in the mirrored library; what a decision is compared against.
struct EntryPlacement: Equatable, Sendable {
    let removal: LibraryRemoval
    let isQueued: Bool
    /// The entry just before this one in the Larder, nil at the front or when not queued.
    let predecessor: ItemID?

    init?(of entryID: ItemID, in content: LibrarySnapshot) {
        guard let entry = content.entries[entryID] else { return nil }
        removal = entry.removal
        let order = content.queue.map(\.entryID)
        isQueued = content.slots[entryID] != nil
        predecessor = order.firstIndex(of: entryID).flatMap { $0 > 0 ? order[$0 - 1] : nil }
    }
}

/// One decision the phone sent and has not yet seen settled.
struct PendingDecision: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Sent; the display shows the expected result.
        case awaiting
        /// No answer after the timeout: the display reverted, the intent stays queued.
        case pendingOnMac
        /// The Mac said applied; the display holds the result until the fetched state catches up.
        case applied(at: Date)
    }

    let intent: LibraryIntent
    /// The entry's mirrored placement when the decision was made.
    let baseline: EntryPlacement
    var phase: Phase = .awaiting
    /// False until the transport accepted the intent; unsent intents are retried.
    var isSent = false

    var id: String { intent.id }
    var entryID: ItemID { intent.action.entryID }
    var showsOptimistically: Bool { phase != .pendingOnMac }

    /// True once the fetched state already shows what this decision asked for.
    func isSatisfied(by placement: EntryPlacement) -> Bool {
        switch intent.action {
        case .keep: placement.isQueued && placement.removal == .none
        case .skip, .markDone: placement.removal != .none && !placement.isQueued
        case .removeFromLarder: !placement.isQueued
        case .restore: placement.removal == .none
        case let .reorder(_, after): placement.isQueued && placement.predecessor == after
        case .requestMedia, .mediaCached: true
        }
    }
}

/// What a row says about its decision, in words.
enum LibraryDecisionStatus: Equatable, Sendable {
    case waiting
    case confirming
    case pendingOnMac
    case failed(String)

    var text: String {
        switch self {
        case .waiting: "Waiting for the Mac to confirm"
        case .confirming: "Confirmed by the Mac, updating"
        case .pendingOnMac: "Pending on Mac: not applied yet. Showing the last state the Mac published."
        case let .failed(reason): reason
        }
    }
}

/// Lays unsettled decisions over the mirrored content. Display only: nothing here is written back.
enum LibraryDecisionOverlay {
    static func apply(_ decisions: [PendingDecision], to content: LibrarySnapshot) -> LibrarySnapshot {
        decisions.filter(\.showsOptimistically).reduce(content) { apply($1, to: $0) }
    }

    private static func apply(_ decision: PendingDecision, to content: LibrarySnapshot) -> LibrarySnapshot {
        var next = content
        let entryID = decision.entryID
        guard let entry = content.entries[entryID] else { return content }
        switch decision.intent.action {
        case .keep:
            guard entry.removal == .none, content.slots[entryID] == nil else { return content }
            let last = content.slots.values.map(\.sortKey).max() ?? -1
            next.slots[entryID] = try? QueueSlot(entryID: entryID, sortKey: last + 1)
        case .removeFromLarder:
            next.slots[entryID] = nil
        case .skip, .markDone:
            next.entries[entryID] = try? entry.with(removal: .retired, removedAt: decision.intent.createdAt)
            next.slots[entryID] = nil
        case .restore:
            guard entry.removal != .none else { return content }
            next.entries[entryID] = try? entry.with(removal: .none, removedAt: nil)
        case let .reorder(_, after):
            guard content.slots[entryID] != nil else { return content }
            var order = content.queue.map(\.entryID).filter { $0 != entryID }
            var index = 0
            if let after {
                guard let position = order.firstIndex(of: after) else { return content }
                index = position + 1
            }
            order.insert(entryID, at: index)
            for (offset, id) in order.enumerated() { next.slots[id] = try? QueueSlot(entryID: id, sortKey: Double(offset)) }
        case .requestMedia, .mediaCached:
            return content
        }
        return next
    }
}

extension LibraryAppModel {
    // MARK: - Reading

    /// The decision in flight for `entryID`, if any.
    func pendingDecision(for entryID: ItemID) -> PendingDecision? { decisions.first { $0.entryID == entryID } }

    /// What to show under the row: the state of its decision or why one was rolled back.
    func decisionStatus(for entryID: ItemID) -> LibraryDecisionStatus? {
        if let pending = pendingDecision(for: entryID) {
            switch pending.phase {
            case .awaiting: return .waiting
            case .pendingOnMac: return .pendingOnMac
            case .applied: return .confirming
            }
        }
        return decisionNotices[entryID].map(LibraryDecisionStatus.failed)
    }

    /// The buttons a row offers now; none while it has a decision in flight.
    func decisionActions(for row: LibraryRow) -> [LibraryDecisionAction] {
        pendingDecision(for: row.id) == nil ? LibraryRowActions.actions(for: row) : []
    }

    // MARK: - Acting

    /// Fire-and-forget from a button: optimistic at once, settled by the Mac's outcome.
    func performDecision(_ action: LibraryDecisionAction, entryID: ItemID) {
        Task { await decide(action, entryID: entryID) }
    }

    /// Records the decision, shows its expected result and sends it. A decision the row would not
    /// offer, or a second one for an entry that already has one, is ignored.
    func decide(_ action: LibraryDecisionAction, entryID: ItemID) async {
        guard let decision = begin(action, entryID: entryID) else { return }
        await send(decision)
    }

    /// Drops local tracking of a decision and reverts its display. The intent is already with the
    /// Mac and cannot be recalled; if the Mac still applies it, the next publish shows the result.
    func cancelDecision(entryID: ItemID) {
        decisions.removeAll { $0.entryID == entryID }
        decisionNotices[entryID] = nil
        rebuildRows()
    }

    func discardDecisionsAfterAccountChange() {
        decisionPoll?.cancel()
        decisionPoll = nil
        decisions = []
        decisionNotices = [:]
        decisionContent = LibrarySnapshot()
        startedEntries = []
    }

    // MARK: - Settling

    /// Compares every unsettled decision with the Mac's outcomes and the fetched state: a rejection
    /// rolls it back with a reason, an applied outcome or a matching publish confirms it, a publish
    /// that moved the entry somewhere else contradicts it (the Mac's state wins), and an unanswered
    /// one reverts to "Pending on Mac" after the timeout while staying tracked.
    func resolveDecisions() async {
        guard !decisions.isEmpty else { return }
        for decision in decisions where !decision.isSent { await send(decision) }
        let mine = ((try? await transport.intentOutcomes()) ?? []).filter { $0.deviceID == deviceID }
        let outcomes = Dictionary(mine.map { ($0.intentID, $0) }, uniquingKeysWith: { first, _ in first })
        let current = now()
        var changed: [String: PendingDecision?] = [:]
        for var decision in decisions {
            let original = decision
            var settled = false
            if let outcome = outcomes[decision.id] {
                if outcome.isApplied {
                    if case .applied = decision.phase {} else { decision.phase = .applied(at: current) }
                } else {
                    decisionNotices[decision.entryID] = Self.rejectionText(outcome.reason)
                    settled = true
                }
            }
            if !settled { settled = isSettledByFetchedState(decision) }
            if !settled { settled = advance(&decision, at: current) }
            if settled { changed[decision.id] = .some(nil) } else if decision != original { changed[decision.id] = decision }
        }
        if !changed.isEmpty { decisions = decisions.compactMap { changed[$0.id] ?? $0 } }
        rebuildRows()
        ensureDecisionPolling()
    }

    private func isSettledByFetchedState(_ decision: PendingDecision) -> Bool {
        guard let placement = EntryPlacement(of: decision.entryID, in: decisionContent) else { return true }
        return decision.isSatisfied(by: placement) || placement != decision.baseline
    }

    /// Applies the clock to a decision; true when it should be forgotten.
    private func advance(_ decision: inout PendingDecision, at current: Date) -> Bool {
        let limit = decisionTiming.confirmationTimeout
        switch decision.phase {
        case .awaiting:
            if current.timeIntervalSince(decision.intent.createdAt) >= limit { decision.phase = .pendingOnMac }
            return false
        case let .applied(since): return current.timeIntervalSince(since) >= limit
        case .pendingOnMac: return false
        }
    }

    // MARK: - Internals

    private func begin(_ action: LibraryDecisionAction, entryID: ItemID) -> PendingDecision? {
        guard !accountQuarantined, pendingDecision(for: entryID) == nil,
              isOffered(action, entryID: entryID),
              let baseline = EntryPlacement(of: entryID, in: decisionContent),
              let intent = try? LibraryIntent(
                  id: UUID().uuidString, deviceID: deviceID, createdAt: now(), action: action.intentAction(for: entryID))
        else { return nil }
        let decision = PendingDecision(intent: intent, baseline: baseline)
        decisionNotices[entryID] = nil
        decisions.append(decision)
        rebuildRows()
        ensureDecisionPolling()
        return decision
    }

    /// Whether the displayed sections offer `action` for `entryID` right now.
    private func isOffered(_ action: LibraryDecisionAction, entryID: ItemID) -> Bool {
        switch action {
        case .removeFromLarder, .markDone: return queued.first { $0.id == entryID }.map { LibraryRowActions.actions(for: $0).contains(action) } ?? false
        case let .reorder(after):
            let order = queued.map(\.id)
            guard let index = order.firstIndex(of: entryID), after != entryID else { return false }
            if let after, !order.contains(after) { return false }
            return (index > 0 ? order[index - 1] : nil) != after
        }
    }

    /// Sends the intent; a failure leaves it unsent and it is retried on the next settle pass.
    private func send(_ decision: PendingDecision) async {
        guard (try? await transport.send(intent: decision.intent)) != nil,
              let index = decisions.firstIndex(where: { $0.id == decision.id }) else { return }
        decisions[index].isSent = true
    }

    /// Looks again every few seconds while any decision is unsettled, then stops.
    private func ensureDecisionPolling() {
        guard decisionPoll == nil, !decisions.isEmpty else { return }
        decisionPoll = Task { [weak self] in
            while let interval = self?.nextDecisionInterval() {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.refresh()
            }
            self?.decisionPoll = nil
        }
    }

    private func nextDecisionInterval() -> Duration? {
        guard !decisions.isEmpty else { return nil }
        return decisions.contains { $0.phase != .pendingOnMac } ? decisionTiming.pollInterval : decisionTiming.pendingPollInterval
    }

    static func rejectionText(_ reason: String?) -> String {
        switch reason {
        case IntentOutcome.reasonExpired: "The Mac declined it: the request was too old."
        case IntentOutcome.reasonUnknownEntry: "The Mac declined it: it no longer has this episode."
        case IntentOutcome.reasonNotApplicable: "The Mac declined it: that does not apply to the episode now."
        case IntentOutcome.reasonFailed: "The Mac could not apply it."
        default: "The Mac declined it."
        }
    }
}
