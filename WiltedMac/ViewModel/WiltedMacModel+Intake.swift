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
    func addArticle() {
        guard let url = URL(string: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard let preparedItemID = try? ItemID.derive(from: url) else { return }

        if fixtureMode {
            preparation = WiltedMacPreparation(
                phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
            )
            return
        }

#if canImport(WiltedProducer)
        guard let coordinator else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "The local larder is unavailable.", fraction: nil, cancellable: false
            )
            return
        }
        preparationTask?.cancel()
        // Article text-to-speech and podcast preparation share one GPU, so they
        // share the admission gate. This path used to start the coordinator
        // directly: two runs could hold the device at once, which is the thing
        // the gate exists to prevent.
        //
        // The place in line is taken here, where the reader asked, so an article
        // orders against podcast requests by intent rather than by whichever
        // task happened to reach the gate first.
        let requestSequence = consumePreparationRequest(
            for: preparedItemID.rawValue, kind: .articlePreparation
        )
        // Decided now, so the composer can say so now rather than sitting on
        // "Validating article URL" for as long as the run ahead takes. A run
        // becomes the gate's business only when its task body reaches `admit()`,
        // one main-actor hop later, so an already-tracked podcast task counts as
        // ahead of this one even while the gate still reads free.
        let queued = preparationGate.isBusy || !podcastPreparationTasks.isEmpty
        preparation = WiltedMacPreparation(
            phase: .preparing,
            detail: queued ? Self.articlePreparationQueuedDetail : "Validating article URL",
            fraction: queued ? nil : 0,
            cancellable: true
        )
        articlePreparationIsPending = true
        preparationTask = Task { [weak self] in
            defer { self?.articlePreparationIsPending = false }
            guard let gate = self?.preparationGate else { return }
            do {
                try await gate.admit(sequence: requestSequence)
            } catch {
                // Cancelled while queued: there is no status stream to carry a
                // terminal state, so this path reports its own.
                self?.preparation = WiltedMacPreparation(
                    phase: .cancelled, detail: "Preparation cancelled.", fraction: nil, cancellable: false
                )
                await self?.recordWorkTicketTransition(
                    kind: .articlePreparation, subjectID: preparedItemID.rawValue,
                    requestSequence: requestSequence, state: .cancelled
                )
                return
            }
            defer { gate.release() }
            if queued {
                self?.preparation = WiltedMacPreparation(
                    phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
                )
            }
            let run = await coordinator.start(url: url)
            guard let self else { await run.cancel(); return }
            self.preparationRun = run
            for await status in run.statuses {
                guard !Task.isCancelled else { await run.cancel(); return }
                self.update(status)
                if status.terminal { break }
            }
            // Present the moment a terminal status is observed, whenever
            // extraction reached the canonical URL first -- including a
            // cancelled or failed run, so a request that fails after
            // extraction still leaves the resolution on its ticket rather
            // than only recording it on success.
            let resolvedItemID = await coordinator.resolvedItemID(forRun: run.runID)?.rawValue
            switch self.preparation?.phase {
            case .completed:
                await self.refreshLifetimeStatistics()
                if await self.queuePreparedPublication(itemID: preparedItemID) {
                    self.syncLifecycle?.startAutomaticUpload()
                }
                await self.recordWorkTicketTransition(
                    kind: .articlePreparation, subjectID: preparedItemID.rawValue,
                    requestSequence: requestSequence, state: .succeeded,
                    resolvedItemID: resolvedItemID
                )
            case .cancelled:
                await self.recordWorkTicketTransition(
                    kind: .articlePreparation, subjectID: preparedItemID.rawValue,
                    requestSequence: requestSequence, state: .cancelled,
                    resolvedItemID: resolvedItemID
                )
            default:
                // The failure detail already carries whatever the status
                // stream reported; no `ProducerError` is available at this
                // boundary to classify further, so this is conservatively
                // `.retryable` -- unlike a podcast run, there is no bounded
                // in-process retry upstream of this ticket at all, so
                // marking it terminal would only ever hide a retry option
                // the reader could otherwise take from Prep.
                await self.recordWorkTicketTransition(
                    kind: .articlePreparation, subjectID: preparedItemID.rawValue,
                    requestSequence: requestSequence, state: .failed,
                    resolvedItemID: resolvedItemID,
                    failureKind: PodcastDownloadFailureKind.retryable.rawValue,
                    lastFailureMessage: self.preparation?.detail
                )
            }
            self.preparationRun = nil
            self.refresh()
        }
