import Foundation
import SwiftData
import WiltedDomain

private typealias EpisodeIdentityRecord = LocalLibrarySchemaV20Models.EpisodeAssociationRecord

extension LocalLibraryStore {
    /// Lists unresolved feed identity candidates, without treating them as
    /// active or reversed episode associations.
    public func pendingPodcastEpisodeIdentityReviews(
        in feedID: ItemID? = nil
    ) throws -> [PodcastEpisodePossibleDuplicateEvidence] {
        try Self.pendingPossibleDuplicateEvidence(in: ModelContext(container), feedID: feedID)
            .sorted { $0.incomingID.rawValue < $1.incomingID.rawValue }
    }

    /// Every readable possible-duplicate flag, for showing the badge. One flag
    /// that cannot be read is left out so it never hides the others; its episode
    /// stays held, because the hold list below goes by the row alone.
    public func readablePodcastPossibleDuplicateFlags() throws -> [PodcastEpisodePossibleDuplicateEvidence] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<EpisodeIdentityRecord>())
            .filter { !$0.isActive && $0.reversedAt == nil }
            .compactMap { record -> PodcastEpisodePossibleDuplicateEvidence? in
                guard let evidence = try? Self.decodeEpisodeAssociationEvidence(record.evidence),
                      case let .pendingPossibleDuplicate(flag) = evidence,
                      flag.incomingID.rawValue == record.representativeID else { return nil }
                return flag
            }
            .sorted { $0.incomingID.rawValue < $1.incomingID.rawValue }
    }

    /// The episode IDs whose automatic feed work is held pending owner review.
    public func podcastEpisodeIdentityReviewHeldIDs(
        in feedID: ItemID? = nil
    ) throws -> Set<ItemID> {
        Set(try Self.pendingPossibleDuplicateHeldIDs(in: ModelContext(container), feedID: feedID)
            .compactMap { try? ItemID(rawValue: $0) })
    }

    /// The owner's answer "this is a different episode": the flag is removed
    /// and nothing else changes. The episode keeps its row, state and audio, and
    /// is no longer kept out of automatic download and preparation. It is never
    /// compared again, because only an ID not yet stored is checked on a refresh.
    @discardableResult
    public func clearPodcastEpisodePossibleDuplicate(_ episodeID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let id = episodeID.rawValue
        let flags = try context.fetch(FetchDescriptor<EpisodeIdentityRecord>(
            predicate: #Predicate { $0.representativeID == id && !$0.isActive && $0.reversedAt == nil }
        ))
        guard !flags.isEmpty else { return false }
        flags.forEach(context.delete)
        try context.save()
        return true
    }

    /// Stages one durable possible-duplicate flag in the caller's transaction.
    /// The fixed ID makes repeated refreshes update the same pending evidence.
    static func stagePossibleDuplicateHold(
        incoming: PodcastEpisode,
        candidateIDs: [ItemID],
        reasons: Set<PodcastEpisodeIdentityMatcher.AmbiguityReason>,
        at timestamp: Timestamp,
        in context: ModelContext
    ) throws {
        let candidates = Array(Set(candidateIDs).subtracting([incoming.itemID]))
            .sorted { $0.rawValue < $1.rawValue }

        let records = try context.fetch(FetchDescriptor<EpisodeIdentityRecord>())
        let prior = records.first {
            !$0.isActive && $0.reversedAt == nil
                && $0.feedID == incoming.feedID.rawValue
                && $0.representativeID == incoming.itemID.rawValue
        }
        if let prior, !Self.isPendingPossibleDuplicate(prior) {
            throw PodcastEpisodeAssociationError.corruptAssociation
        }
        guard !candidates.isEmpty else {
            if let prior { context.delete(prior) }
            return
        }

        let reasons = reasons.map { reason -> PodcastEpisodePossibleDuplicateEvidence.Reason in
            switch reason {
            case .multipleMatches: .multipleMatches
            }
        }.sorted { $0.rawValue < $1.rawValue }
        let members = ([incoming.itemID] + candidates).sorted { $0.rawValue < $1.rawValue }
        let encoder = Self.evidenceEncoder()
        let createdAt = prior?.createdAt ?? timestamp.date
        let evidence = PodcastEpisodePossibleDuplicateEvidence(
            feedID: incoming.feedID, incomingID: incoming.itemID,
            candidateIDs: candidates, reasons: reasons, createdAt: Timestamp(createdAt)
        )
        let evidenceData = try encoder.encode(
            EpisodeAssociationEvidence.pendingPossibleDuplicate(evidence)
        )
        let memberData = try encoder.encode(members)

        if let prior {
            guard !prior.isActive, prior.reversedAt == nil,
                  case .pendingPossibleDuplicate = try Self.decodeEpisodeAssociationEvidence(prior.evidence) else {
                throw PodcastEpisodeAssociationError.corruptAssociation
            }
            guard prior.feedID == incoming.feedID.rawValue,
                  prior.members != memberData || prior.evidence != evidenceData else { return }
            prior.members = memberData
            prior.evidence = evidenceData
        } else {
            let record = EpisodeIdentityRecord(
                associationID: UUID(), feedID: incoming.feedID.rawValue,
                representativeID: incoming.itemID.rawValue,
                members: memberData, evidence: evidenceData, createdAt: timestamp.date,
                capturedMemberState: Data()
            )
            record.isActive = false
            record.reversedAt = nil
            context.insert(record)
        }
    }

    /// A quick same-context lookup used by admission and download claim gates.
    static func hasPendingPossibleDuplicateHold(
        for episodeID: ItemID, in context: ModelContext
    ) throws -> Bool {
        let id = episodeID.rawValue
        var pending = FetchDescriptor<EpisodeIdentityRecord>(
            predicate: #Predicate { $0.representativeID == id && !$0.isActive && $0.reversedAt == nil }
        )
        pending.fetchLimit = 1
        return try !context.fetch(pending).isEmpty
    }

    static func pendingPossibleDuplicateHeldIDs(
        in context: ModelContext, feedID: ItemID? = nil
    ) throws -> Set<String> {
        let rawFeedID = feedID?.rawValue
        return Set(try context.fetch(FetchDescriptor<EpisodeIdentityRecord>())
            .filter {
                !$0.isActive && $0.reversedAt == nil
                    && (rawFeedID == nil || $0.feedID == rawFeedID)
            }
            .map(\.representativeID))
    }

    static func pendingPossibleDuplicateEvidence(
        in context: ModelContext, feedID: ItemID? = nil
    ) throws -> [PodcastEpisodePossibleDuplicateEvidence] {
        let rawFeedID = feedID?.rawValue
        return try context.fetch(FetchDescriptor<EpisodeIdentityRecord>())
            .filter {
                !$0.isActive && $0.reversedAt == nil
                    && (rawFeedID == nil || $0.feedID == rawFeedID)
            }
            .map { record in
                let memberIDs = try JSONDecoder().decode([ItemID].self, from: record.members)
                guard case let .pendingPossibleDuplicate(evidence) =
                        try decodeEpisodeAssociationEvidence(record.evidence),
                      evidence.feedID.rawValue == record.feedID,
                      evidence.incomingID.rawValue == record.representativeID,
                      Set(memberIDs) == Set([evidence.incomingID] + evidence.candidateIDs) else {
                    throw PodcastEpisodeAssociationError.corruptAssociation
                }
                return evidence
            }
    }

    private static func evidenceEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func isPendingPossibleDuplicate(_ record: EpisodeIdentityRecord) -> Bool {
        guard let evidence = try? Self.decodeEpisodeAssociationEvidence(record.evidence),
              case .pendingPossibleDuplicate = evidence else { return false }
        return true
    }
}
