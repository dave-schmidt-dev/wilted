import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// A new local choice follows the manual chronology this store has seen.
    public func freshLocalEpisodeDecisionTimestamp(_ ids: [ItemID], now: Date = Date()) throws -> Timestamp {
        try Timestamp(Self.freshLocalOwnerChoiceDate(ids, now: now, in: ModelContext(container)))
    }

    /// Deletes the revision, download, and artwork records naming the given
    /// episodes' media and returns the URLs they named. One fetch per record
    /// type; the caller commits with one save and only then hands the URLs to
    /// `deleteMediaIfUnreferenced`, so a failed save never deletes audio the
    /// surviving records still name. Dismissal calls it too; unsubscribe reads
    /// the same set through `mediaURLs`, because its staged cascade deletes
    /// these records in separate stages, so every removal reclaims the same
    /// set of files.
    static func deleteMediaRecords(
        forEpisodesWithIDs episodeIDs: Set<String>,
        in context: ModelContext
    ) throws -> [URL] {
        var doomedMedia: [URL] = []
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        where episodeIDs.contains(record.itemID) {
            if let value = record.mediaURL, let mediaURL = URL(string: value) { doomedMedia.append(mediaURL) }
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        where episodeIDs.contains(record.episodeID) {
            if let value = record.localURL, let mediaURL = URL(string: value) { doomedMedia.append(mediaURL) }
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where episodeIDs.contains(record.ownerID) {
            if let value = record.localURL, let mediaURL = URL(string: value) { doomedMedia.append(mediaURL) }
            context.delete(record)
        }
        return doomedMedia
    }

    static func stageRetirementManualDecision(
        _ id: ItemID, at: Timestamp, lookup: EpisodeAssociationReadLookup, in context: ModelContext
    ) {
        if let record = lookup.decisions[id.rawValue] {
            record.decision = EpisodeDecision.skip.rawValue; record.source = EpisodeDecisionSource.manual.rawValue
            record.ruleID = nil; record.decidedAt = at.date
        } else {
            context.insert(LocalLibrarySchemaV16Models.EpisodeDecisionRecord(episodeID: id.rawValue,
                decision: EpisodeDecision.skip.rawValue, source: EpisodeDecisionSource.manual.rawValue,
                ruleID: nil, decidedAt: at.date))
        }
    }

    /// Returns the named Feed-retired episodes to the feed in `context`
    /// without saving. Legacy restoration preserves listening history and
    /// writes a fresh manual Keep in this same context.
    /// Only a retired row changes: a missing or dismissed one is unresolved
    /// (dismissal is the stronger removal and keeps its own restore pathway),
    /// and one with no removal is already at target. `episodeIDs` must be
    /// unique; each list keeps their order.
    @discardableResult
    static func stageUnretirement(
        _ episodeIDs: [ItemID], at: Date = Date(), includesDismissed: Bool = false,
        asOwnerChoice: Bool = true, recordAlreadyAtTargetOwnerChoice: Bool = false,
        in context: ModelContext
    ) throws -> (committed: [ItemID], alreadyAtTarget: [ItemID], unresolved: [ItemID], manualCommitted: [ItemID]) {
        let lookup = try EpisodeAssociationReadLookup(in: context)
        let byID = lookup.episodes
        let decisionByID = lookup.decisions
        let receipts = try context.fetch(FetchDescriptor<LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord>())
        let now = at
        var committed: [ItemID] = []
        var manualCommitted: [ItemID] = []
        var unresolved: [ItemID] = []
        var alreadyAtTarget: [ItemID] = []
        var seen = Set<ItemID>()
        let expanded = episodeIDs.flatMap { lookup.state(for: $0)?.memberIDs ?? [$0] }
            .filter { seen.insert($0).inserted }
        var denied = Set<ItemID>()
        for id in episodeIDs where asOwnerChoice {
            let choice = EpisodeDecisionRecord(episodeID: id, decision: .keep, source: .manual, decidedAt: Timestamp(at))
            let applies = try shouldApplyEpisodeDecision(choice, in: context, lookup: lookup)
            try stageAssociationManualTie(choice, in: context, lookup: lookup)
            if !applies { denied.formUnion(lookup.state(for: id)?.memberIDs ?? [id]) }
        }
        for id in expanded {
            guard !denied.contains(id) else { unresolved.append(id); continue }
            if asOwnerChoice, let restored = try stageManualCompletionRestore(id, at: at, in: context,
                lookup: lookup, receiptCandidates: receipts) {
                if restored { committed.append(id); manualCommitted.append(id) } else { unresolved.append(id) }
                continue
            }
            guard let record = byID[id.rawValue] else { unresolved.append(id); continue }
            if record.removalKind == nil {
                alreadyAtTarget.append(id)
                if asOwnerChoice && recordAlreadyAtTargetOwnerChoice {
                    applyExplicitRestoreDecision(decisionByID[id.rawValue], for: id, at: now, in: context)
                    manualCommitted.append(id)
                }
                continue
            }
            let isAssociated = (lookup.state(for: id)?.memberIDs.count ?? 0) > 1
            guard includesDismissed || isAssociated || record.removalKind == PodcastEpisodeRemovalKind.retired.rawValue else { unresolved.append(id); continue }
            record.removalKind = nil; record.retiredAt = nil
            if asOwnerChoice {
                applyExplicitRestoreDecision(decisionByID[id.rawValue], for: id, at: now, in: context)
                manualCommitted.append(id)
            }
            committed.append(id)
        }
        return (committed, alreadyAtTarget, unresolved, manualCommitted)
    }
    private static func applyExplicitRestoreDecision(
        _ existing: LocalLibrarySchemaV16Models.EpisodeDecisionRecord?, for episodeID: ItemID,
        at: Date, in context: ModelContext
    ) {
        if let existing {
            existing.decision = EpisodeDecision.keep.rawValue
            existing.source = EpisodeDecisionSource.manual.rawValue
            existing.ruleID = nil
            existing.decidedAt = at
        } else {
            context.insert(LocalLibrarySchemaV16Models.EpisodeDecisionRecord(episodeID: episodeID.rawValue,
                decision: EpisodeDecision.keep.rawValue, source: EpisodeDecisionSource.manual.rawValue,
                ruleID: nil, decidedAt: at))
        }
    }

}
