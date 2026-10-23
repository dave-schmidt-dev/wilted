import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// The evidence kind the pipeline attaches to the worker's own report.
    /// `PodcastPreparationPipeline.resultProgress` writes it; prose details are
    /// never the question here.
    private static let workerResultEvidenceKind = "worker-result"
    /// What a worker says when it could not resolve at least one
    /// advertisement. W-INV-013 keeps the whole original rather than guess, so
    /// the episode is prepared and plays -- with every ad still in it.
    private static let uncertainAdRemovalOutcome = "uncertain"

    /// Episodes whose newest preparation kept every advertisement.
    ///
    /// `uncertain` is a succeeded run, so nothing about the episode's row says
    /// work is left: only the journal's structured outcome does. Older
    /// pipelines stopped there, and the listener was left with a prepared
    /// episode that still has its ads. This is the query that finds those rows
    /// so the Larder can offer to run the current pipeline over the original
    /// audio again.
    ///
    /// Three durable conditions:
    /// 1. The newest attempt's terminal entry succeeded and that attempt's
    ///    `worker-result` evidence says `uncertain`. Evidence is used rather
    ///    than the human detail, which older runs worded differently.
    /// 2. The newest ready revision still carries the download's own hash. A
    ///    cut revision on top means the audio on disk is not what
    ///    `PodcastPreparationPipeline.prepare` would send: it reads
    ///    `download.localURL`, but takes its source identity and the playback
    ///    it carries from the newest revision, so re-preparing would map the
    ///    listening position through the wrong timeline.
    /// 3. The download is complete and its file is still here to read.
    ///
    /// One context and one fetch per table, because every Larder load asks
    /// this: the read cost stays flat as the library grows instead of asking
    /// per episode.
    public func podcastEpisodesKeepingAds() throws -> Set<ItemID> {
        let context = ModelContext(container)
        let decoder = JSONDecoder()
        // The journal is one table shared by every request, so it is read once
        // and grouped here rather than fetched per episode.
        var journalByGeneration: [String: [PreparationJournalEntry]] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()) {
            // Pipeline invalidation markers are scheduling state, not attempts.
            guard !record.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix),
                  !record.requestID.hasPrefix(Self.resetPreparationRequestPrefix),
                  let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                  let itemID = try? ItemID(rawValue: record.itemID) else { continue }
            let generation = record.requestID + (status.attempt.map { "|" + $0.key } ?? "")
            journalByGeneration[generation, default: []].append(
                PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
            )
        }
        // The retained journal keeps earlier attempts, so the newest one has to
        // be selected before it can answer anything. A run that wrote no
        // terminal entry is still the newest attempt and fails condition 1.
        var newestAttemptByRequest: [String: [PreparationJournalEntry]] = [:]
        for entries in journalByGeneration.values {
            let ordered = entries.sorted(by: preparationEntryPrecedes)
            guard let requestID = ordered.last?.requestID else { continue }
            if let previous = newestAttemptByRequest[requestID],
               !Self.journalAttemptIsNewer(ordered, than: previous) { continue }
            newestAttemptByRequest[requestID] = ordered
        }

        let downloads = Dictionary(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
                .map { ($0.episodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        var keepingAds = Set<ItemID>()
        // A retired episode is no longer offered anything; its journal and
        // download survive exactly as they were.
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        where record.retiredAt == nil {
            guard let itemID = try? ItemID(rawValue: record.id),
                  let download = downloads[record.id],
                  download.status == PodcastDownloadStatus.completed.rawValue,
                  let downloadHash = download.contentHash,
                  // The newest revision is the source the pipeline would send.
                  readyRevisions[record.id]?.revision.contentHash == downloadHash,
                  let localURL = download.localURL.flatMap(URL.init),
                  FileManager.default.fileExists(atPath: localURL.path),
                  let entries = newestAttemptByRequest[PodcastPreparationPipeline.requestID(for: itemID)],
                  entries.last(where: { $0.status.terminal })?.status.terminalResult?.outcome == .succeeded,
                  entries.contains(where: { entry in
                      entry.status.evidence?.kind == Self.workerResultEvidenceKind
                          && entry.status.evidence?.fields["adRemovalOutcome"] == Self.uncertainAdRemovalOutcome
                  })
            else { continue }
            keepingAds.insert(itemID)
        }
        return keepingAds
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
