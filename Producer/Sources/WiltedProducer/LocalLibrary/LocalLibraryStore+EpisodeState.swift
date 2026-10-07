import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

public struct PodcastQueueAppendResult: Sendable {
    public let state: PodcastQueueState
    public let newlyAdded: [ItemID]
    public let alreadyQueued: [ItemID]
    public let unresolved: [ItemID]
    public let queueReadCount: Int
    public let queueWriteCount: Int
    public let episodeRecordFetchCount: Int
}

public struct PodcastEpisodeBatchResult: Sendable {
    public let committed: [ItemID]
    public let alreadyAtTarget: [ItemID]
    public let unresolved: [ItemID]
    public let retiredAtByID: [ItemID: Timestamp]
    public let episodeRecordFetchCount: Int
    public let listeningRecordFetchCount: Int
    /// Reads of the revision, download, and artwork records retirement
    /// reclaims -- one read per type, and zero when nothing commits.
    public let mediaRecordFetchCount: Int
    public let saveCount: Int
}

extension LocalLibraryStore {
    /// Appends unique IDs in caller order using one queue read and one durable
    /// replacement. Existing positions and the current episode stay intact.
    public func appendPodcastQueueEpisodes(_ requested: [ItemID]) throws -> PodcastQueueAppendResult {
        let state = try podcastQueueState()
        let unique = uniqueEpisodeIDs(requested)
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let existing = Set(state.episodeIDs)
        let alreadyQueued = unique.filter { id in
            guard let record = byID[id.rawValue] else { return false }
            return existing.contains(id) && record.removalKind == nil
        }
        let eligible = unique.filter { id in
            guard let record = byID[id.rawValue] else { return false }
            return !existing.contains(id) && record.removalKind == nil
        }
        let accepted = Set(alreadyQueued).union(eligible)
        let unresolved = unique.filter { !accepted.contains($0) }
        guard !eligible.isEmpty else {
            return PodcastQueueAppendResult(
                state: state, newlyAdded: [], alreadyQueued: alreadyQueued, unresolved: unresolved,
                queueReadCount: 1, queueWriteCount: 0, episodeRecordFetchCount: 1
            )
        }
        let updated = try PodcastQueueState(
            episodeIDs: state.episodeIDs + eligible, currentEpisodeID: state.currentEpisodeID
        )
        try replacePodcastQueue(updated)
        return PodcastQueueAppendResult(
            state: updated, newlyAdded: eligible, alreadyQueued: alreadyQueued, unresolved: unresolved,
            queueReadCount: 1, queueWriteCount: 1, episodeRecordFetchCount: 1
        )
    }

    /// Retires a visible Feed selection in one context, one episode-record
    /// fetch, and one save. Missing and dismissed IDs are unresolved; an
    /// already-retired row is a truthful idempotent success with its stored
    /// retirement timestamp and is never deleted from twice.
    ///
    /// A newly retired episode's revision, download, and artwork records are
    /// deleted in the same context and save, and only once that save commits
    /// are the files they named deleted through `deleteMediaIfUnreferenced`.
    /// The shared-file guard there keeps any file a surviving record still
    /// names, so retiring one episode cannot take another's audio with it.
    /// The episode row, decision records, listening history, and preparation
    /// journal stay, so Restore and history work; the restored episode has no
    /// download or ready revision and reads as not downloaded.
    public func retireEpisodes(_ requested: [ItemID], at retiredAt: Timestamp = Timestamp(Date())) throws -> PodcastEpisodeBatchResult {
        let unique = uniqueEpisodeIDs(requested)
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var committed: [ItemID] = []
        var unresolved: [ItemID] = []
        var alreadyAtTarget: [ItemID] = []
        var retiredAtByID: [ItemID: Timestamp] = [:]
        for id in unique {
            guard let record = byID[id.rawValue] else { unresolved.append(id); continue }
            if record.removalKind == PodcastEpisodeRemovalKind.retired.rawValue {
                alreadyAtTarget.append(id)
                if let retiredAt = record.retiredAt { retiredAtByID[id] = Timestamp(retiredAt) }
                continue
            }
            guard record.removalKind == nil else { unresolved.append(id); continue }
            record.retiredAt = retiredAt.date
            record.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
            committed.append(id)
        }
        var mediaRecordFetchCount = 0
        if !committed.isEmpty {
            mediaRecordFetchCount = 3
            let doomedMedia = try deleteMediaRecords(
                forEpisodesWithIDs: Set(committed.map(\.rawValue)), in: context
            )
            try context.save()
            deleteMediaIfUnreferenced(doomedMedia)
        }
        return PodcastEpisodeBatchResult(
            committed: committed, alreadyAtTarget: alreadyAtTarget, unresolved: unresolved,
            retiredAtByID: retiredAtByID,
            episodeRecordFetchCount: 1, listeningRecordFetchCount: 0,
            mediaRecordFetchCount: mediaRecordFetchCount, saveCount: committed.isEmpty ? 0 : 1
        )
    }

