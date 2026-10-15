import Foundation
import SwiftData
import WiltedDomain

private typealias AssociationRecord = LocalLibrarySchemaV20Models.EpisodeAssociationRecord
private typealias AliasEpisodeRecord = LocalLibrarySchemaV13Models.PodcastEpisodeRecord
private typealias AliasDecisionRecord = LocalLibrarySchemaV16Models.EpisodeDecisionRecord

/// Typed state, including immutable source generation, guards both application
/// and reversal. No media files are opened and no backing row is modified.
struct AssociationMemberState: Codable {
    let episode: PodcastEpisode
    let decision: EpisodeDecisionRecord?
    let listening: PodcastListeningState?
    let removal: PodcastEpisodeRemovalKind?
    let removedAt: Timestamp?
    let playback: [PlaybackState]
    let download: PodcastDownload?
    let revision: StoredAudioRevision?
    let queuePosition: Int?
    let isCurrent: Bool
}

extension LocalLibraryStore {
    /// Builds an exact preview from an explicitly confirmed owner pair. Shared
    /// URLs, dates, titles, durations and hashes are not accepted as proof.
    public func previewEpisodeAssociation(
        confirming confirmation: PodcastEpisodePairConfirmation,
        representativeID: ItemID
    ) throws -> PodcastEpisodeAssociationPreview {
        let context = ModelContext(container)
        let ids = try Self.validateAssociationPair(confirmation, representativeID: representativeID)
        let records = try context.fetch(FetchDescriptor<AssociationRecord>())
        try Self.refuseAssociationOverlap(ids, confirmationID: confirmation.confirmationID, records: records)
        let members = try captureAssociationMembers(ids, feedID: confirmation.feedID)
        // Resolve both as a proposed group, before any association exists.
        let resolved = try Self.resolveLogicalState(
            ids: ids, representativeID: representativeID, in: context
        )
        return PodcastEpisodeAssociationPreview(
            confirmation: confirmation, representativeID: representativeID, resolvedState: resolved,
            capturedMembers: members,
            capturedAssociations: try Self.encodeAssociationState(records)
        )
    }

    /// Applies only an unchanged store-produced preview. The sole save inserts
    /// association history; raw identities, lifecycle, queue and media survive.
    @discardableResult
    public func applyEpisodeAssociation(
        _ preview: PodcastEpisodeAssociationPreview, at: Timestamp = Timestamp(Date())
    ) throws -> PodcastEpisodeAssociation {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let ids = try Self.validateAssociationPair(preview.confirmation, representativeID: preview.representativeID)
        let records = try context.fetch(FetchDescriptor<AssociationRecord>())
        guard try Self.encodeAssociationState(records) == preview.capturedAssociations,
              try captureAssociationMembers(ids, feedID: preview.confirmation.feedID) == preview.capturedMembers else {
            throw PodcastEpisodeAssociationError.stalePreview
        }
        try Self.refuseAssociationOverlap(ids, confirmationID: preview.confirmation.confirmationID, records: records)
        let record = AssociationRecord(
            associationID: UUID(), feedID: preview.confirmation.feedID.rawValue,
            representativeID: preview.representativeID.rawValue,
            members: try Self.associationEncoder().encode(ids),
            evidence: try Self.associationEncoder().encode(preview.confirmation), createdAt: at.date,
            capturedMemberState: preview.capturedMembers
        )
        context.insert(record)
        try context.save()
        return try Self.decodeAssociation(record)
    }