#endif
    }

    func cancelPreparation() {
        guard canCancelPreparation else { return }
        preparation = WiltedMacPreparation(
            phase: .cancelling, detail: "The current work will stop without replacing saved audio.",
            fraction: preparation?.fraction, cancellable: false
        )
        if fixtureMode {
            preparation = nil
            return
        }
#if canImport(WiltedProducer)
        // Cancel the task as well as the run. While the article is queued on the
        // admission gate there is no run yet, and cancelling the task is what
        // makes the gate drop its waiter -- otherwise Cancel did nothing until
        // the preparation ahead of it finished.
        preparationTask?.cancel()
        let run = preparationRun
        Task { await run?.cancel() }
#endif
    }

    /// `autoplay` starts the article once its revision is actually loaded.
    /// Callers cannot do this themselves by following the call with a toggle:
    /// the load runs in a task, so the toggle reaches a controller with nothing
    /// loaded, throws, and is reported as an audio route fault.
    func openNowPlaying(for article: WiltedMacArticle, autoplay: Bool = false) {
        guard article.isReady else { return }
        beginArticlePlaybackTransition(article)
#if canImport(WiltedProducer)
        guard let playback else { return }
        if fixtureRevision == nil && fixtureMode { return }
        let fixtureRevision = fixtureRevision
        // Opening an article is a selection: it supersedes any pending
        // command, and only the newest one may start the loaded audio.
        issuePlaybackCommand(.select, pending: autoplay ? WiltedMacPlaybackCopy.starting : nil, target: article.id,
                             failureMessage: "Audio could not be loaded.") { [weak self] command in
            guard let self else { return }
            let itemID = try? ItemID(rawValue: article.id)
            let stored: StoredAudioRevision
            if let fixtureRevision {
                stored = fixtureRevision
            } else {
                guard let store = self.store, let itemID,
                      let ready = try? await store.readyRevision(for: itemID) else { return }
                stored = ready
            }
            try self.ensureCurrentPlaybackCommand(command)
            try await playback.load(stored)
            try self.ensureNewestSelection(command)
            if autoplay { try self.startIfCurrent(playback, for: command) }
            self.isPlaying = playback.isPlaying
            self.refreshPlaybackReadout()
            if let itemID { await self.loadTranscript(itemID: itemID, revisionID: stored.revision.revisionID) }
        }
#endif
    }

    func beginArticlePlaybackTransition(_ article: WiltedMacArticle) {
        if isNowPlaying { refreshPlaybackReadout() }
        selectedArticleID = article.id
        cancelSeamMarker()
        currentPodcastEpisodeID = nil
        isPodcastPlayback = false
        isLarderQueuePlayback = false
        isNowPlaying = true
        playbackError = nil
        currentTranscript = nil
        playbackPositionSeconds = 0
        playbackDurationSeconds = 0
    }

    func addEpisodeToUpNext(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episode.id) else { return }
        playbackOperationStatus = "Adding \(episode.title) to Larder…"
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.fixturePodcastInstallTask?.value
                try await playback.addPodcastQueueEpisode(id)
                await self.refreshPodcastQueueState()
                self.playbackOperationStatus = "Added \(episode.title) to Larder."
            } catch { self.playbackOperationStatus = "Larder could not be updated." }
        }
#endif
    }

    /// Feeds' Keep: add an episode to the Menu without touching its audio.
    ///
    /// Keeping is a decision about waiting, not about downloading or
    /// preparing, so the download, prepared cut and transcript are all left
    /// exactly as they were. The Menu then offers the one step the episode's
    /// group says it is waiting for -- Download, then Prepare, then Play.
    func keepEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        decideFeedEpisodes(.keep, episodes: [episode])
#endif
    }

    /// Feeds' Skip: take an episode off the list without deleting anything.
    ///
    /// A listener who never started an episode is passing on it, not finishing
    /// with it, so none of its artifacts change: the download, the prepared
    /// cut and the transcript all stay where they are and only the row leaves
    /// the waiting lists. Reversible exclusion is Task 2.8's bar; this keeps
    /// the records alive until that lands.
    func skipFeedEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        undoableSkip = nil
        decideFeedEpisodes(.skip, episodes: [episode])
#endif
    }

    /// Episodes skipped from Feeds: retired, with every record and every byte
    /// still in place. Feeds renders these with a Restore control, because
    /// reversing the one decision the surface owns belongs there.
    var skippedFeedEpisodes: [WiltedMacEpisode] {
        episodes.filter { $0.removalKind == .retired }
            .sorted { $0.releasedAt > $1.releasedAt }
    }

    /// Reverses `skipFeedEpisode`: clears the retirement so the next reload
    /// puts the row back in the Feeds list. Nothing was deleted, so no feed is
    /// consulted and no network is needed. Dismissal reverses through the same
    /// store operation -- see `restoreEpisode(_ dismissal:)`.
    func restoreSkippedFeedEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        decideFeedEpisodes(.restore, episodes: [episode])
