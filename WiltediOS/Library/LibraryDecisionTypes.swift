import Foundation
import WiltedDomain
import WiltedLibrary

/// A decision a person can make about an episode from the phone. Each one becomes an intent
/// for the Mac; the phone itself never changes a slot or a removal.
enum LibraryDecisionAction: Equatable, Sendable {
    case removeFromLarder, markDone, restore
    case newEpisode(LibraryNewEpisodeDecision)
    /// Move to just after `afterEntryID`; nil moves to the front of the Larder.
    /// The moved entry is the owner's Keep choice; the anchor's provenance is unchanged.
    case reorder(afterEntryID: ItemID?)

    var title: String {
        switch self {
        case .removeFromLarder: "Remove from Larder"
        case .markDone: "Mark completed"
        case .restore: "Restore"
        case .reorder: "Move"
        case let .newEpisode(choice): choice == .keep ? "Keep" : "Skip"
        }
    }

    var systemImage: String {
        switch self {
        case .removeFromLarder: "minus.circle"
        case .markDone: "checkmark.circle"
        case .restore: "arrow.uturn.backward"
        case .reorder: "arrow.up.arrow.down"
        case let .newEpisode(choice): choice == .keep ? "checkmark.circle" : "xmark.circle"
        }
    }

    /// Short word used in accessibility identifiers.
    var identifier: String {
        switch self {
        case .removeFromLarder: "remove"
        case .markDone: "done"
        case .restore: "restore"
        case .reorder: "move"
        case let .newEpisode(choice): choice.rawValue
        }
    }

    func intentAction(for entryID: ItemID) -> LibraryIntent.Action {
        switch self {
        case .removeFromLarder: .removeFromLarder(entryID: entryID)
        case .markDone: .markDone(entryID: entryID)
        case .restore: .restore(entryID: entryID)
        case let .reorder(after): .reorder(entryID: entryID, afterEntryID: after)
        case let .newEpisode(choice): .decideNewEpisode(entryID: entryID, decision: choice)
        }
    }
}

/// The buttons a Larder row offers. The phone decides nothing about New or removed episodes;
/// those stay on the Mac, and a Larder row never repeats Feeds' Keep or Skip. Remove from Larder is
/// always available. Every unfinished podcast offers Mark completed. Other kinds retain their
/// existing started-or-downloaded eligibility; podcast retirement does not change their actions.
enum LibraryRowActions {
    static func actions(for row: LibraryRow, onPhone: Bool = false) -> [LibraryDecisionAction] {
        if row.kind == .podcastEpisode {
            return row.completedAt == nil ? [.removeFromLarder, .markDone] : [.removeFromLarder]
        }
        return row.isStarted || (onPhone && row.completedAt == nil)
            ? [.removeFromLarder, .markDone] : [.removeFromLarder]
    }
}

/// Waiting limits for a decision.
struct LibraryDecisionTiming: Sendable {
    /// How long an unacknowledged decision shows as waiting before it reverts to "Pending on Mac".
    /// The Mac's answer is read by the sync tick (every 30 s), so this spans a few rounds.
    var confirmationTimeout: TimeInterval = 90
}

/// Where an entry sits in the mirrored library; what a decision is compared against.
struct EntryPlacement: Equatable, Sendable {
    let removal: LibraryRemoval
    let isQueued: Bool
    /// The entry just before this one in the Larder, nil at the front or when not queued.
    let predecessor: ItemID?

    init(removal: LibraryRemoval, isQueued: Bool, predecessor: ItemID?) {
        self.removal = removal
        self.isQueued = isQueued
        self.predecessor = predecessor
    }

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
    /// Kept with the owner-scoped outbox so a typed conflict can still name an episode after it leaves New.
    var entryTitle: String? = nil
    var phase: Phase = .awaiting
    /// False until the transport accepted the intent; unsent intents are saved in the outbox and retried.
    var isSent = false
    /// When the transport accepted this decision during the current launch.
    var sentAt: Date?
    var confirmationStart: Date { sentAt ?? intent.createdAt }
    /// A decision the listener did not make (an episode that played to its end): sent and tracked like
    /// any other, but it changes nothing on screen and says nothing on the row; the row follows the Mac.
    var isSilent = false
    var retiresEpisode = true
    /// A newer group Restore replaces the local overlay, never the already-sent intent.
    var supersededByRestore = false

    var id: String { intent.id }
    var entryID: ItemID { intent.action.entryID }
    var showsOptimistically: Bool { !isSilent && !supersededByRestore && phase != .pendingOnMac }
    /// True for a decision that ends the episode's time on the Larder.
    var finishesEpisode: Bool {
        switch intent.action {
        case .markDone, .removeFromLarder, .skip: true
        default: false
        }
    }

