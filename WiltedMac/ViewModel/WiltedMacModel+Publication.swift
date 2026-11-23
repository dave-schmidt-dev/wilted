import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedLibrary
import WiltedProducer
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

    /// Refreshes the lifetime statistics card after playback moved the
    /// durable summary. Transport commands call this without waiting; the
    /// finite-writer ledger tracks the task, so close and deinit cancel and
    /// join it as the retired checkpoint writer's did.
    func refreshLifetimeStatisticsAfterPlayback() {
        guard !isClosingTemporaryState else { return }
        let token = UUID()
        let predecessor = lifetimeStatisticsRefreshTailToken.flatMap { subscriptionWriteTasks[$0] }
        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.subscriptionWriteTasks[token] = nil
                    if self.lifetimeStatisticsRefreshTailToken == token {
                        self.lifetimeStatisticsRefreshTailToken = nil
                    }
                }
            }
            await predecessor?.value
            guard let self, !self.isClosingTemporaryState, !Task.isCancelled else { return }
            await self.refreshLifetimeStatistics()
        }
        subscriptionWriteTasks[token] = task
        lifetimeStatisticsRefreshTailToken = token
    }

    /// Deterministic test seam; production never waits on a playback refresh.
    func waitForLifetimeStatisticsRefreshForTesting() async {
        while let token = lifetimeStatisticsRefreshTailToken,
              let task = subscriptionWriteTasks[token] {
            await task.value
        }
    }

#if canImport(WiltedProducer)
    /// Removes an article from the library, committing before anything on
    /// screen changes.
    ///
    /// `LocalLibraryStore.removeArticle` writes the deleted flag and drops the
    /// playlist entry in one save, so a throw means nothing landed and the row,
    /// selection and player stay as they were for a retry. A repeat returns
    /// false and changes nothing.
    @discardableResult
    func commitArticleRemoval(_ article: WiltedMacArticle) async throws -> Bool {
        guard let store else { throw WiltedMacRemovalUnavailable() }
        let itemID = try ItemID(rawValue: article.id)
        let removed = try await store.removeArticle(itemID: itemID)
        if selectedArticleID == article.id || (!isPodcastPlayback && playback?.itemID == itemID) {
            stopPlaybackAfterCommittedRemoval()
        }
        articles.removeAll { $0.id == article.id }
        return removed
    }

    /// Stops what a committed removal just took out of the library.
    ///
    /// The current references clear at once, so no player, widget or remote
    /// command offers the removed item. The pause then runs as a `.stop`
    /// command, which also supersedes a start still pending for it. Callers
    /// reach this only after the store commit, so a failed removal never
    /// interrupts the audio.
    func stopPlaybackAfterCommittedRemoval() {
        stopPlaybackCheckpointTicker()
        cancelSeamMarker()
        currentPodcastEpisodeID = nil
        isPodcastPlayback = false
        selectedArticleID = nil
        isNowPlaying = false
        isPlaying = false
        currentTranscript = nil
        playbackPositionSeconds = 0
        playbackDurationSeconds = 0
        publishNowPlaying(force: true)
        guard let playback else { return }
        issuePlaybackCommand(.stop, pending: nil) { _ in
            // A paused transport has nothing to stop. The pause's checkpoint
            // for the removed item is skipped by the store, and a failed pause
            // surfaces through the command owner.
            guard playback.liveIsPlaying else { return }
            try await playback.pause()
        }
    }
