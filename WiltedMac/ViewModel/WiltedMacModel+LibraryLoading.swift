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

extension WiltedMacModel {
#if canImport(WiltedProducer)
    struct PodcastPlaybackOriginRecord: Codable {
        let libraryPath: String
        let episodeIDs: [String]
        let currentEpisodeID: String
        let origin: String
    }

    static func podcastPlaybackOriginPreferenceKey(for libraryURL: URL) -> String {
        let identity = libraryURL.standardizedFileURL.resolvingSymlinksInPath().path
        return podcastPlaybackOriginPreferenceKeyPrefix + Data(identity.utf8).base64EncodedString()
    }

    private var podcastPlaybackOriginLibraryPath: String {
        libraryURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func restoredPodcastPlaybackOrigin(for state: PodcastQueueState) -> Bool? {
        let key = Self.podcastPlaybackOriginPreferenceKey(for: libraryURL)
        guard let data = preferences.data(forKey: key),
              let record = try? JSONDecoder().decode(PodcastPlaybackOriginRecord.self, from: data),
              record.libraryPath == podcastPlaybackOriginLibraryPath,
              record.episodeIDs == state.episodeIDs.map(\.rawValue),
              record.currentEpisodeID == state.currentEpisodeID?.rawValue else {
            preferences.removeObject(forKey: key)
            return nil
        }
        switch record.origin {
        case "larder": return true
        case "generic": return false
        default:
            preferences.removeObject(forKey: key)
            return nil
        }
    }

    func persistPodcastPlaybackOrigin(for state: PodcastQueueState) {
        guard isPodcastPlayback, !isRestoringPodcastPlayback,
              let currentEpisodeID = currentPodcastEpisodeID,
              state.currentEpisodeID?.rawValue == currentEpisodeID else { return }
        persistPodcastPlaybackOrigin(currentEpisodeID: currentEpisodeID, episodeIDs: state.episodeIDs.map(\.rawValue))
    }

    private func persistPodcastPlaybackOrigin(currentEpisodeID: String, episodeIDs: [String]) {
        guard isPodcastPlayback, !isRestoringPodcastPlayback,
              episodeIDs.contains(currentEpisodeID) else { return }
        let record = PodcastPlaybackOriginRecord(
            libraryPath: podcastPlaybackOriginLibraryPath,
            episodeIDs: episodeIDs,
            currentEpisodeID: currentEpisodeID,
            origin: isLarderQueuePlayback ? "larder" : "generic"
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        preferences.set(data, forKey: Self.podcastPlaybackOriginPreferenceKey(for: libraryURL))
    }

    func clearPodcastPlaybackOrigin() {
        preferences.removeObject(forKey: Self.podcastPlaybackOriginPreferenceKey(for: libraryURL))
        isLarderQueuePlayback = false
    }

    /// Array-compatible rows paired with the sequence at which their store
    /// read began. This is transient read provenance, never a second store.
    struct LibraryEpisodeRows: RandomAccessCollection {
        let values: [WiltedMacEpisode]
        let readEpoch: UInt64
        var startIndex: Int { values.startIndex }
        var endIndex: Int { values.endIndex }
        subscript(position: Int) -> WiltedMacEpisode { values[position] }
    }

#if canImport(WiltedProducer)
    func refreshPodcastQueueState() async {
        guard let store else { return }
        podcastQueueRefreshGeneration &+= 1
        let generation = podcastQueueRefreshGeneration
        let selectionToken = playbackCommands.selectionToken
        let loadedItemID = playback?.itemID
        let loadedRevisionID = playback?.revisionID
        guard let state = try? await store.podcastQueueState() else { return }
        // The test barrier holds a real actor-read state while a later Keep
        // commits and advances the generation, proving that old queue bytes
        // cannot publish after the decision.
        await podcastQueueReadBarrierForTesting?()
        guard generation == podcastQueueRefreshGeneration, !Task.isCancelled,
              selectionToken == playbackCommands.selectionToken,
              loadedItemID == playback?.itemID, loadedRevisionID == playback?.revisionID else { return }
        podcastQueueIDs = state.episodeIDs.map(\.rawValue)
        applyLarderSortIfNeeded()
        // A playlist entry plays outside the queue: the queue's current item is not what is loaded.
        if isPodcastPlayback, !playlistSessionIsCurrent {
            let loadedEpisodeID = playback?.itemID?.rawValue
            let activeEpisodeID = loadedEpisodeID.flatMap { id in
                episodes.contains(where: { $0.id == id }) ? id : nil
            }
            currentPodcastEpisodeID = activeEpisodeID ?? state.currentEpisodeID?.rawValue
            persistPodcastPlaybackOrigin(for: state)
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
        if movedToAnotherEpisode, playbackOperationStatus == nil, let itemID {
            persistPodcastPlaybackOrigin(currentEpisodeID: itemID.rawValue, episodeIDs: podcastQueueIDs)
        }
        playbackOperationStatus = nil
        refreshPlaybackReadout()
        // Continuous playback advances the queue without going through
        // `playEpisode`, so the previous episode's transcript would otherwise
        // stay on screen against the new audio.
        if movedToAnotherEpisode, let itemID {
            currentTranscript = .unavailable
            requestPlaybackPresentation(itemID: itemID, includesCuts: true,
                                        refreshQueue: true, reloadRows: true)
        }
    }

    /// Re-reads the rows the Library draws from the store.
    ///
    /// Failure is silent on purpose: the rows on screen are the ones the last
    /// successful read produced, and replacing them with nothing because a
    /// refresh failed would take the library away over a transient error.
    func reloadLibraryRows() async {
        guard let store else { return }
        // Retry a rename-invalidated read once, using a fresh store snapshot and the same
        // decision epoch guard. Reads rejected while a writer is pending wait for settlement.
        for _ in 0..<2 {
            guard let values = try? await loadLibrary(from: store) else { return }
            guard applyEpisodes(values.episodes) else {
                guard values.episodes.readEpoch < feedRenameReadEpoch else { return }
                if !pendingFeedRenames.isEmpty {
                    feedRenameNeedsReload = true
                    return
                }
                continue
            }
            articles = values.articles
            subscriptions = values.subscriptions
            pruneNavigationState()
            if playlists.isLoaded { await loadPlaylists() }
            return
        }
    }

    func loadLibrary(from store: LocalLibraryStore) async throws
        -> (articles: [WiltedMacArticle], episodes: LibraryEpisodeRows, subscriptions: [WiltedMacSubscription]) {
        libraryReadEpoch &+= 1
        let readEpoch = libraryReadEpoch
        let identity = try await store.podcastLibraryIdentitySnapshot()
        let snapshot = identity.library
        await librarySnapshotReadBarrierForTesting?()
        let associations = WiltedMacLocalLibraryStateSource.associationMetadata(associations: identity.associations, states: identity.states)
        if readEpoch == libraryReadEpoch {
            episodeAssociations = Dictionary(associations.flatMap { association in
                association.memberIDs.map { ($0.rawValue, association) }
            }, uniquingKeysWith: { first, _ in first })
        }

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
        let displayNames = Dictionary(allSubscriptions.compactMap { subscription in
            subscription.displayName.map { (subscription.feedID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        // A pending Show episodes projection decides the feed's Larder
        // visibility, not only the snapshot's durable enabled flag, so a load
        // that began before the toggle cannot republish the hidden rows.
        let subscribed = Set(allSubscriptions.compactMap { subscription -> ItemID? in
            let enabled = projectedFeedEnabled(subscription.feedID.rawValue) ?? subscription.enabled
            return enabled ? subscription.feedID : nil
        })
        var episodeCounts: [ItemID: Int] = [:]
        for episode in snapshot.episodes { episodeCounts[episode.feedID, default: 0] += 1 }
        let subscriptionValues = allSubscriptions.compactMap { subscription -> WiltedMacSubscription? in
            guard let feed = feeds[subscription.feedID] else { return nil }
            return WiltedMacSubscription(
                id: subscription.feedID.rawValue, title: feedRenameDisplayName(subscription.feedID.rawValue, stored: subscription.displayName) ?? feed.title, feedURL: feed.canonicalURL,
                episodeCount: episodeCounts[subscription.feedID] ?? 0,
                subscribedAt: subscription.subscribedAt.date, enabled: subscription.enabled,
                publisherTitle: feed.title, displayName: feedRenameDisplayName(subscription.feedID.rawValue, stored: subscription.displayName)
            )
        }.sorted { LibrarySortKey.title($0.title).localizedStandardCompare(LibrarySortKey.title($1.title)) == .orderedAscending }
        let downloads = snapshot.downloads
        var episodeValues: [WiltedMacEpisode] = []
        // Larder projects every subscribed episode, so its preparation
        // evidence cannot use Prep's display-oriented 200-run default --
        // `snapshot.preparationRuns` is already uncapped.
        // Retained attempt history has several summaries per raw item. Project
        // one current generation without discarding the underlying history.
        var runs: [ItemID: PreparationRunSummary] = [:]
        // The stamp builder needs every run, not only the newest one: the
        // prepared line must come from the run that produced the ready audio
        // even when a later retry failed.
        var runsByItem: [ItemID: [PreparationRunSummary]] = [:]
        for run in snapshot.preparationRuns where run.requestID.hasPrefix(Self.podcastRequestPrefix) {
            runsByItem[run.itemID, default: []].append(run)
            if let previous = runs[run.itemID], !Self.preparationRunIsNewer(run, than: previous) { continue }
            runs[run.itemID] = run
        }
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
            let feedTitle = feedRenameDisplayName(episode.feedID.rawValue, stored: displayNames[episode.feedID])
                ?? feeds[episode.feedID]?.title ?? "Podcast"
            // One `stat`, never a read: media availability has no durable
            // record, so a missing file downgrades only this cached flag,
            // never the outcome or listening rows that prove the work happened.
            let isReadyMediaAvailable = revision.map {
                mediaAvailabilityChecker.fileExists(atPath: $0.mediaURL.path)
            } ?? false
            episodeValues.append(WiltedMacEpisode(
                id: episode.itemID.rawValue, title: episode.title, feedTitle: feedTitle,
                summary: Self.episodeSummary(notes: episode.notes, fallback: episode.author ?? feedTitle),
                notes: episode.notes, artworkURL: episode.artworkURL ?? feeds[episode.feedID]?.artworkURL ?? fixtureArtworkURL,
                releasedAt: (episode.publishedTime ?? episode.createdAt).date,
                publishedAt: episode.publishedTime?.date,
                sourceDurationSeconds: episode.durationSeconds,
                playableDurationSeconds: revision?.revision.durationSeconds,
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
                preparationStamp: WiltedMacPreparationStamp.make(
                    outcome: outcome,
                    readyRevisionID: revision?.revision.revisionID,
                    runs: runsByItem[episode.itemID] ?? []
                ),
                feedID: episode.feedID.rawValue,
                feedURL: episode.feedURL,
                episodeLink: episode.episodeLink
            ))
        }
        episodeValues.append(contentsOf: Self.audiobookRows(from: snapshot, mediaAvailability: mediaAvailabilityChecker))
        // Article feeds are stored beside podcast feeds but are not podcast feeds, so every reload merges
        // them here, from the same snapshot (no second store hop).
        let allSubscriptionValues = Self.subscriptionRows(
            subscriptionValues, articleFeeds: snapshot.articleFeeds, stored: allSubscriptions
        )
        // In-flight removals stay projected onto the reload, so a snapshot
        // cannot resurrect a row whose completion is still writing.
        let projectedEpisodeValues = Self.applyingPendingEpisodeCompletions(
            episodeValues, projections: episodeCompletionProjections
        )
        return (articleValues, LibraryEpisodeRows(values: projectedEpisodeValues, readEpoch: readEpoch),
                allSubscriptionValues.map(applyingPendingFeedRename).map(applyingPendingFeedEnabled))
    }

    /// Imported audiobook volumes as episode-shaped rows, so the durable queue, the player and the
    /// Larder carry them with no second path. A book has no feed, nothing to download and nothing to
    /// prepare: its single joined file is the ready revision, so it reads as downloaded and prepared
    /// and is playable exactly while that file is on disk. A removed volume has no row.
    nonisolated static func audiobookRows(
        from snapshot: LocalLibraryStore.PodcastLibrarySnapshot,
        mediaAvailability: any WiltedMacMediaAvailabilityChecking
    ) -> [WiltedMacEpisode] {
        snapshot.audiobooks.compactMap { book -> WiltedMacEpisode? in
            guard !book.isRemoved, snapshot.removalKindByEpisode[book.itemID] != .dismissed else { return nil }
            let revision = snapshot.readyRevisions[book.itemID]
            let playbackState = revision.flatMap {
                snapshot.playbackStates["\(book.itemID.rawValue)|\($0.revision.revisionID.rawValue)"]
            }
            let released = revision?.revision.createdAt.date ?? .distantPast
            let label = book.sourceFormat == LocalLibraryStore.reportSourceFormat ? "Morning report" : "Audiobook"
            return WiltedMacEpisode(
                id: book.itemID.rawValue, title: book.title, feedTitle: label,
                summary: book.author ?? label, artworkURL: nil,
                releasedAt: released, publishedAt: released,
                sourceDurationSeconds: book.durationSeconds, playableDurationSeconds: book.durationSeconds,
                durationSeconds: book.durationSeconds, playbackSeconds: playbackState?.positionSeconds ?? 0,
                isPlayed: snapshot.listeningStates[book.itemID]?.completedAt != nil,
                retiredAt: snapshot.retiredAtByEpisode[book.itemID]?.date,
                removalKind: snapshot.removalKindByEpisode[book.itemID],
                downloadState: .completed, preparationState: .prepared(summary: label),
                isReadyMediaAvailable: revision.map { mediaAvailability.fileExists(atPath: $0.mediaURL.path) } ?? false,
                audiobook: WiltedMacAudiobookDetails(
                    author: book.author,
                    chapters: book.chapters.map { WiltedMacChapter(title: $0.title, startSeconds: $0.startSeconds) },
                    sourceFormat: book.sourceFormat, volumeIndex: book.volumeIndex, volumeCount: book.volumeCount
                )
            )
        }
    }

    func loadDismissedEpisodes(from store: LocalLibraryStore) async throws -> [WiltedMacDismissedEpisode] {
        let snapshot = try await store.podcastLibrarySnapshot()
        let feeds = snapshot.feeds
        let displayNames = Dictionary(snapshot.subscriptions.compactMap { subscription in
            subscription.displayName.map { (subscription.feedID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let episodeByID = Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.itemID, $0) })
        let preparedItemIDs = Set(snapshot.preparationRuns.map(\.itemID))
        return try await store.dismissedPodcastEpisodes().map { dismissal in
            let episode = episodeByID[dismissal.episodeID]
            // V13's migration placeholder uses the invalid URL and its
            // dismissal time as creation time. It is a durable removal record,
            // not proof of a source date or source duration.
            let factualEpisode = episode?.feedURL.host == "wilted.invalid" ? nil : episode
            return WiltedMacDismissedEpisode(
                id: dismissal.episodeID.rawValue,
                feedID: dismissal.feedID?.rawValue,
                title: dismissal.title ?? "Removed podcast episode",
                feedTitle: dismissal.feedID.flatMap { feedRenameHistoryTitle($0.rawValue, stored: displayNames[$0], publisherTitle: feeds[$0]?.title) }
                    ?? factualEpisode.flatMap { feedRenameHistoryTitle($0.feedID.rawValue, stored: displayNames[$0.feedID], publisherTitle: feeds[$0.feedID]?.title) },
                publishedAt: factualEpisode?.publishedTime?.date,
                sourceDurationSeconds: factualEpisode?.durationSeconds,
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

    /// Projects retained history by persisted generation before observation time.
    nonisolated static func preparationRunIsNewer(
        _ candidate: PreparationRunSummary, than previous: PreparationRunSummary
    ) -> Bool {
        let candidateAttempt = candidate.entries.first?.status.attempt
        let previousAttempt = previous.entries.first?.status.attempt
        let candidateSequence = candidateAttempt?.requestSequence ?? -1
        let previousSequence = previousAttempt?.requestSequence ?? -1
        if candidateSequence != previousSequence { return candidateSequence > previousSequence }
        let candidateCount = candidateAttempt?.attemptCount ?? -1
        let previousCount = previousAttempt?.attemptCount ?? -1
        if candidateCount != previousCount { return candidateCount > previousCount }
        if candidate.updatedAt != previous.updatedAt { return candidate.updatedAt > previous.updatedAt }
        return candidate.id > previous.id
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
            recoveryCopyURL: nil,
            canRetry: canRetry
        )
    }

    /// Whether `name` is a directory the store retains a copy of the library
    /// in: the legacy `<library>.v5-*` copy or a migration backup named
    /// `<library>.v<N>-backup-<UUID>` (LocalLibraryStore+Migration).
    nonisolated static func isRecoveryCopyDirectoryName(_ name: String, libraryName: String) -> Bool {
        let prefix = "\(libraryName).v"
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        if rest.hasPrefix("5-") { return true }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && rest.dropFirst(digits.count).hasPrefix("-backup-")
    }

    /// Every retained copy of the library beside `libraryURL`, newest first.
    nonisolated static func recoveryCopyURLs(for libraryURL: URL) -> [URL] {
        let manager = FileManager.default
        let directory = libraryURL.deletingLastPathComponent()
        let libraryName = libraryURL.lastPathComponent
        let candidates = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .filter { isRecoveryCopyDirectoryName($0.lastPathComponent, libraryName: libraryName) }
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
            guard self.applyEpisodes(values.episodes) else {
                if values.episodes.readEpoch < self.feedRenameReadEpoch { await self.reloadLibraryRows() }
                return
            }
            self.articles = values.articles
            self.subscriptions = values.subscriptions
            self.dismissedEpisodes = (try? await self.loadDismissedEpisodes(from: store)) ?? self.dismissedEpisodes
        }
    }

#endif
}
