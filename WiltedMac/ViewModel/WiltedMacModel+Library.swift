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
    /// Starts one already-claimed episode and waits for it to settle.
    ///
    /// Waiting is what makes the coordinator's queue serial. The claim is
    /// durable, so nothing is lost by taking them one at a time, and a listener
    /// on a domestic connection would rather have one episode finish than six
    /// crawl.
    func startClaimedDownload(_ episodeID: String) async throws {
        // Throwing, never returning. Automation only runs once the library has
        // loaded, so a claim with no episode behind it is a genuine fault. A
        // silent return would count it as downloaded and clear a claim that no
        // transfer ever serviced.
        guard let episode = episodes.first(where: { $0.id == episodeID }) else {
            throw WiltedAutomationFault.claimedEpisodeMissing(episodeID)
        }
        downloadEpisode(episode, alreadyClaimed: true)
        // `downloadEpisode` guard-returns without inserting a task when the
        // coordinator is nil or the episode ID fails to parse. `nil?.value`
        // would turn that into a silent success; a claim with no task behind
        // it is the same "work not actually done" fault as a missing episode.
        guard let task = podcastDownloadTasks[episodeID] else {
            throw WiltedAutomationFault.downloadNotStarted(episodeID)
        }
        do {
            _ = try await task.value
        } catch let error as PodcastDownloadCoordinatorError where error.failureKind != .retryable {
            // Terminal failures (bad hash, bad audio) and `.cancelled`/
            // `.episodeNotFound` (failureKind `nil`) all need a person or a
            // user decision, not bounded in-process retry. `.retryable`
            // errors fall through this catch and rethrow raw, which is what
            // lets `withRetries` retry them normally.
            throw WiltedAutomationNonRetryableDownloadFailure(underlying: error)
        }
    }
