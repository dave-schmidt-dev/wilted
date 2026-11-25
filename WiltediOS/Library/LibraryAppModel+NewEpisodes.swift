import Foundation
import WiltedDomain
import WiltedLibrary

struct LibraryNewEpisodeConflictNotice: Equatable, Identifiable, Sendable {
    let entryID: ItemID
    let title: String?
    let state: LibraryNewEpisodeCurrentState
    let decidedAt: Date

    var id: ItemID { entryID }
}

extension LibraryAppModel {
    static let decideNewEpisodeAction = "decideNewEpisode"
    static let updateMacNewEpisodesText = "Update Wilted on your Mac to decide new episodes from your phone."

    var newEpisodeRows: [LibraryUndecidedEpisode] {
        LibraryUndecidedEpisodeProjection.rows(in: decisionContent)
    }

    var unlistedNewEpisodeConflictNotices: [LibraryNewEpisodeConflictNotice] {
        let listedIDs = Set(newEpisodeRows.map(\.id))
        return newEpisodeConflictNotices.values
            .filter { !listedIDs.contains($0.entryID) }
            .sorted {
                if $0.decidedAt != $1.decidedAt { return $0.decidedAt > $1.decidedAt }
                return $0.entryID.rawValue < $1.entryID.rawValue
            }
    }

    var newEpisodeCapabilityText: String? {
        if accountQuarantined { return "Sync is paused until the account change is reviewed." }
        if macAddCheckFailed { return "Wilted could not check your Mac. Try again in a moment." }
        guard let actions = macAddActions else { return "Checking your Mac…" }
        return actions.contains(Self.decideNewEpisodeAction) ? nil : Self.updateMacNewEpisodesText
    }

    func pendingNewEpisodeDecision(for entryID: ItemID) -> PendingDecision? {
        decisions.first {
            $0.intent.action.entryID == entryID
                && !$0.isSilent && !$0.supersededByRestore
                && isNewEpisodeIntent($0.intent)
        }
    }

    func newEpisodeStatus(for row: LibraryUndecidedEpisode) -> String? {
        if let decision = pendingNewEpisodeDecision(for: row.id) {
            if !decision.isSent { return "Not sent yet. It will retry when sync is available." }
            switch decision.phase {
            case .awaiting: return "Waiting for your Mac to confirm."
            case .pendingOnMac: return "Pending on Mac. Your last published list is still shown."
            case .applied: return "Confirmed by your Mac. Updating the list."
            }
        }
        if let current = newEpisodeConflictStates[row.id] {
            return Self.newEpisodeConflictText(current)
        }
        return decisionNotices[row.id]
    }

    func chooseNewEpisode(_ choice: LibraryNewEpisodeDecision, entryID: ItemID) async {
        guard !accountQuarantined else {
            newEpisodeNotice = "Sync is paused until the account change is reviewed."
            return
        }
        if macAddActions?.contains(Self.decideNewEpisodeAction) != true || macAddCheckFailed {
            await loadAddCapability()
        }
        guard !accountQuarantined else { return }
        guard macAddActions?.contains(Self.decideNewEpisodeAction) == true, !macAddCheckFailed else {
            newEpisodeNotice = newEpisodeCapabilityText ?? Self.updateMacNewEpisodesText
            return
        }
        guard newEpisodeRows.contains(where: { $0.id == entryID }),
              pendingNewEpisodeDecision(for: entryID) == nil else { return }
        newEpisodeNotice = nil
        newEpisodeConflictStates[entryID] = nil
        newEpisodeConflictNotices[entryID] = nil
        await decide(.newEpisode(choice), entryID: entryID)
    }

    func dismissNewEpisodeConflict(_ entryID: ItemID) {
        newEpisodeConflictStates[entryID] = nil
        newEpisodeConflictNotices[entryID] = nil
        decisionNotices[entryID] = nil
    }

    func ensureNewEpisodeCapability() async {
        if macAddActions == nil || macAddCheckFailed { await loadAddCapability() }
    }

    static func newEpisodeConflictText(_ state: LibraryNewEpisodeCurrentState) -> String {
        switch state {
        case .kept: "Your Mac already kept this episode."
        case .skipped: "Your Mac already skipped this episode."
        case .noLongerNew: "This episode is no longer new on your Mac."
        case .unavailable: "Your Mac can no longer decide this episode."
        }
    }
}

private func isNewEpisodeIntent(_ intent: LibraryIntent) -> Bool {
    if case .decideNewEpisode = intent.action { true } else { false }
}
