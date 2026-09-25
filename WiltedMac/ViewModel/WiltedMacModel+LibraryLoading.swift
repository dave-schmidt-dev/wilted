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
#if canImport(WiltedProducer)
    func refreshPodcastQueueState() async {
        guard let store else { return }
        podcastQueueRefreshGeneration &+= 1
        let generation = podcastQueueRefreshGeneration
        guard let state = try? await store.podcastQueueState() else { return }
        guard generation == podcastQueueRefreshGeneration else { return }
        podcastQueueIDs = state.episodeIDs.map(\.rawValue)
        applyMenuSortIfNeeded()
        if isPodcastPlayback {
            let loadedEpisodeID = playback?.itemID?.rawValue
            let activeEpisodeID = loadedEpisodeID.flatMap { id in
                episodes.contains(where: { $0.id == id }) ? id : nil
            }
            currentPodcastEpisodeID = state.currentEpisodeID?.rawValue ?? activeEpisodeID
        }
    }

    func applyPodcastPlaybackObservation(itemID: ItemID?, fault: PlaybackControllerError?) {
        let movedToAnotherEpisode = itemID != nil && currentPodcastEpisodeID != itemID?.rawValue
        currentPodcastEpisodeID = itemID?.rawValue
        if itemID != nil {
            selectedArticleID = nil
            isPodcastPlayback = true
            isNowPlaying = true
        }
        playbackError = switch fault {
        case .podcastMediaUnavailable?: "This episode's saved audio is unavailable."
        case .podcastMediaUnreadable?: "This episode's saved audio could not be opened."
        case .some: "Podcast playback could not continue."
        case nil: nil
        }
        // The fault names the episode that actually failed to load, which on
        // the successor-load-throws path is not `itemID` (that stays the one
        // that just finished). Repairing here, ahead of the next reload,
        // closes the window between a file vanishing and the next snapshot
        // noticing -- e.g. a second `canSelectNextEpisode` check right after
        // this fault fires.
        if case let .podcastMediaUnavailable(unavailableID) = fault,
           let index = episodes.firstIndex(where: { $0.id == unavailableID.rawValue }) {
            episodes[index].isReadyMediaAvailable = false
        }
        playbackOperationStatus = nil
        refreshPlaybackReadout()
        // Continuous playback advances the queue without going through
        // `playEpisode`, so the previous episode's transcript would otherwise
        // stay on screen against the new audio.
        if movedToAnotherEpisode, let itemID {
            currentTranscript = .unavailable
            Task { [weak self] in
                guard let self else { return }
                await self.loadEpisodeTranscript(itemID: itemID)
                // The episode just left behind may be the one that finished
                // and pushed the queue into this one; its Played badge is
                // otherwise stale until something else happens to reload it.
                await self.reloadLibraryRows()
            }
        }
    }

    /// Handles a podcast episode running out with nothing queued behind it.
    ///
    /// `PlaybackController` already advances on its own when the Up Next
    /// queue has another entry — that case surfaces through
    /// `applyPodcastPlaybackObservation` instead and never reaches here. Up
    /// Next is a manually curated list though: pressing Play on a single
    /// episode queues only that one, so the ordinary case of a listen
    /// finishing with nothing queued after it is the common one, not the
    /// exception. This is that case: look at the Larder in the order it is
    /// shown and start the next episode that is both downloaded and
    /// successfully prepared, rather than trading one stall for another with
    /// no one watching.
    ///
    /// The episode that just finished is then retired -- taken off the
    /// Larder shelf without deleting it, unlike the Skip button's dismissal --
    /// because leaving it there means the owner clears by hand what playing
    /// it to the end already said.
    func handlePodcastPlaybackFinished() {
        refreshPlaybackReadout()
        guard isPodcastPlayback, let finishedID = currentPodcastEpisodeID,
              playback?.completed == true, !canSelectNextEpisode else { return }
        Task { [weak self] in
            guard let self else { return }
            // The completed record was already written by the controller
            // before this handler fired; reload so the finished row's Played
            // badge (and any other row that changed underneath it) is
            // current before searching past it.
            await self.reloadLibraryRows()
            let finished = self.episodes.first { $0.id == finishedID }
            // The successor is chosen before the finished episode goes,
            // because the search walks the ordered rows past the finished one
            // and there is nothing to walk past once it has been taken out.
            let next = self.nextReadyEpisode(after: finishedID)
            var note: String?
            if let finished, let id = try? ItemID(rawValue: finished.id) {
                // Finishing is not an accident, so no Undo is offered; and an
                // Undo left over from an earlier Skip must not attach itself
                // to this sentence about a different episode.
                self.undoableRemoval = nil
                // Queue membership is this caller's own concern; see the doc
                // comment on `retireFinishedEpisode` for why `completeAndRetire`
                // does not do this itself.
                if let playback = self.playback {
                    try? await playback.removePodcastQueueEpisode(id)
                    await self.refreshPodcastQueueState()
                }
                note = await self.completeAndRetire(id)
                    ?? "\(finished.title) could not be marked finished."
            }
            guard let next else {
                // Retirement leaves the row in `episodes`, so nothing else
                // clears the player the way a dismissal's deletion used to;
                // without this the finished, retired episode would keep
                // showing as current indefinitely.
                await self.stopPlaybackForRemovedEpisode()
                await self.reloadLibraryRows()
                self.podcastOperationMessage = [note, "No other downloaded, prepared episode is ready to play next."]
                    .compactMap { $0 }.joined(separator: " ")
                return
            }
            self.podcastOperationMessage = note
            self.playEpisode(next)
        }
    }

    /// The next episode after `finishedID`, in the same order the Larder
    /// shows them, whose audio is downloaded and whose preparation finished
    /// successfully.
    ///
    /// The anchor lookup runs against the unfiltered list because by the time
    /// this runs, `finishedID` itself may already be hidden or retired --
    /// the controller's own completion handler retires the finished episode
    /// before handing control back here. Only candidates after the anchor
    /// are filtered: already-played rows are skipped so a shorter episode
    /// already listened to does not loop back in, and optimistically-hidden
    /// or retired rows are skipped because neither should be handed back to
    /// the player.
    private func nextReadyEpisode(after finishedID: String) -> WiltedMacEpisode? {
        let ordered = Self.sortedLarderEpisodes(episodes, by: larderSort)
        guard let index = ordered.firstIndex(where: { $0.id == finishedID }) else { return nil }
        return ordered[ordered.index(after: index)...]
            .first {
                !hiddenEpisodeIDs.contains($0.id) && $0.retiredAt == nil && !$0.isPlayed
                    && canPlayEpisode($0)
            }
    }

    /// Re-reads the rows the Library draws from the store.
    ///
    /// Failure is silent on purpose: the rows on screen are the ones the last
    /// successful read produced, and replacing them with nothing because a
    /// refresh failed would take the library away over a transient error.
    func reloadLibraryRows() async {
        guard let store, let values = try? await loadLibrary(from: store) else { return }
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
    }

    /// Re-reads the local ledger without touching sync or mutable library rows.
    func refreshLifetimeStatistics() async {
        guard let store, let totals = try? await store.lifetimeStatistics() else { return }
        lifetimeStatistics = totals
    }

    func loadLibrary(from store: LocalLibraryStore) async throws
        -> (articles: [WiltedMacArticle], episodes: [WiltedMacEpisode], subscriptions: [WiltedMacSubscription]) {
        let snapshot = try await store.podcastLibrarySnapshot()

        var articleValues: [WiltedMacArticle] = []
        for article in snapshot.articles where !article.isDeleted {
            let revision = snapshot.readyRevisions[article.itemID]
            let playbackState: PlaybackState?
            if let revision {
                playbackState = snapshot.playbackStates["\(article.itemID.rawValue)|\(revision.revision.revisionID.rawValue)"]
            } else {
                playbackState = nil
            }
            articleValues.append(WiltedMacArticle(
                id: article.itemID.rawValue, title: article.title, source: article.source,
                url: article.canonicalURL, isReady: revision != nil,
                durationSeconds: revision?.revision.durationSeconds,
                playbackSeconds: playbackState?.positionSeconds ?? 0,
                isPlayed: playbackState?.completed ?? false,
                createdAt: article.createdAt.date
            ))
        }
        let feeds = snapshot.feeds
        let allSubscriptions = snapshot.subscriptions
        let subscribed = Set(allSubscriptions.filter(\.enabled).map(\.feedID))
        var episodeCounts: [ItemID: Int] = [:]
        for episode in snapshot.episodes { episodeCounts[episode.feedID, default: 0] += 1 }
        let subscriptionValues = allSubscriptions.compactMap { subscription -> WiltedMacSubscription? in
            guard let feed = feeds[subscription.feedID] else { return nil }
            return WiltedMacSubscription(
                id: subscription.feedID.rawValue, title: feed.title, feedURL: feed.canonicalURL,
                episodeCount: episodeCounts[subscription.feedID] ?? 0,
                subscribedAt: subscription.subscribedAt.date, enabled: subscription.enabled
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let downloads = snapshot.downloads
        var episodeValues: [WiltedMacEpisode] = []
        // Larder projects every subscribed episode, so its preparation
        // evidence cannot use Prep's display-oriented 200-run default --
        // `snapshot.preparationRuns` is already uncapped.
        let runs = Dictionary(
            uniqueKeysWithValues: snapshot.preparationRuns
                .filter { $0.requestID.hasPrefix(Self.podcastRequestPrefix) }
                .map { ($0.itemID, $0) }
        )
        // A dismissed episode keeps its row in the store (that is the whole
        // point of the unified removal column), but `episodes` is still the
        // "in the library" projection: `dismissedEpisodes` is the separate
        // list that surfaces it in the Removed popover. A retired episode
        // stays here -- `skippedFeedEpisodes` and the Larder filters read it
        // out of this same array by `removalKind`/`retiredAt`.
        for episode in snapshot.episodes
        where subscribed.contains(episode.feedID)
            && snapshot.removalKindByEpisode[episode.itemID] != .dismissed {
            let revision = snapshot.readyRevisions[episode.itemID]
            let playbackState: PlaybackState?
            if let revision {
                playbackState = snapshot.playbackStates["\(episode.itemID.rawValue)|\(revision.revision.revisionID.rawValue)"]
            } else {
                playbackState = nil
            }
            let transcript: Transcript?
            let outcome: PodcastPreparationOutcome?
            if let revision {
                transcript = snapshot.transcripts["\(episode.itemID.rawValue)|\(revision.revision.revisionID.rawValue)"]
                outcome = snapshot.preparationOutcomes["\(episode.itemID.rawValue)|\(revision.revision.revisionID.rawValue)"]
            } else {
                transcript = nil
                outcome = nil
            }
            // The listening record, not `PlaybackRecord`, is the durable
            // completion fact: `dismissPodcastEpisode` deletes every
            // `PlaybackRecord` for an episode, so a dismiss-then-restore
            // would otherwise forget that it was ever finished.
            let listeningState = snapshot.listeningStates[episode.itemID]
            let retiredAt = snapshot.retiredAtByEpisode[episode.itemID]
            let removalKind = snapshot.removalKindByEpisode[episode.itemID]
            let downloadState: WiltedMacEpisodeDownloadState
            switch downloads[episode.itemID]?.status {
            case .queued: downloadState = .queued
            case .downloading:
                let value = downloads[episode.itemID]!
                downloadState = .downloading(received: value.bytesReceived, expected: value.expectedByteCount)
            case .completed: downloadState = .completed
            case .failed: downloadState = .failed
            case .cancelled: downloadState = .cancelled
            case nil: downloadState = .notDownloaded
            }
            let feedTitle = feeds[episode.feedID]?.title ?? "Podcast"
            // One `stat`, never a read: media availability has no durable
            // record, so a missing file downgrades only this cached flag,
            // never the outcome or listening rows that prove the work happened.
            let isReadyMediaAvailable = revision.map {
                mediaAvailabilityChecker.fileExists(atPath: $0.mediaURL.path)
            } ?? false
            episodeValues.append(WiltedMacEpisode(
                id: episode.itemID.rawValue, title: episode.title, feedTitle: feedTitle,
                summary: Self.episodeSummary(notes: episode.notes, fallback: episode.author ?? feedTitle),
                notes: episode.notes, artworkURL: episode.artworkURL ?? feeds[episode.feedID]?.artworkURL,
                releasedAt: (episode.publishedTime ?? episode.createdAt).date,
                durationSeconds: revision?.revision.durationSeconds ?? episode.durationSeconds,
                playbackSeconds: playbackState?.positionSeconds ?? 0,
                isPlayed: listeningState?.completedAt != nil, retiredAt: retiredAt?.date, removalKind: removalKind,
                downloadState: downloadState,
                preparationState: Self.preparationState(
                    outcome: outcome,
                    run: runs[episode.itemID],
                    readyRevisionID: revision?.revision.revisionID,
                    transcript: transcript
                ),
                isReadyMediaAvailable: isReadyMediaAvailable,
                feedID: episode.feedID.rawValue,
                feedURL: episode.feedURL
            ))
        }
        return (articleValues, episodeValues, subscriptionValues)
    }

    func loadDismissedEpisodes(from store: LocalLibraryStore) async throws -> [WiltedMacDismissedEpisode] {
        let feeds = Dictionary(uniqueKeysWithValues: try await store.podcastFeeds().map { ($0.itemID, $0.title) })
        let preparedItemIDs = Set(try await store.preparationRuns().map(\.itemID))
        return try await store.dismissedPodcastEpisodes().map { dismissal in
            WiltedMacDismissedEpisode(
                id: dismissal.episodeID.rawValue,
                feedID: dismissal.feedID?.rawValue,
                title: dismissal.title ?? "Removed podcast episode",
                feedTitle: dismissal.feedID.flatMap { feeds[$0] },
                dismissedAt: dismissal.dismissedAt.date,
                hasPreparationHistory: preparedItemIDs.contains(dismissal.episodeID)
            )
        }
    }

    static let fixtureEpisodeNotes = """
    A walk through the machines that keep the field office quiet.

    Guest: Ada Ferris (https://example.com/ada)
    Sponsor: Quiet Co, code WILTED at https://example.com/quiet
    """

    /// The row's one-liner. The notes' first paragraph says what the episode
    /// is about; the author or show name, the old summary, only says who made it.
    nonisolated static func episodeSummary(notes: String?, fallback: String) -> String {
        let opening = notes?
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
        return String((opening ?? fallback).prefix(180))
    }

    /// What the library already knows about an episode's preparation.
    ///
    /// The outcome row is the durable proof that preparation completed: it
    /// must exist for the audio revision currently ready to play, and it must
    /// not be marked invalid by a later policy or pipeline change. That proof
    /// is checked before the run's own terminality, not after: a run that
    /// committed its outcome and then died before its terminal journal write
    /// is still proven, and must not read as stuck in `.preparing` forever
    /// just because its journal never closed. The journal is evidence, not
    /// proof -- it supplies the label's ad-count detail via
    /// `recordedSummary(of:)` and, only when no outcome exists, whether a run
    /// is still in flight or has failed. Once an outcome exists, a later
    /// run's own failure (a re-preparation that did not change anything)
    /// never demotes the still-current, proven state.
    nonisolated static func preparationState(
        outcome: PodcastPreparationOutcome?, run: PreparationRunSummary?,
        readyRevisionID: RevisionID?, transcript: Transcript?
    ) -> WiltedMacEpisodePreparationState {
        guard let readyRevisionID, let outcome,
              outcome.revisionID == readyRevisionID, outcome.eligibility != .invalid else {
            if let run, !run.isTerminal { return .preparing(stage: "Preparing…") }
            if let run, run.outcome == .failed { return .failed(preparationFailedLabel) }
            return .notPrepared
        }

        if transcript == nil || transcript?.availability == .absent || transcript?.timing == TranscriptTiming.none {
            return .prepared(summary: "Audio ready · Transcript unavailable")
        }
        switch transcript?.timing {
        case .published:
            return .prepared(summary: preparedSummary(of: run, timing: .published))
        case .aligned:
            return .prepared(summary: preparedSummary(of: run, timing: .aligned))
        case nil, .some(.none):
            return .prepared(summary: preparedSummary(of: run, timing: .none))
        }
    }

    nonisolated static func startupFailure(canRetry: Bool) -> WiltedMacStartupFailure {
        WiltedMacStartupFailure(
            message: "Wilted could not open your larder. The existing library was left in place.",
            detail: nil,
            retainedV5StoreURL: nil,
            canRetry: canRetry
        )
    }

    nonisolated static func retainedV5StoreURLs(for libraryURL: URL) -> [URL] {
        let manager = FileManager.default
        let directory = libraryURL.deletingLastPathComponent()
        let prefix = "\(libraryURL.lastPathComponent).v5-"
        let candidates = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { retainedDirectory -> (URL, Date)? in
                let retainedStore = retainedDirectory.appendingPathComponent(libraryURL.lastPathComponent)
                guard manager.fileExists(atPath: retainedStore.path) else { return nil }
                let values = try? retainedDirectory.resourceValues(forKeys: [.contentModificationDateKey])
                let date = values?.contentModificationDate ?? .distantPast
                return (retainedStore, date)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.path < $1.0.path
            }
            .map(\.0)
    }
#endif

    func refresh() {
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let values = try? await self.loadLibrary(from: store) else { return }
            self.articles = values.articles
            self.applyEpisodes(values.episodes)
            self.subscriptions = values.subscriptions
            self.dismissedEpisodes = (try? await self.loadDismissedEpisodes(from: store)) ?? self.dismissedEpisodes
        }
    }

#endif
}