#endif

    /// Fixture launches share the daily driver's bundle identifier, so they
    /// get their own defaults domain, emptied on every launch: a UI test must
    /// neither inherit the owner's choices nor leave its own behind.
    static func fixturePreferences() -> UserDefaults {
        let suite = "com.zerodelta.wilted.mac.ui-fixture"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// The durable episode records the shelf retains. Hidden and retired
    /// records are not on the shelf; presentation applies its active-podcast
    /// exclusion separately so queue and playback code retain this full set.
    var larderVisibleEpisodes: [WiltedMacEpisode] {
        episodes.filter { !hiddenEpisodeIDs.contains($0.id) && $0.retiredAt == nil }
    }

    /// The Larder is a waiting list; its active podcast is represented by Now
    /// Playing instead. This projection deliberately leaves the durable queue
    /// and `currentPodcastEpisodeID` alone, so playback succession retains its
    /// identity and order. A remembered podcast marker during article playback
    /// is not active podcast playback and therefore stays visible.
    var larderPresentationEpisodes: [WiltedMacEpisode] {
        guard isPodcastPlayback, let currentPodcastEpisodeID else {
            return larderVisibleEpisodes
        }
        return larderVisibleEpisodes.filter { $0.id != currentPodcastEpisodeID }
    }

    /// How many rows one feed contributes to the Larder, counted against the
    /// same set the Larder itself presents. `WiltedMacSubscription.episodeCount`
    /// is the raw snapshot count -- every record the feed holds, retired and
    /// hidden ones included -- so the Feeds card used to claim episodes the
    /// Larder did not show.
    func larderEpisodeCount(forFeedID feedID: String) -> Int {
        larderPresentationEpisodes.filter { $0.feedID == feedID }.count
    }

    /// The one definition of "Played" every completion surface asks. A live
    /// playhead can nominate a manual-Next completion, but only the durable
    /// listening record proves that the episode was completed.
    nonisolated static func isFinished(isPlayed: Bool) -> Bool { isPlayed }

    /// The Menu row asks this before it offers Play: an episode already
    /// finished must not sit in Ready waiting to be played again.
    func isEpisodeFinished(_ episode: WiltedMacEpisode) -> Bool {
        Self.isFinished(isPlayed: episode.isPlayed)
    }

    /// Whether a visible row has playback underway but is not finished. The
    /// current engine position wins over the last saved row position so the
    /// label follows the live playhead, while a zero-position row remains
    /// unlabelled until audio has actually advanced.
    func isEpisodeInProgress(_ episode: WiltedMacEpisode) -> Bool {
        let position = isPodcastPlayback && currentPodcastEpisodeID == episode.id
            ? playbackPositionSeconds
            : episode.playbackSeconds
        guard position > 0 else { return false }
        return !Self.isFinished(isPlayed: episode.isPlayed)
    }

    /// How far this episode's running preparation has got, when it has said.
    /// Nil while it is queued or reporting no fraction, so a Menu row shows an
    /// indeterminate bar rather than one parked at zero.
    func preparationFraction(forEpisode id: String) -> Double? {
        processorRuns.first { $0.itemID == id && $0.outcome == .running }?.fraction
    }

    /// Episodes in the order the Larder's chosen sort shows them. The Menu's
    /// bulk add and the auto-advance search both want "the order the reader is
    /// looking at", which is `larderSort` -- not the retired `libraryOrder`
    /// that could disagree with it.
    nonisolated static func sortedLarderEpisodes(
        _ episodes: [WiltedMacEpisode], by sort: WiltedMacLarderSort
    ) -> [WiltedMacEpisode] {
        let ranked = sortLarderItems(episodes.map(WiltedMacLibraryItem.episode), by: sort)
        let positions = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.id, $0.offset) })
        return episodes.sorted { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
    }

    nonisolated private static func sortLarderItems(
        _ items: [WiltedMacLibraryItem],
        by sort: WiltedMacLarderSort
    ) -> [WiltedMacLibraryItem] {
        items.sorted { lhs, rhs in
            switch sort {
            case .newest:
                if lhs.date != rhs.date { return lhs.date > rhs.date }
            case .oldest:
                if lhs.date != rhs.date { return lhs.date < rhs.date }
            case .shortest:
                switch (lhs.progress.duration, rhs.progress.duration) {
                case let (left?, right?) where left != right:
                    return left < right
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
            case .show:
                let comparison = lhs.source.localizedStandardCompare(rhs.source)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .title:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.id < rhs.id
        }
    }

    func selectLibraryItem(_ id: String) { selectedLibraryItemID = id }

    /// Starts production persistence only after the root surface has made its
    /// loading state visible. Fixture modes are already ready at construction.
    func startStoreBootstrap() {
#if canImport(WiltedProducer)
        guard case .loading = startupState else { return }
        beginStoreBootstrap()
#endif
    }

#if canImport(WiltedProducer)
    private func beginStoreBootstrap() {
        guard !fixtureMode, startupTask == nil, startupAttemptCount < Self.maximumStartupAttempts else { return }
        startupAttemptCount += 1
        startupState = .loading(attempt: startupAttemptCount, step: .openingStore)
        startupStepObserverForTesting?(.openingStore)
        startupTask = Task { [weak self] in
            await self?.performStoreBootstrap()
        }
    }

    /// Advances the loading readout to the phase about to be awaited.
    func announceStartupStep(_ step: WiltedMacStartupStep) {
        startupStepObserverForTesting?(step)
        switch startupState {
        case let .loading(attempt, _):
            startupState = .loading(attempt: attempt, step: step)
        case .ready, .failed:
            break
        }
    }
#endif

    /// The line the startup readout shows while bootstrap runs. A ready or
    /// failed state has no step, so the first phase's words stand in -- they
    /// are never rendered in those states anyway.
    var startupStepLabel: String {
        startupState.loadingStep?.label ?? WiltedMacStartupStep.openingStore.label
    }

    func retryStoreBootstrap() {
#if canImport(WiltedProducer)
        guard case let .failed(failure) = startupState, failure.canRetry else { return }
        beginStoreBootstrap()
#endif
    }

    func presentRetainedV5Store() {
#if canImport(WiltedProducer)
        guard case let .failed(failure) = startupState, let url = failure.retainedV5StoreURL else { return }
        retainedArtifactPresenter(url)
#endif
    }

    /// Deterministic test seam; production does not wait on this task.
    func waitForStoreBootstrap() async {
#if canImport(WiltedProducer)
        await startupTask?.value
#endif
    }

    var syncStatus: WiltedMacSyncStatus {
#if canImport(WiltedProducer)
        syncLifecycle?.status ?? .disabled
#else
        .disabled
#endif
    }

    var syncObservability: WiltedMacObservability {
#if canImport(WiltedProducer)
        syncLifecycle?.observability ?? .unavailable
#else
        .unavailable
#endif
    }

    /// Starts the explicit manual refresh action.
    func refreshSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.startRefresh()
#endif
    }

    /// Starts the explicit manual upload action.
    func uploadPendingSync() {
#if canImport(WiltedProducer)
        Task { [weak self] in
            _ = await self?.queueUnpublishedReadyRevisions()
            self?.syncLifecycle?.startUpload()
        }
#endif
    }

    /// Reconciles durable ready revisions when the producer launches or returns to the
    /// foreground. The task guard makes repeated scene callbacks harmless while the
    /// existing lifecycle coalesces any automatic send requested by the reconciliation.
    func reconcileSyncOnLaunchOrForeground() {
#if canImport(WiltedProducer)
        guard !fixtureMode else { return }
        switch startupState {
        case let .loading(attempt, _):
            pendingSyncReconciliation = true
            if attempt == 0 {
                startStoreBootstrap()
            }
            return
        case .failed:
            return
        case .ready:
            break
        }
        guard let syncLifecycle,
              syncLifecycle.status.phase != .disabled,
              syncReconciliationTask == nil else { return }
        syncReconciliationTask = Task { [weak self] in
            guard let self else { return }
            let queued = await self.queueUnpublishedReadyRevisions()
            if queued {
                self.syncLifecycle?.startAutomaticUpload()
            }
            self.syncReconciliationTask = nil
        }
#endif
    }

    /// Cancels the current bounded sync action.
    func cancelSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.cancel()
#endif
    }

    func subscribeToPodcastFeed(_ url: URL) {
#if canImport(WiltedProducer)
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            podcastOperationMessage = "Enter a complete HTTPS podcast feed URL."
            return
        }
        startPodcastRefresh(urls: [url], subscribing: true)
