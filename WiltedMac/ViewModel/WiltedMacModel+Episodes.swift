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
    /// Rejects a snapshot that began before a durable Feed decision committed.
    /// Existing fixture arrays intentionally remain source-compatible below.
    @discardableResult
    func applyEpisodes(
        _ loaded: LibraryEpisodeRows, allowsAutomaticAdmissions: Bool = true
    ) -> Bool {
        guard loaded.readEpoch >= lastAppliedLibraryReadEpoch else { return false }
        lastAppliedLibraryReadEpoch = loaded.readEpoch
        applyEpisodes(loaded.values, allowsAutomaticAdmissions: allowsAutomaticAdmissions)
        return true
    }

#if canImport(WiltedProducer)
    /// Loads each feed and stores what the subscription horizon admits.
    ///
    /// The subscription is written before its episodes: the horizon rule reads
    /// it, so a feed subscribed to after its episodes were offered would admit
    /// nothing. Anything the feed published but Wilted did not keep is counted
    /// and reported -- a truncated back catalogue must never read as the whole
    /// feed.
    struct PodcastRefreshResult {
        var newEpisodeIDs: [ItemID] = []
        var duplicateSubscription: ItemID?
        var successfulFeedTitles: [String] = []
        var successfulFeedCount = 0
        var failedFeedCount = 0
        /// How each refreshed feed ended, keyed by the URL it was loaded from.
        var feedOutcomes: [URL: WiltedMacFeedRefreshState] = [:]
    }

    private struct PodcastRefreshAllFeedsFailed: Error {}
    struct PodcastSubscriptionPartialFailure: Error {
        let feedTitle: String
        let wasAlreadySubscribed: Bool
    }

    func refreshPodcastURLs(
        _ urls: [URL], subscribing: Bool, initialMetadataLimit: Int? = nil, requestID: UUID? = nil
    ) async throws -> PodcastRefreshResult {
        guard let store else { throw CancellationError() }
        var withheld = 0
        var result = PodcastRefreshResult()
        // Every row is queued before the first request, so none waits unmarked behind the network. A cancel that
        // landed while the caller was reading its subscriptions already settled the rows and cleared the
        // operation, so the cancelled task's cleanup will not settle them again: it must not queue any.
        if !subscribing {
            try Task.checkCancellation()
            queueFeedRefresh(for: urls)
        }
        for url in urls {
            try Task.checkCancellation()
            if !subscribing { markFeedRefresh(forURL: url, .refreshing) }
            var persistedSubscriptionTitle: String?
            var wasAlreadySubscribed = false
            do {
                let loaded = try await podcastFeedClient.load(url)
                try Task.checkCancellation()
                guard requestID == nil || podcastSubscriptionRequestID == requestID else {
                    throw CancellationError()
                }
                try await store.save(feed: loaded.feed)
                try Task.checkCancellation()
                if subscribing {
                    let inserted = try await store.subscribeIfNeeded(PodcastSubscription(
                        feedID: loaded.feed.itemID, subscribedAt: Timestamp(Date())
                    ))
                    if !inserted {
                        result.duplicateSubscription = loaded.feed.itemID
                        wasAlreadySubscribed = true
                    }
                    persistedSubscriptionTitle = loaded.feed.title
                    try Task.checkCancellation()
                }
                var needsInitialAdmission = subscribing && !wasAlreadySubscribed
                if subscribing, !needsInitialAdmission {
                    let existingEpisodes = try await store.podcastEpisodes(for: loaded.feed.itemID)
                    needsInitialAdmission = existingEpisodes.isEmpty
                }
                let admissionKind: LocalLibraryStore.PodcastEpisodeAdmission =
                    needsInitialAdmission ? .backfill : .incremental
                let admissionLimit = needsInitialAdmission ? initialMetadataLimit : nil
                let admission: LocalLibraryStore.PodcastEpisodeAdmissionResult
                if let podcastEpisodeAdmissionOperationForTesting {
                    admission = try await podcastEpisodeAdmissionOperationForTesting(
                        loaded.episodes, admissionKind, admissionLimit
                    )
                } else {
                    admission = try await store.savePodcastEpisodes(
                        loaded.episodes, admission: admissionKind, initialMetadataLimit: admissionLimit
                    )
                }
                try Task.checkCancellation()
                withheld += loaded.droppedEpisodeCount + admission.skipped
                result.newEpisodeIDs.append(contentsOf: admission.newlyAdmitted)
                result.successfulFeedTitles.append(loaded.feed.title)
                result.successfulFeedCount += 1
                result.feedOutcomes[url] = .done
                if !subscribing { markFeedRefresh(forURL: url, .done) }
            } catch is CancellationError {
                if subscribing, let persistedSubscriptionTitle {
                    throw PodcastSubscriptionPartialFailure(
                        feedTitle: persistedSubscriptionTitle, wasAlreadySubscribed: wasAlreadySubscribed
                    )
                }
                throw CancellationError()
            } catch PodcastFeedClientError.cancelled {
                throw PodcastFeedClientError.cancelled
            } catch {
                if subscribing, let persistedSubscriptionTitle {
                    throw PodcastSubscriptionPartialFailure(
                        feedTitle: persistedSubscriptionTitle, wasAlreadySubscribed: wasAlreadySubscribed
                    )
                }
                guard !subscribing else { throw error }
                // A cancelled refresh settles its rows itself; a late failure must not repaint them.
                try Task.checkCancellation()
                result.failedFeedCount += 1
                result.feedOutcomes[url] = .failed
                markFeedRefresh(forURL: url, .failed)
            }
        }
        if !subscribing, result.successfulFeedCount == 0, result.failedFeedCount > 0 {
            throw PodcastRefreshAllFeedsFailed()
        }
        withheldPodcastEpisodeCount = withheld
        try Task.checkCancellation()
        let values = try await loadLibrary(from: store)
        let dismissed = try await loadDismissedEpisodes(from: store)
        try Task.checkCancellation()
        guard requestID == nil || podcastSubscriptionRequestID == requestID else {
            throw CancellationError()
        }
        guard applyEpisodes(values.episodes) else { return result }
        articles = values.articles
        subscriptions = values.subscriptions
        dismissedEpisodes = dismissed
        return result
    }