#endif

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
        guard !isBackfillingTranscript, !isClosingTemporaryState,
              let store, let article = currentArticle else { return }
        let selectionToken = playbackCommands.selectionToken
        let taskID = UUID()
        let statusIsCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.subscriptionWriteTasks[taskID] != nil
                && !self.isClosingTemporaryState && self.selectedArticleID == article.id
                && self.playbackCommands.selectionToken == selectionToken
        }
        // Durable backfill belongs to the selected article even while idle or loading other audio.
        // Global player presentation additionally requires the matching loaded article owner.
        let owner: WiltedMacPlaybackPresentationOwner?
        if let itemID = playback?.itemID, itemID.rawValue == article.id,
           let revisionID = playback?.revisionID {
            owner = playbackPresentationOwner(itemID: itemID, revisionID: revisionID)
        } else { owner = nil }
        isBackfillingTranscript = true
        transcriptBackfillStatus = "Fetching article text…"
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if !statusIsCurrent() { self.transcriptBackfillStatus = nil }
                self.isBackfillingTranscript = false
                self.subscriptionWriteTasks[taskID] = nil
            }
            guard let itemID = try? ItemID(rawValue: article.id),
                  let revision = try? await store.readyRevision(for: itemID, revisionID: owner?.revisionID) else {
                if statusIsCurrent() {
                    self.transcriptBackfillStatus = "This article has no saved audio to attach text to."
                }
                return
            }
            do {
                let body: String
                if let extract = self.transcriptBackfillBodyForTesting {
                    body = try await extract(article.url)
                } else {
                    let extracted = try await NativeArticleExtractor().extract(article.url) { stage, _ in
                        Task { @MainActor [weak self] in
                            guard let self, statusIsCurrent() else { return }
                            self.transcriptBackfillStatus = "Fetching article text: \(stage.rawValue)"
                        }
                    }
                    body = extracted.body
                }
                let oversized = body.utf8.count > Transcript.maximumTextUTF8Bytes
                let transcript = try Transcript(
                    itemID: itemID,
                    revisionID: revision.revision.revisionID,
                    availability: oversized ? .oversized : .available,
                    text: oversized ? nil : body,
                    updatedAt: Timestamp(Date())
                )
                try await store.save(transcript: transcript)
                if let owner, self.ownsPlaybackPresentation(owner),
                   owner.revisionID == revision.revision.revisionID {
                    await self.readPlaybackPresentation(owner, includesCuts: false)
                }
                guard statusIsCurrent() else { return }
                self.transcriptBackfillStatus = oversized
                    ? "The article text is too large to store."
                    : nil
            } catch {
                // Named, not swallowed: the reader has to know whether to retry.
                guard statusIsCurrent() else { return }
                self.transcriptBackfillStatus = Self.backfillFailureMessage(error)
            }
        }
        subscriptionWriteTasks[taskID] = task
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
        guard !isClosingTemporaryState else { return }
        processorRunsRefreshGeneration &+= 1
        guard processorRunsRefreshTask == nil, store != nil else { return }
        processorRunsRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.drainProcessorRunsRefreshes()
        }