    /// Captures current state for a reviewed reversal, even after playback or
    /// owner decisions changed. Reversal never restores captured raw values.
    public func previewEpisodeAssociationReversal(
        _ associationID: UUID, expectedVersion: Int
    ) throws -> PodcastEpisodeAssociationReversalPreview {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<AssociationRecord>())
        guard let record = records.first(where: { $0.associationID == associationID }),
              record.isActive, record.version == expectedVersion else {
            throw PodcastEpisodeAssociationError.staleVersion
        }
        let association = try Self.decodeAssociation(record)
        return PodcastEpisodeAssociationReversalPreview(
            associationID: associationID, expectedVersion: expectedVersion,
            capturedMembers: try captureAssociationMembers(association.memberIDs, feedID: association.feedID),
            capturedAssociations: try Self.encodeAssociationState(records)
        )
    }

    /// A stale reversal preview refuses. A fresh preview can reverse while
    /// preserving every new listening, decision, queue and media value.
    @discardableResult
    public func reverseEpisodeAssociation(
        _ preview: PodcastEpisodeAssociationReversalPreview, at: Timestamp = Timestamp(Date())
    ) throws -> PodcastEpisodeAssociation {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let records = try context.fetch(FetchDescriptor<AssociationRecord>())
        guard let record = records.first(where: {
            $0.associationID == preview.associationID
        }), record.isActive, record.version == preview.expectedVersion else {
            throw PodcastEpisodeAssociationError.staleVersion
        }
        let association = try Self.decodeAssociation(record)
        guard try Self.encodeAssociationState(records) == preview.capturedAssociations,
              try captureAssociationMembers(association.memberIDs, feedID: association.feedID) == preview.capturedMembers else {
            throw PodcastEpisodeAssociationError.conflictingOwnerState
        }
        record.isActive = false
        record.version += 1
        record.reversedAt = at.date
        try context.save()
        return try Self.decodeAssociation(record)
    }

    public func episodeAssociations(includingReversed: Bool = false) throws -> [PodcastEpisodeAssociation] {
        let context = ModelContext(container)
        let lookup = try EpisodeAssociationReadLookup(in: context)
        guard includingReversed else { return lookup.associations }
        let reversed = try context.fetch(FetchDescriptor<AssociationRecord>()).filter { !$0.isActive }
            .compactMap { record -> PodcastEpisodeAssociation? in
                do { return try Self.decodeAssociation(record) }
                catch { EpisodeAssociationReadLookup.reportInvalid(record.associationID); return nil }
            }
        return (lookup.associations + reversed).sorted { $0.associationID.uuidString < $1.associationID.uuidString }
    }

    public func podcastEpisodeLogicalState(for episodeID: ItemID) throws -> PodcastEpisodeLogicalState? {
        try Self.logicalEpisodeState(for: episodeID, in: ModelContext(container))
    }

    /// Shared admission guard, with one lookup for all active groups.
    static func terminalAssociatedEpisodeIDs(in context: ModelContext) throws -> Set<String> {
        let lookup = try EpisodeAssociationReadLookup(in: context)
        return Set(lookup.associations.flatMap { association in
            lookup.state(for: association.representativeID)?.isTerminal == true
                ? association.memberIDs.map(\.rawValue) : []
        })
    }

    static func associationHasManualChoice(for episodeID: ItemID, in context: ModelContext) throws -> Bool {
        let state = try EpisodeAssociationReadLookup(in: context).state(for: episodeID)
        return (state?.memberIDs.count ?? 0) > 1 && state?.manualDecision != nil
    }

    static func shouldApplyEpisodeDecision(
        _ value: EpisodeDecisionRecord, in context: ModelContext,
        lookup: EpisodeAssociationReadLookup? = nil
    ) throws -> Bool {
        let lookup = try lookup ?? EpisodeAssociationReadLookup(in: context)
        let state = lookup.state(for: value.episodeID)
        if value.source != .manual, (state?.memberIDs.count ?? 0) > 1, state?.isTerminal == true { return false }
        if let latest = state?.manualDecidedAt {
            guard value.source == .manual else { return false }
            if value.decidedAt.date < latest.date { return false }
            if value.decidedAt == latest, value.decision == .skip, state?.manualDecision == .keep { return false }
        }
        // A decision may precede admission of its raw episode row.
        if let existing = lookup.decisions[value.episodeID.rawValue],
           existing.source == EpisodeDecisionSource.manual.rawValue {
            guard value.source == .manual else { return false }
            if value.decidedAt.date < existing.decidedAt { return false }
            if value.decidedAt.date == existing.decidedAt,
               value.decision == .skip, existing.decision == EpisodeDecision.keep.rawValue { return false }
        }
        return true
    }

    static func stageAssociationManualTie(
        _ value: EpisodeDecisionRecord, in context: ModelContext,
        lookup: EpisodeAssociationReadLookup? = nil
    ) throws {
        guard value.source == .manual else { return }
        let lookup = try lookup ?? EpisodeAssociationReadLookup(in: context)
        guard let record = lookup.record(for: value.episodeID),
              let state = lookup.state(for: value.episodeID),
              state.memberIDs.contains(where: { id in
                  guard let decision = lookup.decisions[id.rawValue] else { return false }
                  return decision.source == EpisodeDecisionSource.manual.rawValue
                      && decision.decidedAt == value.decidedAt.date && decision.decision != value.decision.rawValue
              }) else { return }
        var dates = try JSONDecoder().decode([Date].self, from: record.manualChoiceConflicts)
        guard !dates.contains(value.decidedAt.date) else { return }
        dates.append(value.decidedAt.date)
        record.manualChoiceConflicts = try associationEncoder().encode(dates.sorted())
        record.version += 1
    }

    static func logicalEpisodeState(for episodeID: ItemID, in context: ModelContext) throws -> PodcastEpisodeLogicalState? {
        try EpisodeAssociationReadLookup(in: context).state(for: episodeID)
    }

    private static func resolveLogicalState(
        ids: [ItemID], representativeID: ItemID, in context: ModelContext
    ) throws -> PodcastEpisodeLogicalState {
        try EpisodeAssociationReadLookup(in: context).resolve(ids: ids, representativeID: representativeID)
    }

    private func captureAssociationMembers(_ ids: [ItemID], feedID: ItemID) throws -> Data {
        let snapshot = try podcastLibrarySnapshot(profile: .publication)
        let members = try ids.map { id -> AssociationMemberState in
            guard let episode = snapshot.episodes.first(where: { $0.itemID == id }) else {
                throw PodcastEpisodeAssociationError.episodeUnavailable
            }
            guard episode.feedID == feedID else { throw PodcastEpisodeAssociationError.crossFeed }
            return AssociationMemberState(
                episode: episode, decision: snapshot.episodeDecisions[id], listening: snapshot.listeningStates[id],
                removal: snapshot.removalKindByEpisode[id], removedAt: snapshot.retiredAtByEpisode[id],
                playback: snapshot.playbackStates.values.filter { $0.itemID == id }
                    .sorted { $0.revisionID.rawValue < $1.revisionID.rawValue },
                download: snapshot.downloads[id], revision: snapshot.readyRevisions[id],
                queuePosition: snapshot.podcastQueue.episodeIDs.firstIndex(of: id),
                isCurrent: snapshot.podcastQueue.currentEpisodeID == id
            )
        }
        return try Self.associationEncoder().encode(members)
    }

    private static func validateAssociationPair(
        _ confirmation: PodcastEpisodePairConfirmation, representativeID: ItemID
    ) throws -> [ItemID] {
        guard confirmation.first != confirmation.second,
              representativeID == confirmation.first || representativeID == confirmation.second else {
            throw PodcastEpisodeAssociationError.invalidPair
        }
        return [confirmation.first, confirmation.second].sorted { $0.rawValue < $1.rawValue }
    }

    private static func refuseAssociationOverlap(
        _ ids: [ItemID], confirmationID: UUID, records: [AssociationRecord]
    ) throws {
        for record in records {
            let association = try decodeAssociation(record)
            guard association.confirmation.confirmationID != confirmationID else {
                throw PodcastEpisodeAssociationError.confirmationAlreadyUsed
            }
            if association.isActive, !Set(association.memberIDs).isDisjoint(with: ids) {
                throw PodcastEpisodeAssociationError.overlappingAssociation
            }
        }
    }

    private static func associationEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func encodeAssociationState(_ records: [AssociationRecord]) throws -> Data {
        try associationEncoder().encode(records.map(decodeAssociation)
            .sorted { $0.associationID.uuidString < $1.associationID.uuidString })
    }

    static func decodeAssociation(_ record: LocalLibrarySchemaV20Models.EpisodeAssociationRecord) throws -> PodcastEpisodeAssociation {
        let members = try JSONDecoder().decode([ItemID].self, from: record.members)
        let confirmation = try JSONDecoder().decode(PodcastEpisodePairConfirmation.self, from: record.evidence)
        guard let feedID = try? ItemID(rawValue: record.feedID),
              let representative = try? ItemID(rawValue: record.representativeID), record.version > 0,
              feedID == confirmation.feedID,
              members == (try validateAssociationPair(confirmation, representativeID: representative)) else {
            throw PodcastEpisodeAssociationError.corruptAssociation
        }
        return PodcastEpisodeAssociation(
            associationID: record.associationID, feedID: feedID, representativeID: representative,
            memberIDs: members, confirmation: confirmation, version: record.version, isActive: record.isActive,
            createdAt: Timestamp(record.createdAt), reversedAt: record.reversedAt.map(Timestamp.init)
        )
    }
}
