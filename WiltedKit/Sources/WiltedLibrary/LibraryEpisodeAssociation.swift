import Foundation
import WiltedDomain

/// Optional, producer-owned logical state. It never proves that audio is cached.
public struct LibraryEpisodeAssociation: Codable, Sendable, Equatable {
    public enum ManualChoice: String, Codable, Sendable { case keep, skip }

    public let schemaVersion: Int
    public let groupID: UUID
    public let representativeID: ItemID
    public let memberIDs: [ItemID]
    public let associationVersion: Int
    public let isTerminal: Bool
    public let latestManualChoice: ManualChoice?
    public let manualDecidedAt: Date?
    public let hasConflictingManualChoices: Bool

    public init(
        schemaVersion: Int = 1, groupID: UUID, representativeID: ItemID, memberIDs: [ItemID],
        associationVersion: Int, isTerminal: Bool, latestManualChoice: ManualChoice? = nil,
        manualDecidedAt: Date? = nil, hasConflictingManualChoices: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.groupID = groupID
        self.representativeID = representativeID
        self.memberIDs = memberIDs
        self.associationVersion = associationVersion
        self.isTerminal = isTerminal
        self.latestManualChoice = latestManualChoice
        self.manualDecidedAt = manualDecidedAt
        self.hasConflictingManualChoices = hasConflictingManualChoices
    }

    /// Unknown or malformed metadata remains transportable but cannot collapse rows.
    public var isSupported: Bool {
        guard schemaVersion == 1, associationVersion > 0, memberIDs.count >= 2,
              memberIDs == memberIDs.sorted(by: { $0.rawValue < $1.rawValue }),
              Set(memberIDs).count == memberIDs.count, memberIDs.contains(representativeID),
              (latestManualChoice == nil) == (manualDecidedAt == nil) else { return false }
        if let date = manualDecidedAt, !date.timeIntervalSince1970.isFinite { return false }
        // A genuine completion after Keep can make the group terminal without
        // changing the latest manual-choice provenance.
        if latestManualChoice == .skip && !isTerminal { return false }
        return true
    }

    /// Only a complete same-feed podcast group authorizes a capable client's display fold.
    /// Missing, inconsistent, overlapping and unsupported groups fall back to raw rows.
    public static func coherentGroups(in entries: [LibraryEntry]) -> [LibraryEpisodeAssociation] {
        let byID = Dictionary(grouping: entries, by: \.id)
        let byGroup = Dictionary(grouping: entries.filter { $0.episodeAssociation != nil }) {
            $0.episodeAssociation!.groupID
        }
        return byGroup.values.compactMap { claims in
            guard let first = claims.first, let association = first.episodeAssociation,
                  association.isSupported, claims.count == association.memberIDs.count,
                  Set(claims.map(\.id)) == Set(association.memberIDs),
                  association.memberIDs.allSatisfy({ id in
                      guard let members = byID[id], members.count == 1, let member = members.first else { return false }
                      return member.kind == .podcastEpisode && member.sourceID == first.sourceID
                          && member.episodeAssociation == association
                  }) else { return nil }
            return association
        }.sorted { $0.groupID.uuidString < $1.groupID.uuidString }
    }

    public static func group(for entryID: ItemID, in entries: [LibraryEntry]) -> LibraryEpisodeAssociation? {
        coherentGroups(in: entries).first { $0.memberIDs.contains(entryID) }
    }
}
