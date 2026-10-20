import CryptoKit
import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    public func record(preparation entry: PreparationJournalEntry) throws {
        let context = ModelContext(container)
        // Delayed callbacks cannot append to, or overwrite, another generation.
        if let attempt = entry.status.attempt {
            guard entry.id.hasPrefix(entry.requestID + "|" + attempt.key + "|") else { return }
            let ticketID = WorkTicketKind.podcastPreparation.rawValue + "|" + entry.itemID.rawValue
            var ticketQuery = FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>(
                predicate: #Predicate { $0.id == ticketID }
            )
            ticketQuery.fetchLimit = 1
            guard let ticket = try context.fetch(ticketQuery).first,
                  ticket.requestSequence == attempt.requestSequence,
                  ticket.attemptCount == attempt.attemptCount,
                  ticket.state == WorkTicketState.running.rawValue else { return }
        }
        let recordID = entry.id
        var descriptor = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        let records = try context.fetch(descriptor)
        preparationJournalLookupRowsRead += records.count
        if let existing = records.first {
            guard entry.status.emittedAt.date >= existing.emittedAt else { return }
            existing.itemID = entry.itemID.rawValue; existing.requestID = entry.requestID
            existing.statusData = try JSONEncoder().encode(entry.status); existing.emittedAt = entry.status.emittedAt.date
        } else { context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry)) }
        try context.save()
    }

    /// Clears legacy unbound rows for compatibility callers. Bound generations
    /// retain their revision provenance and cannot be erased by failed admission.
    public func clearPreparationJournal(for requestID: String) throws {
        let context = ModelContext(container)
        let query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        for record in try context.fetch(query) {
            // Legacy callers cannot erase revision provenance retained by bound attempts.
            if (try? JSONDecoder().decode(PreparationStatus.self, from: record.statusData))?.attempt == nil {
                context.delete(record)
            }
        }
        try context.save()
    }

    public func preparationJournal(for requestID: String) throws -> [PreparationJournalEntry] {
        let context = ModelContext(container)
        var query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == requestID },
            sortBy: [SortDescriptor(\.emittedAt, order: .reverse)]
        )
        query.fetchLimit = 256
        let entries: [PreparationJournalEntry] = try context.fetch(query).compactMap { record in
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
        let markers = try maintenanceInvalidationMarkers(in: context)
        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        let downloadByEpisode = Dictionary(uniqueKeysWithValues: downloads.map { ($0.episodeID, $0) })
        let outcomes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>())
        let readyRevisions = try newestReadyRevisionsByItemID(in: context)
        let preparationKind = WorkTicketKind.podcastPreparation.rawValue
        let tickets = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>(predicate: #Predicate { $0.kind == preparationKind }))
        let ticketAttempts: [String: PreparationAttemptIdentity] = Dictionary(tickets.compactMap { ticket in
            (try? PreparationAttemptIdentity(requestSequence: ticket.requestSequence,
                                             attemptCount: ticket.attemptCount)).map { (ticket.subjectID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        // Selection closures capture value-only identity, never SwiftData rows.
        var currentOutcomeKeys = Set<String>()
        var currentOutcomeProducedAt: [String: Date] = [:]
        for outcome in outcomes where outcome.eligibility == PodcastPreparationEligibility.current.rawValue {
            currentOutcomeKeys.insert(outcome.episodeID + "|" + outcome.revisionID)
            currentOutcomeProducedAt[outcome.episodeID + "|" + outcome.revisionID] = outcome.producedAt
        }
        var resetIDs = Set<ItemID>()
        var forcedIDs = Set<ItemID>()
        var currentIDs = Set<ItemID>()
        var reconciledIDs = Set<ItemID>()
        var mutated = false
        // Each item's candidates come from bounded, generation-exact reads, not a history window.
        typealias Generation = (rows: [LocalLibrarySchemaV3Models.PreparationRecord], entries: [PreparationJournalEntry], itemID: ItemID)
        var generationsByItemID: [ItemID: [Generation]] = [:]
        let itemRaws: Set<String> = Set(ticketAttempts.keys).union(downloads.map(\.episodeID)).union(outcomes.map(\.episodeID)).union(markers.map(\.itemID))
        for raw in itemRaws.sorted() {
            guard let itemID = try? ItemID(rawValue: raw) else { continue }
            let readyID = readyRevisions[raw]?.revisionID.rawValue
            let producedAt = readyID.flatMap { currentOutcomeProducedAt[raw + "|" + $0] }
            let generations = try maintenanceCandidateGenerations(
                for: itemID, ticketAttempt: ticketAttempts[raw], readyRevisionID: readyID,
                currentOutcomeProducedAt: producedAt, in: context, decoder: decoder)
            if !generations.isEmpty { generationsByItemID[itemID] = generations }
        }
        func newerGeneration(_ lhs: Generation, _ rhs: Generation) -> Bool {
            let left = lhs.entries.first?.status.attempt
            let right = rhs.entries.first?.status.attempt
            if left?.requestSequence != right?.requestSequence {
                return (left?.requestSequence ?? -1) > (right?.requestSequence ?? -1)
            }
            if left?.attemptCount != right?.attemptCount {
                return (left?.attemptCount ?? -1) > (right?.attemptCount ?? -1)
            }
            guard let leftLast = lhs.entries.last, let rightLast = rhs.entries.last else { return false }
            return preparationEntryPrecedes(rightLast, leftLast)
        }
        // Select once before evaluating any rule. Dictionary order must never
        // let an old failure condemn a newer in-flight source generation.
        var selected: [Generation] = []
        for (itemID, candidates) in generationsByItemID {
            let readyID = readyRevisions[itemID.rawValue]?.revisionID.rawValue
            let hasCurrentOutcome: Bool
            if let readyID {
                hasCurrentOutcome = currentOutcomeKeys.contains(itemID.rawValue + "|" + readyID)
            } else { hasCurrentOutcome = false }
            var chosen: Generation?
            for candidate in candidates {
                if hasCurrentOutcome {
                    let terminal = candidate.entries.last(where: { $0.status.terminal })?.status.terminalResult
                    guard terminal?.outcome == .succeeded, terminal?.revisionID?.rawValue == readyID else { continue }
                }
                if let previous = chosen {
                    if newerGeneration(candidate, previous) { chosen = candidate }
                } else { chosen = candidate }
            }
            if let chosen { selected.append(chosen) }
        }
        for generation in selected {
            let rows = generation.rows
            let entries = generation.entries
            let itemID = generation.itemID
            let readyRevisionID = readyRevisions[itemID.rawValue]?.revisionID.rawValue
            let terminal = entries.last(where: { $0.status.terminal })?.status.terminalResult
            let outcomeRecord = readyRevisionID.flatMap { revisionID in
                outcomes.first { $0.episodeID == itemID.rawValue && $0.revisionID == revisionID }
            }
            // Only the generation that proved this Ready revision can describe its source.
            // Newer failures/running work must not replace that generation's provenance.
            if outcomeRecord != nil {
                guard terminal?.outcome == .succeeded,
                      terminal?.revisionID?.rawValue == readyRevisionID else { continue }
            }
            let provenance = entries.lazy.compactMap(\.status.evidence)
                .first(where: { $0.kind == Self.pipelineProvenanceEvidenceKind })
            // Matching legacy failure/progress with no output has nothing to
            // invalidate. It remains diagnostic history, but cannot clear a
            // recovery marker without generation/revision proof.
            if provenance?.fields["fingerprint"] == currentFingerprint,
               readyRevisionID == nil, outcomeRecord == nil, terminal?.outcome != .succeeded {
                continue
            }
            if provenance?.fields["fingerprint"] == currentFingerprint,
               (terminal?.outcome == .succeeded && terminal?.revisionID?.rawValue == readyRevisionID)
                || (outcomeRecord == nil && entries.first?.status.attempt != nil
                    && provenance?.fields["sourceRevisionID"] == readyRevisionID) {
                currentIDs.insert(itemID)
                continue
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

            let terminalEvidence = entries.last(where: { $0.status.terminal })?.status.evidence
            var hasPreparedOutcome = false
            for outcome in outcomes where outcome.episodeID == itemID.rawValue { hasPreparedOutcome = true; break }
            // A legacy failed terminal may prove the untouched original source
            // directly. Never pair its source identity with another legacy row,
            // or apply this exception to an episode with prepared-output history.
            let legacyFailure = entries.first?.status.attempt == nil && terminal?.outcome == .failed
                && !hasPreparedOutcome && terminalEvidence?.kind == Self.pipelineProvenanceEvidenceKind
            let sourceEvidence = legacyFailure ? terminalEvidence : provenance
            let sourceHash = sourceEvidence?.fields["sourceHash"].flatMap { $0.isEmpty ? nil : $0 }
            let sourceRevisionID = sourceEvidence?.fields["sourceRevisionID"].flatMap { $0.isEmpty ? nil : $0 }
            let exactLegacySource = legacyFailure && readyRevisionID != nil && sourceRevisionID == readyRevisionID
            let download = downloadByEpisode[itemID.rawValue]
            let sourceIntact: Bool
            if (entries.first?.status.attempt != nil || exactLegacySource),
               (terminal?.outcome == .succeeded && terminal?.revisionID?.rawValue == readyRevisionID)
                || (outcomeRecord == nil && sourceRevisionID == readyRevisionID),
               download?.status == PodcastDownloadStatus.completed.rawValue,
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
            for marker in markers where marker.itemID == itemID.rawValue
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
                currentFingerprint: currentFingerprint, existingMarkers: markers, in: context
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
                currentFingerprint: currentFingerprint, existingMarkers: markers, in: context
            )
            if needsRedownload { forcedIDs.insert(itemID) } else { resetIDs.insert(itemID) }
        }
        for marker in markers where marker.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix) {
            guard let itemID = try? ItemID(rawValue: marker.itemID) else { continue }
            guard !reconciledIDs.contains(itemID) else { continue }
            if currentIDs.contains(itemID) {
                context.delete(marker)
                mutated = true
            } else {
                forcedIDs.insert(itemID)
            }
        }
        for marker in markers where marker.requestID.hasPrefix(Self.resetPreparationRequestPrefix) {
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
        let forcedRequestID = Self.forcedRedownloadRequestPrefix + episodeID.rawValue
        var markerQuery = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == forcedRequestID }
        )
        markerQuery.fetchLimit = 1
        let markers = try context.fetch(markerQuery)
        preparationMaintenanceRowsRead += markers.count
        guard !markers.isEmpty else { return }
        let itemID = episodeID.rawValue
        let forced = Self.forcedRedownloadRequestPrefix
        let reset = Self.resetPreparationRequestPrefix
        let rows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate {
                $0.itemID == itemID && ($0.requestID.starts(with: forced) || $0.requestID.starts(with: reset))
            }
        ))
        preparationMaintenanceRowsRead += rows.count
        for row in rows { context.delete(row) }
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
        var query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        query.fetchLimit = 1
        let rows = try context.fetch(query)
        preparationMaintenanceRowsRead += rows.count
        return !rows.isEmpty
    }

    /// What the preparation that produced this revision removed.
    ///
    /// `preparationRuns()` decodes every journalled status in the library,
    /// which is the wrong shape for a lookup the player performs each time it
    /// loads a transcript. A bounded recent scan handles the usual case;
    /// the current outcome anchors an older Ready-proving generation on a miss.
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
        let outcomeID = raw + "|" + revisionID.rawValue
        var outcomeQuery = FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>(
            predicate: #Predicate { $0.id == outcomeID }
        )
        outcomeQuery.fetchLimit = 1
        guard let outcome = try context.fetch(outcomeQuery).first,
              outcome.eligibility == PodcastPreparationEligibility.current.rawValue else { return nil }
        let generations = try maintenanceCandidateGenerations(
            for: itemID, ticketAttempt: nil, readyRevisionID: revisionID.rawValue,
            currentOutcomeProducedAt: outcome.producedAt, in: context, decoder: decoder)
        for generation in generations {
            for entry in generation.entries.reversed() where entry.status.terminal {
                guard let result = entry.status.terminalResult, result.outcome == .succeeded,
                      result.revisionID == revisionID, let timeline = entry.status.timeline else { continue }
                return timeline
            }
        }
        return nil
    }

    /// A ceiling on the newest-first scan above. An item that has been
    /// prepared repeatedly normally finds its last success within a few rows;
    /// older Ready proof uses the separately bounded maintenance lookup.
    private static let maximumTimelineLookupRecords = 64

}
