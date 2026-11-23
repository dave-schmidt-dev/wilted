import Foundation
import SwiftData
import WiltedDomain

/// What one soft Skip needs to be taken back or closed out later: the moment it happened and each
/// member's decision as it stood just before. Codable so the app can keep it across a quit and close
/// the Skip at the next launch.
public struct SoftSkipRecord: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let episodeID: ItemID
        /// `nil` means the member had no decision before the Skip.
        public let prior: EpisodeDecisionRecord?
        public init(episodeID: ItemID, prior: EpisodeDecisionRecord?) {
            self.episodeID = episodeID; self.prior = prior
        }
    }

    public let retiredAt: Timestamp
    /// Every member this Skip newly retired: the ones whose media closing the Skip deletes.
    public let retiredIDs: [ItemID]
    /// Every member whose decision the Skip wrote, with what it held before: Undo's undo list.
    public let entries: [Entry]

    public init(retiredAt: Timestamp, retiredIDs: [ItemID], entries: [Entry]) {
        self.retiredAt = retiredAt; self.retiredIDs = retiredIDs; self.entries = entries
    }

    /// Builds the record from a Skip's result. A member whose earlier decision could not be read has
    /// no entry, so Undo leaves it skipped, while closing the Skip still reclaims its media.
    public init(retiredAt: Timestamp, committed: [ItemID], alreadyAtTarget: [ItemID],
                prior: [ItemID: EpisodeDecisionRecord?]) {
        self.init(retiredAt: retiredAt, retiredIDs: committed, entries: (committed + alreadyAtTarget).compactMap { id in
            prior.index(forKey: id).map { Entry(episodeID: id, prior: prior[$0].value) }
        })
    }

    public var priorDecisions: [ItemID: EpisodeDecisionRecord?] {
        var result: [ItemID: EpisodeDecisionRecord?] = [:]
        for entry in entries { result.updateValue(entry.prior, forKey: entry.episodeID) }
        return result
    }

    public var entryIDs: [ItemID] { entries.map(\.episodeID) }

    /// The same Skip without the given members, or nil when none of its retired members are left. Used
    /// when some members go away on their own (their feed is unsubscribed), so Undo and the cleanup
    /// that follows cover only the rest.
    public func removing(_ gone: Set<ItemID>) -> SoftSkipRecord? {
        let rest = retiredIDs.filter { !gone.contains($0) }
        guard !rest.isEmpty else { return nil }
        return SoftSkipRecord(retiredAt: retiredAt, retiredIDs: rest, entries: entries.filter { !gone.contains($0.episodeID) })
    }

    /// The same Skip reduced to the members whose cleanup is still to do.
    public func keeping(_ kept: Set<ItemID>) -> SoftSkipRecord? {
        removing(Set(retiredIDs).subtracting(kept))
    }
}

/// One member of an open soft Skip, as admission and downloads see it.
struct SoftSkipHold {
    let feedID: ItemID
    let retiredAt: Date
    /// The member held a kept slot before the Skip (a Keep decision or a place in the queue), so
    /// Undo would take that slot back and admission must not fill it meanwhile.
    let reservesCapacity: Bool
}

/// What closing a soft Skip did.
public struct SoftSkipClose: Equatable, Sendable {
    /// Members still retired from the Skip whose media is now gone, or never existed.
    public let finished: [ItemID]
    /// Members still retired whose media was kept because the player has them loaded. Their cleanup
    /// is still owed.
    public let held: [ItemID]
}

extension LocalLibraryStore {
    /// Each member's stored decision, read in the caller's context. A member with none maps to `nil`;
    /// one whose record cannot be read is left out, so nothing is "restored" from a guess.
    static func priorDecisions(of ids: [ItemID], lookup: EpisodeAssociationReadLookup)
        -> [ItemID: EpisodeDecisionRecord?] {
        var result: [ItemID: EpisodeDecisionRecord?] = [:]
        for id in ids {
            guard let record = lookup.decisions[id.rawValue] else {
                result.updateValue(nil, forKey: id)
                continue
            }
            guard let decision = EpisodeDecision(rawValue: record.decision),
                  let source = EpisodeDecisionSource(rawValue: record.source) else { continue }
            result.updateValue(
                EpisodeDecisionRecord(episodeID: id, decision: decision, source: source,
                                      ruleID: record.ruleID, decidedAt: Timestamp(record.decidedAt)),
                forKey: id
            )
        }
        return result
    }

