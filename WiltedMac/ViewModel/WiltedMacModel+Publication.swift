import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

extension WiltedMacModel {
#if canImport(WiltedProducer)
    func applyPodcastPlaybackObservationForTesting(itemID: ItemID?, fault: PlaybackControllerError?) {
        applyPodcastPlaybackObservation(itemID: itemID, fault: fault)
    }
#endif

    /// Deterministic test seam for the natural-completion path.
    ///
    /// Production reaches `handlePodcastPlaybackFinished` only through
    /// `playback?.playbackDidFinishHandler`, which the audio backend fires
    /// from its own completion callback -- not something a test can trigger
    /// without a real, timed audio file. Driving `playback.completed` to
    /// `true` first with `simulatePodcastPlaybackReachedEndForTesting()` and
    /// then calling this reaches the same guard and search logic natural
    /// completion does.
    func simulatePodcastPlaybackFinishedForTesting() {
#if canImport(WiltedProducer)
        handlePodcastPlaybackFinished()
#endif
    }

    /// Writes the terminal checkpoint that audio reaching the end writes, and
    /// nothing else.
    ///
    /// `markCurrentPlaybackCompleted()` used to serve as this shim, but it now
    /// also retires the row from the Larder, so using it here would take the
    /// finished episode out before the handler under test ever saw it.
    func simulatePodcastPlaybackReachedEndForTesting() async {
#if canImport(WiltedProducer)
        guard let playback else { return }
        try? await playback.markCompleted()
        refreshPlaybackReadout()
        await reloadLibraryRows()
#endif
    }

#if canImport(WiltedProducer)
    func update(_ status: PreparationStatus) {
        let phase: WiltedMacPreparation.Phase
        switch status.stage {
        case .preparing: phase = .preparing
        case .fetching: phase = .preparing
        case .extracting: phase = .extracting
        case .synthesizing: phase = .synthesizing
        case .assembling: phase = .assembling
        case .saving: phase = .saving
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        preparation = WiltedMacPreparation(
            phase: phase, detail: status.detail, fraction: status.fraction, cancellable: status.cancellable
        )
    }

    @discardableResult
    func queuePreparedPublication(itemID: ItemID, chunkedFile: AudioChunkedFile? = nil) async -> Bool {
        guard let store, let syncLifecycle,
              let article = try? await store.article(for: itemID),
              let stored = try? await store.readyRevision(for: itemID),
              let bytes = try? Data(contentsOf: stored.mediaURL),
              let chunkedFile = chunkedFile ?? (try? AudioChunking.chunk(bytes)) else { return false }
        let revisionResult = await syncLifecycle.queueRevision(stored.revision, chunkedFile: chunkedFile)
        let itemResult = await syncLifecycle.queueItem(article, currentRevisionID: stored.revision.revisionID)
        guard case .success = itemResult, case .success = revisionResult else { return false }
        articlePublicationCount += 1
        return true
    }

    /// Re-queues ready revisions that are durable locally but absent from the outbound queue.
    ///
    /// Publication is otherwise queued only at the instant a preparation completes, so any
    /// enqueue that failed then stays unqueued forever: the revision cannot be re-derived by
    /// re-preparing it either, because the same text and settings derive the same immutable
    /// revision ID and `saveReadyRevision` rejects a second media path for it. Reconciling
    /// from durable local state before an upload is what makes the queue recoverable, and it
    /// matches W-INV-007's rule that local state, not CloudKit, is the source of truth.
    ///
    /// Membership is checked rather than sync status so a partially queued item repairs
    /// itself, and a revision whose media file is gone is skipped instead of failing the
    /// whole upload. The item record has one stable identity across revisions, so an
    /// acknowledgement counts only when its persisted pointer names the ready revision.
    func queueUnpublishedReadyRevisions() async -> Bool {
        guard let store, let syncLifecycle else { return false }
        guard let articles = try? await store.articles() else { return false }
        let state = try? await store.syncRepositoryState()
        let queued = Set((state?.pendingChanges.map(\.recordID) ?? []) + Array(state?.remoteAcknowledgedRecordIDs ?? []))
        var didQueue = false
        for article in articles where !article.isDeleted {
            guard let stored = try? await store.readyRevision(for: article.itemID),
                  FileManager.default.fileExists(atPath: stored.mediaURL.path),
                  let bytes = try? Data(contentsOf: stored.mediaURL),
                  let chunkedFile = try? AudioChunking.chunk(bytes),
                  let revisionRecordID = try? WiltedRecordID.revision(article.itemID, stored.revision.revisionID) else { continue }
            let chunkRecordIDs = chunkedFile.manifest.chunks.compactMap {
                try? WiltedRecordID.revisionChunk(article.itemID, stored.revision.revisionID, index: $0.index)
            }
            guard let itemRecordID = try? WiltedRecordID.item(article.itemID) else { continue }
            let revisionExpected = Set([revisionRecordID] + chunkRecordIDs)
            let hasCurrentItemPointer = state.map { state in
                let pointsToReadyRevision: (WiltedRecordEnvelope?) -> Bool = { record in
                    guard case let .string(revisionID)? = record?.fields["currentRevisionID"] else { return false }
                    return revisionID == stored.revision.revisionID.rawValue
                }
                if state.pendingChanges.contains(where: {
                    $0.recordID == itemRecordID && pointsToReadyRevision($0.record)
                }) {
                    return true
                }
                return state.remoteAcknowledgedRecordIDs.contains(itemRecordID) &&
                    state.records.contains(where: {
                        $0.id == itemRecordID && pointsToReadyRevision($0)
                    })
            } ?? false
            guard !revisionExpected.isSubset(of: queued) || !hasCurrentItemPointer else { continue }
            if revisionExpected.isSubset(of: queued) {
                if case .success = await syncLifecycle.queueItem(article, currentRevisionID: stored.revision.revisionID) {
                    didQueue = true
                }
            } else {
                didQueue = await queuePreparedPublication(itemID: article.itemID, chunkedFile: chunkedFile) || didQueue
            }
        }
        let hasSendablePending = (try? await store.syncRepositoryState())?.sendableChanges.isEmpty == false
        return didQueue || hasSendablePending
    }

    func queueCurrentPlaybackCheckpoint() async {
        await refreshLifetimeStatistics()
        guard let store, let syncLifecycle, let playbackItemID = playback?.itemID,
              selectedArticleID == playbackItemID.rawValue,
              articles.contains(where: { $0.id == playbackItemID.rawValue }),
              let playbackRevisionID = playback?.revisionID,
              let state = try? await store.playbackState(for: playbackItemID, revisionID: playbackRevisionID) else { return }
        let sidecar = try? await store.playbackSidecar(for: playbackItemID, revisionID: playbackRevisionID)
        let opaque = sidecar.map {
            WiltedOpaqueSidecar(changeTag: $0.changeTag, encodedSystemFields: $0.encodedSystemFields)
        }
        if case .success = await syncLifecycle.queuePlayback(state, sidecar: opaque) {
            articlePlaybackCheckpointCount += 1
        }
    }

    /// Removes an article from the library.
    ///
    /// Marks the stored article deleted and records a local tombstone, which
    /// is what `refresh()` and the sync repository both already read. The
    /// library had no removal path at all, so anything prepared once —
    /// including a stray fixture row written before fixture mode moved to a
    /// temporary directory — stayed on screen permanently.
    ///
    /// Local only. Publishing the tombstone to CloudKit rides the existing
    /// pending-change path and is not triggered from here.
    func removeArticle(_ article: WiltedMacArticle) {
#if canImport(WiltedProducer)
        guard let store else { return }
        undoableRemoval = nil
        if selectedArticleID == article.id {
            selectedArticleID = nil
            isNowPlaying = false
            currentTranscript = nil
            // Nothing is loaded any more, so the widget has to stop showing it.
            publishNowPlaying(force: true)
        }
        Task { [weak self] in
            guard let self else { return }
            guard let itemID = try? ItemID(rawValue: article.id) else { return }
            guard let stored = try? await store.articles().first(where: { $0.itemID == itemID }) else { return }
            guard let deleted = try? Article(
                itemID: stored.itemID, canonicalURL: stored.canonicalURL, title: stored.title,
                source: stored.source, author: stored.author, publishedTime: stored.publishedTime,
                createdAt: stored.createdAt, isDeleted: true
            ) else { return }
            try? await store.save(article: deleted)
            // Keyed by item, deliberately. `record(tombstone:)` upserts on `id`,
            // and this is the only path in the producer that writes one, so
            // removing the same article twice leaves one row rather than two.
            let tombstone = LocalLibraryTombstone(
                id: itemID.rawValue,
                itemID: itemID,
                requestedAt: Timestamp(Date())
            )
            try? await store.record(tombstone: tombstone)
            self.refresh()
        }
#endif
    }

    /// Fetches and stores the transcript for an already-prepared article.
    ///
    /// Transcript persistence shipped on 2026-08-23; anything prepared before
    /// that has audio and no text, and re-preparing cannot fix it because the
    /// revision ID is derived from the same content and `saveReadyRevision`
    /// refuses to re-point an existing revision. The text is re-extracted from
    /// the canonical URL and saved against the existing revision, so no new
    /// revision, media file, or synthesis run is created.
    func backfillCurrentTranscript() {
#if canImport(WiltedProducer)
        guard !isBackfillingTranscript, let store, let article = currentArticle else { return }
        isBackfillingTranscript = true
        transcriptBackfillStatus = "Fetching article text…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBackfillingTranscript = false }
            guard let itemID = try? ItemID(rawValue: article.id),
                  let revision = try? await store.readyRevision(for: itemID) else {
                self.transcriptBackfillStatus = "This article has no saved audio to attach text to."
                return
            }
            do {
                let extracted = try await NativeArticleExtractor().extract(article.url) { stage, _ in
                    Task { @MainActor [weak self] in
                        self?.transcriptBackfillStatus = "Fetching article text: \(stage.rawValue)"
                    }
                }
                let oversized = extracted.body.utf8.count > Transcript.maximumTextUTF8Bytes
                let transcript = try Transcript(
                    itemID: itemID,
                    revisionID: revision.revision.revisionID,
                    availability: oversized ? .oversized : .available,
                    text: oversized ? nil : extracted.body,
                    updatedAt: Timestamp(Date())
                )
                try await store.save(transcript: transcript)
                await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                self.transcriptBackfillStatus = oversized
                    ? "The article text is too large to store."
                    : nil
            } catch {
                // Named, not swallowed: the reader has to know whether to retry.
                self.transcriptBackfillStatus = Self.backfillFailureMessage(error)
            }
        }
#endif
    }

