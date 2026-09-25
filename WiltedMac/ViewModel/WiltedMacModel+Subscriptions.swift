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
    /// The episode the Menu should start once the current one is finished:
    /// the first queued entry that is not the episode just finished, has not
    /// been retired or hidden, and can actually be played.
    func nextMenuEpisodeToPlay() -> WiltedMacEpisode? {
        let finishedID = currentPodcastEpisodeID
        for id in podcastQueueIDs {
            guard id != finishedID, !hiddenEpisodeIDs.contains(id),
                  let candidate = episodes.first(where: { $0.id == id }),
                  candidate.retiredAt == nil, canPlayEpisode(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// Re-points the player at an episode that was just prepared.
    ///
    /// Preparation supersedes the revision and deletes the audio it was cut
    /// from, carrying the saved position onto the new timeline. A player still
    /// holding the old revision would keep playing the advertisements and
    /// would fail on its next load, so the episode is selected again, which
    /// resumes from the carried position and picks up the new transcript.
    func reloadPreparedPlayback(_ episodeID: String, itemID: ItemID) async {
        guard currentPodcastEpisodeID == episodeID, let playback else { return }
        let wasPlaying = playback.liveIsPlaying
        do {
            try await playback.selectPodcastQueueEpisode(itemID, autoplay: wasPlaying)
            refreshPlaybackReadout()
        } catch {
            playbackError = "This episode's saved audio is unavailable."
        }
        await loadEpisodeTranscript(itemID: itemID)
    }
#endif

#if canImport(WiltedProducer)
    /// Turns the worker's own stage vocabulary into something a listener reads.
    nonisolated static func preparationLabel(for progress: PodcastPreparationProgress) -> String {
        switch progress.stage {
        case "pipeline.start": "Preparing…"
        case "transcript.published.fetch": "Fetching the published transcript…"
        case "transcript.published.parse", "transcript.published.accepted",
             "transcript.published.aligned", "transcript.published.unverified":
            "Reading the published transcript…"
        case "transcript.published.unreadable", "transcript.published.unreachable",
             "transcript.published.unparseable": "No usable published transcript. Transcribing…"
        // Named apart from the unusable cases above because this one is not a
        // missing transcript: the feed published a good one for a different
        // rendering of the episode than the download produced.
        case "transcript.published.misaligned":
            "The published transcript does not match this audio. Transcribing…"
        case "transcript.stt.start": "Transcribing the audio…"
        case "transcript.stt.complete": "Transcribed."
        case "transcript.stt.failed": "Transcription unavailable."
        case "transcript.glossary.terms", "transcript.glossary.progress", "transcript.glossary.complete":
            "Correcting names from the show notes…"
        case "transcript.prose.extract", "transcript.prose.accepted": "Reading the episode page…"
        case "transcript.absent": "No transcript available."
        case "transcript.remap": "Resynchronising the transcript…"
        case "ads.model.load": "Loading the advertisement classifier…"
        case "ads.detect.start", "ads.detect.calls", "ads.detect.complete": "Finding advertisements…"
        case "ads.cut.start", "ads.cut.complete": "Removing advertisements…"
        case "ads.cut.refused", "ads.cut.empty": "Advertisements left in place."
        case "audio.publish": "Storing the prepared audio…"
        case "pipeline.complete": "Prepared."
        default: "Preparing…"
        }
    }
#endif

    func cancelEpisodeDownload(_ episode: WiltedMacEpisode) {
        podcastDownloadTasks[episode.id]?.cancel()
    }

    func retryEpisodeDownload(_ episode: WiltedMacEpisode) { downloadEpisode(episode) }

    /// Fetches the episode again and prepares the fresh copy.
    ///
    /// Preparation writes the cut audio over the download, so an episode cut
    /// from a transcript that did not describe its file cannot be redone: the
    /// only copy of the source is the damaged result. This asks the publisher
    /// for the episode again, and the download's own completion starts the
    /// preparation, exactly as a first download does.
    func redownloadEpisode(_ episode: WiltedMacEpisode) {
        downloadEpisode(episode, ignoringExisting: true)
    }

    func waitForPodcastOperations() async {
        await linkClassificationTask?.value
        await podcastSubscriptionClassificationTask?.value
        await bootstrapRecoveryTask?.value
        let refresh = podcastRefreshTask
        let downloads = Array(podcastDownloadTasks.values)
        let restores = Array(podcastRestoreTasks.values)
        await refresh?.value
        for task in downloads { _ = try? await task.value }
        for task in restores { await task.value }
    }

    /// Test-only drain for preparations. The normal operation wait intentionally
    /// excludes long-running speech work, while model regressions need to
    /// observe every queued task leaving the process-owned table.
    func waitForPodcastPreparationOperationsForTesting() async {
#if canImport(WiltedProducer)
        let tasks = Array(podcastPreparationTasks.values)
        for task in tasks { await task.value }
#endif
    }

    /// Turns a feed's episodes on or off in the Larder without unsubscribing.
    func setSubscription(_ subscription: WiltedMacSubscription, enabled: Bool) {
#if canImport(WiltedProducer)
        guard let store, let feedID = try? ItemID(rawValue: subscription.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.save(subscription: PodcastSubscription(
                    feedID: feedID, subscribedAt: Timestamp(subscription.subscribedAt), enabled: enabled
                ))
                let values = try await self.loadLibrary(from: store)
                self.articles = values.articles
                self.applyEpisodes(values.episodes)
                self.subscriptions = values.subscriptions
                self.podcastOperationMessage = enabled
                    ? "\(subscription.title) is showing in Larder again."
                    : "\(subscription.title) is hidden from Larder. Wilted still keeps its episodes."
            } catch {
                self.podcastOperationMessage = "\(subscription.title) could not be updated."
            }
        }
#endif
    }

    /// Unsubscribes and clears every record the feed owned.
    ///
    /// Audio already downloaded stays on disk: an audio revision is identified
    /// by its content, so removing files here could break an episode from
    /// another feed that happens to share them.
    func unsubscribe(_ subscription: WiltedMacSubscription) {
#if canImport(WiltedProducer)
        guard let store, let feedID = try? ItemID(rawValue: subscription.id) else { return }
        undoableRemoval = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let removed = try await store.unsubscribeFromPodcast(feedID: feedID)
                let values = try await self.loadLibrary(from: store)
                self.articles = values.articles
                self.applyEpisodes(values.episodes)
                self.subscriptions = values.subscriptions
                self.dismissedEpisodes = try await self.loadDismissedEpisodes(from: store)
                self.podcastOperationMessage =
                    "Unsubscribed from \(subscription.title) and removed \(removed) episode\(removed == 1 ? "" : "s")."
            } catch {
                self.podcastOperationMessage = "\(subscription.title) could not be unsubscribed."
            }
        }
#endif
    }

    /// Marks an episode the listener has started completed, deleting nothing.
    ///
    /// The row's Skip button used to call `removeEpisode`, which erased the
    /// episode's records and needed a network feed check to bring anything
    /// back. The accepted Menu mockup asks for a reversible exclusion instead:
    /// a started episode is marked finished through the same listening record
    /// every other completion writes, and taken off the playback queue, while
    /// its media, preparation outcome, transcript and identity all stay on
    /// disk. `undoSkipEpisode` therefore restores it entirely offline. An
    /// episode never started has nothing to finish, and its state is left
    /// exactly as it was.
    func skipEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard hasStartedEpisode(episode) else {
            podcastOperationMessage = "\(episode.title) was not started, so nothing was marked completed."
            return
        }
        withdrawPreparationRequest(for: episode.id)
        undoableRemoval = nil
        let wasPlaying = currentPodcastEpisodeID == episode.id
        undoableSkip = episode
        podcastOperationMessage = "Marked \(episode.title) completed. Undo completion restores it."
        Task { [weak self] in
            guard let self, let store = self.store, let id = try? ItemID(rawValue: episode.id) else { return }
            do {
                // `lastRevisionID` stays nil on purpose: a skip is not
                // evidence about the revision's audio. The store persists this
                // listening shape and the retirement together, so Feeds never
                // sees the completed row as active between two saves.
                let skipped = try await store.completeAndRetireEpisode(listening: PodcastListeningState(
                    episodeID: id, completedAt: Timestamp(Date()),
                    lastRevisionID: nil, updatedAt: Timestamp(Date())
                ))
                guard skipped else {
                    self.undoableSkip = nil
                    self.podcastOperationMessage = "\(episode.title) could not be marked completed."
                    return
                }
                if let playback = self.playback {
                    try? await playback.removePodcastQueueEpisode(id)
                    await self.refreshPodcastQueueState()
                }
                if wasPlaying { await self.stopPlaybackForRemovedEpisode() }
                await self.reloadLibraryRows()
            } catch {
                self.undoableSkip = nil
                self.podcastOperationMessage = "\(episode.title) could not be marked completed."
            }
        }
