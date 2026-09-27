import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    public func record(preparation entry: PreparationJournalEntry) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        if let existing = records.first(where: { $0.id == entry.id }) {
            existing.itemID = entry.itemID.rawValue; existing.requestID = entry.requestID
            existing.statusData = try JSONEncoder().encode(entry.status); existing.emittedAt = entry.status.emittedAt.date
        } else { context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry)) }
        try context.save()
    }

    /// Forgets one request's journal. A request identifier names an item, not
    /// an attempt, so a second attempt writes over the first's rows; without
    /// this the first attempt's terminal row would outlive it and report the
    /// second as finished while it was still running.
    public func clearPreparationJournal(for requestID: String) throws {
        let context = ModelContext(container)
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        where record.requestID == requestID {
            context.delete(record)
        }
        try context.save()
    }

    public func preparationJournal(for requestID: String) throws -> [PreparationJournalEntry] {
        let context = ModelContext(container)
        let entries: [PreparationJournalEntry] = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()).filter { $0.requestID == requestID }.compactMap { record in
            guard let status = try? JSONDecoder().decode(PreparationStatus.self, from: record.statusData), let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
            return PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
        }
        return entries.sorted(by: preparationEntryPrecedes)
    }

    /// Deletes any earlier recovery markers for this episode and writes a
    /// fresh durable marker naming the rule that condemned it, so a launch
    /// that dies before admitting the recovery still finds it on the next
    /// one -- see `resetEpisodeIDs`/`forcedRedownloadEpisodeIDs` on
    /// `PodcastPreparationInvalidationResult`.
    private func writeInvalidationMarker(
        for itemID: ItemID, ruleID: String, needsRedownload: Bool, currentFingerprint: String,
        existingMarkers: [LocalLibrarySchemaV3Models.PreparationRecord], in context: ModelContext
    ) throws {
        for marker in existingMarkers where marker.itemID == itemID.rawValue
            && (marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                || marker.requestID.hasPrefix(Self.resetPreparationRequestPrefix)) {
            context.delete(marker)
        }
        if needsRedownload {
            let markerRequestID = Self.forcedRedownloadRequestPrefix + itemID.rawValue
            let markerID = markerRequestID + "|marker"
            let markerError = try ProducerError(
                code: .invalidRequest,
                message: "The preparation pipeline changed and this episode needs a fresh download.",
                retryable: true,
                stage: "pipeline-invalidation"
            )
            let markerEvidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
                "fingerprint": currentFingerprint,
                "requiresRedownload": "true",
                "ruleID": ruleID
            ])
            let markerStatus = try PreparationStatus(
                stage: .failed,
                detail: markerError.message,
                cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .failed, error: markerError),
                emittedAt: Timestamp(Date()),
                evidence: markerEvidence
            )
            context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(
                PreparationJournalEntry(id: markerID, itemID: itemID, requestID: markerRequestID, status: markerStatus)
            ))
        } else {
            let markerRequestID = Self.resetPreparationRequestPrefix + itemID.rawValue
            let markerID = markerRequestID + "|marker"
            let markerEvidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
                "fingerprint": currentFingerprint,
                "requiresRedownload": "false",
                "ruleID": ruleID
            ])
            let markerStatus = try PreparationStatus(
                stage: .preparing,
                detail: "The preparation pipeline changed; this episode will be prepared again.",
                cancellable: false,
                emittedAt: Timestamp(Date()),
                evidence: markerEvidence
            )
            context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(
                PreparationJournalEntry(id: markerID, itemID: itemID, requestID: markerRequestID, status: markerStatus)
            ))
        }
    }

    /// Atomically clears podcast preparation results an explicit rule
    /// condemns. The journal is the provenance record: the first pipeline
    /// event names the source revision and hash, while the terminal event
    /// names the successor revision when a cut was committed.
    ///
    /// A fingerprint drift with no rule that applies to it is left untouched
    /// -- neither the journal nor any durable outcome row is disturbed --
    /// because most pipeline-hash changes (a log message, a comment, a
    /// refactor with no output effect) do not make an existing artifact
    /// wrong. `rules` has no default: every caller must say, explicitly,
    /// what it considers incompatible.
    public func invalidateStalePodcastPreparations(
        currentFingerprint: String, rules: [PodcastPreparationInvalidationRule]
    ) throws -> PodcastPreparationInvalidationResult {
        let context = ModelContext(container)
        let decoder = JSONDecoder()
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        let podcastRecords = records.filter { $0.requestID.hasPrefix("podcast-prepare|") }
        let grouped = Dictionary(grouping: podcastRecords, by: \.requestID)
        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        let downloadByEpisode = Dictionary(uniqueKeysWithValues: downloads.map { ($0.episodeID, $0) })
        let outcomes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        var resetIDs = Set<ItemID>()
        var forcedIDs = Set<ItemID>()
        var currentIDs = Set<ItemID>()
        var reconciledIDs = Set<ItemID>()
        var mutated = false

        for (_, rows) in grouped {
            let entries = rows.compactMap { record -> PreparationJournalEntry? in
                guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                      let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
                return PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
            }.sorted(by: preparationEntryPrecedes)
            guard let itemID = entries.last?.itemID else { continue }
            let provenance = entries.lazy.compactMap(\.status.evidence)
                .first(where: { $0.kind == Self.pipelineProvenanceEvidenceKind })
            guard provenance?.fields["fingerprint"] != currentFingerprint else {
                currentIDs.insert(itemID)
                continue
            }

            let readyRevisionID = readyRevisions[itemID.rawValue]?.revisionID.rawValue
            let outcomeRecord = readyRevisionID.flatMap { revisionID in
                outcomes.first { $0.episodeID == itemID.rawValue && $0.revisionID == revisionID }
            }
            let subject = PodcastPreparationInvalidationSubject(
                episodeID: itemID,
                semanticVersion: outcomeRecord?.semanticVersion,
                pipelineFingerprint: outcomeRecord?.pipelineFingerprint ?? provenance?.fields["fingerprint"]
            )
            guard let rule = rules.first(where: { $0.applies(subject) }) else {
                // No rule condemns this drift: leave the journal and any
                // surviving recovery markers alone rather than treating a
                // harmless fingerprint change as a reason to re-prepare or
                // re-download.
                continue
            }

            let terminal = entries.last(where: { $0.status.terminal })?.status.terminalResult
            let sourceHash = provenance?.fields["sourceHash"].flatMap { $0.isEmpty ? nil : $0 }
            let sourceRevisionID = provenance?.fields["sourceRevisionID"].flatMap { $0.isEmpty ? nil : $0 }
            let download = downloadByEpisode[itemID.rawValue]
            let sourceIntact: Bool
            if download?.status == PodcastDownloadStatus.completed.rawValue,
               let sourceHash,
               download?.contentHash == sourceHash,
               let sourceURL = download?.localURL.flatMap(URL.init) {
                sourceIntact = Self.localFileContentHash(at: sourceURL) == sourceHash
            } else {
                sourceIntact = false
            }
            let preparedSuccess = terminal?.outcome == .succeeded
            let successorReplacedSource = preparedSuccess
                && (sourceHash == nil || download?.contentHash != sourceHash || sourceRevisionID != terminal?.revisionID?.rawValue)
            let needsRedownload = rule.consequence == .forceRedownload || !sourceIntact || successorReplacedSource

            for record in rows { context.delete(record) }
            for marker in records where marker.itemID == itemID.rawValue
                && (marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                    || marker.requestID.hasPrefix(Self.resetPreparationRequestPrefix)) {
                context.delete(marker)
            }
            reconciledIDs.insert(itemID)
            mutated = true
            if let outcomeRecord {
                outcomeRecord.eligibility = PodcastPreparationEligibility.invalid.rawValue
                outcomeRecord.invalidationRuleID = rule.id
            }
            try writeInvalidationMarker(
                for: itemID, ruleID: rule.id, needsRedownload: needsRedownload,
                currentFingerprint: currentFingerprint, existingMarkers: records, in: context
            )
            if needsRedownload { forcedIDs.insert(itemID) } else { resetIDs.insert(itemID) }
        }

        // Pass 2 covers preparation outcomes left `.current` with no journal
        // group for the loop above to walk. That is not "no audio change,
        // so no journal was ever written" -- `PodcastPreparationPipeline.
        // prepare()` calls `journalTerminal` on both the success and catch
        // paths, cut or not -- it is a journal that was cleared or never
        // completed for this ready revision, e.g. a second run's
        // `clearPreparationJournal` wiping the
        // first run's entry before the second run itself finished. Either
        // way the provenance a redownload decision needs -- the source hash
        // recorded at download time, before any cut -- is gone with the
        // journal. `sourceIntact` cannot be reconstructed here: the download
        // record's `contentHash` is the CURRENT file's hash, so comparing it
        // against a fresh re-hash of that same file is always true, even
        // when the file is already-cut output. Resetting in place on that
        // false signal would re-run the pipeline over already-cut audio.
        // Always force a redownload instead -- it costs bandwidth, never
        // correctness.
        let visitedIDs = reconciledIDs.union(currentIDs)
        for outcomeRecord in outcomes where outcomeRecord.eligibility == PodcastPreparationEligibility.current.rawValue {
            guard let itemID = try? ItemID(rawValue: outcomeRecord.episodeID), !visitedIDs.contains(itemID),
                  let ready = readyRevisions[itemID.rawValue], ready.revisionID.rawValue == outcomeRecord.revisionID,
                  outcomeRecord.pipelineFingerprint != currentFingerprint else { continue }
            let subject = PodcastPreparationInvalidationSubject(
                episodeID: itemID, semanticVersion: outcomeRecord.semanticVersion,
                pipelineFingerprint: outcomeRecord.pipelineFingerprint
            )
            guard let rule = rules.first(where: { $0.applies(subject) }) else { continue }
            let needsRedownload = true
            outcomeRecord.eligibility = PodcastPreparationEligibility.invalid.rawValue
            outcomeRecord.invalidationRuleID = rule.id
            mutated = true
            reconciledIDs.insert(itemID)
            try writeInvalidationMarker(
                for: itemID, ruleID: rule.id, needsRedownload: needsRedownload,
                currentFingerprint: currentFingerprint, existingMarkers: records, in: context
            )
            if needsRedownload { forcedIDs.insert(itemID) } else { resetIDs.insert(itemID) }
        }

        for marker in records where marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix) {
            guard let itemID = try? ItemID(rawValue: marker.itemID) else { continue }
            guard !reconciledIDs.contains(itemID) else { continue }
            if currentIDs.contains(itemID) {
                context.delete(marker)
                mutated = true
            } else {
                forcedIDs.insert(itemID)
            }
        }
        for marker in records where marker.requestID.hasPrefix(Self.resetPreparationRequestPrefix) {
            guard let itemID = try? ItemID(rawValue: marker.itemID) else { continue }
            guard !reconciledIDs.contains(itemID) else { continue }
            if currentIDs.contains(itemID) {
                context.delete(marker)
                mutated = true
            } else {
                resetIDs.insert(itemID)
            }
        }
        resetIDs.subtract(forcedIDs)
        if mutated { try context.save() }
        return PodcastPreparationInvalidationResult(
            resetEpisodeIDs: resetIDs.sorted { $0.rawValue < $1.rawValue },
            forcedRedownloadEpisodeIDs: forcedIDs.sorted { $0.rawValue < $1.rawValue }
        )
    }

    /// Re-hashes the bytes instead of trusting two persisted copies of the
    /// same download hash. A missing, unreadable, or changing file is not
    /// positive evidence that stale preparation can safely reuse its source.
    private static func localFileContentHash(at url: URL) -> String? {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A forced download has replaced the ambiguous prepared bytes with a
    /// fresh source. Convert its durable marker instead of clearing it: if the
    /// app exits before preparation is admitted, the next launch still knows
    /// to resume without downloading the same source again.
    public func markForcedRedownloadCompleted(
        for episodeID: ItemID,
        currentFingerprint: String
    ) throws {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
        let forcedRequestID = Self.forcedRedownloadRequestPrefix + episodeID.rawValue
        guard rows.contains(where: { $0.requestID == forcedRequestID }) else { return }
        for row in rows where row.itemID == episodeID.rawValue
            && (row.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
                || row.requestID.hasPrefix(Self.resetPreparationRequestPrefix)) {
            context.delete(row)
        }
        let resetRequestID = Self.resetPreparationRequestPrefix + episodeID.rawValue
        let evidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
            "fingerprint": currentFingerprint,
            "requiresRedownload": "false"
        ])
        let status = try PreparationStatus(
            stage: .preparing,
            detail: "The fresh download will be prepared with the current pipeline.",
            cancellable: false,
            emittedAt: Timestamp(Date()),
            evidence: evidence
        )
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: resetRequestID + "|marker", itemID: episodeID,
            requestID: resetRequestID, status: status
        )))
        try context.save()
    }

    /// Whether pipeline invalidation still requires bytes from the publisher.
    ///
    /// This is queried at transfer time, not only during bootstrap. A queued
    /// download claim can survive an app exit, and its automation resume must
    /// retain the forced-download requirement instead of accepting the stale
    /// file that caused the marker.
    public func requiresForcedRedownload(for episodeID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        let requestID = Self.forcedRedownloadRequestPrefix + episodeID.rawValue
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
            .contains { $0.requestID == requestID }
    }

    /// What the preparation that produced this revision removed.
    ///
    /// `preparationRuns()` decodes every journalled status in the library,
    /// which is the wrong shape for a lookup the player performs each time it
    /// loads a transcript. Only the terminal statuses of this item are
    /// decoded, and only a successful one carries a timeline.
    ///
    /// The revision is part of the question rather than a detail of the
    /// answer. Cutting an episode changes its bytes and therefore its
    /// identity, so a timeline belongs to exactly one revision; drawing the
    /// newest success over whatever is ready now would put cut markers on
    /// uncut audio if a re-download or a prune ever moved the ready revision
    /// back. Journal entries old enough to carry no revision are skipped, and
    /// they predate timelines anyway.
    public func latestPreparationTimeline(
        for itemID: ItemID,
        revisionID: RevisionID
    ) throws -> PreparationStatus.PreparationTimeline? {
        let raw = itemID.rawValue
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.itemID == raw },
            sortBy: [SortDescriptor(\.emittedAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.maximumTimelineLookupRecords
        let decoder = JSONDecoder()
        for record in try context.fetch(descriptor) {
            guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                  status.terminal,
                  let result = status.terminalResult,
                  result.outcome == .succeeded,
                  result.revisionID == revisionID,
                  let timeline = status.timeline else { continue }
            return timeline
        }
        return nil
    }

    /// A ceiling on the newest-first scan above. An item that has been
    /// prepared repeatedly still finds its last success within a few rows,
    /// and a library whose journal was never pruned should not turn one
    /// transcript load into a full-table decode.
    private static let maximumTimelineLookupRecords = 64

}
