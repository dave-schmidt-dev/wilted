import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let outboxLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryOutbox")

/// The model's side of `LibraryIntentOutbox`: what is on disk, whether it may be written, and which
/// library owner the saved intents belong to. Owned by `LibraryAppModel+Outbox`.
@MainActor
final class LibraryOutboxState {
    let outbox: LibraryIntentOutbox
    /// The last set written successfully; nil before the first write of a fresh outbox.
    var written: LibraryIntentOutbox.Saved?
    /// Intent ids that are on disk now. Siri promises delivery only for these.
    var durableIDs: Set<String> = []
    /// The owner stamped on the next write.
    var ownerToken: String?
    /// False after a read failure, so this run never replaces a file it could not read.
    var writable = true
    /// True while several of the model's lists change together, so no half-changed set is written.
    var batching = false
    /// True once the saved intents were checked against the mirror's owner at the first local load.
    var ownerVerified = false
    /// The owner the launch's file was stamped with, and the intents it brought back.
    var restoredOwner: String?
    var restoredIDs: Set<String> = []

    init(outbox: LibraryIntentOutbox) { self.outbox = outbox }
}

extension LibraryAppModel {
    /// Tracks the saved intents again at launch, unsent, exactly as they were made. Nothing is sent
    /// here: the first local load checks they belong to this library's owner, and the next sync round
    /// sends them (`resolveDecisions`, `resolveAdds`, `refreshMediaFromCache`).
    func restoreOutbox() {
        let state = outboxState
        switch state.outbox.load() {
        case .empty: return
        case .unreadable: state.writable = false
        case let .saved(saved):
            state.written = saved
            state.durableIDs = saved.intentIDs
            state.ownerToken = saved.ownerToken
            state.restoredOwner = saved.ownerToken
            state.restoredIDs = saved.intentIDs
            state.batching = true
            defer { state.batching = false }
            decisions = saved.decisions.map { saved in
                var decision = PendingDecision(intent: saved.intent, baseline: saved.baseline)
                decision.isSilent = saved.isSilent
                decision.retiresEpisode = saved.retiresEpisode
                decision.supersededByRestore = saved.supersededByRestore
                return decision
            }
            adds = saved.adds.map { PendingAdd(intent: $0.intent, title: $0.title) }
            unacknowledgedMedia = Dictionary(
                saved.acknowledgements.map { ($0.action.entryID, $0) }, uniquingKeysWith: { first, _ in first })
            outboxLog.notice("Restored \(saved.intentIDs.count, privacy: .public) unsent intents from the last run.")
        }
    }

    /// Run once, at the first local load, before anything is sent: intents saved under another owner
    /// (the account changed while the app was closed) are dropped, never sent to this library. Intents
    /// saved before the mirror knew any owner are kept, as a running app keeps them when it first binds one.
    func verifyOutboxOwner(_ owner: String?) {
        let state = outboxState
        guard !state.ownerVerified else { return }
        state.ownerVerified = true
        let sameOwner = state.restoredOwner == nil || state.restoredOwner == owner
        let foreign = sameOwner ? [] : state.restoredIDs
        state.ownerToken = owner
        guard !foreign.isEmpty else { persistOutbox(); return }
        outboxLog.error("Dropped \(foreign.count, privacy: .public) saved intents made under a different iCloud account.")
        state.batching = true
        decisions.removeAll { foreign.contains($0.id) }
        adds.removeAll { foreign.contains($0.id) }
        unacknowledgedMedia = unacknowledgedMedia.filter { !foreign.contains($0.value.id) }
        state.batching = false
        persistOutbox()
    }

    /// The mirror's owner changed (first binding, or a fresh library after account recovery).
    func outboxOwnerChanged(_ owner: String?) {
        guard outboxState.ownerVerified, outboxState.ownerToken != owner else { return }
        outboxState.ownerToken = owner
        persistOutbox()
    }

    /// The unsent intents as they must be on disk now.
    var outboxContents: LibraryIntentOutbox.Saved {
        LibraryIntentOutbox.Saved(
            ownerToken: outboxState.ownerToken,
            decisions: decisions.filter { !$0.isSent }.map {
                LibraryIntentOutbox.Decision(
                    intent: $0.intent, baseline: $0.baseline, isSilent: $0.isSilent,
                    retiresEpisode: $0.retiresEpisode, supersededByRestore: $0.supersededByRestore)
            },
            adds: adds.filter { !$0.isSent }.map { LibraryIntentOutbox.Add(intent: $0.intent, title: $0.title) },
            acknowledgements: unacknowledgedMedia.values.sorted { $0.id < $1.id })
    }

    /// Writes the unsent set when it changed. Called whenever `decisions`, `adds` or
    /// `unacknowledgedMedia` change, so a new intent is on disk before its send starts and leaves the
    /// file only once the transport accepted it (or the listener cancelled it, or the account was reset).
    func persistOutbox() {
        let state = outboxState
        guard !state.batching else { return }
        guard state.outbox.url != nil, state.writable else { state.durableIDs = []; return }
        let next = outboxContents
        guard next != state.written else { return }
        do {
            try state.outbox.save(next)
            state.written = next
            state.durableIDs = next.intentIDs
        } catch {
            // The file still holds the last good write; only intents in both are saved.
            state.durableIDs.formIntersection(next.intentIDs)
            outboxLog.error("Could not save \(next.intentIDs.count, privacy: .public) unsent intents: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// True when the intent is on disk and will be sent after a relaunch.
    func isDurablyQueued(_ intentID: String) -> Bool { outboxState.durableIDs.contains(intentID) }
}
