import Foundation
import SwiftData
import WiltedDomain

/// One episode the Larder may offer to prepare again with the current engine,
/// and what the store knows about the audio it would replace.
public struct PodcastPrepareAgainCandidate: Equatable, Sendable {
    public let episodeID: ItemID
    /// The newest ready revision: what stays playable until a run replaces it.
    public let readyRevision: StoredAudioRevision
    /// Whether the ready revision is a cut of an original that no longer exists
    /// in the library. A cut cannot be fed back to the pipeline, so its
    /// original is downloaded again; an uncut original is already on disk.
    public let isCut: Bool
    /// What the preparation that produced the ready revision kept, on the
    /// original's clock. Absent for cuts made before timelines were journalled,
    /// and for episodes that were never cut.
    public let keptTimeline: PreparationStatus.PreparationTimeline?
    /// The hash of the original that preparation read, when its journal says.
    public let sourceHash: String?
    public let enclosureURL: URL

    public init(
        episodeID: ItemID, readyRevision: StoredAudioRevision, isCut: Bool,
        keptTimeline: PreparationStatus.PreparationTimeline?, sourceHash: String?, enclosureURL: URL
    ) {
        self.episodeID = episodeID
        self.readyRevision = readyRevision
        self.isCut = isCut
        self.keptTimeline = keptTimeline
        self.sourceHash = sourceHash
        self.enclosureURL = enclosureURL
    }
}

extension LocalLibraryStore {
    /// The evidence kind the pipeline attaches to the worker's own report.
    private static let workerResultEvidenceKind = "worker-result"
    /// Written on the journal row of a prepare-again run that changed nothing:
    /// it refused, or kept the existing cut. Its terminal success names the
    /// ready revision, so this is how a later reader tells it from the run
    /// that produced that revision.
    static let keptExistingAudioEvidenceKind = "prepare-again-kept"