#endif
    }

    /// Appends every currently eligible prepared episode in Larder order.
    /// `addPodcastQueueEpisode` only mutates the durable queue; it never
    /// selects or starts an episode, so the current playback is untouched.
    func addAllPreparedEpisodesToMenu() {
#if canImport(WiltedProducer)
        let eligible = preparedEpisodesReadyForMenu
        guard !eligible.isEmpty, let playback else { return }
        // Publish the requested order immediately. The durable controller
        // still owns the final answer and the catch below reconciles a failed
        // write, but holding every row back until a serial batch completes
        // made a multi-episode press look like only its first item queued.
        let requestedIDs = eligible.map(\.id)
        podcastQueueIDs.append(contentsOf: requestedIDs)
        playbackOperationStatus = "Adding \(eligible.count) prepared episodes to Larder…"
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            var addedCount = 0
            do {
                await self.fixturePodcastInstallTask?.value
                for episode in eligible {
                    guard let id = try? ItemID(rawValue: episode.id) else { continue }
                    try await playback.addPodcastQueueEpisode(id)
                    addedCount += 1
                }
                await self.refreshPodcastQueueState()
                self.playbackOperationStatus = "Added \(addedCount) prepared episode\(addedCount == 1 ? "" : "s") to Larder."
            } catch {
                await self.refreshPodcastQueueState()
                self.playbackOperationStatus = addedCount == 0
                    ? "Larder could not be updated."
                    : "Added \(addedCount) prepared episode\(addedCount == 1 ? "" : "s") to Larder."
            }
        }
#endif
    }

    func openMenu() {
        selectedNavigation = .menu
    }

    func playEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        performPlaybackStart(for: episode, isLarderIntent: false)
#endif
    }

    func playLarderEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        performPlaybackStart(for: episode, isLarderIntent: true)
#endif
    }