    /// A sentence a reader can act on, never a raw error dump.
    ///
    /// `ArticleExtractionError` already writes for people, so it passes through.
    /// Transport failures are matched by code rather than rendered: a `URLError`
    /// only has readable `localizedDescription` when URLSession populated it, and
    /// otherwise falls back to `The operation couldn't be completed.
    /// (NSURLErrorDomain error -1009.)`. Everything unmatched collapses to one
    /// generic line, because printing a domain and code into the player is the
    /// same defect as printing `1743` for a duration.
    static func backfillFailureMessage(_ error: Error) -> String {
#if canImport(WiltedProducer)
        if let extraction = error as? ArticleExtractionError, let text = extraction.errorDescription {
            return text
        }
#endif
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Wilted could not reach the article. Check your connection and try again."
            case .timedOut:
                return "The article server did not respond in time. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Wilted could not reach that site."
            default:
                break
            }
        }
        return "Could not fetch the article text. Check the link and try again."
    }

    /// Reloads the preparation run history behind the Processor destination.
    func refreshProcessorRuns() {
#if canImport(WiltedProducer)
        guard let store else { return }
        processorRunsRefreshGeneration &+= 1
        let generation = processorRunsRefreshGeneration
        Task { [weak self] in
            guard let self else { return }
            guard let runs = try? await store.preparationRuns() else { return }
            // Episodes prepare through the same journal as articles, so the
            // history has to be able to name both kinds of item.
            var titles = Dictionary(
                uniqueKeysWithValues: ((try? await store.articles()) ?? [])
                    .map { ($0.itemID.rawValue, ($0.title, $0.source)) }
            )
            let feedTitles = Dictionary(
                uniqueKeysWithValues: ((try? await store.podcastFeeds()) ?? []).map { ($0.itemID, $0.title) }
            )
            for episode in (try? await store.podcastEpisodes()) ?? [] {
                titles[episode.itemID.rawValue] = (episode.title, feedTitles[episode.feedID] ?? "Podcast")
            }
            for dismissal in (try? await store.dismissedPodcastEpisodes()) ?? [] {
                titles[dismissal.episodeID.rawValue] = (
                    dismissal.title ?? "Removed podcast episode",
                    dismissal.feedID.flatMap { feedTitles[$0] } ?? "Removed podcast"
                )
            }
            let durableRuns = runs.map { run in
                let known = titles[run.itemID.rawValue]
                let outcome: WiltedMacProcessorRun.Outcome = if !run.isTerminal {
                    .running
                } else {
                    switch run.outcome {
                    case .succeeded: .succeeded
                    case .cancelled: .cancelled
                    default: .failed
                    }
                }
                let isPodcast = run.requestID.hasPrefix(Self.podcastRequestPrefix)
                let events = Self.processorEvents(for: run)
                let detail = run.failure?.message ?? run.detail
                let timeline = run.entries.last(where: { $0.status.terminal })?.status.timeline
                return WiltedMacProcessorRun(
                    id: run.requestID,
                    itemID: run.itemID.rawValue,
                    isPodcast: isPodcast,
                    // A run that failed before extraction never learned a
                    // title, so the item identity is all there is to name it.
                    title: known?.0 ?? "Unknown item",
                    source: known?.1 ?? run.itemID.rawValue,
                    stage: run.stage.rawValue,
                    detail: detail,
                    narrative: Self.processorNarrative(isPodcast: isPodcast, outcome: outcome, detail: detail,
                                                       events: events),
                    fraction: run.fraction,
                    outcome: outcome,
                    updatedAt: run.updatedAt.date,
                    events: events,
                    timeline: timeline
                )
            }
            guard generation == self.processorRunsRefreshGeneration else { return }

            let trackedItemIDs = Set(self.podcastPreparationTasks.keys)
            self.projectedProcessorRuns = self.projectedProcessorRuns.filter {
                trackedItemIDs.contains($0.key)
            }
            var mergedRuns = durableRuns.filter { run in
                guard run.isPodcast, trackedItemIDs.contains(run.itemID) else { return true }
                guard let projected = self.projectedProcessorRuns[run.itemID] else {
                    // A queued task has not reached the journal yet. Do not
                    // redraw the failed row from its previous attempt.
                    return false
                }
                // The durable row wins once it is at least as new as the
                // projection, including a terminal row written at completion.
                return run.updatedAt >= projected.updatedAt
            }
            for projected in self.projectedProcessorRuns.values
                where trackedItemIDs.contains(projected.itemID)
                    && !mergedRuns.contains(where: { $0.id == projected.id }) {
                mergedRuns.insert(projected, at: 0)
            }
            self.processorRuns = mergedRuns
        }
#endif
    }

    static let podcastRequestPrefix = "podcast-prepare|"

    /// The legacy terminal detail, from builds that journalled only that the
    /// run had finished.
    nonisolated static let legacyPreparedDetail = "Prepared."

    /// What a finished run recorded it did, so "Synced transcript" alone never
    /// stands in for "were the advertisements removed?" after a relaunch.
    ///
    /// Current builds journal the outcome summary as the terminal row. Older
    /// ones wrote "Prepared.", but their `pipeline.complete` row still counted
    /// the advertisements, and zero there is the honest answer for an episode
    /// the build that never loaded the detector marked prepared.
    nonisolated static func recordedSummary(of run: PreparationRunSummary?) -> String? {
        guard let run, run.isTerminal, run.outcome == .succeeded else { return nil }
        if run.detail != legacyPreparedDetail, !run.detail.isEmpty { return run.detail }
        let completion = run.entries.last { $0.id.hasSuffix("|pipeline.complete") }?.status.detail ?? ""
        guard let match = completion.firstMatch(of: #/^(\d+) advertisements?/#),
              let count = Int(match.1) else { return nil }
        let ads = switch count {
        case 0: "no ads found"
        case 1: "1 ad removed"
        default: "\(count) ads removed"
        }
        return "\(PodcastPreparationResult.readyLabel) · \(ads) · \(PodcastPreparationResult.transcriptStep(.aligned))"
    }

    /// What a finished preparation removed, counted per kind.
    ///
    /// Three kinds are not one number. A listener who sees "3 ads removed"
    /// cannot tell a show that ran two sponsor reads from one that ran its own
    /// trailer twice, and those are different enough that the second is not
    /// really an ad removal at all. Each removal journals its kind alongside
    /// its boundaries, so the summary counts them separately rather than
    /// collapsing them.
    ///
    /// Returns nil when no removal in the run carries a kind, which is every
    /// journal written before kinds existed -- the caller keeps its previous
    /// wording rather than claiming a breakdown it does not have.
    nonisolated static func removalKindSummary(of run: PreparationRunSummary?) -> String? {
        guard let run, run.isTerminal, run.outcome == .succeeded else { return nil }
        // A run that was retried inside one request journals its spans twice.
        // Keying by ordinal keeps the latest attempt's count rather than the
        // sum of every attempt.
        var kindByOrdinal: [String: String] = [:]
        for entry in run.entries {
            guard let evidence = entry.status.evidence, evidence.kind == "advertisement",
                  let ordinal = evidence.fields["ordinal"] else { continue }
            kindByOrdinal[ordinal] = evidence.fields["removalKind"] ?? PodcastAdSegment.defaultKind
        }
        guard !kindByOrdinal.isEmpty else { return nil }

        var counts: [String: Int] = [:]
        for kind in kindByOrdinal.values { counts[kind, default: 0] += 1 }
        // Recognised kinds lead, in the taxonomy's own order, so a paid read
        // is never buried under credits. Anything else is a worker the app is
        // newer than; it is still shown, sorted, rather than dropped.
        let known = PodcastAdSegment.recognisedKinds.filter { counts[$0] != nil }
        let unknown = counts.keys.filter { !PodcastAdSegment.recognisedKinds.contains($0) }.sorted()
        let figures = (known + unknown).map { "\(counts[$0] ?? 0) \($0)" }
        return figures.joined(separator: ", ") + " removed"
    }

    /// The prepared-row summary: a per-kind removal breakdown when the run
    /// journalled one, and the previous wording when it did not.
    nonisolated static func preparedSummary(
        of run: PreparationRunSummary?, timing: TranscriptTiming
    ) -> String {
        let step = PodcastPreparationResult.transcriptStep(timing)
        if let kinds = removalKindSummary(of: run) {
            return "\(PodcastPreparationResult.readyLabel) · \(kinds) · \(step)"
        }
        return recordedSummary(of: run) ?? "\(PodcastPreparationResult.readyLabel) · \(step)"
    }

    /// Where a cut lands in the prepared audio: the end of the last kept
    /// interval before it, carried onto the output clock. Zero when the cut
    /// starts the episode, because nothing was kept ahead of it.
    nonisolated static func preparedSeam(
        for removed: PreparationStatus.PreparationTimeline.RemovedInterval,
        in timeline: PreparationStatus.PreparationTimeline
    ) -> TimeInterval {
        timeline.kept.last(where: { $0.originalEndSeconds <= removed.originalStartSeconds })
            .map { $0.outputStartSeconds + ($0.originalEndSeconds - $0.originalStartSeconds) } ?? 0
    }

#endif
}
