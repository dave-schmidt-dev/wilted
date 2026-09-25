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
        var successfulFeedCount = 0
        var failedFeedCount = 0
    }

    private struct PodcastRefreshAllFeedsFailed: Error {}

    func refreshPodcastURLs(_ urls: [URL], subscribing: Bool) async throws -> PodcastRefreshResult {
        guard let store else { throw CancellationError() }
        var withheld = 0
        var result = PodcastRefreshResult()
        for url in urls {
            try Task.checkCancellation()
            do {
                let loaded = try await podcastFeedClient.load(url)
                try await store.save(feed: loaded.feed)
                if subscribing {
                    let inserted = try await store.subscribeIfNeeded(PodcastSubscription(
                        feedID: loaded.feed.itemID, subscribedAt: Timestamp(Date())
                    ))
                    if !inserted { result.duplicateSubscription = loaded.feed.itemID }
                }
                let admission = try await store.savePodcastEpisodes(
                    loaded.episodes, admission: subscribing ? .backfill : .incremental
                )
                withheld += loaded.droppedEpisodeCount + admission.skipped
                result.newEpisodeIDs.append(contentsOf: admission.newlyAdmitted)
                result.successfulFeedCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch PodcastFeedClientError.cancelled {
                throw PodcastFeedClientError.cancelled
            } catch {
                guard !subscribing else { throw error }
                result.failedFeedCount += 1
            }
        }
        if !subscribing, result.successfulFeedCount == 0, result.failedFeedCount > 0 {
            throw PodcastRefreshAllFeedsFailed()
        }
        withheldPodcastEpisodeCount = withheld
        let values = try await loadLibrary(from: store)
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
        dismissedEpisodes = try await loadDismissedEpisodes(from: store)
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
    func applyEpisodes(_ loaded: [WiltedMacEpisode]) {
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
        for id in pendingMenuAdditions where !candidates.contains(id) {
            candidates.append(id)
        }
        if !candidates.isEmpty { autoAddPreparedEpisodesToMenu(candidates) }
    }

    /// The episodes that became prepared on this reload, and only those.
    ///
    /// An episode this process has never seen is deliberately excluded: the
    /// first load after launch publishes a whole library of already-prepared
    /// rows, and treating that as an arrival would empty the Larder into the
    /// Menu every time the app opened.
    nonisolated static func episodeIDsNewlyPrepared(
        in loaded: [WiltedMacEpisode], preparedBefore: Set<String>, knownBefore: Set<String>
    ) -> [String] {
        loaded
            .filter { $0.preparationState.isPrepared && knownBefore.contains($0.id)
                      && !preparedBefore.contains($0.id) }
            .map(\.id)
    }

    /// Appends freshly prepared episodes to the durable queue when the
    /// listener has asked the Menu to fill itself.
    ///
    /// A candidate is one the Menu could render and add: not hidden, not
    /// retired, not already played, and satisfying `canAddEpisodeToMenu`
    /// (playable audio, not the current episode, not already a durable
    /// member). An admission whose write raises is named in
    /// `podcastOperationMessage` and held in `pendingMenuAdditions` for the
    /// next reload to retry.
    private func autoAddPreparedEpisodesToMenu(_ ids: [String]) {
        menuAdditionTask = Task { [weak self] in
            await self?.performAutoAddPreparedEpisodesToMenu(ids)
        }
    }

    /// The awaited body of one auto-add pass, so a test can drive it to
    /// settlement without polling the view.
    func performAutoAddPreparedEpisodesToMenu(_ ids: [String]) async {
#if canImport(WiltedProducer)
        guard automationSettings.autoAddPreparedToMenu, let playback else { return }
        let eligible = ids.compactMap { id in episodes.first { $0.id == id } }
            .filter { !hiddenEpisodeIDs.contains($0.id) && $0.retiredAt == nil && !$0.isPlayed
                      && canAddEpisodeToMenu($0) }
        guard !eligible.isEmpty else {
            // A candidate that no longer satisfies the shipped predicate
            // cannot succeed on a later reload either, so it stops being
            // retried.
            pendingMenuAdditions.subtract(ids)
            return
        }
        podcastQueueIDs.append(contentsOf: eligible.map(\.id))
        var failed: [String] = []
        for episode in eligible {
            guard let id = try? ItemID(rawValue: episode.id) else { continue }
            do {
                if let menuAdmissionForTesting {
                    try await menuAdmissionForTesting(id)
                } else {
                    try await playback.addPodcastQueueEpisode(id)
                }
            } catch {
                failed.append(episode.id)
            }
        }
        await refreshPodcastQueueState()
        if failed.isEmpty {
            pendingMenuAdditions.subtract(eligible.map(\.id))
        } else {
            pendingMenuAdditions.formUnion(failed)
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
    /// URL; podcasts share the subscription feed URL when the source record
    /// has one. URL values stay URL values so the share sheet receives link
    /// semantics instead of an ordinary string.
    var currentPlaybackShareURL: URL? {
        if let article = currentArticle {
            return article.url
        }
        if let episode = currentEpisode {
            return episode.feedURL
        }
        return nil
    }

    /// Honest text payload used when the current podcast has no feed URL.
    var currentPlaybackShareText: String? {
        if let article = currentArticle {
            return article.title + " · " + article.source
        }
        if let episode = currentEpisode {
            return episode.title + " — " + episode.feedTitle
        }
        return nil
    }

    var currentPlaybackShareTitle: String {
        currentArticle?.title ?? currentEpisode?.title ?? "Now Playing"
    }

    var currentPlaybackShareMessage: String {
        if let article = currentArticle {
            return article.title + " · " + article.source
        }
        if let episode = currentEpisode {
            return episode.title + " · " + episode.feedTitle
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

    /// The Menu entries the badge and its label count: the same visible rows
    /// the Menu renders, in Menu order. The current podcast stays durable in
    /// the queue but is represented by Now Playing, while entries on either
    /// side remain waiting rows.
    var menuUpcomingEpisodeIDs: [String] {
        menuWaitingEpisodes.map(\.id)
    }

    /// The Menu rows after the selected durable ordering. Non-custom orders
    /// are applied to the persisted queue as soon as the choice changes, so
    /// this remains a defensive presentation projection while that write is
    /// in flight.
    var menuDisplayEpisodeIDs: [String] {
        sortedMenuEpisodeIDs(podcastQueueIDs, by: menuSort)
    }

    /// The whole Menu's known listening time, summed from the same waiting set
    /// every Menu heading counts. Unknown durations stay visible as a count
    /// rather than being silently treated as zero.
    var menuAudioSummary: WiltedMacQueueAudioSummary {
        WiltedMacQueueAudioSummary(episodes: menuWaitingEpisodes)
    }

    /// One group's known listening time, from the group itself rather than the
    /// current search: the sidebar describes the Menu, not the view.
    func menuGroupAudioSummary(_ group: WiltedMacMenuGroup) -> WiltedMacQueueAudioSummary {
        WiltedMacQueueAudioSummary(episodes: menuUnfilteredEpisodes(in: group))
    }

    /// Every episode waiting on the Menu, in the Menu's own order.
    ///
    /// The Menu is the one place episodes wait: the durable queue defines the
    /// waiting set, and the rows are those the library still holds. A queued
    /// id the library no longer carries -- a played-and-retired episode, say
    /// -- simply has no row.
    var menuWaitingEpisodes: [WiltedMacEpisode] {
        let visible = Dictionary(uniqueKeysWithValues: larderPresentationEpisodes.map { ($0.id, $0) })
        return menuDisplayEpisodeIDs.compactMap { visible[$0] }
    }

    /// The rows one group renders under the current search.
    ///
    /// A group heading's count, its filter chip's count, and the rows below it
    /// all come from this function, so a count cannot disagree with the list
    /// it labels. The sidebar totals and the bulk sets deliberately read the
    /// waiting set directly: a search narrows the view, not the group.
    func menuEpisodes(in group: WiltedMacMenuGroup) -> [WiltedMacEpisode] {
        menuSearchResults.filter { Self.menuGroup(for: $0) == group }
    }

    /// A group's rows without the search applied: what the sidebar totals and
    /// every bulk action mean.
    func menuUnfilteredEpisodes(in group: WiltedMacMenuGroup) -> [WiltedMacEpisode] {
        menuWaitingEpisodes.filter { Self.menuGroup(for: $0) == group }
    }

    /// What "available can be downloaded, downloaded can be prepared,
    /// prepared can be played" means for one episode.
    ///
    /// Preparing is still Downloaded: the audio is here and the cut is not,
    /// so the row carries the progress figure rather than moving groups.
    nonisolated static func menuGroup(for episode: WiltedMacEpisode) -> WiltedMacMenuGroup {
        guard episode.downloadState == .completed else { return .available }
        guard episode.preparationState.isPrepared, episode.isReadyMediaAvailable else {
            return .downloaded
        }
        return .playable
    }

    /// The rows the Menu renders: the selected group, or every waiting episode
    /// when no filter is set. Search narrows both, because it is a view of
    /// what the reader can see, while the group itself is unchanged.
    var menuFilteredEpisodes: [WiltedMacEpisode] {
        guard let menuFilter else { return menuSearchResults }
        return menuSearchResults.filter { Self.menuGroup(for: $0) == menuFilter }
    }

    /// Sections for the selected presentation. Feed and Date collect rows by
    /// their source and release day; Status retains the existing lifecycle
    /// groups and is the only mode that owns group actions.
    func menuSections(
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) -> [WiltedMacMenuSection] {
        switch menuGrouping {
        case .feed:
            var feeds: [String] = []
            var episodesByFeed: [String: [WiltedMacEpisode]] = [:]
            for episode in menuFilteredEpisodes {
                if episodesByFeed[episode.feedTitle] == nil { feeds.append(episode.feedTitle) }
                episodesByFeed[episode.feedTitle, default: []].append(episode)
            }
            return feeds.map { feed in
                WiltedMacMenuSection(
                    id: "feed-\(feed)", title: feed, detail: nil,
                    statusGroup: nil, episodes: episodesByFeed[feed] ?? []
                )
            }
        case .status:
            let groups = menuFilter.map { [$0] } ?? WiltedMacMenuGroup.allCases
            return groups.compactMap { group in
                let episodes = menuEpisodes(in: group)
                guard !episodes.isEmpty else { return nil }
                return WiltedMacMenuSection(
                    id: "status-\(group.rawValue)", title: group.displayName,
                    detail: group.detail, statusGroup: group, episodes: episodes
                )
            }
        case .date:
            var dates: [Date] = []
            var episodesByDate: [Date: [WiltedMacEpisode]] = [:]
            for episode in menuFilteredEpisodes {
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
                return WiltedMacMenuSection(
                    id: "date-\(date.timeIntervalSinceReferenceDate)", title: title,
                    detail: nil, statusGroup: nil, episodes: episodesByDate[date] ?? []
                )
            }
        }
    }

    // MARK: - Menu search

    /// Shorter than this and a query matches so much transcript text that the
    /// result is noise, while every keystroke still pays for the scan.
    static let transcriptSearchMinimumLength = 3
    /// How long the field must be still before the store is asked.
    static let transcriptSearchDebounce: Duration = .milliseconds(250)

    /// Whether the Menu is showing a search right now.
    var isSearchingMenu: Bool { !trimmedSearchQuery.isEmpty }

    var trimmedSearchQuery: String {
        librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The waiting rows a search admits, before the group filter.
    var menuSearchResults: [WiltedMacEpisode] {
        guard isSearchingMenu else { return menuWaitingEpisodes }
        return menuWaitingEpisodes.filter(matchesMenuSearch)
    }

}