    /// Every episode the Larder may offer to prepare again with the current
    /// engine, in episode-ID order.
    ///
    /// Eligible: an episode that is not retired or completed, whose newest
    /// ready revision has a preparation outcome that is not invalid, and whose
    /// newest finished preparation attempt did not run on
    /// `PodcastPreparationPipeline.semanticVersion`.
    ///
    /// The engine is judged from the journal's own `engineVersion` evidence,
    /// not from the outcome row: the V10 backfill stamped outcomes it could not
    /// prove as current, so `semanticVersion` there says nothing about which
    /// engine ran. No evidence, or `unknown-legacy`, counts as older. Any
    /// result counts as a try, including a failed or uncertain one, because
    /// the point is to run each episode through the current engine once; a
    /// cancelled attempt does not, since nothing was decided.
    ///
    /// One context and one fetch per table, because every Larder load asks
    /// this: the read cost stays flat as the library grows.
    public func podcastEpisodesToPrepareAgain() throws -> [PodcastPrepareAgainCandidate] {
        let context = ModelContext(container)
        let attemptsByEpisode = try journalAttemptsByEpisode(in: context)
        let downloads = Dictionary(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
                .map { ($0.episodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let outcomes = Dictionary(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let completed = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
                .filter { $0.completedAt != nil }.map(\.id)
        )
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        var candidates: [PodcastPrepareAgainCandidate] = []
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        where record.retiredAt == nil && !completed.contains(record.id) {
            guard let itemID = try? ItemID(rawValue: record.id),
                  let ready = readyRevisions[record.id],
                  let enclosureURL = URL(string: record.enclosureURL),
                  let outcome = outcomes[record.id + "|" + ready.revisionID.rawValue],
                  outcome.eligibility != PodcastPreparationEligibility.invalid.rawValue
            else { continue }
            let attempts = attemptsByEpisode[record.id] ?? []
            if let newest = Self.newestFinishedAttempt(attempts),
               let engine = newest.engineVersion, engine == PodcastPreparationPipeline.semanticVersion {
                continue
            }
            let producing = Self.attemptProducing(ready.revisionID, in: attempts)
            let provenanceHash = producing?.sourceHash
            // What the journal cannot prove stays a cut: feeding a cut to the
            // pipeline as if it were the original is the one wrong answer.
            var isCut = true
            if let producing {
                let hashDiffers = provenanceHash.map { $0 != ready.revision.contentHash }
                let removedSomething = !(producing.timeline?.removed.isEmpty ?? true)
                if let changed = producing.audioChanged {
                    isCut = changed || removedSomething || hashDiffers == true
                } else if let hashDiffers {
                    isCut = hashDiffers || removedSomething
                }
            }
            // An uncut original is only "the existing path" while its file is
            // still the download the pipeline would read.
            if !isCut {
                let download = downloads[record.id]
                let intact = download?.status == PodcastDownloadStatus.completed.rawValue
                    && download?.contentHash == ready.revision.contentHash
                    && download?.localURL.flatMap(URL.init)?.standardizedFileURL.path
                        == ready.mediaURL.standardizedFileURL.path
                    && FileManager.default.fileExists(atPath: ready.mediaURL.path)
                if !intact { isCut = true }
            }
            let timeline = producing?.timeline.flatMap { $0.kept.isEmpty ? nil : $0 }
            candidates.append(PodcastPrepareAgainCandidate(
                episodeID: itemID, readyRevision: ready, isCut: isCut,
                keptTimeline: isCut ? timeline : nil, sourceHash: isCut ? provenanceHash : nil,
                enclosureURL: enclosureURL
            ))
        }
        return candidates.sorted { $0.episodeID.rawValue < $1.episodeID.rawValue }
    }

    // MARK: Journal attempts

    /// One preparation attempt as the journal retains it, reduced to the facts
    /// eligibility needs.
    private struct JournalAttempt {
        let entries: [PreparationJournalEntry]

        var terminal: PreparationStatus? { entries.last(where: { $0.status.terminal })?.status }
        var provenance: PreparationEvidence? {
            entries.lazy.compactMap(\.status.evidence)
                .first(where: { $0.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind })
        }
        /// Read from the provenance rows rather than the terminal one, which
        /// carries evidence only when the pipeline fingerprint resolved.
        var engineVersion: String? {
            entries.lazy.compactMap(\.status.evidence)
                .filter { $0.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind }
                .compactMap { $0.fields["engineVersion"] }.first(where: { !$0.isEmpty })
        }
        var sourceHash: String? {
            entries.lazy.compactMap(\.status.evidence)
                .filter { $0.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind }
                .compactMap { $0.fields["sourceHash"] }.first(where: { !$0.isEmpty })
        }
        /// Whether the worker rewrote the audio. Journals older than the
        /// `audioChanged` field carry only the outcome, and only `cut` ever
        /// changed the audio: `uncertain` keeps the whole original (W-INV-013).
        var audioChanged: Bool? {
            let result = entries.lazy.compactMap(\.status.evidence)
                .first(where: { $0.kind == LocalLibraryStore.workerResultEvidenceKind })
            if let changed = result?.fields["audioChanged"] { return changed == "true" }
            return result?.fields["adRemovalOutcome"].map { $0 == "cut" }
        }
        var timeline: PreparationStatus.PreparationTimeline? { terminal?.timeline }
        /// A run that ended by keeping the audio it found, so its success names
        /// the ready revision without having produced it.
        var keptExistingAudio: Bool {
            entries.contains { $0.status.evidence?.kind == LocalLibraryStore.keptExistingAudioEvidenceKind }
        }
    }

    /// Every episode's attempts, oldest first, read from one pass over the
    /// journal table. Invalidation markers are scheduling state, not attempts.
    private func journalAttemptsByEpisode(in context: ModelContext) throws -> [String: [JournalAttempt]] {
        let decoder = JSONDecoder()
        var generations: [String: [PreparationJournalEntry]] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()) {
            guard !record.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix),
                  !record.requestID.hasPrefix(Self.resetPreparationRequestPrefix),
                  let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                  let itemID = try? ItemID(rawValue: record.itemID) else { continue }
            let generation = record.requestID + (status.attempt.map { "|" + $0.key } ?? "")
            generations[generation, default: []].append(
                PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
            )
        }
        var byEpisode: [String: [JournalAttempt]] = [:]
        for entries in generations.values {
            let ordered = entries.sorted(by: preparationEntryPrecedes)
            guard let last = ordered.last else { continue }
            byEpisode[last.itemID.rawValue, default: []].append(JournalAttempt(entries: ordered))
        }
        for key in byEpisode.keys {
            byEpisode[key]?.sort { !Self.journalAttemptIsNewer($0.entries, than: $1.entries) }
        }
        return byEpisode
    }

    /// The newest attempt that reached a result or is still in flight. A
    /// cancelled attempt is skipped: the listener stopped it before it decided
    /// anything, so it cannot stand in for having tried the engine.
    private static func newestFinishedAttempt(_ attempts: [JournalAttempt]) -> JournalAttempt? {
        attempts.last { $0.terminal?.terminalResult?.outcome != .cancelled }
    }

    /// The newest attempt whose success is the ready revision. A later failed
    /// or refused run is not the one that produced the audio, so only this
    /// attempt can say what was cut and where.
    private static func attemptProducing(_ revisionID: RevisionID, in attempts: [JournalAttempt]) -> JournalAttempt? {
        attempts.last {
            $0.terminal?.terminalResult?.outcome == .succeeded
                && $0.terminal?.terminalResult?.revisionID == revisionID
                && !$0.keptExistingAudio
        }
    }

    /// Which of two journalled attempts is the newer one.
    ///
    /// A persisted generation identity decides when both rows carry one, which
    /// is how a failed retry is known to supersede an older success even when
    /// its clock is the same. Legacy runs predate attempts, so their event
    /// order decides instead.
    private static func journalAttemptIsNewer(
        _ candidate: [PreparationJournalEntry], than previous: [PreparationJournalEntry]
    ) -> Bool {
        let candidateAttempt = candidate.last?.status.attempt
        let previousAttempt = previous.last?.status.attempt
        if let candidateAttempt, let previousAttempt {
            if candidateAttempt.requestSequence != previousAttempt.requestSequence {
                return candidateAttempt.requestSequence > previousAttempt.requestSequence
            }
            if candidateAttempt.attemptCount != previousAttempt.attemptCount {
                return candidateAttempt.attemptCount > previousAttempt.attemptCount
            }
        }
        guard let candidateLast = candidate.last, let previousLast = previous.last else { return false }
        return preparationEntryPrecedes(previousLast, candidateLast)
    }
}