    /// True once the fetched state already shows what this decision asked for.
    func isSatisfied(by placement: EntryPlacement) -> Bool {
        switch intent.action {
        case .keep: placement.isQueued && placement.removal == .none
        case .decideNewEpisode: false
        case .skip, .markDone: placement.removal != .none && !placement.isQueued
        case .removeFromLarder: !placement.isQueued && (!retiresEpisode || placement.removal != .none)
        case .restore: placement.removal == .none
        case let .reorder(_, after): placement.isQueued && placement.predecessor == after
        // Add-flow intents are not row decisions; nothing on a row can satisfy them.
        case .requestMedia, .mediaCached, .subscribe, .addArticle, .addLink, .adFeedback,
             .setHeadlineSaved, .setHeadlinePublisherMuted, .listenNext, .requestBulletinAudio, .cancelListenNext,
             .setShowStartOffset, .setShowPlaybackSpeed, .setNotebookEntry, .unsupported: true
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
        let group = LibraryEpisodeAssociation.group(for: entryID, in: Array(content.entries.values))
        // A newer explicit owner choice supersedes an outstanding phone overlay.
        if let at = group?.manualDecidedAt, at > decision.intent.createdAt { return content }
        let members = group?.memberIDs ?? [entryID]
        switch decision.intent.action {
        case .keep:
            guard entry.removal == .none, content.slots[entryID] == nil else { return content }
            let last = content.slots.values.map(\.sortKey).max() ?? -1
            next.slots[entryID] = try? QueueSlot(entryID: entryID, sortKey: last + 1)
        case .decideNewEpisode:
            // Conditional New decisions are never projected optimistically.
            return content
        case .removeFromLarder:
            for id in members {
                if let member = content.entries[id], member.kind == .podcastEpisode {
                    next.entries[id] = try? member.with(removal: .retired, removedAt: decision.intent.createdAt)
                }
                next.slots[id] = nil
            }
        case .skip, .markDone:
            for id in members {
                if let member = content.entries[id] {
                    next.entries[id] = try? member.with(removal: .retired, removedAt: decision.intent.createdAt)
                }
                next.slots[id] = nil
            }
        case .restore:
            for id in members {
                if let member = content.entries[id], member.removal != .none {
                    next.entries[id] = try? member.with(removal: .none, removedAt: nil)
                }
            }
        case let .reorder(_, after):
            let moving = content.queue.map(\.entryID).filter { members.contains($0) }
            guard !moving.isEmpty else { return content }
            var order = content.queue.map(\.entryID).filter { !members.contains($0) }
            var index = 0
            if let after {
                let anchors = LibraryEpisodeAssociation.group(for: after, in: Array(content.entries.values))?.memberIDs ?? [after]
                guard let position = order.lastIndex(where: { anchors.contains($0) }) else { return content }
                index = position + 1
            }
            order.insert(contentsOf: moving, at: index)
            for (offset, id) in order.enumerated() { next.slots[id] = try? QueueSlot(entryID: id, sortKey: Double(offset)) }
        case .requestMedia, .mediaCached, .subscribe, .addArticle, .addLink, .adFeedback,
             .setHeadlineSaved, .setHeadlinePublisherMuted, .listenNext, .requestBulletinAudio, .cancelListenNext,
             .setShowStartOffset, .setShowPlaybackSpeed, .setNotebookEntry, .unsupported:
            return content
        }
        if let group {
            let terminal: Bool?
            switch decision.intent.action {
            case .removeFromLarder, .skip, .markDone: terminal = true
            case .restore: terminal = false
            default: terminal = nil
            }
            if let terminal {
                let overlay = LibraryEpisodeAssociation(groupID: group.groupID, representativeID: group.representativeID,
                    memberIDs: group.memberIDs, associationVersion: group.associationVersion, isTerminal: terminal,
                    latestManualChoice: terminal ? .skip : .keep, manualDecidedAt: decision.intent.createdAt)
                for id in members {
                    guard let member = next.entries[id] else { continue }
                    next.entries[id] = try? LibraryEntry(id: member.id, kind: member.kind, sourceID: member.sourceID,
                        title: member.title, summary: member.summary, publishedAt: member.publishedAt,
                        durationSeconds: member.durationSeconds, artworkRef: member.artworkRef,
                        removal: member.removal, removedAt: member.removedAt, episodeAssociation: overlay, payload: member.payload)
                }
            }
        }
        return next
    }
}
