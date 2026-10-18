import Foundation
import WiltedLibrary
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

let removalLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "Removal")

extension WiltedMacModel {
#if canImport(WiltedProducer)
    /// The episode the Larder should start once the current one is finished:
    /// the first queued entry that is not the episode just finished, has not
    /// been retired or hidden, and can actually be played.
    func nextLarderEpisodeToPlay() -> WiltedMacEpisode? {
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
        issuePlaybackCommand(.select, pending: nil, target: episodeID,
                             failureMessage: "This episode's saved audio is unavailable.") { [weak self] command in
            guard let self else { return }
            guard let store = self.store,
                  let stored = try await store.readyRevision(for: itemID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try self.ensureCurrentPlaybackCommand(command)
            try await playback.load(stored)
            try self.ensureNewestSelection(command)
            if wasPlaying { try self.startIfCurrent(playback, for: command) }
            self.refreshPlaybackReadout()
            self.requestPlaybackPresentation(itemID: itemID, includesCuts: true, traceToken: command.token)
        }
        await playbackCommands.tail?.value
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
    /// The row and the Larder project the new value before the write is
    /// awaited, so the toggle answers the tap instead of waiting for the store.
    /// A repeat of the value being saved is acknowledged and dropped; a
    /// different value is held and written once, after the one in flight, and
    /// the projection follows the newest request instead of the first. A
    /// failure puts only this feed's enabled field back on its last durable
    /// value and restores the rows this projection withheld.
    func setSubscription(_ subscription: WiltedMacSubscription, enabled: Bool) {
#if canImport(WiltedProducer)
        guard let store, !isClosingTemporaryState else { return }
        let feedID = subscription.id
        switch pendingFeedWrites[feedID] {
        case .removing: return
        case let .updating(inFlight):
            queuedFeedEnabled[feedID] = enabled == inFlight ? nil : enabled
            if feedEnabledProjections[feedID] == nil {
                feedEnabledProjections[feedID] = WiltedMacFeedEnabledProjection(
                    committed: inFlight, projected: enabled
                )
            }
            projectFeedEnabled(feedID, enabled: enabled)
            invalidateProjectedLibraryReads()
            return
        case nil: break
        }
        let prior = feedEnabledProjections[feedID]
        let durable = prior?.committed
            ?? subscriptions.first(where: { $0.id == feedID })?.enabled
            ?? subscription.enabled
        pendingFeedWrites[feedID] = .updating(enabled: enabled)
        feedEnabledProjections[feedID] = WiltedMacFeedEnabledProjection(
            committed: durable, projected: enabled, withheldEpisodes: prior?.withheldEpisodes ?? []
        )
        projectFeedEnabled(feedID, enabled: enabled)
        invalidateProjectedLibraryReads()
        trackSubscriptionWrite { [weak self] in
            guard let self else { return }
            defer {
                self.pendingFeedWrites[feedID] = nil
                self.queuedFeedEnabled[feedID] = nil
                self.feedEnabledProjections[feedID] = nil
            }
            var target = enabled
            var row = subscription
            while true {
                do {
                    try await self.subscriptionWriteHookForTesting?()
                    try await store.save(subscription: PodcastSubscription(
                        feedID: try ItemID(rawValue: row.id), subscribedAt: Timestamp(row.subscribedAt), enabled: target
                    ))
                } catch {
                    self.rollbackFeedEnabledProjection(feedID, title: row.title)
                    return
                }
                // The enabled write is durable now. A failed reread below must
                // not read as a failed write: the row already holds the
                // committed value and the projection stands as the record.
                self.feedEnabledProjections[feedID]?.committed = target
                if let values = try? await self.loadLibrary(from: store) {
                    self.articles = values.articles
                    self.applyEpisodes(values.episodes)
                    self.subscriptions = values.subscriptions
                }
                self.podcastOperationMessage = target
                    ? "\(row.title) is showing in Larder again."
                    : "\(row.title) is hidden from Larder. Wilted still keeps its episodes."
                guard let next = self.queuedFeedEnabled.removeValue(forKey: feedID), next != target else { return }
                target = next
                row = self.subscriptions.first(where: { $0.id == feedID }) ?? row
                self.pendingFeedWrites[feedID] = .updating(enabled: next)
                self.projectFeedEnabled(feedID, enabled: next)
                self.invalidateProjectedLibraryReads()
            }
        }
#endif
    }

    /// Puts a failed toggle back on the value of its last durable commit,
    /// touching only this feed's row and the episode rows this projection
    /// withheld. A concurrent rename, another feed's pending write, and every
    /// other row stay exactly where they are.
    func rollbackFeedEnabledProjection(_ feedID: String, title: String) {
        if let projection = feedEnabledProjections[feedID] {
            projectFeedEnabled(feedID, enabled: projection.committed)
        }
        podcastOperationMessage = "\(title) could not be updated."
    }

#if canImport(WiltedProducer)
    /// Unsubscribes and clears every record the feed owned, committing before
    /// anything on screen changes.
    ///
    /// The store's cascade is one save, so a throw means nothing was removed
    /// and the row, selection and player stay as they were for a retry. The
    /// feed's downloaded audio is deleted once the save lands (W-INV-025),
    /// except a file another surviving episode still names: an audio revision
    /// is identified by its content, so episodes can share one. There is no
    /// Undo; resubscribing is the way back.
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

    /// Podcast Remove records the same retained-media finish as Mark completed.
    /// The existing nonpodcast branch keeps its established removal behavior.
    func removeEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        if !episode.isAudiobook {
            finishEpisodes([episode])
            return
        }
#endif
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
        let selectionToken = playbackCommands.selectionToken
        let itemID = playback?.itemID
        let revisionID = playback?.revisionID
        try? await playback?.pause()
        guard selectionToken == playbackCommands.selectionToken,
              itemID == playback?.itemID, revisionID == playback?.revisionID else { return }
        cancelPlaybackPresentation()
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
    }

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

    // MARK: Article feeds

    /// `base` plus the article feeds the reader follows. Article feeds are stored beside podcast feeds
    /// but are not `PodcastFeed`s, so the podcast rows that produced `base` do not carry them.
    static func subscriptionRows(
        _ base: [WiltedMacSubscription], articleFeeds feeds: [ArticleFeed], stored: [PodcastSubscription]
    ) -> [WiltedMacSubscription] {
        guard !feeds.isEmpty else { return base }
        let byFeed = Dictionary(stored.map { ($0.feedID, $0) }, uniquingKeysWith: { first, _ in first })
        let baseIDs = Set(base.map(\.id))
        let articleRows = feeds.compactMap { feed -> WiltedMacSubscription? in
            guard !baseIDs.contains(feed.itemID.rawValue), let subscription = byFeed[feed.itemID] else { return nil }
            return WiltedMacSubscription(
                id: feed.itemID.rawValue, title: subscription.displayName ?? feed.title, feedURL: feed.canonicalURL, episodeCount: 0,
                subscribedAt: subscription.subscribedAt.date, enabled: subscription.enabled,
                publisherTitle: feed.title, displayName: subscription.displayName
            )
        }
        return (base + articleRows).sorted { LibrarySortKey.title($0.title).localizedStandardCompare(LibrarySortKey.title($1.title)) == .orderedAscending }
    }

    /// Follows (or refreshes) a feed that lists posts rather than audio. A new subscription prepares
    /// nothing: its back catalogue is offered, not queued for the GPU. A refresh keeps what the feed's
    /// rules and policy keep, one article at a time through the shared preparation gate.
    func refreshArticleFeed(
        url: URL, subscribing: Bool, store: LocalLibraryStore
    ) async throws -> (feedID: ItemID, title: String, duplicate: Bool) {
        let document = try await podcastFeedClient.loadArticleFeed(url)
        if subscribing, document.items.isEmpty { throw PodcastFeedHasNoAudio() }
        let feed = try ArticleFeed(
            canonicalURL: url, title: document.title, author: document.author, createdAt: Timestamp(Date())
        )
        try await store.save(articleFeed: feed)
        try Task.checkCancellation()
        var duplicate = false
        if subscribing {
            let inserted = try await store.subscribeIfNeeded(
                PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(Date()))
            )
            duplicate = !inserted
        }
        let refresh = ArticleFeedRefresh(store: store, defaults: automationSettings.feedAutomationDefaults)
        var prepare: ArticleFeedRefresh.Prepare?
        if !subscribing {
            prepare = { [weak self] (link: URL) async throws -> ItemID in
                guard let self else { throw CancellationError() }
                return try await self.prepareFeedArticle(link)
            }
        }
        let outcome = try await refresh.refresh(feed: feed, document: document, prepare: prepare) { [weak self] line in
            Task { @MainActor in self?.podcastOperationMessage = line }
        }
        setOfferedArticles(outcome.offered, feed: feed)
        return (feed.itemID, feed.title, duplicate)
    }