#endif
    }

    /// Reverses `skipEpisode`'s local completion from local state alone.
    ///
    /// The listening record is cleared and the episode plays again from the
    /// media already on disk; no feed is consulted, which is the acceptance
    /// bar the owner set for a mistaken Skip.
    func undoSkipEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        undoableSkip = nil
        podcastOperationMessage = "Restoring \(episode.title)…"
        Task { [weak self] in
            guard let self, let store = self.store, let id = try? ItemID(rawValue: episode.id) else { return }
            do {
                let restored = try await store.undoCompletedAndRetiredEpisode(id)
                guard restored else {
                    self.podcastOperationMessage = "\(episode.title) could not be restored."
                    return
                }
                await self.reloadLibraryRows()
                self.podcastOperationMessage = "Restored \(episode.title)."
                if let restored = self.episodes.first(where: { $0.id == episode.id }) {
                    self.playEpisode(restored)
                }
            } catch {
                self.podcastOperationMessage = "\(episode.title) could not be restored."
            }
        }
#endif
    }

    /// Removes an episode for good, not just from this view.
    ///
    /// The in-memory hide is the optimistic half: it takes the row off screen
    /// on the next render, before the store round-trip returns. The durable
    /// half is the store's dismissal, which is what stops the next refresh
    /// parsing the same episode out of the same feed and inserting it again.
    /// Without it a removal lasted until the next launch, because this set is
    /// all there was.
    func removeEpisode(_ episode: WiltedMacEpisode) {
        hideEpisode(episode)
        undoableRemoval = nil
        undoableSkip = nil
        podcastOperationMessage = "Removed \(episode.title)."
#if canImport(WiltedProducer)
        // Read before the removal runs: once the row is gone there is nothing
        // left to compare the playing episode against.
        let wasPlaying = currentPodcastEpisodeID == episode.id
        Task { [weak self] in
            guard let self else { return }
            if wasPlaying { await self.stopPlaybackForRemovedEpisode() }
            if await self.dismissEpisode(episode) == false {
                self.podcastOperationMessage = "\(episode.title) could not be removed."
            } else {
                self.undoableRemoval = self.dismissedEpisodes.first { $0.id == episode.id }
            }
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Stops the transport when the episode being removed is the one playing.
    ///
    /// Removal took the row, the stored records and the Up Next entry and left
    /// the player running, so Skip on a playing episode kept the audio going
    /// for something the library no longer held, with the rail and the system
    /// widget still offering controls for it. `removeArticle` already cleared
    /// its side; this is the same care for the other kind.
    func stopPlaybackForRemovedEpisode() async {
        try? await playback?.pause()
        stopPlaybackCheckpointTicker()
        cancelSeamMarker()
        currentPodcastEpisodeID = nil
        isPodcastPlayback = false
        isNowPlaying = false
        isPlaying = false
        currentTranscript = nil
        playbackPositionSeconds = 0
        playbackDurationSeconds = 0
        // Nothing is loaded any more, so the widget has to stop showing it.
        publishNowPlaying(force: true)
    }
#endif

    /// The optimistic half of a removal: the row leaves the screen on the next
    /// render, and any work still running for it stops.
    func hideEpisode(_ episode: WiltedMacEpisode) {
        podcastDownloadTasks[episode.id]?.cancel()
        podcastPreparationTasks[episode.id]?.cancel()
        withdrawPreparationRequest(for: episode.id)
        removeDeferredAutomaticPreparation(episode.id)
        // A removed episode has no business holding a run slot. Cancelling the
        // task is not enough on its own: an episode still waiting on the gate
        // has no task to cancel, and its entry outlived the row.
        preparationQueue.leave(episode.id)
        hiddenEpisodeIDs.insert(episode.id)
        if selectedLibraryItemID == episode.id { selectedLibraryItemID = nil }
    }

#if canImport(WiltedProducer)
    /// The durable half of a removal, awaited rather than fired off so a
    /// caller with something to do afterwards can do it in order.
    ///
    /// Returns whether the dismissal stuck. The optimistic hide is rolled back
    /// here when it did not, but the message stays the caller's to write:
    /// removal by hand and removal on finishing have different things to say.
    private func dismissEpisode(_ episode: WiltedMacEpisode) async -> Bool {
        guard let store, let id = try? ItemID(rawValue: episode.id) else { return false }
        do {
            try await store.dismissPodcastEpisode(id)
            if let playback {
                try? await playback.removePodcastQueueEpisode(id)
                await refreshPodcastQueueState()
            }
            let values = try await loadLibrary(from: store)
            articles = values.articles
            applyEpisodes(values.episodes)
            subscriptions = values.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: store)
            return true
        } catch {
            hiddenEpisodeIDs.remove(episode.id)
            return false
        }
    }
#endif

    /// Restores a removed episode. The row never left the store, so this
    /// needs no feed evidence -- unlike the old dismiss-deleted-the-row
    /// design, there is nothing to re-match against a re-fetched feed.
    func restoreEpisode(_ dismissal: WiltedMacDismissedEpisode) {
#if canImport(WiltedProducer)
        guard podcastRestoreTasks[dismissal.id] == nil,
              let store, let episodeID = try? ItemID(rawValue: dismissal.id) else { return }
        undoableRemoval = nil
        podcastOperationMessage = "Restoring \(dismissal.title)…"
        podcastRestoreTasks[dismissal.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.podcastRestoreTasks[dismissal.id] = nil }
            await self.restoreEpisode(dismissal, episodeID: episodeID, store: store)
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Clears the optimistic hide once the store confirms the episode is
    /// restored, so the row can actually reappear this session.
    ///
    /// Reported 2026-09-05: skipping the Waveform episode, then restoring it
    /// in the same session, left the store saying "Restored X to Larder."
    /// while the row stayed off screen until the app relaunched. `removeEpisode`
    /// inserts the id into `hiddenEpisodeIDs` immediately, ahead of the store
    /// round-trip, and the shelf's visible set filters on that id. The store-side
    /// restore was working the whole time; nothing ever told the hide set the
    /// row was no longer hidden. Both branches below -- the store reporting a
    /// fresh restore, and the store reporting the episode was already
    /// restored on an earlier attempt -- have to clear the id, because either
    /// one means the store no longer considers the episode removed.
    ///
    /// The row never left the store under dismissal or retirement, so unlike
    /// the old design, restoring needs no re-fetched feed to prove identity --
    /// it is the same store operation `restoreSkippedFeedEpisode` uses.
    func restoreEpisode(
        _ dismissal: WiltedMacDismissedEpisode, episodeID: ItemID, store: LocalLibraryStore
    ) async {
        do {
            let restored = try await store.restoreEpisode(episodeID)
            guard restored else {
                hiddenEpisodeIDs.remove(dismissal.id)
                dismissedEpisodes = try await loadDismissedEpisodes(from: store)
                podcastOperationMessage = "\(dismissal.title) was already restored."
                return
            }
            hiddenEpisodeIDs.remove(dismissal.id)
            let values = try await loadLibrary(from: store)
            articles = values.articles
            applyEpisodes(values.episodes)
            subscriptions = values.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: store)
            podcastOperationMessage = "Restored \(dismissal.title) to Feeds."
        } catch {
            podcastOperationMessage = "\(dismissal.title) could not be restored. Retry Restore."
        }
    }
#endif

#if canImport(WiltedProducer)
    func startPodcastRefresh(urls: [URL], subscribing: Bool) {
        guard podcastRefreshTask == nil else { return }
        isRefreshingPodcasts = true
        undoableRemoval = nil
        podcastOperationMessage = subscribing ? "Adding podcast feed…" : "Refreshing subscribed podcasts…"
        podcastRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.refreshPodcastURLs(urls, subscribing: subscribing)
                self.lastPodcastRefreshNewEpisodeIDs = result.newEpisodeIDs.map(\.rawValue)
                if subscribing {
                    self.podcastFeedDraft = ""
                    if let duplicate = result.duplicateSubscription {
                        // Nothing was added, so the answer is the feed already
                        // followed: point at it rather than report a failure.
                        self.selectedPodcastFeedID = duplicate.rawValue
                        self.podcastOperationMessage = "Already following this podcast."
                    } else {
                        self.selectedPodcastFeedID = nil
                        self.podcastOperationMessage = result.newEpisodeIDs.isEmpty
                            ? "Podcast subscription added."
                            : "Podcast subscription added with \(result.newEpisodeIDs.count) episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
                    }
                } else {
                    self.podcastOperationMessage = result.newEpisodeIDs.isEmpty
                        ? "Podcast episodes are up to date."
                        : "Added \(result.newEpisodeIDs.count) new episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
                }
            } catch is CancellationError {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch PodcastFeedClientError.cancelled {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch {
                self.podcastOperationMessage = "Podcast feed unavailable. Check the address or retry when online."
            }
            self.isRefreshingPodcasts = false
            self.podcastRefreshTask = nil
        }
    }

#endif
}