    /// Restores only Feed-retired rows. A dismissed row remains the stronger
    /// removal and continues through its existing explicit restore pathway.
    public func restoreEpisodes(_ requested: [ItemID]) throws -> PodcastEpisodeBatchResult {
        let unique = uniqueEpisodeIDs(requested)
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let listening = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        let listeningByID = Dictionary(uniqueKeysWithValues: listening.map { ($0.id, $0) })
        let now = Date()
        var committed: [ItemID] = []
        var unresolved: [ItemID] = []
        var alreadyAtTarget: [ItemID] = []
        for id in unique {
            guard let record = byID[id.rawValue] else { unresolved.append(id); continue }
            if record.removalKind == nil { alreadyAtTarget.append(id); continue }
            guard record.removalKind == PodcastEpisodeRemovalKind.retired.rawValue else { unresolved.append(id); continue }
            record.removalKind = nil; record.retiredAt = nil
            listeningByID[id.rawValue]?.lastRevisionID = nil
            listeningByID[id.rawValue]?.updatedAt = now
            committed.append(id)
        }
        if !committed.isEmpty { try context.save() }
        return PodcastEpisodeBatchResult(
            committed: committed, alreadyAtTarget: alreadyAtTarget, unresolved: unresolved,
            retiredAtByID: [:],
            episodeRecordFetchCount: 1, listeningRecordFetchCount: 1,
            mediaRecordFetchCount: 0, saveCount: committed.isEmpty ? 0 : 1
        )
    }

    private func uniqueEpisodeIDs(_ requested: [ItemID]) -> [ItemID] {
        var seen = Set<ItemID>()
        return requested.filter { seen.insert($0).inserted }
    }

    /// Deletes the revision, download, and artwork records naming the given
    /// episodes' media and returns the URLs they named. One fetch per record
    /// type; the caller commits with one save and only then hands the URLs to
    /// `deleteMediaIfUnreferenced`, so a failed save never deletes audio the
    /// surviving records still name. Mirrors the collection dismissal and
    /// unsubscribe read, so every removal reclaims the same set of files.
    private func deleteMediaRecords(
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

    public func savePreparationOutcome(_ outcome: PodcastPreparationOutcome) throws {
        let context = ModelContext(container)
        try upsertPreparationOutcome(outcome, in: context)
        try context.save()
    }

    /// Inserts or updates one outcome row without saving, so a caller can
    /// combine it with other writes (the revision it proves, the download it
    /// closes out) in a single atomic `context.save()`.
    func upsertPreparationOutcome(_ outcome: PodcastPreparationOutcome, in context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
        if let existing = records.first(where: { $0.id == outcome.id }) {
            existing.policyDigest = outcome.policyDigest
            existing.pipelineFingerprint = outcome.pipelineFingerprint
            existing.semanticVersion = outcome.semanticVersion
            existing.producedAt = outcome.producedAt.date
            existing.eligibility = outcome.eligibility.rawValue
            existing.invalidationRuleID = outcome.invalidationRuleID
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord(outcome))
        }
    }

