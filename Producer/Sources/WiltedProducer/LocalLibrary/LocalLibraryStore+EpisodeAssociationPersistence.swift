import Foundation
import WiltedDomain

extension LocalLibraryStore {
    static func validateAssociationPair(
        _ confirmation: PodcastEpisodePairConfirmation, representativeID: ItemID
    ) throws -> [ItemID] {
        guard confirmation.first != confirmation.second,
              representativeID == confirmation.first || representativeID == confirmation.second else {
            throw PodcastEpisodeAssociationError.invalidPair
        }
        return [confirmation.first, confirmation.second].sorted { $0.rawValue < $1.rawValue }
    }

    static func refuseAssociationOverlap(
        _ ids: [ItemID], confirmationID: UUID,
        records: [LocalLibrarySchemaV20Models.EpisodeAssociationRecord]
    ) throws {
        for record in records {
            guard let evidence = try? decodeEpisodeAssociationEvidence(record.evidence) else {
                EpisodeAssociationReadLookup.reportInvalid(record.associationID)
                if !record.isActive, record.reversedAt == nil { continue }
                throw PodcastEpisodeAssociationError.corruptAssociation
            }
            if evidence.isPossibleDuplicateFlag { continue }
            guard let association = try? decodeAssociation(record) else {
                EpisodeAssociationReadLookup.reportInvalid(record.associationID)
                throw PodcastEpisodeAssociationError.corruptAssociation
            }
            guard association.confirmation.confirmationID != confirmationID else {
                throw PodcastEpisodeAssociationError.confirmationAlreadyUsed
            }
            if association.isActive, !Set(association.memberIDs).isDisjoint(with: ids) {
                throw PodcastEpisodeAssociationError.overlappingAssociation
            }
        }
    }

    static func associationEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func encodeAssociationState(
        _ records: [LocalLibrarySchemaV20Models.EpisodeAssociationRecord]
    ) throws -> Data {
        try associationEncoder().encode(records.map(AssociationStoredState.init)
            .sorted { $0.associationID.uuidString < $1.associationID.uuidString })
    }

    static func decodeEpisodeAssociationEvidence(_ data: Data) throws -> EpisodeAssociationEvidence {
        try EpisodeAssociationEvidence.decode(data)
    }

    static func decodeAssociation(_ record: LocalLibrarySchemaV20Models.EpisodeAssociationRecord) throws -> PodcastEpisodeAssociation {
        let members = try JSONDecoder().decode([ItemID].self, from: record.members)
        let evidence = try decodeEpisodeAssociationEvidence(record.evidence)
        guard let feedID = try? ItemID(rawValue: record.feedID),
              let representative = try? ItemID(rawValue: record.representativeID), record.version > 0,
              isSortedUniqueMemberList(members, representativeID: representative) else {
            throw PodcastEpisodeAssociationError.corruptAssociation
        }
        guard case .ownerConfirmed(let confirmation) = evidence,
              feedID == confirmation.feedID,
              members == (try validateAssociationPair(confirmation, representativeID: representative)) else {
            throw PodcastEpisodeAssociationError.corruptAssociation
        }
        return PodcastEpisodeAssociation(
            associationID: record.associationID, feedID: feedID, representativeID: representative,
            memberIDs: members, confirmation: confirmation, version: record.version,
            isActive: record.isActive, createdAt: Timestamp(record.createdAt),
            reversedAt: record.reversedAt.map(Timestamp.init)
        )
    }

    private static func isSortedUniqueMemberList(_ members: [ItemID], representativeID: ItemID) -> Bool {
        members.count >= 2 && Set(members).count == members.count
            && members == members.sorted { $0.rawValue < $1.rawValue }
            && members.contains(representativeID)
    }
}
