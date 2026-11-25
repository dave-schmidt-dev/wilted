import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    // MARK: - Reading

    /// The decision in flight for `entryID`, if any.
    /// The listener's own pending decision for the entry; a silent one (an episode that played out) is not
    /// theirs and neither hides the row's buttons nor blocks a decision they make.
    func pendingDecision(for entryID: ItemID) -> PendingDecision? { decisions.first { sameLogicalEpisode($0.entryID, entryID) && !$0.isSilent && !$0.supersededByRestore } }

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
        pendingDecision(for: row.id) == nil ? LibraryRowActions.actions(for: row, onPhone: media[row.id] == .onPhone) : []
    }

    // MARK: - Acting

    /// Fire-and-forget from a button: optimistic at once, settled by the Mac's outcome.
    func performDecision(_ action: LibraryDecisionAction, entryID: ItemID) {
        Task { await decide(action, entryID: entryID) }
    }

    /// Records the decision, shows its expected result and sends it. A decision the row would not
    /// offer, or a second one for an entry that already has one, is ignored.
    func decide(_ action: LibraryDecisionAction, entryID: ItemID, requiresOffer: Bool = true, silent: Bool = false) async {
        guard let decision = begin(action, entryID: entryID, requiresOffer: requiresOffer, silent: silent) else { return }
        await send(decision)
    }

    /// Drops local tracking of a decision and reverts its display. The intent is already with the
    /// Mac and cannot be recalled; if the Mac still applies it, the next publish shows the result.
    func cancelDecision(entryID: ItemID) {
        if sameLogicalEpisode(undoableCompletion, entryID) { undoableCompletion = nil }
        decisions.removeAll { sameLogicalEpisode($0.entryID, entryID) }
        decisionNotices[entryID] = nil
        forgetFinishedHere(entryID, because: "stopped waiting")
        journal?.note("decision-cancelled entry=\(entryID.rawValue)")
        rebuildRows()
    }

    func discardDecisionsAfterAccountChange() {
        decisions = []
        decisionNotices = [:]
        newEpisodeConflictStates = [:]
        newEpisodeConflictNotices = [:]
        newEpisodeNotice = nil
        decisionContent = LibrarySnapshot()
        startedEntries = []
        undoableCompletion = nil
        discardFinishedHereAfterAccountChange()
    }

    // MARK: - Settling

    /// Compares every unsettled decision with the Mac's outcomes and the fetched state: a rejection
    /// rolls it back with a reason, an applied outcome or a matching publish confirms it, a publish
    /// that moved the entry somewhere else contradicts it (the Mac's state wins), and an unanswered
    /// one reverts to "Pending on Mac" after the timeout while staying tracked. A decision the Mac does
    /// not have yet is still owed to it: a contradicting publish only reverts its display, and it stays
    /// in the outbox until it is sent.
    func resolveDecisions(outcomes read: [IntentOutcome]) async {
        guard !decisions.isEmpty else {
            clearUnavailableCompletionRestore()
            return
        }
        for decision in decisions where !decision.isSent { await send(decision) }
        let mine = read.filter { $0.deviceID == deviceID }
        let outcomes = Dictionary(mine.map { ($0.intentID, $0) }, uniquingKeysWith: { first, _ in first })
        let current = now()
        var changed: [String: PendingDecision?] = [:]
        for var decision in decisions {
            let original = decision
            var settled = false
            if let outcome = outcomes[decision.id] {
                if outcome.isApplied {
                    if case .applied = decision.phase {} else {
                        decision.phase = .applied(at: current)
                        journal?.note("decision-applied \(decision.journalFields)")
                    }
                } else {
                    if sameLogicalEpisode(undoableCompletion, decision.entryID), !decision.supersededByRestore {
                        undoableCompletion = nil
                    }
                    if !decision.isSilent, !decision.supersededByRestore {
                        decisionNotices[decision.entryID] = Self.rejectionText(outcome.reason)
                    }
                    if case .decideNewEpisode = decision.intent.action {
                        if outcome.reason == IntentOutcome.reasonNewEpisodeConflict,
                           let current = outcome.currentNewEpisodeState {
                            newEpisodeConflictStates[decision.entryID] = current
                            decisionNotices[decision.entryID] = Self.newEpisodeConflictText(current)
                            newEpisodeConflictNotices[decision.entryID] = LibraryNewEpisodeConflictNotice(
                                entryID: decision.entryID,
                                title: decision.entryTitle ?? decisionContent.entries[decision.entryID]?.title,
                                state: current, decidedAt: outcome.decidedAt)
                        } else if outcome.reason == IntentOutcome.reasonUnsupportedAction {
                            newEpisodeConflictStates[decision.entryID] = nil
                            newEpisodeConflictNotices[decision.entryID] = nil
                            decisionNotices[decision.entryID] = Self.updateMacNewEpisodesText
                        } else {
                            newEpisodeConflictStates[decision.entryID] = nil
                            newEpisodeConflictNotices[decision.entryID] = nil
                        }
                    }
                    if decision.finishesEpisode, !decision.supersededByRestore {
                        forgetFinishedHere(decision.entryID, because: "declined by the Mac")
                    }
                    journal?.note("decision-declined \(decision.journalFields) reason=\"\(outcome.reason ?? "none")\"")
                    settled = true
                }
            }
            var why = "declined"
            if !settled { settled = isSettledByFetchedState(decision); why = "library-shows-it" }
            if !settled, !decision.isSent, isContradictedByFetchedState(decision) { decision.phase = .pendingOnMac }
            if !settled { settled = advance(&decision, at: current); why = "applied-wait-over" }
            if settled {
                changed[decision.id] = .some(nil)
                journal?.note("decision-forgotten \(decision.journalFields) why=\(why)")
            } else if decision != original {
                changed[decision.id] = decision
                if decision.phase == .pendingOnMac, original.phase != .pendingOnMac {
                    journal?.note("decision-pending-on-mac \(decision.journalFields) sent=\(decision.isSent)")
                }
            }
        }
        if !changed.isEmpty { decisions = decisions.compactMap { changed[$0.id] ?? $0 } }
        clearUnavailableCompletionRestore()
        rebuildRows()
    }

    /// Phone Restore is durable; retain it while the episode remains retired.
    private func clearUnavailableCompletionRestore() {
        if let entryID = undoableCompletion, !isOffered(.restore, entryID: entryID) {
            undoableCompletion = nil
        }
    }

    private func isSettledByFetchedState(_ decision: PendingDecision) -> Bool {
        if case .decideNewEpisode = decision.intent.action {
            if case .applied = decision.phase {
                return !LibraryUndecidedEpisodeProjection.contains(decision.entryID, in: decisionContent)
            }
            return false
        }
        if let at = episodeGroup(decision.entryID)?.manualDecidedAt, at > decision.intent.createdAt { return true }
        if case .restore = decision.intent.action, let group = episodeGroup(decision.entryID) {
            return group.latestManualChoice == .keep && (group.manualDecidedAt.map { $0 >= decision.intent.createdAt } ?? false)
        }
        guard let placement = EntryPlacement(of: decision.entryID, in: decisionContent) else { return decision.isSent }
        if decision.isSatisfied(by: placement) { return true }
        // An unsent decision is never dropped for a contradiction: the Mac has not seen it yet.
        return decision.isSent && placement != decision.baseline
    }

    /// The fetched state moved the entry away from where it was when the decision was made.
    private func isContradictedByFetchedState(_ decision: PendingDecision) -> Bool {
        guard let placement = EntryPlacement(of: decision.entryID, in: decisionContent) else { return true }
        return placement != decision.baseline
    }

    /// Applies the clock to a decision; true when it should be forgotten.
    private func advance(_ decision: inout PendingDecision, at current: Date) -> Bool {
        let limit = decisionTiming.confirmationTimeout
        switch decision.phase {
        case .awaiting:
            if decision.isSent, current.timeIntervalSince(decision.confirmationStart) >= limit {
                decision.phase = .pendingOnMac
            }
            return false
        case let .applied(since): return current.timeIntervalSince(since) >= limit
        case .pendingOnMac: return false
        }
    }

    // MARK: - Internals

    /// `requiresOffer` is false and `silent` true for an episode that just played out: the listener did
    /// not ask, so the row's own buttons do not gate it and nothing on screen changes until the Mac does.
    private func begin(_ action: LibraryDecisionAction, entryID: ItemID, requiresOffer: Bool = true, silent: Bool = false) -> PendingDecision? {
        let priorFinishes = decisions.filter { decision in
            guard !decision.isSilent, !decision.supersededByRestore, sameLogicalEpisode(decision.entryID, entryID) else { return false }
            switch decision.intent.action {
            case .markDone, .removeFromLarder, .skip: return true
            default: return false
            }
        }
        let restoringGroup = action == .restore && episodeGroup(entryID) != nil && !priorFinishes.isEmpty
        guard !accountQuarantined, !decisions.contains(where: {
            sameLogicalEpisode($0.entryID, entryID) && !$0.supersededByRestore
                && (silent ? $0.intent.action == .markDone(entryID: entryID) : !$0.isSilent)
                && !(restoringGroup && priorFinishes.contains($0))
        }),
              !requiresOffer || isOffered(action, entryID: entryID),
              let baseline = EntryPlacement(of: entryID, in: decisionContent),
              let intent = try? LibraryIntent(
                  id: UUID().uuidString, deviceID: deviceID, createdAt: now(), action: action.intentAction(for: entryID))
        else { return nil }
        if restoringGroup {
            let ids = Set(priorFinishes.map(\.id))
            for index in decisions.indices where ids.contains(decisions[index].id) {
                decisions[index].supersededByRestore = true
            }
        }
        var decision = PendingDecision(
            intent: intent, baseline: baseline, entryTitle: decisionContent.entries[entryID]?.title)
        decision.isSilent = silent
        decision.retiresEpisode = decisionContent.entries[entryID]?.kind == .podcastEpisode
        if !silent, decision.retiresEpisode, action == .removeFromLarder || action == .markDone { undoableCompletion = entryID }
        if action == .restore { undoableCompletion = nil }
        if !silent { decisionNotices[entryID] = nil }
        decisions.append(decision)
        journal?.note("decision-begun action=\(action) entry=\(entryID.rawValue) silent=\(silent)")
        if !silent, action == .removeFromLarder || action == .markDone {
            for id in episodeGroup(entryID)?.memberIDs ?? [entryID] { withdrawQueuePlayback(id) }
            // After the unload: a loaded episode that is not at its end counts as played again.
            rememberFinishedHere(entryID)
        }
        if action == .restore { forgetFinishedHere(entryID, because: "restored") }
        rebuildRows()
        return decision
    }

    /// Whether the displayed sections offer `action` for `entryID` right now.
    private func isOffered(_ action: LibraryDecisionAction, entryID: ItemID) -> Bool {
        switch action {
        case .newEpisode:
            return macAddActions?.contains("decideNewEpisode") == true
                && LibraryUndecidedEpisodeProjection.contains(entryID, in: decisionContent)
        case .removeFromLarder, .markDone: return logicalRow(for: entryID).map { LibraryRowActions.actions(for: $0, onPhone: media[$0.id] == .onPhone).contains(action) } ?? false
        case .restore:
            let overlaid = LibraryDecisionOverlay.apply(decisions, to: decisionContent)
            return episodeGroup(entryID)?.isTerminal == true || overlaid.entries[entryID]?.removal == .retired
        case let .reorder(after):
            let order = logicalQueued.map(\.id)
            guard let index = order.firstIndex(of: entryID), after != entryID else { return false }
            if let after, !order.contains(after) { return false }
            return (index > 0 ? order[index - 1] : nil) != after
        }
    }

    /// Sends the intent; a failure leaves it unsent and it is retried on the next settle pass.
    private func send(_ decision: PendingDecision) async {
        if case .decideNewEpisode = decision.intent.action {
            if macAddActions?.contains(Self.decideNewEpisodeAction) != true || macAddCheckFailed {
                await loadAddCapability()
            }
            guard !accountQuarantined,
                  macAddActions?.contains(Self.decideNewEpisodeAction) == true,
                  !macAddCheckFailed,
                  decisions.contains(where: { $0.id == decision.id && !$0.isSent }) else { return }
        }
        do {
            try await transport.send(intent: decision.intent)
            if let index = decisions.firstIndex(where: { $0.id == decision.id && !$0.isSent }) {
                var accepted = decisions[index]
                accepted.sentAt = now()
                accepted.isSent = true
                decisions[index] = accepted
            }
            journal?.note("decision-sent \(decision.journalFields)")
        } catch {
            journal?.note("decision-send-failed \(decision.journalFields)")
        }
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

private extension PendingDecision {
    /// `action=<name> entry=<id>` for a journal line; the action is named as `decision-begun` names it.
    var journalFields: String {
        "action=\(String(describing: intent.action).prefix { $0 != "(" }) entry=\(entryID.rawValue)"
    }
}