#endif

    /// Publishes freshly loaded rows without dropping what only this process
    /// knows.
    ///
    /// `preparationState` is derived from what the library can prove, and a
    /// preparation waiting for the run slot has proved nothing: it has no
    /// journal entry until the worker starts, so the store reports it as not
    /// prepared. Every download that lands reloads the whole library, so one
    /// episode finishing its transfer used to put another episode's `Queued`
    /// row back to offering `Prepare` -- a button that does nothing, because
    /// the run it would start already exists -- while its turn was still
    /// coming. A run this process started keeps the state this process gave it
    /// until it reaches a terminal one of its own.
    func applyEpisodes(_ loaded: [WiltedMacEpisode], allowsAutomaticAdmissions: Bool = true) {
#if canImport(WiltedProducer)
        // The preparation queue counts as running. An episode waiting for the
        // run slot has no task and no deferred job, so a reload used to reset
        // its row to not-prepared while the entry kept its place in line --
        // which is how Larder and Prep came to disagree about how many were
        // waiting, and how a queued episode offered a Prepare button that
        // could do nothing.
        let running = Set(podcastPreparationTasks.keys)
            .union(deferredAutomaticPreparations.map(\.episodeID))
            .union(preparationQueue.itemIDs)
#else
        let running: Set<String> = []
#endif
        let preparedBefore = Set(episodes.filter { $0.preparationState.isPrepared }.map(\.id))
        let knownBefore = Set(episodes.map(\.id))
        episodes = Self.applyingRunningPreparations(to: loaded, from: episodes, running: running)
        var candidates = Self.episodeIDsNewlyPrepared(in: episodes, preparedBefore: preparedBefore,
                                                      knownBefore: knownBefore)
        // An admission whose durable write raised is retried on the next
        // reload; without this the arrival filter excludes it (it was already
        // prepared before this reload) and the failed attempt would be final.
        for id in pendingLarderAdditions where !candidates.contains(id) {
            candidates.append(id)
        }
        if allowsAutomaticAdmissions, !candidates.isEmpty { autoAddPreparedEpisodesToLarder(candidates) }
    }

    /// The episodes that became prepared on this reload, and only those.
    ///
    /// An episode this process has never seen is deliberately excluded: the
    /// first load after launch publishes a whole library of already-prepared
    /// rows, and treating that as an arrival would empty the Larder into the
    /// Larder every time the app opened.
    nonisolated static func episodeIDsNewlyPrepared(
        in loaded: [WiltedMacEpisode], preparedBefore: Set<String>, knownBefore: Set<String>
    ) -> [String] {
        loaded
            .filter { $0.preparationState.isPrepared && knownBefore.contains($0.id)
                      && !preparedBefore.contains($0.id) }
            .map(\.id)
    }

    /// Appends freshly prepared episodes to the durable queue when the
    /// listener has asked the Larder to fill itself.
    ///
    /// A candidate is one the Larder could render and add: not hidden, not
    /// retired, not already played, and satisfying `canAddEpisodeToLarder`
    /// (playable audio, not the current episode, not already a durable
    /// member). An admission whose write raises is named in
    /// `podcastOperationMessage` and held in `pendingLarderAdditions` for the
    /// next reload to retry.
    private func autoAddPreparedEpisodesToLarder(_ ids: [String]) {
        larderAdditionTask = Task { [weak self] in
            await self?.performAutoAddPreparedEpisodesToLarder(ids)
        }
    }

    /// The awaited body of one auto-add pass, so a test can drive it to
    /// settlement without polling the view.
    func performAutoAddPreparedEpisodesToLarder(_ ids: [String]) async {
#if canImport(WiltedProducer)
        guard automationSettings.autoAddPreparedToLarder, let playback else { return }
        let eligible = ids.compactMap { id in episodes.first { $0.id == id } }
            .filter { !hiddenEpisodeIDs.contains($0.id) && $0.retiredAt == nil && !$0.isPlayed
                      && canAddEpisodeToLarder($0) }
        guard !eligible.isEmpty else {
            // A candidate that no longer satisfies the shipped predicate
            // cannot succeed on a later reload either, so it stops being
            // retried.
            pendingLarderAdditions.subtract(ids)
            return
        }
        podcastQueueIDs.append(contentsOf: eligible.map(\.id))
        var failed: [String] = []
        for episode in eligible {
            guard let id = try? ItemID(rawValue: episode.id) else { continue }
            do {
                if let larderAdmissionForTesting {
                    try await larderAdmissionForTesting(id)
                } else {
                    try await playback.addPodcastQueueEpisode(id)
                }
            } catch {
                failed.append(episode.id)
            }
        }
        await refreshPodcastQueueState()
        if failed.isEmpty {
            pendingLarderAdditions.subtract(eligible.map(\.id))
        } else {
            pendingLarderAdditions.formUnion(failed)
            podcastOperationMessage = failed.count == 1
                ? "An episode could not be added to Larder. It will be retried."
                : "\(failed.count) episodes could not be added to Larder. They will be retried."
        }
#else
        _ = ids
#endif
    }

    /// Carries a preparation state this process owns onto the loaded row.
    /// Separated from the reload so the rule can be read and tested on its own.
    nonisolated static func applyingRunningPreparations(
        to loaded: [WiltedMacEpisode], from current: [WiltedMacEpisode], running: Set<String>
    ) -> [WiltedMacEpisode] {
        var inFlight: [String: WiltedMacEpisodePreparationState] = [:]
        for episode in current where running.contains(episode.id) {
            guard case .preparing = episode.preparationState else { continue }
            inFlight[episode.id] = episode.preparationState
        }
        guard !inFlight.isEmpty else { return loaded }
        return loaded.map { episode in
            guard let state = inFlight[episode.id] else { return episode }
            var value = episode
            value.preparationState = state
            return value
        }
    }

    func updateEpisode(_ id: String, transform: (inout WiltedMacEpisode) -> Void) {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
        transform(&episodes[index])
    }

    /// Progress callbacks are delivered through queued MainActor tasks. Once
    /// the store reload publishes a terminal state, an older callback must not
    /// move the row backwards to downloading.
    func updateActiveEpisodeDownload(_ id: String, received: Int64, expected: Int64?) -> Bool {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return false }
        switch episodes[index].downloadState {
        case .queued, .downloading:
            episodes[index].downloadState = .downloading(received: received, expected: expected)
            return true
        case .notDownloaded, .completed, .failed, .cancelled:
            return false
        }
    }

    /// Quarantines sync after an account-owner change.
    func quarantineSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.quarantineAccount()