#if canImport(WiltedProducer)
    private func performPlaybackStart(for episode: WiltedMacEpisode, isLarderIntent: Bool) {
        guard let playback, let id = try? ItemID(rawValue: episode.id) else { return }
        let opening = "Opening \(episode.title)…"
        playbackOperationStatus = opening
        // A selection supersedes any pending command, auto-advance included.
        // The queue move lands without autoplay; only the newest command may
        // then start it, so a Pause issued meanwhile wins.
        issuePlaybackCommand(.select, pending: opening, target: episode.id,
                             failureMessage: WiltedMacPlaybackCopy.missing) { [weak self] command in
            guard let self else { return }
            defer { if self.playbackOperationStatus == opening { self.playbackOperationStatus = nil } }
            do {
                await self.fixturePodcastInstallTask?.value
                Self.playbackLog.notice("playEpisode started: episode=\(episode.id, privacy: .public)")
                // The outgoing episode is still current here; the forced
                // publish below is the one that names the new episode.
                self.refreshPlaybackReadout(shouldPublishNowPlaying: false)
                await self.refreshPhonePositionBeforePlay()
                // Before the queue moves, any newer command cancels this one
                // outright; once it has moved, only a newer selection does.
                try self.ensureCurrentPlaybackCommand(command)

                let isQueued = self.podcastQueueIDs.contains(episode.id)
                if isLarderIntent && isQueued {
                    if self.menuSort != .custom {
                        let displayed = self.sortedMenuEpisodeIDs(self.podcastQueueIDs, by: self.menuSort)
                        if displayed != self.podcastQueueIDs {
                            self.podcastQueueIDs = displayed
                            if let episodeIDs = try? displayed.map({ try ItemID(rawValue: $0) }),
                               let state = try? PodcastQueueState(
                                   episodeIDs: episodeIDs,
                                   currentEpisodeID: self.currentPodcastEpisodeID.flatMap { try? ItemID(rawValue: $0) }
                               ) {
                                try await playback.replacePodcastQueue(state)
                            }
                        }
                    }
                    let queueState = try? await self.store?.podcastQueueState()
                    let outgoingCurrentID = queueState?.currentEpisodeID
                        ?? self.currentPodcastEpisodeID.flatMap { try? ItemID(rawValue: $0) }
                    if let outgoingCurrentID, playback.itemID == outgoingCurrentID, playback.revisionID != nil {
                        try await playback.checkpoint()
                    }
                    try self.ensureCurrentPlaybackCommand(command)
                    try await playback.selectPodcastQueueEpisode(id, autoplay: false)
                    try self.ensureNewestSelection(command)
                    // The selected row loaded, so the session now belongs to
                    // the durable queue it was selected from. A load failure
                    // throws past this line and leaves the outgoing session's
                    // mode alone.
                    self.isLarderQueuePlayback = true
                } else {
                    try self.ensureCurrentPlaybackCommand(command)
                    // The controller asks at its own start point, after the
                    // load's last await, so a Pause issued meanwhile wins.
                    try await playback.playPodcastQueueEpisodeNow(id, startsIf: { self.isCurrentPlaybackCommand(command) })
                    try self.ensureNewestSelection(command)
                    self.menuSort = .custom
                    // A generic Play keeps the Larder-wide continuation
                    // contract, and it ends any queue-origin mode the
                    // previous session had.
                    self.isLarderQueuePlayback = false
                }
                // Only the newest command starts audio: a Pause or seek issued
                // meanwhile keeps the selection but not the start.
                try self.startIfCurrent(playback, for: command)
                self.isPlaying = playback.isPlaying

                Self.playbackLog.notice(
                    "playEpisode returned: episode=\(episode.id, privacy: .public) isPlaying=\(playback.liveIsPlaying, privacy: .public) time=\(playback.livePositionSeconds, privacy: .public) rate=\(playback.playbackRate, privacy: .public)"
                )
                self.selectedArticleID = nil
                self.currentPodcastEpisodeID = episode.id
                self.isPodcastPlayback = true
                self.isNowPlaying = true
                self.currentTranscript = .unavailable
                self.refreshPlaybackReadout(shouldPublishNowPlaying: false)
                self.publishNowPlaying(force: true)
                await self.refreshPodcastQueueState()
                await self.loadEpisodeTranscript(itemID: id)
                self.refreshPlaybackReadout()
                if self.isCurrentPlaybackCommand(command) { self.playbackError = nil }
            } catch {
                if !(error is WiltedMacPlaybackSuperseded) { await self.refreshPodcastQueueState() }
                Self.playbackLog.error(
                    "playEpisode failed: episode=\(episode.id, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }
        }
    }
#endif

    func removeEpisodeFromUpNext(_ episodeID: String) {
#if canImport(WiltedProducer)
        guard !isClosingTemporaryState,
              let playback, let id = try? ItemID(rawValue: episodeID) else { return }
        playbackOperationStatus = "Updating Larder…"
        let token = UUID()
        let predecessors = Array(subscriptionWriteTasks.values)
        let task = Task { @MainActor [weak self] in
            defer { self?.subscriptionWriteTasks[token] = nil }
            guard let self else { return }
            // Queue removal is durable, so it serializes behind every writer
            // already entered in the finite ledger before touching playback.
            for predecessor in predecessors { await predecessor.value }
            guard !self.isClosingTemporaryState, !Task.isCancelled else { return }
            do {
                try await playback.removePodcastQueueEpisode(id)
                guard !self.isClosingTemporaryState, !Task.isCancelled else { return }
                await self.refreshPodcastQueueState()
                guard !self.isClosingTemporaryState, !Task.isCancelled else { return }
                self.playbackOperationStatus = nil
            } catch {
                guard !self.isClosingTemporaryState, !Task.isCancelled else { return }
                self.playbackOperationStatus = "Could not update Larder."
            }
        }
        // Register before the task reaches its first await so close and tests
        // drain this exact durable writer rather than an unrelated playback task.
        subscriptionWriteTasks[token] = task
#endif
    }

    /// The exact set the Available bulk action acts on, so its button's count
    /// and the rows it changes are one answer. Never the search's subset: a
    /// group action covers the group, and the view disables it while a search
    /// is active rather than silently acting on the rows that remain. Rows
    /// already queued or downloading are excluded, so the count is work the
    /// press will start.
    var menuDownloadableEpisodes: [WiltedMacEpisode] {
        menuUnfilteredEpisodes(in: .available).filter { !$0.downloadState.isInFlight }
    }

    /// Available rows whose downloads have been admitted and are still running.
    var menuDownloadsInFlight: [WiltedMacEpisode] {
        menuUnfilteredEpisodes(in: .available).filter { $0.downloadState.isInFlight }
    }

    /// Downloaded rows the bulk override can start now. This includes ordinary
    /// not-started rows and rows deferred for off-peak, but excludes a genuine
    /// running preparation so the action cannot duplicate work.
    var menuPreparableEpisodes: [WiltedMacEpisode] {
        menuUnfilteredEpisodes(in: .downloaded).filter {
            isDeferredForOffPeak($0.id) || Self.isEligibleForPreparation($0)
        }
    }

}