    /// Takes back a soft Skip in one save and returns the episodes that were put back on the feed.
    ///
    /// Each member is handled alone and only while the Skip is still the latest word on it: its
    /// decision must still be this Skip's own manual Skip, stamped `skippedAt`. A member the owner
    /// has since kept, skipped again, or otherwise decided is left exactly as it is, so a stale Undo
    /// never overrides a newer action. For a member that qualifies, the decision goes back to what it
    /// was (a missing prior removes the record) and, if it is still retired from this same Skip, it
    /// returns to the feed. Nothing is deleted or re-created: the audio, playback position and
    /// listening history were never touched, and no new Keep is written.
    @discardableResult
    public func undoSoftSkip(_ record: SoftSkipRecord) throws -> [ItemID] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let lookup = try EpisodeAssociationReadLookup(in: context)
        let skippedAt = record.retiredAt.date
        var restored: [ItemID] = []
        for entry in record.entries {
            guard let current = lookup.decisions[entry.episodeID.rawValue],
                  current.decision == EpisodeDecision.skip.rawValue,
                  current.source == EpisodeDecisionSource.manual.rawValue,
                  current.decidedAt == skippedAt else { continue }
            if let prior = entry.prior {
                current.decision = prior.decision.rawValue; current.source = prior.source.rawValue
                current.ruleID = prior.ruleID; current.decidedAt = prior.decidedAt.date
            } else {
                context.delete(current)
            }
            if let episode = lookup.episodes[entry.episodeID.rawValue],
               episode.removalKind == PodcastEpisodeRemovalKind.retired.rawValue,
               episode.retiredAt == skippedAt {
                episode.removalKind = nil; episode.retiredAt = nil
                restored.append(entry.episodeID)
            }
        }
        if context.hasChanges { try context.save() }
        releaseSoftSkipHolds(record.retiredIDs, at: record.retiredAt)
        return restored
    }

    /// Closes a soft Skip once Undo can no longer happen: deletes the media records of every member
    /// still retired from this Skip, then their files. A member the owner restored or skipped again
    /// since is left alone, a member of a group of linked episodes keeps its media, as a direct Skip
    /// of one does, and a member in `protecting` (the player has it loaded, which the store cannot
    /// see) keeps its media and is reported as `held`, so its cleanup can be tried again later. The
    /// check and the deletion share one save. Safe to repeat.
    @discardableResult
    public func finalizeSoftSkip(
        _ requested: [ItemID], at retiredAt: Timestamp, protecting: Set<ItemID> = []
    ) throws -> SoftSkipClose {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let lookup = try EpisodeAssociationReadLookup(in: context)
        // A Skip of one row retires its linked members too, and the record may name only the row. The
        // members are read from the store, so none is left out whatever the caller recorded.
        var seen = Set<ItemID>()
        let ids = requested.flatMap { lookup.state(for: $0)?.memberIDs ?? [$0] }.filter { seen.insert($0).inserted }
        var finished: [ItemID] = []
        var held: [ItemID] = []
        var doomed = Set<String>()
        for id in ids {
            guard let episode = lookup.episodes[id.rawValue],
                  episode.removalKind == PodcastEpisodeRemovalKind.retired.rawValue,
                  episode.retiredAt == retiredAt.date else { continue }
            if protecting.contains(id) { held.append(id); continue }
            finished.append(id)
            if (lookup.state(for: id)?.memberIDs.count ?? 1) <= 1 { doomed.insert(id.rawValue) }
        }
        guard !doomed.isEmpty else {
            releaseSoftSkipHolds(ids, at: retiredAt)
            return SoftSkipClose(finished: finished, held: held)
        }
        let media = try Self.deleteMediaRecords(forEpisodesWithIDs: doomed, in: context)
        try context.save()
        // From here a download that finishes for these members is refused (see `finalizePodcastDownload`).
        // A member whose audio stays because the player has it loaded gives its slot up all the same.
        releaseSoftSkipHolds(ids, at: retiredAt)
        deleteMediaIfUnreferenced(media)
        return SoftSkipClose(finished: finished, held: held)
    }

    /// Frees the slots a Skip held, but only the ones this very Skip took: an episode that was
    /// restored and skipped again holds its slot for the newer Skip, which a stale close or Undo
    /// must not release.
    func releaseSoftSkipHolds(_ ids: [ItemID], at retiredAt: Timestamp) {
        for id in ids where softSkipHolds[id]?.retiredAt == retiredAt.date { softSkipHolds[id] = nil }
    }
}