#endif
    }

    /// Clears the explicit account quarantine after review.
    func resetSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.resetAfterAccountChange()
#endif
    }

    var currentArticle: WiltedMacArticle? {
        guard let selectedArticleID else { return nil }
        return articles.first(where: { $0.id == selectedArticleID })
    }

    var currentEpisode: WiltedMacEpisode? {
        guard let currentPodcastEpisodeID else { return nil }
        return episodes.first(where: { $0.id == currentPodcastEpisodeID })
    }

    /// The native URL payload for Now Playing. Articles share their canonical
    /// URL; podcasts share the episode's own page when its feed published one,
    /// and never the subscription feed. URL values stay URL values so the share
    /// sheet receives link semantics instead of an ordinary string.
    var currentPlaybackShareURL: URL? {
        if let article = currentArticle {
            return article.url
        }
        return currentEpisode?.episodeLink
    }

    /// What a podcast without an episode page shares instead: its title and show.
    var currentPlaybackShareText: String? {
        if let article = currentArticle {
            return article.title + " · " + article.source
        }
        if let episode = currentEpisode {
            return episode.title + " — " + episode.feedTitle
        }
        return nil
    }

    /// Said beside the title and show when there is no page to link to.
    static let noEpisodePageText = "No episode page"

    var currentPlaybackShareTitle: String {
        currentArticle?.title ?? currentEpisode?.title ?? "Now Playing"
    }

    var currentPlaybackShareMessage: String {
        if let article = currentArticle {
            return article.title + " · " + article.source
        }
        if let episode = currentEpisode {
            return episode.episodeLink == nil
                ? Self.noEpisodePageText
                : episode.title + " · " + episode.feedTitle
        }
        return "Now Playing"
    }

    /// Compact context beside an episode's primary lifecycle line. Current
    /// playback wins over queue membership because the current item is not an
    /// upcoming item, even though the durable queue contains its identifier.
    func episodePlaybackIndicators(for episodeID: String) -> [String] {
        if isPodcastPlayback, currentPodcastEpisodeID == episodeID {
            return [isPlaying ? "Playing" : "Now Playing"]
        }
        return podcastQueueIDs.contains(episodeID) ? ["In Larder"] : []
    }

    /// The Larder entries the badge and its label count: the same visible rows
    /// the Larder renders, in Larder order. The current podcast stays durable in
    /// the queue but is represented by Now Playing, while entries on either
    /// side remain waiting rows.
    var larderUpcomingEpisodeIDs: [String] {
        larderWaitingEpisodes.map(\.id)
    }

    /// The Larder rows after the selected durable ordering. Non-custom orders
    /// are applied to the persisted queue as soon as the choice changes, so
    /// this remains a defensive presentation projection while that write is
    /// in flight.
    var larderDisplayEpisodeIDs: [String] {
        sortedLarderEpisodeIDs(podcastQueueIDs, by: larderSort)
    }

    /// The whole Larder's known listening time, summed from the same waiting set
    /// every Larder heading counts. Unknown durations stay visible as a count
    /// rather than being silently treated as zero.
    var larderAudioSummary: WiltedMacQueueAudioSummary {
        WiltedMacQueueAudioSummary(episodes: larderWaitingEpisodes)
    }

    /// One group's known listening time, from the group itself rather than the
    /// current search: the sidebar describes the Larder, not the view.
    func larderGroupAudioSummary(_ group: WiltedMacLarderGroup) -> WiltedMacQueueAudioSummary {
        WiltedMacQueueAudioSummary(episodes: larderUnfilteredEpisodes(in: group))
    }

    /// Every episode waiting on the Larder, in the Larder's own order.
    ///
    /// The Larder is the one place episodes wait: the durable queue defines the
    /// waiting set, and the rows are those the library still holds. A queued
    /// id the library no longer carries -- a played-and-retired episode, say
    /// -- simply has no row.
    var larderWaitingEpisodes: [WiltedMacEpisode] {
        let visible = Dictionary(uniqueKeysWithValues: larderPresentationEpisodes.map { ($0.id, $0) })
        return larderDisplayEpisodeIDs.compactMap { visible[$0] }
    }

    /// The rows one group renders under the current search.
    ///
    /// A group heading's count, its filter chip's count, and the rows below it
    /// all come from this function, so a count cannot disagree with the list
    /// it labels. The sidebar totals and the bulk sets deliberately read the
    /// waiting set directly: a search narrows the view, not the group.
    func larderEpisodes(in group: WiltedMacLarderGroup) -> [WiltedMacEpisode] {
        larderSearchResults.filter { Self.larderGroup(for: $0) == group }
    }

    /// A group's rows without the search applied: what the sidebar totals and
    /// every bulk action mean.
    func larderUnfilteredEpisodes(in group: WiltedMacLarderGroup) -> [WiltedMacEpisode] {
        larderWaitingEpisodes.filter { Self.larderGroup(for: $0) == group }
    }

    /// What "available can be downloaded, downloaded can be prepared,
    /// prepared can be played" means for one episode.
    ///
    /// Preparing is still Downloaded: the audio is here and the cut is not,
    /// so the row carries the progress figure rather than moving groups.
    nonisolated static func larderGroup(for episode: WiltedMacEpisode) -> WiltedMacLarderGroup {
        guard episode.downloadState == .completed else { return .available }
        guard episode.preparationState.isPrepared, episode.isReadyMediaAvailable else {
            return .downloaded
        }
        return .playable
    }

    /// The rows the Larder renders: the selected group, or every waiting episode
    /// when no filter is set. Search narrows both, because it is a view of
    /// what the reader can see, while the group itself is unchanged.
    var larderFilteredEpisodes: [WiltedMacEpisode] {
        guard let larderFilter else { return larderSearchResults }
        return larderSearchResults.filter { Self.larderGroup(for: $0) == larderFilter }
    }

    /// Sections for the selected presentation. Feed and Date collect rows by
    /// their source and release day; Status retains the existing lifecycle
    /// groups and is the only mode that owns group actions.
    func larderSections(
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) -> [WiltedMacLarderSection] {
        switch larderGrouping {
        case .feed:
            var feeds: [String] = []
            var episodesByFeed: [String: [WiltedMacEpisode]] = [:]
            for episode in larderFilteredEpisodes {
                if episodesByFeed[episode.feedTitle] == nil { feeds.append(episode.feedTitle) }
                episodesByFeed[episode.feedTitle, default: []].append(episode)
            }
            return feeds.map { feed in
                WiltedMacLarderSection(
                    id: "feed-\(feed)", title: feed, detail: nil,
                    statusGroup: nil, episodes: episodesByFeed[feed] ?? []
                )
            }
        case .status:
            let groups = larderFilter.map { [$0] } ?? WiltedMacLarderGroup.allCases
            return groups.compactMap { group in
                let episodes = larderEpisodes(in: group)
                guard !episodes.isEmpty else { return nil }
                return WiltedMacLarderSection(
                    id: "status-\(group.rawValue)", title: group.displayName,
                    detail: group.detail, statusGroup: group, episodes: episodes
                )
            }
        case .date:
            var dates: [Date] = []
            var episodesByDate: [Date: [WiltedMacEpisode]] = [:]
            for episode in larderFilteredEpisodes {
                let date = calendar.startOfDay(for: episode.releasedAt)
                if episodesByDate[date] == nil { dates.append(date) }
                episodesByDate[date, default: []].append(episode)
            }
            return dates.map { date in
                let title: String
                if calendar.isDate(date, inSameDayAs: now) {
                    title = "Today"
                } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                          calendar.isDate(date, inSameDayAs: yesterday) {
                    title = "Yesterday"
                } else {
                    title = date.formatted(date: .abbreviated, time: .omitted)
                }
                return WiltedMacLarderSection(
                    id: "date-\(date.timeIntervalSinceReferenceDate)", title: title,
                    detail: nil, statusGroup: nil, episodes: episodesByDate[date] ?? []
                )
            }
        }
    }

    // MARK: - Larder search

    /// Shorter than this and a query matches so much transcript text that the
    /// result is noise, while every keystroke still pays for the scan.
    static let transcriptSearchMinimumLength = 3
    /// How long the field must be still before the store is asked.
    static let transcriptSearchDebounce: Duration = .milliseconds(250)

    /// Whether the Larder is showing a search right now.
    var isSearchingLarder: Bool { !trimmedSearchQuery.isEmpty }

    var trimmedSearchQuery: String {
        librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The waiting rows a search admits, before the group filter.
    var larderSearchResults: [WiltedMacEpisode] {
        guard isSearchingLarder else { return larderWaitingEpisodes }
        return larderWaitingEpisodes.filter(matchesLarderSearch)
    }

}
