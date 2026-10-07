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
    /// get their own defaults domain, emptied on first use: a UI test must
    /// neither inherit the owner's choices nor leave its own behind. The
    /// suite is named by process and model, so Mac test hosts running in
    /// sibling worktrees at the same time cannot wipe each other's state.
    static func fixturePreferences(suiteName: String = fixturePreferencesSuiteName()) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    static let fixturePreferencesSuitePrefix = "com.zerodelta.wilted.mac.ui-fixture"

    static func fixturePreferencesSuiteName() -> String {
        "\(fixturePreferencesSuitePrefix).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
    }

    /// Removes the suites (and their plists) of fixture processes that are gone. A suite whose owner
    /// is live, or whose owner cannot be told, is left alone.
    static func sweepStaleFixturePreferenceSuites(
        in directory: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
    ) {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = fixturePreferencesSuitePrefix + "."
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".plist") {
            let suite = String(entry.dropLast(".plist".count))
            guard let owner = suite.dropFirst(prefix.count).split(separator: ".").first.flatMap({ Int32($0) }),
                  owner > 0, kill(owner, 0) != 0, errno == ESRCH else { continue }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
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

    /// The Larder row asks this before it offers Play: an episode already
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
    /// Nil while it is queued or reporting no fraction, so a Larder row shows an
    /// indeterminate bar rather than one parked at zero.
    func preparationFraction(forEpisode id: String) -> Double? {
        processorRuns.first { $0.itemID == id && $0.outcome == .running }?.fraction
    }

    /// Episodes in the order the Larder's chosen sort shows them. The Larder's
    /// bulk add and the auto-advance search both want "the order the reader is
    /// looking at", which is `feedsSort` -- not the retired `libraryOrder`
    /// that could disagree with it.
    nonisolated static func sortedLarderEpisodes(
        _ episodes: [WiltedMacEpisode], by sort: WiltedMacFeedsSort
    ) -> [WiltedMacEpisode] {
        let ranked = sortLarderItems(episodes.map(WiltedMacLibraryItem.episode), by: sort)
        let positions = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.id, $0.offset) })
        return episodes.sorted { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
    }

    nonisolated private static func sortLarderItems(
        _ items: [WiltedMacLibraryItem],
        by sort: WiltedMacFeedsSort
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

    func subscribeToPodcastFeed(_ url: URL, initialMetadataCount: Int? = nil) {
#if canImport(WiltedProducer)
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            podcastOperationMessage = "Enter a complete HTTPS podcast feed URL."
            return
        }
        startPodcastSubscriptionIntake(
            url, initialMetadataCount: initialMetadataCount ?? pendingPodcastSubscriptionInitialMetadataCount
        )
#endif
    }

    /// Classifies the Feeds-owned composer input, subscribing direct feeds and
    /// requiring confirmation before following a feed advertised by a page.
    func addPodcastFeedDraft(initialMetadataCount: Int? = nil) {
#if canImport(WiltedProducer)
        if let initialMetadataCount,
           WiltedAutomationSettings.validInitialEpisodeMetadataCount(initialMetadataCount) == nil {
            podcastFeedDraftStatus = "Choose between 1 and 100 initial episodes."
            return
        }
        let trimmed = podcastFeedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            podcastFeedDraftStatus = "Enter a complete HTTPS podcast feed or show-page address."
            return
        }
        if fixtureSubscriptionIntakeMode {
            startPodcastSubscriptionIntake(url, initialMetadataCount: initialMetadataCount)
            return
        }
        guard podcastSubscriptionClassificationTask == nil else { return }
        advertisedFeed = nil
        selectedPodcastFeedID = nil
        pendingPodcastSubscriptionInitialMetadataCount = initialMetadataCount
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
                case let .podcastCatalogShow(show): outcome = .confirm(show.feedURL, show.title)
                case .article: outcome = .notAFeed
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as PodcastCatalogLookupError {
                outcome = error == .cancelled ? .cancelled : .lookupFailed(error)
            } catch let error as PastedLinkClassifierError {
                if error == .invalidURL {
                    outcome = .invalid
                } else {
                    outcome = .unreachable
                }
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
        case confirm(URL, String? = nil)
        case notAFeed
        case cancelled, invalid, unreachable
        /// Apple's show lookup failed in a way worth naming.
        case lookupFailed(PodcastCatalogLookupError)
    }

    private func apply(_ outcome: PodcastSubscriptionCheckOutcome) {
#if canImport(WiltedProducer)
        switch outcome {
        case let .subscribe(url):
            podcastFeedDraftStatus = nil
            subscribeToPodcastFeed(url)
        case let .confirm(feedURL, showTitle):
            advertisedFeed = feedURL
            if let showTitle {
                podcastFeedDraftStatus = "Found \(showTitle). Confirm before subscribing."
            } else {
                podcastFeedDraftStatus = "This page advertises one podcast feed. Confirm before subscribing."
            }
        case .notAFeed:
            podcastFeedDraftStatus = "That page does not advertise a podcast feed."
        case .cancelled:
            podcastFeedDraftStatus = Self.podcastCheckCancelledStatus
        case .invalid:
            podcastFeedDraftStatus = "Enter a complete HTTPS podcast feed or supported Apple show address."
        case .unreachable:
            podcastFeedDraftStatus = "Wilted could not reach that address. Check it, or retry when online."
        case let .lookupFailed(error):
            podcastFeedDraftStatus = Self.appleLookupFailureStatus(error)
        }
#endif
    }

    /// What a failed Apple show lookup says. Each names the cause and what to do, rather than
    /// blaming the connection for a link that simply has no show behind it.
    static func appleLookupFailureStatus(_ error: PodcastCatalogLookupError) -> String {
        switch error {
        case .invalidCollectionID:
            "That Apple Podcasts address is not a supported show link."
        case .resultNotFound:
            "Apple Podcasts has no show at that link, or it has no public feed. Check the link or paste the feed address."
        case .timedOut:
            "Apple Podcasts took too long to answer. Retry when online."
        case .invalidResponse, .responseTooLarge, .unsafeRedirect:
            "Apple Podcasts gave an answer Wilted could not use. Retry later or paste the feed address."
        case .cancelled:
            podcastCheckCancelledStatus
        }
    }

    func cancelPodcastSubscriptionCheck() {
        // Move both identities first so a cancellation-ignoring client cannot
        // overwrite the next request's composer feedback.
        let ownsRefresh = podcastSubscriptionRequestID != nil
        podcastSubscriptionCheckGeneration &+= 1
        podcastSubscriptionRequestID = nil
        pendingPodcastSubscriptionInitialMetadataCount = nil
        podcastSubscriptionClassificationTask?.cancel()
        podcastSubscriptionClassificationTask = nil
        if ownsRefresh {
            podcastRefreshTask?.cancel(); podcastRefreshOperationID = nil
            podcastRefreshTask = nil; isRefreshingPodcasts = false
            settleFeedRefreshStates()
        }
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
        guard let store, !isClosingTemporaryState, podcastRefreshTask == nil else { return }
        isRefreshingPodcasts = true
        podcastOperationMessage = "Refreshing subscribed podcasts…"
        let operationID = UUID()
        let ledgerToken = UUID()
        podcastRefreshOperationID = operationID
        podcastRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.subscriptionWriteTasks[ledgerToken] = nil
                if self.podcastRefreshOperationID == operationID {
                    self.isRefreshingPodcasts = false
                    self.podcastRefreshTask = nil
                    self.podcastRefreshOperationID = nil
                    self.settleFeedRefreshStates()
                }
            }
            do {
                let subscriptions = try await store.subscriptions().filter(\.enabled)
                var urls: [URL] = []
                for subscription in subscriptions {
                    if let url = try await store.podcastFeed(for: subscription.feedID)?.canonicalURL {
                        urls.append(url)
                    }
                }
                let result = try await self.refreshPodcastURLs(urls, subscribing: false)
                guard self.podcastRefreshOperationID == operationID else { return }
                self.lastPodcastRefreshNewEpisodeIDs = result.newEpisodeIDs.map(\.rawValue)
                if result.successfulFeedCount > 0 { self.setLastAutomationRefresh(Date()) }
                let update = result.newEpisodeIDs.isEmpty
                    ? "Podcast episodes are up to date."
                    : "Added \(result.newEpisodeIDs.count) new episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
                self.podcastOperationMessage = result.failedFeedCount == 0
                    ? update
                    : "\(update) \(result.failedFeedCount) feed\(result.failedFeedCount == 1 ? "" : "s") could not be refreshed."
            } catch is CancellationError {
                guard self.podcastRefreshOperationID == operationID else { return }
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch PodcastFeedClientError.cancelled {
                guard self.podcastRefreshOperationID == operationID else { return }
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch {
                guard self.podcastRefreshOperationID == operationID else { return }
                self.podcastOperationMessage = "Podcasts could not be refreshed. Check your connection and retry."
            }
        }
        if let podcastRefreshTask { subscriptionWriteTasks[ledgerToken] = podcastRefreshTask }
#endif
    }

    func cancelPodcastRefresh() {
        podcastRefreshTask?.cancel()
        podcastRefreshOperationID = nil
        podcastRefreshTask = nil
        isRefreshingPodcasts = false
        settleFeedRefreshStates()
        podcastOperationMessage = "Podcast refresh cancelled."
    }

}