    public func preparationOutcome(for episodeID: ItemID, revisionID: RevisionID) throws -> PodcastPreparationOutcome? {
        let context = ModelContext(container)
        let id = "\(episodeID.rawValue)|\(revisionID.rawValue)"
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
            .first(where: { $0.id == id }),
            let eligibility = PodcastPreparationEligibility(rawValue: record.eligibility) else { return nil }
        return PodcastPreparationOutcome(
            episodeID: episodeID, revisionID: revisionID, policyDigest: record.policyDigest,
            pipelineFingerprint: record.pipelineFingerprint, semanticVersion: record.semanticVersion,
            producedAt: Timestamp(record.producedAt), eligibility: eligibility,
            invalidationRuleID: record.invalidationRuleID
        )
    }

    public func saveListening(_ state: PodcastListeningState) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        if let existing = records.first(where: { $0.id == state.episodeID.rawValue }) {
            existing.completedAt = state.completedAt?.date
            existing.lastRevisionID = state.lastRevisionID?.rawValue
            existing.updatedAt = state.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(state))
        }
        try context.save()
    }

    public func listeningState(for episodeID: ItemID) throws -> PodcastListeningState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
            .first(where: { $0.id == episodeID.rawValue }) else { return nil }
        return PodcastListeningState(
            episodeID: episodeID, completedAt: record.completedAt.map(Timestamp.init),
            lastRevisionID: record.lastRevisionID.flatMap { try? RevisionID(rawValue: $0) },
            updatedAt: Timestamp(record.updatedAt)
        )
    }

    /// Records a manual completion and retires the same active episode in one
    /// save. A started Larder row uses this rather than separately writing a
    /// listening fact and a retirement, so Feeds cannot observe a completed
    /// episode as active after an interrupted write.
    ///
    /// Existing prepared media, transcripts, and revisions are deliberately
    /// untouched. A dismissal is stronger than retirement and is never
    /// replaced by this operation.
    @discardableResult
    public func completeAndRetireEpisode(
        listening: PodcastListeningState,
        at retiredAt: Timestamp = Timestamp(Date())
    ) throws -> Bool {
        let context = ModelContext(container)
        let identifier = listening.episodeID.rawValue
        guard let episode = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == identifier }), episode.removalKind == nil else { return false }

        let listeningRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        if let existing = listeningRecords.first(where: { $0.id == identifier }) {
            existing.completedAt = listening.completedAt?.date
            existing.lastRevisionID = listening.lastRevisionID?.rawValue
            existing.updatedAt = listening.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(listening))
        }
        episode.retiredAt = retiredAt.date
        episode.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
        try context.save()
        return true
    }

    /// Reverses a completion written by `completeAndRetireEpisode` in one
    /// save. It intentionally accepts only a retirement with the manual
    /// completion shape (`lastRevisionID == nil`), so stale Undo Skip cannot
    /// restore or alter a separately dismissed episode.
    @discardableResult
    public func undoCompletedAndRetiredEpisode(
        _ episodeID: ItemID,
        updatedAt: Timestamp = Timestamp(Date())
    ) throws -> Bool {
        let context = ModelContext(container)
        let identifier = episodeID.rawValue
        guard let episode = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == identifier }),
            episode.removalKind == PodcastEpisodeRemovalKind.retired.rawValue,
            let listening = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
            .first(where: { $0.id == identifier }),
            listening.completedAt != nil,
            listening.lastRevisionID == nil else { return false }

        listening.completedAt = nil
        listening.updatedAt = updatedAt.date
        episode.removalKind = nil
        episode.retiredAt = nil
        try context.save()
        return true
    }

    /// Idempotent: retiring an episode already retired or dismissed is a
    /// no-op returning `false`. Retiring cannot override a dismissal --
    /// dismissal is the stronger of the two removals; see `dismissPodcastEpisode`.
    ///
    /// A real retirement deletes the episode's revision, download, and
    /// artwork records and, once the record save commits, the files they
    /// named through `deleteMediaIfUnreferenced` -- subject to the same
    /// shared-file guard dismissal uses, so a file another surviving episode
    /// still names stays. The episode row, decision records, listening
    /// history, and preparation journal survive, so Restore and history work.
    @discardableResult
    public func retireEpisode(_ episodeID: ItemID, at retiredAt: Timestamp = Timestamp(Date())) throws -> Bool {
        let context = ModelContext(container)
        let identifier = episodeID.rawValue
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == identifier }), record.removalKind == nil else { return false }
        let doomedMedia = try deleteMediaRecords(forEpisodesWithIDs: [identifier], in: context)
        record.retiredAt = retiredAt.date
        record.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
        try context.save()
        deleteMediaIfUnreferenced(doomedMedia)
        return true
    }

    /// The removal timestamp, whichever removal kind wrote it -- `nil` for
    /// an episode still on the shelf.
    public func retiredAt(for episodeID: ItemID) throws -> Timestamp? {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == episodeID.rawValue })?.retiredAt.map(Timestamp.init)
    }

    /// The removal state itself -- `nil` for an episode still on the shelf.
    public func removalKind(for episodeID: ItemID) throws -> PodcastEpisodeRemovalKind? {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == episodeID.rawValue })?.removalKind
            .flatMap(PodcastEpisodeRemovalKind.init(rawValue:))
    }

    /// Reverses `retireEpisode` or `dismissPodcastEpisode`, returning an
    /// episode to the library regardless of which removal it carried -- the
    /// one control both a retired and a dismissed row offer to come back.
    /// Idempotent: an episode with no removal recorded returns `false`.
    @discardableResult
    public func restoreEpisode(_ episodeID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        let identifier = episodeID.rawValue
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == identifier }), record.removalKind != nil else { return false }
        record.removalKind = nil
        record.retiredAt = nil
        let restoredAt = Date()
        // Clearing `lastRevisionID` (not `completedAt`) keeps "I listened to
        // this" intact while defeating the bootstrap sweep's exact-revision
        // match: a re-download that lands on the same content-addressed
        // revision would otherwise get silently re-retired on next launch,
        // undoing the restore the user just asked for.
        if let listening = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>()
        ).first(where: { $0.id == identifier }) {
            listening.lastRevisionID = nil
            listening.updatedAt = restoredAt
        }
        try context.save()
        return true
    }

    /// Stable identifiers recorded on an outcome row translated from a legacy
    /// `podcast-invalidation|` or `podcast-reset-preparation|` marker by
    /// `reconcilePodcastStateV10()`.
    public static let legacyForcedRedownloadInvalidationRuleID = "legacy-forced-redownload"
    public static let legacyResetPreparationInvalidationRuleID = "legacy-reset-preparation"

    /// `semanticVersion` sentinel for a backfilled outcome row whose
    /// `pipelineFingerprint` is `nil` -- genuinely unknown provenance, not
    /// today's pipeline. Stamping today's version on such a row would be a
    /// false durable claim about what produced it.
    public static let legacyUnknownProvenanceSemanticVersion = "unknown-legacy"

    /// Idempotent post-open backfill translating pre-V10 evidence into the new
    /// durable outcome, listening, and retirement records.
    ///
    /// Each step only inserts where nothing already proves the fact, and step
    /// 4 deletes every marker it translates or supersedes, so a second call
    /// is a true no-op with respect to those: there is nothing left for it to
    /// find. The one exception is a forced-redownload marker with no
    /// matching outcome row, which step 4 deliberately leaves in place (see
    /// its doc comment) -- a second call finds it again and, correctly,
    /// leaves it again. Every step commits before the next reads, so a later
    /// step's fetch always sees a fully persisted prior step rather than
    /// racing an uncommitted `ModelContext`.
    public func reconcilePodcastStateV10() throws {
        let context = ModelContext(container)
        try backfillPreparationOutcomesForV10Reconciliation(in: context)
        try context.save()
        try backfillListeningRecordsForV10Reconciliation(in: context)
        try context.save()
        // Step 3: `retiredAt` is left `nil` for every existing row here. A
        // completed-but-unretired episode is a real, one-time retirement on
        // first launch after Phase 5, not a no-op backfill, so it is handled
        // by the separate `retireCompletedEpisodesMissingRetirement()` rather
        // than folded into this function's idempotent-by-construction steps.
        try translateLegacyInvalidationMarkersForV10Reconciliation(in: context)
        try context.save()
    }

    /// Retires every episode whose listening record says the listener
    /// reached the end of its current ready revision and whose episode row
    /// has no `retiredAt` yet.
    ///
    /// Scoped to the *current* ready revision (not just any completed
    /// listening fact) so a dismissed-then-restored episode, whose ready
    /// revision was deleted and has not been re-downloaded, is left alone
    /// rather than retired sight unseen. A legacy completion without a
    /// revision ID may retire only when that ready revision was created no
    /// later than the completion and the listening row was not refreshed after
    /// completion; a later download or restore remains active. Separate from
    /// `reconcilePodcastStateV10` because, unlike every step there, this is
    /// not a no-op on repeat first launches: it is the completion flow's own
    /// retirement, run once for every episode that finished before this
    /// method existed. On first launch after this ships, every already-Played
    /// episode with a matching ready revision leaves the Larder at once.
    public func retireCompletedEpisodesMissingRetirement() throws {
        let context = ModelContext(container)
        let listeningRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
            .filter { $0.completedAt != nil }
        guard !listeningRecords.isEmpty else { return }
        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        var changed = false
        for listening in listeningRecords {
            guard let episode = episodes.first(where: { $0.id == listening.id }), episode.removalKind == nil,
                  let episodeID = try? ItemID(rawValue: listening.id),
                  let ready = readyRevisions[episodeID.rawValue],
                  let completedAt = listening.completedAt else { continue }
            let matchesCompletedRevision = listening.lastRevisionID == ready.revision.revisionID.rawValue
            let legacyCompletionHasPriorReadyRevision = listening.lastRevisionID == nil
                && listening.updatedAt <= completedAt
                && ready.revision.createdAt.date <= completedAt
            guard matchesCompletedRevision || legacyCompletionHasPriorReadyRevision else { continue }
            episode.retiredAt = Date()
            episode.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
            changed = true
        }
        if changed { try context.save() }
    }

    /// Step 1: an episode with a ready revision and no outcome row for it gets
    /// one manufactured from the newest matching journal success. A `nil`
    /// `pipelineFingerprint` means "prepared by an unknown earlier pipeline"
    /// and still evaluates to `.current` -- legacy artifacts must stay
    /// playable.
    private func backfillPreparationOutcomesForV10Reconciliation(in context: ModelContext) throws {
        let decoder = JSONDecoder()
        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        let existingOutcomeIDs = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()).map(\.id)
        )
        let journalRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        for episodeRecord in episodes {
            guard let episodeID = try? ItemID(rawValue: episodeRecord.id),
                  let ready = readyRevisions[episodeID.rawValue] else { continue }
            let outcomeID = "\(episodeID.rawValue)|\(ready.revisionID.rawValue)"
            guard !existingOutcomeIDs.contains(outcomeID) else { continue }
            let entries: [PreparationJournalEntry] = journalRecords
                .filter {
                    $0.itemID == episodeID.rawValue
                        && !$0.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                        && !$0.requestID.hasPrefix(Self.resetPreparationRequestPrefix)
                }
                .compactMap { record in
                    guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData) else { return nil }
                    return PreparationJournalEntry(id: record.id, itemID: episodeID, requestID: record.requestID, status: status)
                }
                .sorted(by: preparationEntryPrecedes)
            guard let match = entries.last(where: {
                $0.status.terminal
                    && $0.status.terminalResult?.outcome == .succeeded
                    && $0.status.terminalResult?.revisionID == ready.revisionID
            }) else { continue }
            let fingerprint: String?
            if let evidence = match.status.evidence, evidence.kind == Self.pipelineProvenanceEvidenceKind,
               let value = evidence.fields["fingerprint"], !value.isEmpty {
                fingerprint = value
            } else {
                fingerprint = nil
            }
            let outcome = PodcastPreparationOutcome(
                episodeID: episodeID, revisionID: ready.revisionID,
                // Cannot be reconstructed from history -- legacy rows carry no
                // digest. A deliberate, documented default, not a bug.
                policyDigest: "",
                pipelineFingerprint: fingerprint,
                // A nil fingerprint means no real provenance evidence was
                // found -- stamping today's semantic version would falsely
                // claim this artifact came from the current pipeline.
                semanticVersion: fingerprint != nil
                    ? PodcastPreparationPipeline.semanticVersion
                    : Self.legacyUnknownProvenanceSemanticVersion,
                producedAt: match.status.emittedAt, eligibility: .current, invalidationRuleID: nil
            )
            context.insert(LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord(outcome))
        }
    }

    /// Step 2: an episode whose ready revision has a completed `PlaybackRecord`
    /// and no listening row yet gets one, so "I finished this" survives the
    /// migration that introduced the item-scoped fact.
    private func backfillListeningRecordsForV10Reconciliation(in context: ModelContext) throws {
        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        let existingListeningIDs = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>()).map(\.id)
        )
        let playbackRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        for episodeRecord in episodes {
            guard let episodeID = try? ItemID(rawValue: episodeRecord.id),
                  !existingListeningIDs.contains(episodeID.rawValue),
                  let ready = readyRevisions[episodeID.rawValue] else { continue }
            guard let playback = playbackRecords.first(where: {
                $0.itemID == episodeID.rawValue && $0.revisionID == ready.revisionID.rawValue && $0.completed
            }) else { continue }
            let state = PodcastListeningState(
                episodeID: episodeID, completedAt: Timestamp(playback.updatedAt),
                lastRevisionID: ready.revisionID, updatedAt: Timestamp(playback.updatedAt)
            )
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(state))
        }
    }

    /// Step 4: legacy `podcast-invalidation|` / `podcast-reset-preparation|`
    /// markers -- ones written before the rule table in
    /// `invalidateStalePodcastPreparations` existed -- are translated onto
    /// the matching `.current` outcome row when one exists and the marker is
    /// at least as new as it, and dropped once their information is applied
    /// or superseded.
    ///
    /// A matching outcome row no longer proves a marker is legacy debt:
    /// `invalidateStalePodcastPreparations` itself writes a marker in the
    /// same transaction it sets an outcome's `eligibility` to `.invalid`,
    /// for episodes that DO have an outcome row (its pass 2 specifically
    /// targets those). Deleting that marker here unconditionally destroys
    /// the only durable record of a scheduled forced-redownload or reset
    /// before it is ever admitted, permanently: `requiresForcedRedownload`
    /// and the marker-rebuild pass in `invalidateStalePodcastPreparations`
    /// both derive solely from marker survival, not from `eligibility`.
    /// `.invalid` + a marker is therefore live scheduling state, not legacy
    /// debt, and must be left alone. Only a `.current` outcome is the true
    /// legacy case this step exists for: no rule has fired through the new
    /// mechanism for that episode, so a surviving marker can only be a
    /// leftover pre-V10 write.
    private func translateLegacyInvalidationMarkersForV10Reconciliation(in context: ModelContext) throws {
        let markers = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()).filter {
            $0.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                || $0.requestID.hasPrefix(Self.resetPreparationRequestPrefix)
        }
        guard !markers.isEmpty else { return }
        let decoder = JSONDecoder()
        let outcomes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        for marker in markers {
            let isForcedRedownload = marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
            let ruleID = isForcedRedownload
                ? Self.legacyForcedRedownloadInvalidationRuleID
                : Self.legacyResetPreparationInvalidationRuleID
            guard let episodeID = try? ItemID(rawValue: marker.itemID),
                  let ready = readyRevisions[episodeID.rawValue],
                  let outcome = outcomes.first(where: {
                      $0.episodeID == episodeID.rawValue && $0.revisionID == ready.revisionID.rawValue
                  }),
                  outcome.eligibility == PodcastPreparationEligibility.current.rawValue else {
                continue
            }
            // A matching `.current` outcome row exists with no invalidation
            // rule having fired for it, so this is the true legacy case: the
            // marker's information is either applied below or superseded by
            // a newer success -- either way the marker itself is spent and
            // gets deleted.
            context.delete(marker)
            guard let markerStatus = try? decoder.decode(PreparationStatus.self, from: marker.statusData),
                  markerStatus.emittedAt.date >= outcome.producedAt else {
                // Undecodable, or genuinely older than the outcome it would
                // invalidate: leave the outcome as `.current` rather than
                // mislabel a newer, good artifact as invalid.
                continue
            }
            outcome.eligibility = PodcastPreparationEligibility.invalid.rawValue
            outcome.invalidationRuleID = ruleID
        }
    }

}