#endif
    }

    /// Classifies the Feeds-owned composer input, subscribing direct feeds and
    /// requiring confirmation before following a feed advertised by a page.
    func addPodcastFeedDraft() {
#if canImport(WiltedProducer)
        let trimmed = podcastFeedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            podcastFeedDraftStatus = "Enter a complete HTTPS podcast feed or show-page address."
            return
        }
        guard podcastSubscriptionClassificationTask == nil else { return }
        advertisedFeed = nil
        selectedPodcastFeedID = nil
        isCheckingPodcastSubscription = true
        podcastFeedDraftStatus = Self.podcastCheckInProgressStatus
        podcastSubscriptionCheckGeneration &+= 1
        let generation = podcastSubscriptionCheckGeneration
        podcastSubscriptionClassificationTask = Task { [weak self] in
            guard let self else { return }
            let outcome: PodcastSubscriptionCheckOutcome
            do {
                let kind = try await self.pastedLinkClassifier.classify(url)
                try Task.checkCancellation()
                switch kind {
                case .podcastFeed: outcome = .subscribe(url)
                case .articleAdvertisingFeed(let feedURL): outcome = .confirm(feedURL)
                case .article: outcome = .notAFeed
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .unreachable
            }
            // A cancelled check still resumes, and by then the listener may have
            // started the next one. Only the current generation may write the
            // shared status, or a stale answer clears a live check's progress.
            guard generation == self.podcastSubscriptionCheckGeneration else { return }
            self.isCheckingPodcastSubscription = false
            self.podcastSubscriptionClassificationTask = nil
            self.apply(outcome)
        }
#endif
    }

    /// What one classification of the Feeds composer input concluded.
    private enum PodcastSubscriptionCheckOutcome {
        case subscribe(URL)
        case confirm(URL)
        case notAFeed
        case cancelled
        case unreachable
    }

    private func apply(_ outcome: PodcastSubscriptionCheckOutcome) {
#if canImport(WiltedProducer)
        switch outcome {
        case let .subscribe(url):
            podcastFeedDraftStatus = nil
            subscribeToPodcastFeed(url)
        case let .confirm(feedURL):
            advertisedFeed = feedURL
            podcastFeedDraftStatus = "This page advertises one podcast feed. Confirm before subscribing."
        case .notAFeed:
            podcastFeedDraftStatus = "That page does not advertise a podcast feed."
        case .cancelled:
            podcastFeedDraftStatus = Self.podcastCheckCancelledStatus
        case .unreachable:
            podcastFeedDraftStatus = "Wilted could not reach that address. Check it, or retry when online."
        }
#endif
    }

    func cancelPodcastSubscriptionCheck() {
        guard let task = podcastSubscriptionClassificationTask else { return }
        // The generation moves with the cancellation, so the task being
        // cancelled here cannot write anything after this point.
        podcastSubscriptionCheckGeneration &+= 1
        task.cancel()
        podcastSubscriptionClassificationTask = nil
        isCheckingPodcastSubscription = false
        podcastFeedDraftStatus = Self.podcastCheckCancelledStatus
    }

    /// Follows the feed the last added page advertised.
    func subscribeToAdvertisedFeed() {
        guard let advertisedFeed else { return }
        self.advertisedFeed = nil
        podcastFeedDraft = advertisedFeed.absoluteString
        podcastFeedDraftStatus = nil
        subscribeToPodcastFeed(advertisedFeed)
    }

    /// Moves a feed found by Larder's article classifier to its owning screen.
    ///
    /// The address moves rather than being copied: leaving it in the article box
    /// as well would offer the same paste two homes.
    func handPodcastFeedToSubscriptions(_ url: URL) {
        advertisedFeed = nil
        urlDraft = ""
        podcastFeedDraft = url.absoluteString
        podcastFeedDraftStatus = "Podcast feed detected. Review the address, then subscribe."
        selectedNavigation = .feeds
    }

    func dismissAdvertisedFeed() {
        advertisedFeed = nil
    }

    func refreshPodcastFeeds() {
#if canImport(WiltedProducer)
        guard let store, podcastRefreshTask == nil else { return }
        isRefreshingPodcasts = true
        podcastOperationMessage = "Refreshing subscribed podcasts…"
        podcastRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let subscriptions = try await store.subscriptions().filter(\.enabled)
                var urls: [URL] = []
                for subscription in subscriptions {
                    if let url = try await store.podcastFeed(for: subscription.feedID)?.canonicalURL {
                        urls.append(url)
                    }
                }
                let result = try await self.refreshPodcastURLs(urls, subscribing: false)
                self.lastPodcastRefreshNewEpisodeIDs = result.newEpisodeIDs.map(\.rawValue)
                self.setLastAutomationRefresh(Date())
                let update = result.newEpisodeIDs.isEmpty
                    ? "Podcast episodes are up to date."
                    : "Added \(result.newEpisodeIDs.count) new episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
                self.podcastOperationMessage = result.failedFeedCount == 0
                    ? update
                    : "\(update) \(result.failedFeedCount) feed\(result.failedFeedCount == 1 ? "" : "s") could not be refreshed."
            } catch is CancellationError {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch PodcastFeedClientError.cancelled {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch {
                self.podcastOperationMessage = "Podcasts could not be refreshed. Check your connection and retry."
            }
            self.isRefreshingPodcasts = false
            self.podcastRefreshTask = nil
        }
#endif
    }

    func cancelPodcastRefresh() {
        podcastRefreshTask?.cancel()
        podcastRefreshTask = nil
        isRefreshingPodcasts = false
        podcastOperationMessage = "Podcast refresh cancelled."
    }

}
