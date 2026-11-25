import Foundation
import WiltedDomain

/// A conditional Keep or Skip choice made from the phone's New episodes list.
public enum LibraryNewEpisodeDecision: String, Codable, Sendable, Equatable {
    case keep
    case skip
}

/// The state the Mac found when a conditional New episodes choice reached it.
public enum LibraryNewEpisodeCurrentState: String, Codable, Sendable, Equatable {
    case kept
    case skipped
    case noLongerNew
    case unavailable
}

/// A phone list row derived from the Mac's replicated episode and queue state.
public struct LibraryUndecidedEpisode: Sendable, Equatable, Identifiable {
    public let entry: LibraryEntry
    /// Raw episode identities represented by this logical row.
    public let memberIDs: [ItemID]

    public var id: ItemID { entry.id }

    public init(entry: LibraryEntry, memberIDs: [ItemID]) {
        self.entry = entry
        self.memberIDs = memberIDs
    }
}

/// Reconstructs the Mac Feeds undecided set from the same published entries,
/// associations, and queue slots that already drive the phone's Larder.
public enum LibraryUndecidedEpisodeProjection {
    /// Shared eligibility rule for the published phone rows and the Mac's
    /// transactional recheck. Associated episodes are projected as one row;
    /// callers pass the whole group's active and queued facts here.
    public static func isNewEpisodeCandidate(
        kind: LibraryKind,
        removal: LibraryRemoval,
        groupIsTerminal: Bool? = nil,
        groupHasActiveMember: Bool = false,
        isQueued: Bool,
        isAudiobook: Bool = false
    ) -> Bool {
        guard kind == .podcastEpisode, !isAudiobook, !isQueued else { return false }
        if let groupIsTerminal {
            return !groupIsTerminal && groupHasActiveMember
        }
        return removal == .none
    }

    /// Newest first, with stable ID ordering for equal publication dates.
    public static func rows(in snapshot: LibrarySnapshot) -> [LibraryUndecidedEpisode] {
        let entries = snapshot.entries
        let groups = LibraryEpisodeAssociation.coherentGroups(in: Array(entries.values))
        let groupsByMember = Dictionary(groups.flatMap { group in
            group.memberIDs.map { ($0, group) }
        }, uniquingKeysWith: { first, _ in first })
        let queued = Set(snapshot.queue.map(\.entryID))
        var seenGroups = Set<UUID>()
        var result: [LibraryUndecidedEpisode] = []

        for entry in entries.values where entry.kind == .podcastEpisode {
            if let group = groupsByMember[entry.id] {
                guard isNewEpisodeCandidate(
                    kind: entry.kind, removal: entry.removal, groupIsTerminal: group.isTerminal,
                    groupHasActiveMember: group.memberIDs.contains { entries[$0]?.removal == LibraryRemoval.none },
                    isQueued: !Set(group.memberIDs).isDisjoint(with: queued)
                ),
                      seenGroups.insert(group.groupID).inserted,
                      let representative = entries[group.representativeID] ?? group.memberIDs.compactMap({ entries[$0] }).first
                else { continue }
                result.append(LibraryUndecidedEpisode(entry: representative, memberIDs: group.memberIDs))
            } else {
                guard isNewEpisodeCandidate(kind: entry.kind, removal: entry.removal, isQueued: queued.contains(entry.id)) else { continue }
                result.append(LibraryUndecidedEpisode(entry: entry, memberIDs: [entry.id]))
            }
        }

        return result.sorted {
            if $0.entry.publishedAt != $1.entry.publishedAt { return $0.entry.publishedAt > $1.entry.publishedAt }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    /// Whether any member of this logical episode is still on the New list.
    public static func contains(_ entryID: ItemID, in snapshot: LibrarySnapshot) -> Bool {
        rows(in: snapshot).contains { $0.id == entryID || $0.memberIDs.contains(entryID) }
    }
}