    /// Prepares one feed article behind the same admission gate as a pasted article, so text-to-speech
    /// never holds the GPU twice, and records the work on its ticket.
    func prepareFeedArticle(_ url: URL) async throws -> ItemID {
        guard let coordinator else { throw ArticlePreparationError.failed("The local larder is unavailable.") }
        let subject = try ItemID.derive(from: url).rawValue
        let sequence = consumePreparationRequest(for: subject, kind: .articlePreparation)
        try await preparationGate.admit(sequence: sequence)
        defer { preparationGate.release() }
        do {
            let id = try await coordinator.prepareArticle(url: url) { [weak self] detail in
                Task { @MainActor in self?.podcastOperationMessage = "Preparing article: \(detail)" }
            }
            if await queuePreparedPublication(itemID: id) { syncLifecycle?.startAutomaticUpload() }
            await recordWorkTicketTransition(
                kind: .articlePreparation, subjectID: subject, requestSequence: sequence,
                state: .succeeded, resolvedItemID: id.rawValue
            )
            return id
        } catch {
            await recordWorkTicketTransition(
                kind: .articlePreparation, subjectID: subject, requestSequence: sequence,
                state: error is CancellationError ? .cancelled : .failed,
                failureKind: error is CancellationError ? nil : PodcastDownloadFailureKind.retryable.rawValue,
                lastFailureMessage: String(describing: error)
            )
            throw error
        }
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
                        self.podcastFeedDraftStatus = !result.articleFeedIDs.isEmpty
                            ? "\(showName) added as an article feed."
                            : "\(showName) added with \(count) episode\(count == 1 ? "" : "s")."
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
            } catch is PodcastFeedHasNoAudio {
                guard self.podcastRefreshOperationID == operationID,
                      requestID == nil || self.podcastSubscriptionRequestID == requestID else { return }
                self.podcastFeedDraftStatus = PodcastFeedHasNoAudio.message
                self.podcastOperationMessage = PodcastFeedHasNoAudio.message
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
