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

private let removalLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "Removal")

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
        let subscriptionWrites = Array(subscriptionWriteTasks.values)
        let restores = Array(podcastRestoreTasks.values)
        for task in subscriptionWrites { await task.value }
        await refresh?.value
        let downloads = Array(podcastDownloadTasks.values)
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
    ///
    /// The row is marked pending before the write is awaited. A repeat of the value being saved is
    /// acknowledged and dropped; a different value is held and written once, after the one in flight.
    func setSubscription(_ subscription: WiltedMacSubscription, enabled: Bool) {
#if canImport(WiltedProducer)
        guard let store, !isClosingTemporaryState else { return }
        let feedID = subscription.id
        switch pendingFeedWrites[feedID] {
        case .removing: return
        case let .updating(inFlight):
            queuedFeedEnabled[feedID] = enabled == inFlight ? nil : enabled
            return
        case nil: break
        }
        pendingFeedWrites[feedID] = .updating(enabled: enabled)
        trackSubscriptionWrite { [weak self] in
            guard let self else { return }
            defer { self.pendingFeedWrites[feedID] = nil; self.queuedFeedEnabled[feedID] = nil }
            var target = enabled
            var row = subscription
            while true {
                do {
                    try await self.subscriptionWriteHookForTesting?()
                    try await store.save(subscription: PodcastSubscription(
                        feedID: try ItemID(rawValue: row.id), subscribedAt: Timestamp(row.subscribedAt), enabled: target
                    ))
                    let values = try await self.loadLibrary(from: store)
                    self.articles = values.articles
                    self.applyEpisodes(values.episodes)
                    self.subscriptions = values.subscriptions
                    self.podcastOperationMessage = target
                        ? "\(row.title) is showing in Larder again."
                        : "\(row.title) is hidden from Larder. Wilted still keeps its episodes."
                } catch {
                    self.podcastOperationMessage = "\(row.title) could not be updated."
                    return
                }
                guard let next = self.queuedFeedEnabled.removeValue(forKey: feedID), next != target,
                      let latest = self.subscriptions.first(where: { $0.id == feedID }) else { return }
                target = next
                row = latest
                self.pendingFeedWrites[feedID] = .updating(enabled: next)
            }
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Unsubscribes and clears every record the feed owned, committing before
    /// anything on screen changes.
    ///
    /// The store's cascade is one save, so a throw means nothing was removed
    /// and the row, selection and player stay as they were for a retry. Audio
    /// already downloaded stays on disk: an audio revision is identified by
    /// its content, so removing files here could break an episode from another
    /// feed that happens to share them. There is no Undo; resubscribing is the
    /// way back.
    @discardableResult
    func commitUnsubscribe(_ subscription: WiltedMacSubscription) async throws -> Int {
        guard let store, pendingFeedWrites[subscription.id] == nil else { throw WiltedMacRemovalUnavailable() }
        let feedID = try ItemID(rawValue: subscription.id)
        pendingFeedWrites[subscription.id] = .removing
        defer { pendingFeedWrites[subscription.id] = nil }
        // Episode rows carry no feed identity, so the feed's members are read
        // before the cascade deletes them.
        let owned = Set(try await store.podcastEpisodes(for: feedID).map(\.itemID.rawValue))
        let removed = try await store.unsubscribeFromPodcast(feedID: feedID)
        let loaded = isPodcastPlayback ? playback?.itemID?.rawValue : nil
        if [currentPodcastEpisodeID, loaded].contains(where: { $0.map(owned.contains) == true }) {
            stopPlaybackAfterCommittedRemoval()
        }
        if let selected = selectedLibraryItemID, owned.contains(selected) { selectedLibraryItemID = nil }
        // Undo records for this feed's episodes would restore rows that no
        // longer exist; any other episode's undo is left alone.
        if undoableRemoval?.feedID == subscription.id { undoableRemoval = nil }
        if let skipped = undoableSkip, owned.contains(skipped.id) { undoableSkip = nil }
        subscriptions.removeAll { $0.id == subscription.id }
        // The cascade has committed, so a failed reload must not read as a
        // failed removal: the rows above are already gone, and the error is
        // logged rather than thrown.
        do {
            let values = try await loadLibrary(from: store)
            articles = values.articles
            applyEpisodes(values.episodes)
            subscriptions = values.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: store)
        } catch {
            removalLog.error("Library reload after unsubscribe failed: \(String(describing: error), privacy: .public)")
        }
        await refreshPodcastQueueState()
        return removed
    }
#endif

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
    ///
    /// `requireStarted` is false only for the phone's Mark completed, where the listening
    /// happened on the phone and the Mac has no saved position of its own.
    func skipEpisode(_ episode: WiltedMacEpisode, requireStarted: Bool = true) {
#if canImport(WiltedProducer)
        guard !requireStarted || hasStartedEpisode(episode) else {
            podcastOperationMessage = "\(episode.title) was not started, so nothing was marked completed."
            return
        }
        withdrawPreparationRequest(for: episode.id)
        undoableRemoval = nil
        let wasPlaying = currentPodcastEpisodeID == episode.id
        undoableSkip = episode
        podcastOperationMessage = "Marked \(episode.title) completed. Undo completion restores it."
        trackSubscriptionWrite { [weak self] in
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
                await self.releaseWaitingEpisodesAfterRetirement(of: episode)
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
        trackSubscriptionWrite { [weak self] in
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
        trackSubscriptionWrite { [weak self] in
            guard let self else { return }
            if wasPlaying { await self.stopPlaybackForRemovedEpisode() }
            if await self.dismissEpisode(episode) == false {
                self.podcastOperationMessage = "\(episode.title) could not be removed."
            } else {
                self.undoableRemoval = self.dismissedEpisodes.first { $0.id == episode.id }
                await self.releaseWaitingEpisodes(feedIDs: Set([episode.feedID].compactMap { $0 }))
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
    /// Tracks finite subscription writes so fixture teardown can cancel and
    /// drain them before its owned store directory is removed.
    func trackSubscriptionWrite(_ operation: @escaping @MainActor () async -> Void) {
        guard !isClosingTemporaryState else { return }
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.subscriptionWriteTasks[id] = nil
        }
        subscriptionWriteTasks[id] = task
    }

    func startPodcastRefresh(
        urls: [URL], subscribing: Bool,
        initialMetadataLimit: Int? = nil,
        requestID: UUID? = nil
    ) {
        guard !isClosingTemporaryState, podcastRefreshTask == nil else { return }
        isRefreshingPodcasts = true
        undoableRemoval = nil
        podcastOperationMessage = subscribing ? "Adding podcast feed…" : "Refreshing subscribed podcasts…"
        let ledgerToken = UUID()
        let operationID = UUID()
        podcastRefreshOperationID = operationID
        podcastRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.subscriptionWriteTasks[ledgerToken] = nil
                if self.podcastRefreshOperationID == operationID,
                   (requestID == nil || self.podcastSubscriptionRequestID == requestID) {
                    self.isRefreshingPodcasts = false
                    self.podcastRefreshTask = nil
                    self.podcastRefreshOperationID = nil
                    self.settleFeedRefreshStates()
                    if subscribing {
                        self.isCheckingPodcastSubscription = false
                        self.podcastSubscriptionRequestID = nil
                    }
                }
            }
            do {
                let result = try await self.refreshPodcastURLs(
                    urls, subscribing: subscribing, initialMetadataLimit: initialMetadataLimit, requestID: requestID
                )
                guard self.podcastRefreshOperationID == operationID,
                      requestID == nil || self.podcastSubscriptionRequestID == requestID else { return }
                self.lastPodcastRefreshNewEpisodeIDs = result.newEpisodeIDs.map(\.rawValue)
                if !subscribing, result.successfulFeedCount > 0 {
                    self.setLastAutomationRefresh(Date())
                }
                if subscribing {
                    let showName = result.successfulFeedTitles.first ?? "this podcast"
                    self.podcastFeedDraft = ""
                    if let duplicate = result.duplicateSubscription {
                        self.selectedPodcastFeedID = duplicate.rawValue
                        self.podcastFeedDraftStatus = "Already following \(showName)."
                        self.podcastOperationMessage = "Already following \(showName)."
                    } else {
                        self.selectedPodcastFeedID = nil
                        let count = result.newEpisodeIDs.count
                        self.podcastFeedDraftStatus = "\(showName) added with \(count) episode\(count == 1 ? "" : "s")."
                        self.podcastOperationMessage = self.podcastFeedDraftStatus
                    }
                } else {
                    self.podcastOperationMessage = result.newEpisodeIDs.isEmpty
                        ? "Podcast episodes are up to date."
                        : "Added \(result.newEpisodeIDs.count) new episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
                }
            } catch is CancellationError {
                guard self.podcastRefreshOperationID == operationID,
                      requestID == nil || self.podcastSubscriptionRequestID == requestID else { return }
                self.podcastFeedDraftStatus = subscribing ? Self.podcastCheckCancelledStatus : self.podcastFeedDraftStatus
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch PodcastFeedClientError.cancelled {
                guard self.podcastRefreshOperationID == operationID,
                      requestID == nil || self.podcastSubscriptionRequestID == requestID else { return }
                self.podcastFeedDraftStatus = subscribing ? Self.podcastCheckCancelledStatus : self.podcastFeedDraftStatus
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch let partial as PodcastSubscriptionPartialFailure {
                guard self.podcastRefreshOperationID == operationID,
                      requestID == nil || self.podcastSubscriptionRequestID == requestID else { return }
                let prefix = partial.wasAlreadySubscribed ? "Already following \(partial.feedTitle)" : "\(partial.feedTitle) was added"
                self.podcastFeedDraftStatus = "\(prefix), but its episode metadata could not be saved. Retry refresh."
                self.podcastOperationMessage = self.podcastFeedDraftStatus
            } catch {
                guard self.podcastRefreshOperationID == operationID,
                      requestID == nil || self.podcastSubscriptionRequestID == requestID else { return }
                self.podcastFeedDraftStatus = subscribing
                    ? "Podcast feed unavailable. Check the address or retry when online."
                    : self.podcastFeedDraftStatus
                self.podcastOperationMessage = "Podcast feed unavailable. Check the address or retry when online."
            }
        }
        if let podcastRefreshTask {
            subscriptionWriteTasks[ledgerToken] = podcastRefreshTask
        }
    }

#endif
}
