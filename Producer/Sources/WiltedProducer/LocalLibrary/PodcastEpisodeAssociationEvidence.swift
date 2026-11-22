import Foundation
import WiltedDomain

/// The two source IDs in a feed that the owner explicitly confirmed as one episode.
public struct PodcastEpisodePairConfirmation: Codable, Equatable, Sendable {
    public let confirmationID: UUID
    public let feedID: ItemID
    public let first: ItemID
    public let second: ItemID
    public let confirmedAt: Timestamp

    public init(confirmationID: UUID, feedID: ItemID, first: ItemID, second: ItemID,
                confirmedAt: Timestamp) {
        self.confirmationID = confirmationID
        self.feedID = feedID
        self.first = first
        self.second = second
        self.confirmedAt = confirmedAt
    }
}

public enum PodcastEpisodeAssociationError: Error, Equatable, Sendable {
    case invalidPair
    case crossFeed
    case episodeUnavailable
    case overlappingAssociation
    case stalePreview
    case staleVersion
    case conflictingOwnerState
    case confirmationAlreadyUsed
    case corruptAssociation
}

public struct PodcastEpisodePossibleDuplicateEvidence: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Equatable, Sendable {
        case multipleMatches
        case durationConflict
    }

    public let feedID: ItemID
    public let incomingID: ItemID
    public let candidateIDs: [ItemID]
    public let reasons: [Reason]
    public let createdAt: Timestamp

    public init(feedID: ItemID, incomingID: ItemID, candidateIDs: [ItemID], reasons: [Reason], createdAt: Timestamp) {
        self.feedID = feedID
        self.incomingID = incomingID
        self.candidateIDs = candidateIDs
        self.reasons = reasons
        self.createdAt = createdAt
    }
}

/// The evidence data column stores owner associations and the possible-duplicate
/// flags feed ingest raises, without changing the SwiftData schema. Older owner
/// records stored the confirmation directly and remain readable.
enum EpisodeAssociationEvidence: Codable, Equatable, Sendable {
    case ownerConfirmed(PodcastEpisodePairConfirmation)
    case pendingPossibleDuplicate(PodcastEpisodePossibleDuplicateEvidence)

    var isPossibleDuplicateFlag: Bool {
        if case .pendingPossibleDuplicate = self { true } else { false }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case ownerConfirmation
        case pendingPossibleDuplicate
    }

    private enum Kind: String, Codable {
        case ownerConfirmed
        case pendingPossibleDuplicate
    }

    static func decode(_ data: Data) throws -> EpisodeAssociationEvidence {
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode(PodcastEpisodePairConfirmation.self, from: data) {
            return .ownerConfirmed(legacy)
        }
        return try decoder.decode(EpisodeAssociationEvidence.self, from: data)
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ownerConfirmed(let confirmation):
            try container.encode(Kind.ownerConfirmed, forKey: .kind)
            try container.encode(confirmation, forKey: .ownerConfirmation)
        case .pendingPossibleDuplicate(let evidence):
            try container.encode(Kind.pendingPossibleDuplicate, forKey: .kind)
            try container.encode(evidence, forKey: .pendingPossibleDuplicate)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ownerConfirmed:
            self = .ownerConfirmed(try container.decode(PodcastEpisodePairConfirmation.self, forKey: .ownerConfirmation))
        case .pendingPossibleDuplicate:
            self = .pendingPossibleDuplicate(try container.decode(PodcastEpisodePossibleDuplicateEvidence.self, forKey: .pendingPossibleDuplicate))
        }
    }
}
