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
        let states = try associationMemberStates(ids, feedID: confirmation.feedID)
        // Resolve both as a proposed group, before any association exists.
        let resolved = try Self.resolveLogicalState(
            ids: ids, representativeID: representativeID, in: context
        )
        return PodcastEpisodeAssociationPreview(
            confirmation: confirmation, representativeID: representativeID, resolvedState: resolved,
            approvalConsequences: Self.approvalConsequences(for: states, resolved: resolved),
            capturedMembers: try Self.associationEncoder().encode(states),
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
        let states = try associationMemberStates(association.memberIDs, feedID: association.feedID)
        return PodcastEpisodeAssociationReversalPreview(
            associationID: associationID, expectedVersion: expectedVersion,
            consequences: Self.reversalConsequences(associationID: associationID, for: states),
            capturedMembers: try Self.associationEncoder().encode(states),
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

    /// Side-effect-free comparison evidence for one explicitly named same-feed
    /// pair. It writes nothing, creates no confirmation, opens no media, and
    /// refuses same-ID, unavailable, or cross-feed pairs. Other metadata
    /// candidates and existing associations are reported as ambiguity for the
    /// owner to read; they never decide anything on their own.
    public func podcastEpisodeAssociationComparison(
        first firstID: ItemID, second secondID: ItemID
    ) throws -> PodcastEpisodeAssociationComparison {
        guard firstID != secondID else { throw PodcastEpisodeAssociationError.invalidPair }
        let snapshot = try podcastLibrarySnapshot(profile: .publication)
        guard let firstEpisode = snapshot.episodes.first(where: { $0.itemID == firstID }),
              let secondEpisode = snapshot.episodes.first(where: { $0.itemID == secondID }) else {
            throw PodcastEpisodeAssociationError.episodeUnavailable
        }
        guard firstEpisode.feedID == secondEpisode.feedID else {
            throw PodcastEpisodeAssociationError.crossFeed
        }
        let pairIDs: Set<ItemID> = [firstID, secondID]
        let existing = try episodeAssociations().filter { !Set($0.memberIDs).isDisjoint(with: pairIDs) }
        let sharesMetadata = Self.comparisonMetadataMatches(firstEpisode, secondEpisode)
        let otherCandidates = snapshot.episodes
            .filter { candidate in
                candidate.feedID == firstEpisode.feedID && !pairIDs.contains(candidate.itemID)
                    && (Self.comparisonMetadataMatches(candidate, firstEpisode)
                        || Self.comparisonMetadataMatches(candidate, secondEpisode))
            }
            .map(\.itemID)
            .sorted { $0.rawValue < $1.rawValue }
        let pairGUIDs = Set([firstEpisode.rssGUID, secondEpisode.rssGUID].compactMap { $0 })
        let crossFeedCandidates = pairGUIDs.isEmpty ? [] : snapshot.episodes
            .filter { candidate in
                candidate.feedID != firstEpisode.feedID && !pairIDs.contains(candidate.itemID)
                    && candidate.rssGUID.map { pairGUIDs.contains($0) } == true
            }
            .map(\.itemID)
            .sorted { $0.rawValue < $1.rawValue }
        let lookup = try EpisodeAssociationReadLookup(in: ModelContext(container))
        let resolved = lookup.resolve(
            ids: [firstID, secondID].sorted { $0.rawValue < $1.rawValue }, representativeID: firstID
        )
        var ambiguities: [PodcastEpisodeAssociationComparison.Ambiguity] = []
        if !sharesMetadata { ambiguities.append(.metadataDiffers) }
        if !otherCandidates.isEmpty { ambiguities.append(.otherMetadataCandidates) }
        if !crossFeedCandidates.isEmpty { ambiguities.append(.crossFeedGUIDCandidate) }
        if !existing.isEmpty { ambiguities.append(.existingAssociation) }
        if resolved.hasConflictingManualChoices { ambiguities.append(.conflictingManualChoices) }
        return PodcastEpisodeAssociationComparison(
            feedID: firstEpisode.feedID,
            first: Self.comparisonMember(for: firstEpisode, in: snapshot),
            second: Self.comparisonMember(for: secondEpisode, in: snapshot),
            sharesMetadata: sharesMetadata,
            otherCandidateIDs: otherCandidates,
            crossFeedSameGUIDCandidateIDs: crossFeedCandidates,
            existingAssociationIDs: existing.map(\.associationID).sorted { $0.uuidString < $1.uuidString },
            ambiguities: ambiguities,
            resolvedState: resolved
        )
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
        try Self.associationEncoder().encode(try associationMemberStates(ids, feedID: feedID))
    }

    private func associationMemberStates(_ ids: [ItemID], feedID: ItemID) throws -> [AssociationMemberState] {
        let snapshot = try podcastLibrarySnapshot(profile: .publication)
        return try ids.map { id -> AssociationMemberState in
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
    }

    /// The pair matches only when title, publication date and duration all
    /// agree -- the audit's own discovery rule. Similar metadata is a hint for
    /// the owner, never proof of identity.
    static func comparisonMetadataMatches(_ left: PodcastEpisode, _ right: PodcastEpisode) -> Bool {
        left.title == right.title
            && left.publishedTime != nil && left.publishedTime == right.publishedTime
            && left.durationSeconds != nil && left.durationSeconds == right.durationSeconds
    }

    static func comparisonMember(
        for episode: PodcastEpisode, in snapshot: PodcastLibrarySnapshot
    ) -> PodcastEpisodeAssociationComparisonMember {
        let download = snapshot.downloads[episode.itemID]
        let revision = snapshot.readyRevisions[episode.itemID]
        let decision = snapshot.episodeDecisions[episode.itemID]
        let playback = snapshot.playbackStates.values
            .filter { $0.itemID == episode.itemID }
            .max { $0.updatedAt < $1.updatedAt }
        return PodcastEpisodeAssociationComparisonMember(
            episodeID: episode.itemID,
            feedID: episode.feedID,
            rssGUID: episode.rssGUID,
            title: episode.title,
            publishedAt: episode.publishedTime,
            durationSeconds: episode.durationSeconds,
            originalMediaContentHash: download?.status == .completed ? download?.contentHash : nil,
            preparedRevisionID: revision?.revisionID,
            playbackPositionSeconds: playback?.positionSeconds,
            playbackCompleted: playback?.completed ?? false,
            listeningCompletedAt: snapshot.listeningStates[episode.itemID]?.completedAt,
            decision: decision?.decision,
            decisionSource: decision?.source,
            decidedAt: decision?.decidedAt,
            queuePosition: snapshot.podcastQueue.episodeIDs.firstIndex(of: episode.itemID),
            isQueueCurrent: snapshot.podcastQueue.currentEpisodeID == episode.itemID,
            isRemoved: snapshot.removalKindByEpisode[episode.itemID] != nil
        )
    }

    static func approvalConsequences(
        for members: [AssociationMemberState], resolved: PodcastEpisodeLogicalState
    ) -> PodcastEpisodeAssociationApprovalConsequences {
        // The same guard `claimPodcastDownload(scope: .untouched)` applies to a
        // terminal group: a multi-member terminal group refuses the claim.
        let isDownloadEligible = members.count <= 1 || !resolved.isTerminal
        let values = members.map { member in
            let hasDownload = member.download != nil
            return PodcastEpisodeAssociationApprovalConsequences.Member(
                episodeID: member.episode.itemID,
                retainsRawRow: member.removal == nil,
                hasDownloadRecord: hasDownload,
                canClaimDownload: isDownloadEligible && !hasDownload,
                queuePosition: member.queuePosition,
                isQueueCurrent: member.isCurrent
            )
        }
        // The Larder's own projection: retained raw rows fold into one row at
        // the representative, and a terminal group is hidden whole. A member's
        // raw removal alone does not hide an active group row.
        let hasRetainedMember = members.contains { $0.removal == nil }
        return PodcastEpisodeAssociationApprovalConsequences(
            representativeID: resolved.representativeID,
            memberIDs: resolved.memberIDs,
            members: values,
            winningDecision: resolved.manualDecision,
            manualDecidedAt: resolved.manualDecidedAt,
            hasConflictingManualChoices: resolved.hasConflictingManualChoices,
            isTerminal: resolved.isTerminal,
            isLarderRowVisible: !resolved.isTerminal && hasRetainedMember,
            isAdmissionEligible: !resolved.isTerminal,
            isDownloadEligible: isDownloadEligible,
            hasQueueSlot: values.contains { $0.queuePosition != nil }
        )
    }

    static func reversalConsequences(
        associationID: UUID, for members: [AssociationMemberState]
    ) -> PodcastEpisodeAssociationReversalConsequences {
        let manual = members.compactMap { member -> EpisodeDecisionRecord? in
            guard let decision = member.decision, decision.source == .manual else { return nil }
            return decision
        }
        let latest = manual.map(\.decidedAt).max()
        let newest = manual.filter { $0.decidedAt == latest }
        let keep = newest.contains { $0.decision == .keep }
        let skip = newest.contains { $0.decision == .skip }
        let resolved: EpisodeDecision? = keep ? .keep : (skip ? .skip : nil)
        let values = members.map { member in
            let own = member.decision.flatMap { record -> EpisodeDecision? in
                guard record.source == .manual else { return nil }
                return record.decision
            }
            let hasOwn = own != nil
            return PodcastEpisodeAssociationReversalConsequences.Member(
                episodeID: member.episode.itemID,
                ownManualDecision: own,
                resolvedManualDecision: resolved,
                losesNewerResolvedOverride: hasOwn && resolved != nil && resolved != own,
                losesInheritedProtection: !hasOwn && resolved == .keep,
                losesInheritedSuppression: !hasOwn && resolved == .skip,
                hasDownloadRecord: member.download != nil,
                isRemoved: member.removal != nil
            )
        }
        return PodcastEpisodeAssociationReversalConsequences(
            associationID: associationID,
            memberIDs: members.map { $0.episode.itemID },
            members: values,
            warnsAutomationMayRetire: values.contains { $0.losesInheritedProtection }
        )
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