#endif
    }

    static let podcastRequestPrefix = "podcast-prepare|"

    /// The legacy terminal detail, from builds that journalled only that the
    /// run had finished.
    nonisolated static let legacyPreparedDetail = "Prepared."

    /// Rebuilds the saved result from worker evidence when the terminal row
    /// predates the four ad-check labels.
    nonisolated static func recordedSummary(
        of run: PreparationRunSummary?, timing: TranscriptTiming? = nil, hasText: Bool? = nil
    ) -> String? {
        guard let run, run.isTerminal, run.outcome == .succeeded else { return nil }
        if let worker = run.entries.reversed().compactMap({ entry -> [String: String]? in
            guard let evidence = entry.status.evidence, evidence.kind == "worker-result" else { return nil }
            return evidence.fields
        }).first, let recordedOutcome = worker["adRemovalOutcome"] {
            // Older builds used "uncertain" even when the provider was never asked.
            let skipped = recordedOutcome == "uncertain" && worker["adsMayRemain"] == nil
                && run.entries.contains { entry in
                    guard let evidence = entry.status.evidence else { return false }
                    return evidence.kind.hasPrefix("not-sent-") || (evidence.kind == "labeller-stop"
                        && ["daily-cap", "command-line-tool-unavailable"].contains(evidence.fields["kind"] ?? ""))
                }
            let outcome = skipped ? "disabled" : recordedOutcome
            let leftIn = run.entries.contains {
                $0.status.evidence?.kind == "advertisement-left-in"
            }
            let adsMayRemain = worker["adsMayRemain"].map { $0 == "true" }
                ?? (outcome == "uncertain" || leftIn)
            let label = PodcastPreparationResult.adCheckLabel(outcome: outcome, adsMayRemain: adsMayRemain)
            var parts = [PodcastPreparationResult.readyLabel, label]
            if let warning = worker["warning"], outcome == "disabled" || outcome == "uncertain" {
                let prefix = ["Some ads may remain:", "original audio includes ads:"].first(where: warning.hasPrefix)
                let reason = warning.dropFirst(prefix?.count ?? 0).trimmingCharacters(in: .whitespacesAndNewlines)
                if !reason.isEmpty { parts.append(reason) }
            }
            let removedCount = Int(worker["advertisements"] ?? "") ?? 0
            if removedCount > 0, outcome == "cut" {
                if label == "Some ads may remain" { parts.append("Ads removed") }
                if let kinds = removalKindSummary(of: run) {
                    parts.append(kinds.hasSuffix(" removed") ? String(kinds.dropLast(" removed".count)) : kinds)
                } else {
                    let seconds = Double(worker["removedSeconds"] ?? "") ?? 0
                    parts.append(PodcastPreparationResult.removedSummary(advertisements: removedCount, secondsRemoved: seconds))
                }
            }
            let sourceTiming = worker["timing"].flatMap(TranscriptTiming.init(rawValue:))
            parts.append(PodcastPreparationResult.transcriptStep(
                timing ?? .none, hasText: hasText, sourceTiming: sourceTiming))
            return parts.joined(separator: " · ")
        }
        if let kinds = removalKindSummary(of: run) {
            let leftIn = run.entries.contains {
                $0.status.evidence?.kind == "advertisement-left-in"
            }
            var parts = [PodcastPreparationResult.readyLabel,
                         leftIn ? "Some ads may remain" : "Ads removed"]
            if leftIn { parts.append("Ads removed") }
            parts.append(kinds.hasSuffix(" removed") ? String(kinds.dropLast(" removed".count)) : kinds)
            parts.append(PodcastPreparationResult.transcriptStep(timing ?? .none, hasText: hasText))
            return parts.joined(separator: " · ")
        }
        if run.detail != legacyPreparedDetail, !run.detail.isEmpty {
            return normalizedRecordedSummary(run.detail, timing: timing, hasText: hasText)
        }
        let completion = run.entries.last { $0.id.hasSuffix("|pipeline.complete") }?.status.detail ?? ""
        guard let match = completion.firstMatch(of: #/^(\d+) advertisements?/#),
              let count = Int(match.1) else { return nil }
        let label = count > 0 ? "Ads removed" : "Ad check skipped"
        let detail = count > 0 ? " · \(PodcastPreparationResult.removedSummary(advertisements: count, secondsRemoved: 0))" : ""
        return "\(PodcastPreparationResult.readyLabel) · \(label)\(detail) · \(PodcastPreparationResult.transcriptStep(timing ?? .none, hasText: hasText))"
    }

    private nonisolated static func normalizedRecordedSummary(
        _ detail: String, timing: TranscriptTiming?, hasText: Bool?
    ) -> String {
        var parts = detail.components(separatedBy: " · ")
        for index in parts.indices {
            if parts[index] == "Prepared" || parts[index] == "Prepared." {
                parts[index] = PodcastPreparationResult.readyLabel
            } else if parts[index].hasPrefix("original audio includes ads:") {
                let reason = parts[index].dropFirst("original audio includes ads:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                parts[index] = reason.isEmpty ? "Some ads may remain" : "Some ads may remain: \(reason)"
            } else if parts[index] == "no ads found" || parts[index] == "ad removal disabled" {
                parts[index] = "Ad check skipped"
            } else if parts[index].contains(" ads removed") || parts[index].contains(" ad removed") {
                let values = parts[index].split(separator: " ")
                if values.count >= 3, Int(values[0]) != nil,
                   values[1].hasPrefix("ad"), values[2] == "removed" {
                    let count = values[0]
                    let duration = values.dropFirst(3).joined(separator: " ")
                    let unit = count == "1" ? "ad" : "ads"
                    let detail = duration.isEmpty ? "\(count) \(unit)" : "\(count) \(unit) \(duration)"
                    parts[index] = "Ads removed · \(detail)"
                }
            } else if parts[index].hasPrefix("transcript ") {
                parts[index] = PodcastPreparationResult.transcriptStep(timing ?? .none, hasText: hasText)
            }
        }
        return parts.joined(separator: " · ")
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
        of run: PreparationRunSummary?, timing: TranscriptTiming, hasText: Bool? = nil
    ) -> String {
        recordedSummary(of: run, timing: timing, hasText: hasText)
            ?? "\(PodcastPreparationResult.readyLabel) · Ad check skipped · \(PodcastPreparationResult.transcriptStep(timing, hasText: hasText))"
    }

    /// Where a cut lands in the prepared audio: the end of the last kept
    /// interval before it, carried onto the output clock. Zero when the cut
    /// starts the episode, because nothing was kept ahead of it.
    nonisolated static func preparedSeam(
        for removed: PreparationStatus.PreparationTimeline.RemovedInterval,
        in timeline: PreparationStatus.PreparationTimeline
    ) -> TimeInterval {
        timeline.preparedSeam(for: removed)
    }

#endif
}

/// A confirmed removal reached a model with no open library store.
struct WiltedMacRemovalUnavailable: Error {}
