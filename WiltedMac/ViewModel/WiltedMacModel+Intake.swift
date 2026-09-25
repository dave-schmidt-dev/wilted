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
        guard let fixtureRevision else {
            if fixtureMode { return }
            Task { [weak self] in
                guard let self, let store = self.store,
                      let itemID = try? ItemID(rawValue: article.id),
                      let revision = try? await store.readyRevision(for: itemID) else { return }
                do {
                    try await playback.load(revision)
                    if autoplay { try playback.play() }
                    self.isPlaying = playback.isPlaying
                    self.refreshPlaybackReadout()
                    await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                } catch { self.playbackError = "Audio could not be loaded." }
            }
            return
        }
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.load(fixtureRevision)
                if autoplay { try playback.play() }
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                if let itemID = try? ItemID(rawValue: article.id) {
                    await self.loadTranscript(
                        itemID: itemID,
                        revisionID: fixtureRevision.revision.revisionID
                    )
                }
            } catch { self.playbackError = "Audio could not be loaded." }
        }
#endif
    }

    func beginArticlePlaybackTransition(_ article: WiltedMacArticle) {
        if isNowPlaying { refreshPlaybackReadout() }
        selectedArticleID = article.id
        cancelSeamMarker()
        currentPodcastEpisodeID = nil
        isPodcastPlayback = false
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
        guard !podcastQueueIDs.contains(episode.id) else { return }
        // The optimistic half first: the row moves on the next render even
        // before the durable round trip, exactly as a removal does.
        podcastQueueIDs.append(episode.id)
        podcastOperationMessage = "Kept \(episode.title). It is in Larder."
        if automationSettings.downloadEverythingOnMenu,
           Self.menuGroup(for: episode) == .available {
            // The override fetches what it kept through the same admission the
            // row's Download button and the group's bulk action use, so a
            // later arrival is no different from one already on the Menu. An
            // episode that already has its audio is not fetched again.
            downloadEpisode(episode)
        }
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episode.id) else { return }
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.fixturePodcastInstallTask?.value
                try await playback.addPodcastQueueEpisode(id)
                await self.refreshPodcastQueueState()
            } catch {
                self.podcastQueueIDs.removeAll { $0 == episode.id }
                self.podcastOperationMessage = "\(episode.title) could not be kept."
            }
        }
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
        guard let store, let id = try? ItemID(rawValue: episode.id) else { return }
        withdrawPreparationRequest(for: episode.id)
        undoableSkip = nil
        podcastOperationMessage =
            "Skipped \(episode.title). Its download, prepared cut and transcript are untouched."
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.retireEpisode(id)
                await self.reloadLibraryRows()
            } catch {
                self.podcastOperationMessage = "\(episode.title) could not be skipped."
            }
        }
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
        guard let store, let id = try? ItemID(rawValue: episode.id) else { return }
        podcastOperationMessage = "Restoring \(episode.title)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await store.restoreEpisode(id)
                await self.reloadLibraryRows()
                self.podcastOperationMessage = "Restored \(episode.title) to Feeds."
            } catch {
                self.podcastOperationMessage = "\(episode.title) could not be restored."
            }
        }
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
        guard let playback, let id = try? ItemID(rawValue: episode.id) else { return }
        playbackOperationStatus = "Opening \(episode.title)…"
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.fixturePodcastInstallTask?.value
                Self.playbackLog.notice(
                    "playEpisode started: episode=\(episode.id, privacy: .public)"
                )
                // The outgoing episode is still current here; the forced
                // publish below is the one that names the new episode.
                self.refreshPlaybackReadout(shouldPublishNowPlaying: false)
                try await playback.playPodcastQueueEpisodeNow(id)
                Self.playbackLog.notice(
                    "playEpisode returned: episode=\(episode.id, privacy: .public) isPlaying=\(playback.liveIsPlaying, privacy: .public) time=\(playback.livePositionSeconds, privacy: .public) rate=\(playback.playbackRate, privacy: .public)"
                )
                self.menuSort = .custom
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
                self.playbackError = nil
                self.playbackOperationStatus = nil
            } catch {
                await self.refreshPodcastQueueState()
                // A manual play throws before `podcastStateHandler` ever runs,
                // so this is the only place that repairs the flag for this path.
                if case let PlaybackControllerError.podcastMediaUnavailable(unavailableID) = error,
                   let index = self.episodes.firstIndex(where: { $0.id == unavailableID.rawValue }) {
                    self.episodes[index].isReadyMediaAvailable = false
                }
                self.playbackError = "This episode's saved audio is unavailable."
                Self.playbackLog.error(
                    "playEpisode failed: episode=\(episode.id, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                self.playbackOperationStatus = nil
            }
        }
#endif
    }

    func removeEpisodeFromUpNext(_ episodeID: String) {
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episodeID) else { return }
        playbackOperationStatus = "Updating Larder…"
        Task { [weak self] in
            try? await playback.removePodcastQueueEpisode(id)
            await self?.refreshPodcastQueueState()
            self?.playbackOperationStatus = nil
        }
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
