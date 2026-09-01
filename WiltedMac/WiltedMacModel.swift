import Foundation
import Observation
import AppKit

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

struct WiltedMacArticle: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let source: String
    let url: URL
    let isReady: Bool
    /// Present once audio exists. The library row states how long an article
    /// takes to listen to, which is the one fact that decides whether to
    /// start it now, and it was the only list in the app that withheld it.
    let durationSeconds: TimeInterval?
    let createdAt: Date

    init(
        id: String,
        title: String,
        source: String,
        url: URL,
        isReady: Bool,
        durationSeconds: TimeInterval?,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.url = url
        self.isReady = isReady
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

enum WiltedMacLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case unplayed = "Unplayed"
    case inProgress = "In Progress"
    case finished = "Finished"
    var id: Self { self }
}

enum WiltedMacLibraryOrder: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest"
    case oldest = "Oldest"
    var id: Self { self }
}

enum WiltedMacEpisodeDownloadState: Equatable, Sendable {
    case notDownloaded
    case queued
    case downloading(received: Int64, expected: Int64?)
    case completed
    case failed
    case cancelled
}

/// What preparation has done to a downloaded episode, and what it is doing now.
///
/// Preparation is the difference between Wilted and a plain podcast client:
/// the advertisements come out and the transcript is synchronised with what is
/// left. It takes minutes, so the row says which stage it is in rather than
/// going quiet.
enum WiltedMacEpisodePreparationState: Equatable, Sendable {
    case notPrepared
    case preparing(stage: String)
    case prepared(summary: String)
    case failed(String)

    var isRunning: Bool { if case .preparing = self { true } else { false } }

    /// The line the row shows under the title, or nil when there is nothing
    /// worth saying.
    var label: String? {
        switch self {
        case .notPrepared: nil
        case .preparing(let stage): stage
        case .prepared(let summary): summary
        case .failed(let message): message
        }
    }
}

/// One row of the Feeds card: a podcast Wilted follows, and what following it
/// currently yields.
struct WiltedMacSubscription: Identifiable, Hashable, Sendable {
    /// The feed's `ItemID`, which is what the store keys a subscription on.
    let id: String
    let title: String
    let feedURL: URL
    let episodeCount: Int
    let subscribedAt: Date
    var enabled: Bool
}

struct WiltedMacEpisode: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let feedTitle: String
    let summary: String
    let artworkURL: URL?
    let releasedAt: Date
    let durationSeconds: TimeInterval?
    let playbackSeconds: TimeInterval
    var downloadState: WiltedMacEpisodeDownloadState
    var preparationState: WiltedMacEpisodePreparationState = .notPrepared

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.feedTitle == rhs.feedTitle &&
            lhs.summary == rhs.summary && lhs.artworkURL == rhs.artworkURL && lhs.releasedAt == rhs.releasedAt &&
            lhs.durationSeconds == rhs.durationSeconds && lhs.playbackSeconds == rhs.playbackSeconds &&
            lhs.downloadState == rhs.downloadState && lhs.preparationState == rhs.preparationState
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum WiltedMacLibraryItem: Identifiable, Hashable, Sendable {
    case article(WiltedMacArticle)
    case episode(WiltedMacEpisode)

    var id: String {
        switch self { case .article(let value): value.id; case .episode(let value): value.id }
    }
    var title: String {
        switch self { case .article(let value): value.title; case .episode(let value): value.title }
    }
    var source: String {
        switch self { case .article(let value): value.source; case .episode(let value): value.feedTitle }
    }
    var date: Date {
        switch self { case .article(let value): value.createdAt; case .episode(let value): value.releasedAt }
    }
    var progress: (position: TimeInterval, duration: TimeInterval?) {
        switch self {
        case .article(let value): (0, value.durationSeconds)
        case .episode(let value): (value.playbackSeconds, value.durationSeconds)
        }
    }
}

/// Presentation view of one recorded preparation attempt.
///
/// The producer runs one preparation at a time and keeps a journal of every
/// status each attempt emitted. Nothing surfaced that journal, so a run that
/// failed overnight left no trace a reader could find. This is the row shape
/// the Processor destination lists.
struct WiltedMacProcessorRun: Identifiable, Equatable, Sendable {
    enum Outcome: String, Sendable {
        case running, succeeded, failed, cancelled
    }

    let id: String
    let title: String
    let source: String
    let stage: String
    let detail: String
    let fraction: Double?
    let outcome: Outcome
    let updatedAt: Date

    /// Colour is emphasis only; `outcomeLabel` always states the outcome.
    var tone: WiltedStatusTone {
        switch outcome {
        case .running: .active
        case .succeeded: .positive
        case .cancelled: .neutral
        case .failed: .failure
        }
    }

    var outcomeLabel: String {
        switch outcome {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Presentation view of a stored transcript.
///
/// The domain `Transcript` lives behind `canImport(WiltedProducer)`, so the
/// producer keeps a local shape here for the same reason `WiltedMacArticle`
/// exists: the views stay compilable without the producer package, and UI code
/// never handles a domain type directly.
/// One timed line of a transcript, in the audio's own clock.
struct WiltedMacTranscriptCue: Identifiable, Equatable, Sendable {
    /// Position in the transcript. Start times can repeat across cues in a
    /// published caption file, so the index is what identifies a row.
    let id: Int
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
}

struct WiltedMacTranscript: Equatable, Sendable {
    enum Availability: String, Sendable {
        case available
        case stale
        case oversized
        case malformed
        case absent
    }

    let availability: Availability
    let text: String?
    /// Empty unless the transcript's timing was measured against this exact
    /// audio. An estimate is not timing and never appears here.
    var cues: [WiltedMacTranscriptCue] = []
    /// Whether the timing came from the publisher or from Wilted's own pass.
    var timingSource: String?

    /// A transcript that can follow the playback clock.
    var isSynchronized: Bool { isReadable && !cues.isEmpty }

    /// The cue covering `seconds`, for a reader following playback.
    ///
    /// Binary search rather than a scan: this runs on every readout tick, and
    /// a three-hour episode carries thousands of cues.
    func cueIndex(at seconds: TimeInterval) -> Int? {
        guard !cues.isEmpty, seconds >= cues[0].startSeconds else { return nil }
        var low = 0, high = cues.count - 1, found = 0
        while low <= high {
            let middle = (low + high) / 2
            if cues[middle].startSeconds <= seconds { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return found
    }

    var isReadable: Bool {
        (availability == .available || availability == .stale) && !(text ?? "").isEmpty
    }

    /// Says why text is missing instead of silently showing nothing. The
    /// listener already did this; the producer showed no transcript at all.
    var unavailableLabel: String {
        switch availability {
        case .oversized: "Transcript unavailable: article text is too large"
        case .malformed: "Transcript unavailable: article text could not be read"
        case .absent, .available, .stale: "Transcript unavailable"
        }
    }

    var disclosureTitle: String {
        if availability == .stale { return "Transcript (may be outdated)" }
        guard let timingSource else { return "Transcript" }
        return "Transcript · \(timingSource)"
    }

    /// The listener always shows this row and explains why text is missing.
    /// The producer rendered nothing at all when it had no transcript loaded,
    /// so this is what a missing one resolves to.
    static let unavailable = WiltedMacTranscript(availability: .absent, text: nil)
}

struct WiltedMacPreparation: Equatable, Sendable {
    enum Phase: String, Sendable {
        case preparing
        case extracting
        case synthesizing
        case assembling
        case saving
        case cancelling
        case completed
        case cancelled
        case failed

        var title: String {
            switch self {
            case .preparing: "Preparing article"
            case .extracting: "Extracting article"
            case .synthesizing: "Generating speech"
            case .assembling: "Assembling audio"
            case .saving: "Saving revision"
            case .cancelling: "Cancelling preparation"
            case .completed: "Ready to play"
            case .cancelled: "Preparation cancelled"
            case .failed: "Preparation failed"
            }
        }

        /// A finished run. The Processor destination shows the active card
        /// only while work is genuinely in flight.
        var isTerminal: Bool {
            switch self {
            case .completed, .cancelled, .failed: true
            default: false
            }
        }
    }

    let phase: Phase
    let detail: String
    let fraction: Double?
    let cancellable: Bool
}

/// The producer's permanent destinations.
///
/// Library, feeds, preparation, and settings remain work destinations.
/// Playback is owned by the persistent bottom rail instead of competing for
/// navigation. Feeds is its own destination because Larder is for the things
/// worth reading and listening to; which sources supply them is upkeep, and it
/// was pushing the actual library below the fold.
enum WiltedMacNavigation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case library
    case feeds
    case processor
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .library: WiltedScreenCopy.library
        case .feeds: WiltedScreenCopy.feeds
        case .processor: WiltedScreenCopy.processor
        case .settings: WiltedScreenCopy.settings
        }
    }

    var symbolName: String {
        switch self {
        case .library: "books.vertical"
        case .feeds: "dot.radiowaves.left.and.right"
        case .processor: "gearshape.2"
        case .settings: "gearshape"
        }
    }
}

#if canImport(WiltedProducer)
typealias WiltedMacStoreBootstrap = @Sendable (URL) async throws -> LocalLibraryStore
#endif

struct WiltedMacStartupFailure: Equatable, Sendable {
    let message: String
    let retainedV5StoreURL: URL?
    let canRetry: Bool
}

enum WiltedMacStartupState: Equatable, Sendable {
    case loading(attempt: Int)
    case ready
    case failed(WiltedMacStartupFailure)
}

/// Main-actor presentation state for the local Mac producer.
@Observable
@MainActor
final class WiltedMacModel {
    private static let maximumStartupAttempts = 2

    private(set) var startupState: WiltedMacStartupState = .loading(attempt: 0)
    var urlDraft = ""
    /// What the single add box is doing right now. Telling a feed from an
    /// article needs the document, so the button can sit on a network round
    /// trip; an unannounced pause there reads as a control that did nothing.
    private(set) var linkDraftStatus: String?
    /// A feed the page just added advertises. Offered, never taken: following a
    /// site's whole feed is a different request from saving one article of it.
    private(set) var advertisedFeed: URL?
    /// Episodes the last refresh loaded but did not keep, either because the
    /// feed exceeded the client's episode ceiling or because they published
    /// before the subscription. Reported so a partial view of a feed is never
    /// presented as the whole feed.
    var withheldPodcastEpisodeCount = 0
    var librarySearchQuery = ""
    var libraryFilter: WiltedMacLibraryFilter = .all
    var libraryOrder: WiltedMacLibraryOrder = .newest
    var selectedNavigation: WiltedMacNavigation = .library
    private(set) var articles: [WiltedMacArticle] = []
    private(set) var episodes: [WiltedMacEpisode] = []
    private(set) var podcastOperationMessage: String?
    private(set) var isRefreshingPodcasts = false
    private(set) var selectedLibraryItemID: String?
    private(set) var preparation: WiltedMacPreparation?
    private(set) var selectedArticleID: String?
    private(set) var isNowPlaying = false
    private(set) var isPlaying = false
    private(set) var playbackError: String?
    /// Readout state the listener already published. The producer's player
    /// showed transports and nothing else, so the Mac could not answer "how
    /// far in am I?" — a question the same audio answers on iPhone.
    private(set) var playbackPositionSeconds: TimeInterval = 0
    private(set) var playbackDurationSeconds: TimeInterval = 0
    /// Every recorded preparation attempt, newest first.
    private(set) var processorRuns: [WiltedMacProcessorRun] = []
    /// Progress for an in-flight transcript backfill (W-INV-001: a network
    /// fetch never runs without the surface saying so).
    private(set) var transcriptBackfillStatus: String?
    private(set) var isBackfillingTranscript = false
    private(set) var currentTranscript: WiltedMacTranscript?
    private(set) var podcastQueueIDs: [String] = []
    private(set) var currentPodcastEpisodeID: String?
    private(set) var playbackRate: Double = 1
    private(set) var playbackVolume: Double = 1
    private(set) var playbackOperationStatus: String?
    private(set) var articlePublicationCount = 0
    private(set) var articlePlaybackCheckpointCount = 0
    /// Set only when a route operation actually failed. The recovery control
    /// is gated on this so it does not advertise a fix for a fault that has
    /// not happened, matching how every other recovery control here behaves.
    private(set) var audioRouteFault = false

    let fixtureMode: Bool

#if canImport(WiltedProducer)
    private var store: LocalLibraryStore?
    private var coordinator: PreparationCoordinator?
    private var playback: PlaybackController?
    private var syncLifecycle: WiltedMacSyncLifecycle?
    /// Podcast feeds Wilted follows, newest subscription first.
    var subscriptions: [WiltedMacSubscription] = []

    private let libraryURL: URL
    private let mediaDirectory: URL
    private let syncTransportFactory: WiltedMacSyncTransportFactory?
    private let assetResolver: LocalLibraryAssetResolver
    private let storeBootstrap: WiltedMacStoreBootstrap
    private let retainedArtifactPresenter: (URL) -> Void
    private var startupAttemptCount = 0
    private var startupTask: Task<Void, Never>?
    private var pendingSyncReconciliation = false
    private var preparationRun: PreparationRun?
    private var preparationTask: Task<Void, Never>?
    private var syncReconciliationTask: Task<Void, Never>?
    private var podcastRefreshTask: Task<Void, Never>?
    private var podcastDownloadTasks: [String: Task<Void, Never>] = [:]
    private var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    private var podcastPreparationPipeline: PodcastPreparationPipeline?
    private var podcastPreparationTasks: [String: Task<Void, Never>] = [:]
    /// Removing advertisements is why preparation exists. Read once, when the
    /// pipeline is built, so this is not a switch: a Settings control would
    /// have to rebuild the pipeline to mean anything, and none exists yet.
    private let removesAdvertisements = true
    private var hiddenEpisodeIDs: Set<String> = []
    private var fixtureDownloadFailuresRemaining = 0
    private let podcastFeedClient: PodcastFeedClient
    private let pastedLinkClassifier: PastedLinkClassifier
    private var linkClassificationTask: Task<Void, Never>?
    private var fixtureRevision: StoredAudioRevision?
    private var fixturePodcastInstallTask: Task<Void, Never>?
    private var playbackOperationTask: Task<Void, Never>?
    private var isPodcastPlayback = false
#endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         syncTransportFactory: WiltedMacSyncTransportFactory? = nil,
         assetResolver: @escaping LocalLibraryAssetResolver = { _, _ in nil },
         stateDirectoryOverride: URL? = nil,
         storeBootstrap: WiltedMacStoreBootstrap? = nil,
         retainedArtifactPresenter: ((URL) -> Void)? = nil,
         podcastFeedClient: PodcastFeedClient = PodcastFeedClient(),
         pastedLinkClassifier: PastedLinkClassifier = PastedLinkClassifier()) {
        let usesFixtureMode = arguments.contains("--wilted-ui-fixture-article-flow")
            || arguments.contains("--wilted-ui-fixture-quarantined")
            || arguments.contains("--wilted-ui-smoke")
            || arguments.contains("--wilted-ui-fixture-ready")
            || arguments.contains("--wilted-ui-fixture-playing")
            || arguments.contains("--wilted-ui-fixture-preparing")
            || arguments.contains("--wilted-ui-fixture-podcasts")
            || arguments.contains("--wilted-ui-fixture-download-failure")
        fixtureMode = usesFixtureMode

#if canImport(WiltedProducer)
        let stateDirectory = stateDirectoryOverride ?? Self.stateDirectory(fixtureMode: usesFixtureMode)
        self.libraryURL = stateDirectory.appendingPathComponent("library.sqlite")
        self.mediaDirectory = stateDirectory.appendingPathComponent("media", isDirectory: true)
        self.syncTransportFactory = syncTransportFactory
        self.assetResolver = assetResolver
        self.storeBootstrap = storeBootstrap ?? { url in
            try await Task.detached(priority: .userInitiated) {
                try LocalLibraryStore(url: url)
            }.value
        }
        self.retainedArtifactPresenter = retainedArtifactPresenter ?? { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        self.podcastFeedClient = podcastFeedClient
        self.pastedLinkClassifier = pastedLinkClassifier
        fixtureDownloadFailuresRemaining = arguments.contains("--wilted-ui-fixture-download-failure") ? 1 : 0

        if usesFixtureMode {
            let configuredStore = try? LocalLibraryStore(url: self.libraryURL)
            configureStoreDependencies(configuredStore)
            startupState = configuredStore == nil
                ? .failed(Self.startupFailure(libraryURL: self.libraryURL, canRetry: false))
                : .ready
            installFixture(
                ready: arguments.contains("--wilted-ui-fixture-ready") || arguments.contains("--wilted-ui-fixture-playing"),
                preparing: arguments.contains("--wilted-ui-fixture-preparing"),
                podcasts: arguments.contains("--wilted-ui-fixture-podcasts")
            )
            if arguments.contains("--wilted-ui-fixture-quarantined") {
                syncLifecycle?.quarantineAccount()
            }
            if arguments.contains("--wilted-ui-fixture-playing"), let firstArticle = articles.first(where: { $0.isReady }) {
                openNowPlaying(for: firstArticle)
                togglePlayback()
            }
        }
#else
        _ = arguments
#endif
    }

    var libraryItems: [WiltedMacLibraryItem] {
        let query = librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = articles.map(WiltedMacLibraryItem.article) +
            episodes.filter { !hiddenEpisodeIDs.contains($0.id) }.map(WiltedMacLibraryItem.episode)
        let filtered = combined.filter { item in
            let matchesQuery = query.isEmpty || item.title.localizedCaseInsensitiveContains(query) ||
                item.source.localizedCaseInsensitiveContains(query)
            guard matchesQuery else { return false }
            let progress = item.progress
            let finished = progress.duration.map { $0 > 0 && progress.position >= $0 * 0.95 } ?? false
            switch libraryFilter {
            case .all: return true
            case .unplayed: return progress.position <= 0 && !finished
            case .inProgress: return progress.position > 0 && !finished
            case .finished: return finished
            }
        }
        return filtered.sorted {
            if $0.date != $1.date { return libraryOrder == .newest ? $0.date > $1.date : $0.date < $1.date }
            return $0.id < $1.id
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
        startupState = .loading(attempt: startupAttemptCount)
        startupTask = Task { [weak self] in
            await self?.performStoreBootstrap()
        }
    }
#endif

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
        case let .loading(attempt):
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

    /// Follows the feed the last added page advertised.
    func subscribeToAdvertisedFeed() {
        guard let advertisedFeed else { return }
        self.advertisedFeed = nil
        subscribeToPodcastFeed(advertisedFeed)
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
                try await self.refreshPodcastURLs(urls, subscribing: false)
                self.podcastOperationMessage = "Podcast episodes are up to date."
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

    func downloadEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        if fixtureMode {
            guard podcastDownloadTasks[episode.id] == nil else { return }
            updateEpisode(episode.id) { $0.downloadState = .queued }
            podcastOperationMessage = "Queued \(episode.title) for download."
            podcastDownloadTasks[episode.id] = Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.updateEpisode(episode.id) { $0.downloadState = .cancelled }
                    self.podcastOperationMessage = "Download cancelled."
                    self.podcastDownloadTasks[episode.id] = nil
                    return
                }
                self.updateEpisode(episode.id) { $0.downloadState = .downloading(received: 3, expected: 6) }
                self.podcastOperationMessage = "Downloading \(episode.title)…"
                await Task.yield()
                guard !Task.isCancelled else {
                    self.updateEpisode(episode.id) { $0.downloadState = .cancelled }
                    self.podcastOperationMessage = "Download cancelled."
                    self.podcastDownloadTasks[episode.id] = nil
                    return
                }
                if self.fixtureDownloadFailuresRemaining > 0 {
                    self.fixtureDownloadFailuresRemaining -= 1
                    self.updateEpisode(episode.id) { $0.downloadState = .failed }
                    self.podcastOperationMessage = "Download failed. Retry when you are online."
                } else {
                    self.updateEpisode(episode.id) { $0.downloadState = .completed }
                    self.podcastOperationMessage = "\(episode.title) is available offline."
                }
                self.podcastDownloadTasks[episode.id] = nil
            }
            return
        }
        guard podcastDownloadTasks[episode.id] == nil,
              let coordinator = podcastDownloadCoordinator,
              let itemID = try? ItemID(rawValue: episode.id) else { return }
        updateEpisode(episode.id) { $0.downloadState = .queued }
        podcastOperationMessage = "Queued \(episode.title) for download."
        podcastDownloadTasks[episode.id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await coordinator.download(episodeID: itemID) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.updateActiveEpisodeDownload(
                            episode.id,
                            received: progress.bytesReceived,
                            expected: progress.expectedByteCount
                        ) == true else { return }
                        self?.podcastOperationMessage = "Downloading \(episode.title)…"
                    }
                }
                guard let store = self.store else { throw CancellationError() }
                let values = try await self.loadLibrary(from: store)
                self.articles = values.articles
                self.episodes = values.episodes
                self.subscriptions = values.subscriptions
                self.podcastOperationMessage = "\(episode.title) is available offline."
                self.podcastDownloadTasks[episode.id] = nil
                self.prepareEpisode(episode)
                return
            } catch PodcastDownloadCoordinatorError.cancelled {
                self.updateEpisode(episode.id) { $0.downloadState = .cancelled }
                self.podcastOperationMessage = "Download cancelled."
            } catch {
                self.updateEpisode(episode.id) { $0.downloadState = .failed }
                self.podcastOperationMessage = "Download failed. Retry when you are online."
            }
            self.podcastDownloadTasks[episode.id] = nil
        }
#endif
    }

    /// Removes the advertisements and synchronises the transcript.
    ///
    /// Runs automatically once a download lands, and manually from the row for
    /// an episode that was downloaded before preparation existed or whose last
    /// attempt failed. Every stage is reported as it happens: the speech and
    /// classification passes take minutes, and a silent window is
    /// indistinguishable from a hung one.
    func prepareEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard podcastPreparationTasks[episode.id] == nil,
              let pipeline = podcastPreparationPipeline,
              let itemID = try? ItemID(rawValue: episode.id) else { return }
        updateEpisode(episode.id) { $0.preparationState = .preparing(stage: "Preparing…") }
        podcastOperationMessage = "Preparing \(episode.title)…"
        // Built here rather than inside the task so it captures the model
        // directly: the worker calls it from its own queue for minutes.
        let report: @Sendable (PodcastPreparationProgress) -> Void = { [weak self] progress in
            let label = Self.preparationLabel(for: progress)
            Task { @MainActor in
                self?.updateEpisode(episode.id) { $0.preparationState = .preparing(stage: label) }
            }
        }
        podcastPreparationTasks[episode.id] = Task { [weak self] in
            defer { self?.podcastPreparationTasks[episode.id] = nil }
            do {
                let result = try await pipeline.prepare(episodeID: itemID, onStatus: report)
                guard let self else { return }
                let summary = Self.preparedSummary(
                    advertisements: result.adSegments.count, secondsRemoved: result.removedSeconds,
                    timing: result.transcript.timing
                )
                self.podcastOperationMessage = "\(episode.title): \(summary)"
                if let store = self.store {
                    let values = try await self.loadLibrary(from: store)
                    self.articles = values.articles
                    self.episodes = values.episodes
                    self.subscriptions = values.subscriptions
                }
                // Applied after the reload, not before. The reload derives
                // preparation state from what the library can prove, and how
                // many advertisements a run cut is not stored, so it would
                // otherwise replace this run's summary with a generic one.
                self.updateEpisode(episode.id) { $0.preparationState = .prepared(summary: summary) }
                await self.reloadPreparedPlayback(episode.id, itemID: itemID)
                self.refreshProcessorRuns()
            } catch is CancellationError {
                self?.updateEpisode(episode.id) { $0.preparationState = .notPrepared }
                self?.podcastOperationMessage = "Preparation cancelled."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "Preparation failed."
                self?.updateEpisode(episode.id) { $0.preparationState = .failed(message) }
                self?.podcastOperationMessage = message
            }
        }
#endif
    }

    func cancelEpisodePreparation(_ episode: WiltedMacEpisode) {
        podcastPreparationTasks[episode.id]?.cancel()
    }

#if canImport(WiltedProducer)
    /// Re-points the player at an episode that was just prepared.
    ///
    /// Preparation supersedes the revision and deletes the audio it was cut
    /// from, carrying the saved position onto the new timeline. A player still
    /// holding the old revision would keep playing the advertisements and
    /// would fail on its next load, so the episode is selected again, which
    /// resumes from the carried position and picks up the new transcript.
    private func reloadPreparedPlayback(_ episodeID: String, itemID: ItemID) async {
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
        case "transcript.published.parse", "transcript.published.accepted": "Reading the published transcript…"
        case "transcript.published.unreadable", "transcript.published.unreachable",
             "transcript.published.unparseable": "No usable published transcript. Transcribing…"
        case "transcript.stt.start": "Transcribing the audio…"
        case "transcript.stt.complete": "Transcribed."
        case "transcript.stt.failed": "Transcription unavailable."
        case "transcript.prose.extract", "transcript.prose.accepted": "Reading the episode page…"
        case "transcript.absent": "No transcript available."
        case "transcript.remap": "Resynchronising the transcript…"
        case "ads.model.load": "Loading the advertisement classifier…"
        case "ads.detect.start", "ads.detect.complete": "Finding advertisements…"
        case "ads.cut.start", "ads.cut.complete": "Removing advertisements…"
        case "ads.cut.refused", "ads.cut.empty": "Advertisements left in place."
        case "audio.publish": "Storing the prepared audio…"
        case "pipeline.complete": "Prepared."
        default: "Preparing…"
        }
    }

    nonisolated static func preparedSummary(
        advertisements: Int, secondsRemoved: Double, timing: TranscriptTiming
    ) -> String {
        var parts: [String] = []
        if advertisements > 0, secondsRemoved > 0 {
            let removed = WiltedDuration.clock(secondsRemoved)
            parts.append(advertisements == 1 ? "1 ad removed (\(removed))"
                                             : "\(advertisements) ads removed (\(removed))")
        } else {
            parts.append("No advertisements found")
        }
        switch timing {
        case .published: parts.append("synced transcript from the feed")
        case .aligned: parts.append("synced transcript")
        case .none: parts.append("no synced transcript")
        }
        return parts.joined(separator: " · ")
    }
#endif

    func cancelEpisodeDownload(_ episode: WiltedMacEpisode) {
        podcastDownloadTasks[episode.id]?.cancel()
    }

    func retryEpisodeDownload(_ episode: WiltedMacEpisode) { downloadEpisode(episode) }

    func waitForPodcastOperations() async {
        await linkClassificationTask?.value
        let refresh = podcastRefreshTask
        let downloads = Array(podcastDownloadTasks.values)
        await refresh?.value
        for task in downloads { await task.value }
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
                self.episodes = values.episodes
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let removed = try await store.unsubscribeFromPodcast(feedID: feedID)
                let values = try await self.loadLibrary(from: store)
                self.articles = values.articles
                self.episodes = values.episodes
                self.subscriptions = values.subscriptions
                self.podcastOperationMessage =
                    "Unsubscribed from \(subscription.title) and removed \(removed) episode\(removed == 1 ? "" : "s")."
            } catch {
                self.podcastOperationMessage = "\(subscription.title) could not be unsubscribed."
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
        podcastDownloadTasks[episode.id]?.cancel()
        podcastPreparationTasks[episode.id]?.cancel()
        hiddenEpisodeIDs.insert(episode.id)
        if selectedLibraryItemID == episode.id { selectedLibraryItemID = nil }
        podcastOperationMessage = "Removed \(episode.title). Refreshing will not bring it back."
#if canImport(WiltedProducer)
        guard let store, let id = try? ItemID(rawValue: episode.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.dismissPodcastEpisode(id)
                if let playback = self.playback {
                    try? await playback.removePodcastQueueEpisode(id)
                    await self.refreshPodcastQueueState()
                }
                let values = try await self.loadLibrary(from: store)
                self.articles = values.articles
                self.episodes = values.episodes
                self.subscriptions = values.subscriptions
            } catch {
                self.hiddenEpisodeIDs.remove(episode.id)
                self.podcastOperationMessage = "\(episode.title) could not be removed."
            }
        }
#endif
    }

#if canImport(WiltedProducer)
    private func startPodcastRefresh(urls: [URL], subscribing: Bool) {
        guard podcastRefreshTask == nil else { return }
        isRefreshingPodcasts = true
        podcastOperationMessage = subscribing ? "Adding podcast feed…" : "Refreshing subscribed podcasts…"
        podcastRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.refreshPodcastURLs(urls, subscribing: subscribing)
                if subscribing { self.urlDraft = "" }
                self.podcastOperationMessage = "Podcast episodes are up to date."
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

    /// Loads each feed and stores what the subscription horizon admits.
    ///
    /// The subscription is written before its episodes: the horizon rule reads
    /// it, so a feed subscribed to after its episodes were offered would admit
    /// nothing. Anything the feed published but Wilted did not keep is counted
    /// and reported -- a truncated back catalogue must never read as the whole
    /// feed.
    private func refreshPodcastURLs(_ urls: [URL], subscribing: Bool) async throws {
        guard let store else { throw CancellationError() }
        var withheld = 0
        for url in urls {
            try Task.checkCancellation()
            let loaded = try await podcastFeedClient.load(url)
            try await store.save(feed: loaded.feed)
            if subscribing {
                try await store.save(subscription: PodcastSubscription(
                    feedID: loaded.feed.itemID, subscribedAt: Timestamp(Date())
                ))
            }
            let admission = try await store.savePodcastEpisodes(
                loaded.episodes, admission: subscribing ? .backfill : .incremental
            )
            withheld += loaded.droppedEpisodeCount + admission.skipped
        }
        withheldPodcastEpisodeCount = withheld
        let values = try await loadLibrary(from: store)
        articles = values.articles
        episodes = values.episodes
        subscriptions = values.subscriptions
    }

#endif

    private func updateEpisode(_ id: String, transform: (inout WiltedMacEpisode) -> Void) {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
        transform(&episodes[index])
    }

    /// Progress callbacks are delivered through queued MainActor tasks. Once
    /// the store reload publishes a terminal state, an older callback must not
    /// move the row backwards to downloading.
    private func updateActiveEpisodeDownload(_ id: String, received: Int64, expected: Int64?) -> Bool {
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

    var hasCurrentPlayback: Bool { currentArticle != nil || currentEpisode != nil }

    var canSelectPreviousEpisode: Bool {
        guard isPodcastPlayback, let currentPodcastEpisodeID,
              let index = podcastQueueIDs.firstIndex(of: currentPodcastEpisodeID) else { return false }
        return index > podcastQueueIDs.startIndex
    }

    var canSelectNextEpisode: Bool {
        guard isPodcastPlayback, let currentPodcastEpisodeID,
              let index = podcastQueueIDs.firstIndex(of: currentPodcastEpisodeID) else { return false }
        return podcastQueueIDs.index(after: index) < podcastQueueIDs.endIndex
    }

    var canCancelPreparation: Bool { preparation?.cancellable == true }

    /// The player's one-line status, matching the listener's status channel so
    /// the same condition reads the same way on both platforms. Never color
    /// alone: the tone accompanies this text rather than replacing it.
    var playbackStatusMessage: String {
        if !hasCurrentPlayback { return "Nothing is playing" }
        if let playbackError { return playbackError }
        if isPlaying { return "Playing" }
        if isNowPlaying { return "Paused" }
        return "Ready"
    }

    var playbackStatusTone: WiltedStatusTone {
        if playbackError != nil { return .failure }
        if isPlaying { return .active }
        return .neutral
    }

    /// Elapsed and total, in the listener's wording.
    var playbackProgressLabel: String {
        WiltedDuration.progress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    /// The spoken form of the same readout.
    var playbackProgressSpokenLabel: String {
        WiltedDuration.spokenProgress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    /// Adds whatever was pasted, working out for itself which kind it is.
    ///
    /// Two boxes made the reader classify an address before pasting it, and a
    /// podcast address dropped in the article box produced a parse error rather
    /// than a subscription. The document decides instead: an unmistakable feed
    /// extension short-circuits, anything else is fetched once and sniffed.
    func addPastedLink() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            linkDraftStatus = "Enter a complete HTTPS address."
            return
        }
        advertisedFeed = nil
        linkDraftStatus = nil
        guard !fixtureMode else { addArticle(); return }

#if canImport(WiltedProducer)
        guard linkClassificationTask == nil else { return }
        linkDraftStatus = "Checking that address\u{2026}"
        linkClassificationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.linkClassificationTask = nil }
            do {
                let kind = try await self.pastedLinkClassifier.classify(url)
                guard !Task.isCancelled else { self.linkDraftStatus = nil; return }
                self.linkDraftStatus = nil
                switch kind {
                case .podcastFeed:
                    self.subscribeToPodcastFeed(url)
                case .article:
                    self.addArticle()
                case .articleAdvertisingFeed(let feedURL):
                    self.advertisedFeed = feedURL
                    self.addArticle()
                }
            } catch is CancellationError {
                self.linkDraftStatus = nil
            } catch {
                self.linkDraftStatus = "Wilted could not reach that address. Check it, or retry when online."
            }
        }
#else
        addArticle()
#endif
    }

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
        preparation = WiltedMacPreparation(
            phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
        )
        preparationTask = Task { [weak self] in
            let run = await coordinator.start(url: url)
            guard let self else { await run.cancel(); return }
            self.preparationRun = run
            for await status in run.statuses {
                guard !Task.isCancelled else { await run.cancel(); return }
                self.update(status)
                if status.terminal { break }
            }
            if self.preparation?.phase == .completed {
                if await self.queuePreparedPublication(itemID: preparedItemID) {
                    self.syncLifecycle?.startAutomaticUpload()
                }
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
        if fixtureMode { return }
#if canImport(WiltedProducer)
        let run = preparationRun
        Task { await run?.cancel() }
#endif
    }

    func openNowPlaying(for article: WiltedMacArticle) {
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
                    self.isPlaying = playback.isPlaying
                    self.refreshPlaybackReadout()
                    await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                } catch { self.playbackError = "Audio could not be loaded." }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.load(fixtureRevision)
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

    private func beginArticlePlaybackTransition(_ article: WiltedMacArticle) {
        selectedArticleID = article.id
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
        playbackOperationStatus = "Adding \(episode.title) to Up Next…"
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.fixturePodcastInstallTask?.value
                try await playback.addPodcastQueueEpisode(id)
                await self.refreshPodcastQueueState()
                self.playbackOperationStatus = "Added \(episode.title) to Up Next."
            } catch { self.playbackOperationStatus = "Up Next could not be updated." }
        }
#endif
    }

    func playEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episode.id) else { return }
        let wasQueued = podcastQueueIDs.contains(episode.id)
        playbackOperationStatus = "Opening \(episode.title)…"
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.fixturePodcastInstallTask?.value
                try await playback.addPodcastQueueEpisode(id)
                try await playback.selectPodcastQueueEpisode(id, autoplay: true)
                self.selectedArticleID = nil
                self.currentPodcastEpisodeID = episode.id
                self.isPodcastPlayback = true
                self.isNowPlaying = true
                self.currentTranscript = .unavailable
                await self.refreshPodcastQueueState()
                await self.loadEpisodeTranscript(itemID: id)
                self.refreshPlaybackReadout()
                self.playbackError = nil
                self.playbackOperationStatus = nil
            } catch {
                if !wasQueued {
                    try? await playback.removePodcastQueueEpisode(id)
                    await self.refreshPodcastQueueState()
                }
                self.playbackError = "This episode's saved audio is unavailable."
                self.playbackOperationStatus = nil
            }
        }
#endif
    }

    func removeEpisodeFromUpNext(_ episodeID: String) {
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episodeID) else { return }
        playbackOperationStatus = "Updating Up Next…"
        Task { [weak self] in
            try? await playback.removePodcastQueueEpisode(id)
            await self?.refreshPodcastQueueState()
            self?.playbackOperationStatus = nil
        }
#endif
    }

    func moveEpisodeInUpNext(from source: Int, to destination: Int) {
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackOperationStatus = "Reordering Up Next…"
        Task { [weak self] in
            try? await playback.movePodcastQueueEpisode(from: source, to: destination)
            await self?.refreshPodcastQueueState()
            self?.playbackOperationStatus = nil
        }
#endif
    }

    func setPlaybackRate(_ value: Double) {
        playbackRate = min(max(value, 0.5), 2)
#if canImport(WiltedProducer)
        playback?.setRate(Float(playbackRate))
        guard isPodcastPlayback, let store, let id = playback?.itemID else { return }
        let selectedRate = playbackRate
        playbackOperationStatus = "Saving playback speed…"
        Task { [weak self] in
            try? await store.save(playbackSpeed: PodcastPlaybackSpeed(
                itemID: id, speed: selectedRate, updatedAt: Timestamp(Date())
            ))
            self?.playbackOperationStatus = nil
        }
#endif
    }

    func setPlaybackVolume(_ value: Double) {
        playbackVolume = min(max(value, 0), 1)
#if canImport(WiltedProducer)
        playback?.setVolume(Float(playbackVolume))
#endif
    }

    func scrub(to value: Double) {
        guard value.isFinite else { return }
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(to: value)
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#else
        playbackPositionSeconds = min(max(value, 0), max(0, playbackDurationSeconds))
#endif
    }

    /// Republishes elapsed/total from the controller.
    ///
    /// `PlaybackController` advances its own position, but nothing observed it
    /// while audio ran, so the producer's readout would freeze at the loaded
    /// value. The player view drives this on a one-second cadence, matching
    /// the listener's `refreshNowPlayingReadout`.
    func refreshPlaybackReadout() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackDurationSeconds = playback.durationSeconds
        // The live engine read, not the checkpointed one. `positionSeconds`
        // only moves on load, seek, and checkpoint, so polling it left the
        // readout frozen between transport presses.
        playbackPositionSeconds = min(max(0, playback.livePositionSeconds), max(0, playback.durationSeconds))
        isPlaying = playback.liveIsPlaying
        playbackRate = Double(playback.playbackRate)
#endif
    }

#if canImport(WiltedProducer)
    private func loadTranscript(itemID: ItemID, revisionID: RevisionID) async {
        guard let store else { return }
        guard let stored = try? await store.transcript(for: itemID, revisionID: revisionID) else {
            currentTranscript = WiltedMacTranscript(availability: .absent, text: nil)
            return
        }
        let availability: WiltedMacTranscript.Availability = switch stored.availability {
        case .available: .available
        case .stale: .stale
        case .oversized: .oversized
        case .malformed: .malformed
        case .absent: .absent
        }
        let timingSource: String? = switch stored.timing {
        case .published: "synced from the feed"
        case .aligned: "synced"
        case .none: nil
        }
        currentTranscript = WiltedMacTranscript(
            availability: availability, text: stored.text,
            cues: (stored.cues ?? []).enumerated().map { index, cue in
                WiltedMacTranscriptCue(id: index, startSeconds: cue.startSeconds,
                                       endSeconds: cue.endSeconds, text: cue.text)
            },
            timingSource: timingSource
        )
    }
#endif

#if canImport(WiltedProducer)
    /// Loads the transcript for whichever revision of an episode is ready now.
    ///
    /// The revision cannot be remembered from when the episode was downloaded:
    /// preparation cuts the audio, which changes its bytes and therefore its
    /// identity, so the current one has to be read back from the library.
    private func loadEpisodeTranscript(itemID: ItemID) async {
        guard let store, let stored = try? await store.readyRevision(for: itemID) else {
            currentTranscript = .unavailable
            return
        }
        await loadTranscript(itemID: itemID, revisionID: stored.revision.revisionID)
    }
#endif

    func togglePlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.toggle()
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#else
        isPlaying.toggle()
#endif
    }

    /// Returns to Library without changing playback state.
    ///
    /// The player no longer draws its own back button — the sidebar is
    /// permanent, so a second way back was redundant and the listener has no
    /// equivalent — but menu and keyboard paths still need the operation.
    func returnToLibrary() {
        selectedNavigation = .library
    }

    func rewind() { seek(by: -15) }
    func forward() { seek(by: 30) }

    func previousPlayback() { navigatePodcastQueue(previous: true) }
    func nextPlayback() { navigatePodcastQueue(previous: false) }

    /// Starts a new playback session and publishes its durable checkpoint.
    func restartPlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.restart()
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.playbackError = "Playback restart is unavailable." }
        }
#endif
    }

    /// Records a playback fault that a route recovery can plausibly clear, so
    /// the recovery control appears only when it has something to act on.
    func reportAudioRouteFault(_ message: String) {
        playbackError = message
        audioRouteFault = true
    }

    func recoverAudioRoute() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.recoverFromRouteChange()
                self.audioRouteFault = false
                self.playbackError = nil
                self.refreshPlaybackReadout()
            } catch {
                self.playbackError = "Audio route recovery failed."
            }
        }
#else
        audioRouteFault = false
        playbackError = nil
#endif
    }

    func checkpointForQuit() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await playback.handlePauseOrQuit()
            await self.queueCurrentPlaybackCheckpoint()
        }
#endif
    }

    /// Deterministic model-test seam for the same checkpoint path used by
    /// transport actions. It never contacts a live service.
    func checkpointCurrentPlaybackForTesting() async {
#if canImport(WiltedProducer)
        try? await playback?.checkpoint()
        await queueCurrentPlaybackCheckpoint()
#endif
    }

    func completePodcastPlaybackForTesting(successfully: Bool = true) {
#if canImport(WiltedProducer)
        (playback?.backend as? WiltedFixturePlaybackBackend)?.finish(successfully: successfully)
#endif
    }

    func waitForPlaybackOperationForTesting() async {
#if canImport(WiltedProducer)
        await playbackOperationTask?.value
#endif
    }

    func installEpisodeForTesting(_ episode: WiltedMacEpisode) {
        guard !episodes.contains(where: { $0.id == episode.id }) else { return }
        episodes.append(episode)
    }

    func beginArticlePlaybackTransitionForTesting(_ article: WiltedMacArticle) {
        beginArticlePlaybackTransition(article)
    }

#if canImport(WiltedProducer)
    func applyPodcastPlaybackObservationForTesting(itemID: ItemID?, fault: PlaybackControllerError?) {
        applyPodcastPlaybackObservation(itemID: itemID, fault: fault)
    }
#endif

#if canImport(WiltedProducer)
    private func update(_ status: PreparationStatus) {
        let phase: WiltedMacPreparation.Phase
        switch status.stage {
        case .preparing: phase = .preparing
        case .fetching: phase = .preparing
        case .extracting: phase = .extracting
        case .synthesizing: phase = .synthesizing
        case .assembling: phase = .assembling
        case .saving: phase = .saving
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        preparation = WiltedMacPreparation(
            phase: phase, detail: status.detail, fraction: status.fraction, cancellable: status.cancellable
        )
    }

    @discardableResult
    private func queuePreparedPublication(itemID: ItemID, chunkedFile: AudioChunkedFile? = nil) async -> Bool {
        guard let store, let syncLifecycle,
              let article = try? await store.article(for: itemID),
              let stored = try? await store.readyRevision(for: itemID),
              let bytes = try? Data(contentsOf: stored.mediaURL),
              let chunkedFile = chunkedFile ?? (try? AudioChunking.chunk(bytes)) else { return false }
        let revisionResult = await syncLifecycle.queueRevision(stored.revision, chunkedFile: chunkedFile)
        let itemResult = await syncLifecycle.queueItem(article, currentRevisionID: stored.revision.revisionID)
        guard case .success = itemResult, case .success = revisionResult else { return false }
        articlePublicationCount += 1
        return true
    }

    /// Re-queues ready revisions that are durable locally but absent from the outbound queue.
    ///
    /// Publication is otherwise queued only at the instant a preparation completes, so any
    /// enqueue that failed then stays unqueued forever: the revision cannot be re-derived by
    /// re-preparing it either, because the same text and settings derive the same immutable
    /// revision ID and `saveReadyRevision` rejects a second media path for it. Reconciling
    /// from durable local state before an upload is what makes the queue recoverable, and it
    /// matches W-INV-007's rule that local state, not CloudKit, is the source of truth.
    ///
    /// Membership is checked rather than sync status so a partially queued item repairs
    /// itself, and a revision whose media file is gone is skipped instead of failing the
    /// whole upload.
    private func queueUnpublishedReadyRevisions() async -> Bool {
        guard let store, syncLifecycle != nil else { return false }
        guard let articles = try? await store.articles() else { return false }
        let state = try? await store.syncRepositoryState()
        let queued = Set((state?.pendingChanges.map(\.recordID) ?? []) + Array(state?.remoteAcknowledgedRecordIDs ?? []))
        var didQueue = false
        for article in articles where !article.isDeleted {
            guard let stored = try? await store.readyRevision(for: article.itemID),
                  FileManager.default.fileExists(atPath: stored.mediaURL.path),
                  let bytes = try? Data(contentsOf: stored.mediaURL),
                  let chunkedFile = try? AudioChunking.chunk(bytes),
                  let revisionRecordID = try? WiltedRecordID.revision(article.itemID, stored.revision.revisionID) else { continue }
            let chunkRecordIDs = chunkedFile.manifest.chunks.compactMap {
                try? WiltedRecordID.revisionChunk(article.itemID, stored.revision.revisionID, index: $0.index)
            }
            let expected = Set([revisionRecordID] + chunkRecordIDs)
            guard !expected.isSubset(of: queued) else { continue }
            didQueue = await queuePreparedPublication(itemID: article.itemID, chunkedFile: chunkedFile) || didQueue
        }
        let hasSendablePending = (try? await store.syncRepositoryState())?.sendableChanges.isEmpty == false
        return didQueue || hasSendablePending
    }

    private func queueCurrentPlaybackCheckpoint() async {
        guard let store, let syncLifecycle, let playbackItemID = playback?.itemID,
              selectedArticleID == playbackItemID.rawValue,
              articles.contains(where: { $0.id == playbackItemID.rawValue }),
              let playbackRevisionID = playback?.revisionID,
              let state = try? await store.playbackState(for: playbackItemID, revisionID: playbackRevisionID) else { return }
        let sidecar = try? await store.playbackSidecar(for: playbackItemID, revisionID: playbackRevisionID)
        let opaque = sidecar.map {
            WiltedOpaqueSidecar(changeTag: $0.changeTag, encodedSystemFields: $0.encodedSystemFields)
        }
        if case .success = await syncLifecycle.queuePlayback(state, sidecar: opaque) {
            articlePlaybackCheckpointCount += 1
        }
    }

    /// Removes an article from the library.
    ///
    /// Marks the stored article deleted and records a local tombstone, which
    /// is what `refresh()` and the sync repository both already read. The
    /// library had no removal path at all, so anything prepared once —
    /// including a stray fixture row written before fixture mode moved to a
    /// temporary directory — stayed on screen permanently.
    ///
    /// Local only. Publishing the tombstone to CloudKit rides the existing
    /// pending-change path and is not triggered from here.
    func removeArticle(_ article: WiltedMacArticle) {
#if canImport(WiltedProducer)
        guard let store else { return }
        if selectedArticleID == article.id {
            selectedArticleID = nil
            isNowPlaying = false
            currentTranscript = nil
        }
        Task { [weak self] in
            guard let self else { return }
            guard let itemID = try? ItemID(rawValue: article.id) else { return }
            guard let stored = try? await store.articles().first(where: { $0.itemID == itemID }) else { return }
            guard let deleted = try? Article(
                itemID: stored.itemID, canonicalURL: stored.canonicalURL, title: stored.title,
                source: stored.source, author: stored.author, publishedTime: stored.publishedTime,
                createdAt: stored.createdAt, isDeleted: true
            ) else { return }
            try? await store.save(article: deleted)
            // Keyed by item, deliberately. `record(tombstone:)` upserts on `id`,
            // and this is the only path in the producer that writes one, so
            // removing the same article twice leaves one row rather than two.
            let tombstone = LocalLibraryTombstone(
                id: itemID.rawValue,
                itemID: itemID,
                requestedAt: Timestamp(Date())
            )
            try? await store.record(tombstone: tombstone)
            self.refresh()
        }
#endif
    }

    /// Fetches and stores the transcript for an already-prepared article.
    ///
    /// Transcript persistence shipped on 2026-08-23; anything prepared before
    /// that has audio and no text, and re-preparing cannot fix it because the
    /// revision ID is derived from the same content and `saveReadyRevision`
    /// refuses to re-point an existing revision. The text is re-extracted from
    /// the canonical URL and saved against the existing revision, so no new
    /// revision, media file, or synthesis run is created.
    func backfillCurrentTranscript() {
#if canImport(WiltedProducer)
        guard !isBackfillingTranscript, let store, let article = currentArticle else { return }
        isBackfillingTranscript = true
        transcriptBackfillStatus = "Fetching article text…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBackfillingTranscript = false }
            guard let itemID = try? ItemID(rawValue: article.id),
                  let revision = try? await store.readyRevision(for: itemID) else {
                self.transcriptBackfillStatus = "This article has no saved audio to attach text to."
                return
            }
            do {
                let extracted = try await NativeArticleExtractor().extract(article.url) { stage, _ in
                    Task { @MainActor [weak self] in
                        self?.transcriptBackfillStatus = "Fetching article text: \(stage.rawValue)"
                    }
                }
                let oversized = extracted.body.utf8.count > Transcript.maximumTextUTF8Bytes
                let transcript = try Transcript(
                    itemID: itemID,
                    revisionID: revision.revision.revisionID,
                    availability: oversized ? .oversized : .available,
                    text: oversized ? nil : extracted.body,
                    updatedAt: Timestamp(Date())
                )
                try await store.save(transcript: transcript)
                await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                self.transcriptBackfillStatus = oversized
                    ? "The article text is too large to store."
                    : nil
            } catch {
                // Named, not swallowed: the reader has to know whether to retry.
                self.transcriptBackfillStatus = Self.backfillFailureMessage(error)
            }
        }
#endif
    }

    /// A sentence a reader can act on, never a raw error dump.
    ///
    /// `ArticleExtractionError` already writes for people, so it passes through.
    /// Transport failures are matched by code rather than rendered: a `URLError`
    /// only has readable `localizedDescription` when URLSession populated it, and
    /// otherwise falls back to `The operation couldn't be completed.
    /// (NSURLErrorDomain error -1009.)`. Everything unmatched collapses to one
    /// generic line, because printing a domain and code into the player is the
    /// same defect as printing `1743` for a duration.
    static func backfillFailureMessage(_ error: Error) -> String {
#if canImport(WiltedProducer)
        if let extraction = error as? ArticleExtractionError, let text = extraction.errorDescription {
            return text
        }
#endif
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Wilted could not reach the article. Check your connection and try again."
            case .timedOut:
                return "The article server did not respond in time. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Wilted could not reach that site."
            default:
                break
            }
        }
        return "Could not fetch the article text. Check the link and try again."
    }

    /// Reloads the preparation run history behind the Processor destination.
    func refreshProcessorRuns() {
#if canImport(WiltedProducer)
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let runs = try? await store.preparationRuns() else { return }
            // Episodes prepare through the same journal as articles, so the
            // history has to be able to name both kinds of item.
            var titles = Dictionary(
                uniqueKeysWithValues: ((try? await store.articles()) ?? [])
                    .map { ($0.itemID.rawValue, ($0.title, $0.source)) }
            )
            let feedTitles = Dictionary(
                uniqueKeysWithValues: ((try? await store.podcastFeeds()) ?? []).map { ($0.itemID, $0.title) }
            )
            for episode in (try? await store.podcastEpisodes()) ?? [] {
                titles[episode.itemID.rawValue] = (episode.title, feedTitles[episode.feedID] ?? "Podcast")
            }
            self.processorRuns = runs.map { run in
                let known = titles[run.itemID.rawValue]
                let outcome: WiltedMacProcessorRun.Outcome = if !run.isTerminal {
                    .running
                } else {
                    switch run.outcome {
                    case .succeeded: .succeeded
                    case .cancelled: .cancelled
                    default: .failed
                    }
                }
                return WiltedMacProcessorRun(
                    id: run.requestID,
                    // A run that failed before extraction never learned a
                    // title, so the item identity is all there is to name it.
                    title: known?.0 ?? "Unknown item",
                    source: known?.1 ?? run.itemID.rawValue,
                    stage: run.stage.rawValue,
                    detail: run.failure?.message ?? run.detail,
                    fraction: run.fraction,
                    outcome: outcome,
                    updatedAt: run.updatedAt.date
                )
            }
        }
#endif
    }

#if canImport(WiltedProducer)
    private func performStoreBootstrap() async {
        do {
            let configuredStore = try await storeBootstrap(libraryURL)
            configureStoreDependencies(configuredStore)
            // The account-review gate is durable state, so restore it before
            // the ready surface can expose sync controls.
            syncLifecycle?.restoreAccountQuarantine()
            let library = try await loadLibrary(from: configuredStore)
            articles = library.articles
            episodes = library.episodes
            subscriptions = library.subscriptions
            await restorePodcastPlayback()
            startupState = .ready
            if pendingSyncReconciliation {
                pendingSyncReconciliation = false
                reconcileSyncOnLaunchOrForeground()
            }
        } catch {
            configureStoreDependencies(nil)
            let retainedURL = await Task.detached { [libraryURL] in
                Self.retainedV5StoreURL(for: libraryURL)
            }.value
            startupState = .failed(WiltedMacStartupFailure(
                message: "Wilted could not open your larder. The existing library was left in place.",
                retainedV5StoreURL: retainedURL,
                canRetry: startupAttemptCount < Self.maximumStartupAttempts
            ))
        }
        startupTask = nil
    }

    private func configureStoreDependencies(_ configuredStore: LocalLibraryStore?) {
        store = configuredStore
        coordinator = configuredStore.map {
            PreparationCoordinator(store: $0, mediaDirectory: mediaDirectory)
        }
        playback = configuredStore.map {
            PlaybackController(
                store: $0,
                backend: fixtureMode ? WiltedFixturePlaybackBackend() : AVAudioPlayerBackend(),
                deviceID: "mac"
            )
        }
        playback?.podcastStateHandler = { [weak self] itemID, fault in
            self?.applyPodcastPlaybackObservation(itemID: itemID, fault: fault)
        }
        podcastDownloadCoordinator = configuredStore.map {
            PodcastDownloadCoordinator(store: $0, libraryDirectory: mediaDirectory)
        }
        podcastPreparationPipeline = fixtureMode ? nil : configuredStore.map {
            PodcastPreparationPipeline(
                store: $0,
                workDirectory: mediaDirectory.appendingPathComponent("preparation", isDirectory: true),
                removeAds: removesAdvertisements
            )
        }
        var selectedSyncFactory = syncTransportFactory
#if WILTED_CLOUDKIT_LIVE
        if !fixtureMode, selectedSyncFactory == nil, let configuredStore {
            let liveConfiguration = WiltedMacLiveSyncConfiguration(
                database: CKContainer(identifier: "iCloud.com.zerodelta.wilted").privateCloudDatabase,
                assetRootURL: mediaDirectory,
                store: configuredStore,
                assetResolver: assetResolver
            )
            selectedSyncFactory = makeWiltedMacLiveSyncTransportFactory(configuration: liveConfiguration)
        }
#endif
        syncLifecycle = configuredStore.map {
            WiltedMacSyncLifecycle(
                store: $0,
                transportFactory: fixtureMode ? nil : selectedSyncFactory,
                assetResolver: assetResolver
            )
        }
    }

    private func restorePodcastPlayback() async {
        guard let playback else { return }
        playbackOperationStatus = "Restoring Up Next…"
        await playback.restorePodcastQueue()
        await refreshPodcastQueueState()
        if let itemID = playback.itemID,
           episodes.contains(where: { $0.id == itemID.rawValue }) {
            currentPodcastEpisodeID = itemID.rawValue
            selectedArticleID = nil
            isPodcastPlayback = true
            isNowPlaying = true
            refreshPlaybackReadout()
            await loadEpisodeTranscript(itemID: itemID)
        }
        playbackOperationStatus = nil
    }

    private func refreshPodcastQueueState() async {
        guard let store, let state = try? await store.podcastQueueState() else { return }
        podcastQueueIDs = state.episodeIDs.map(\.rawValue)
        if isPodcastPlayback {
            let loadedEpisodeID = playback?.itemID?.rawValue
            let activeEpisodeID = loadedEpisodeID.flatMap { id in
                episodes.contains(where: { $0.id == id }) ? id : nil
            }
            currentPodcastEpisodeID = state.currentEpisodeID?.rawValue ?? activeEpisodeID
        }
    }

    private func applyPodcastPlaybackObservation(itemID: ItemID?, fault: PlaybackControllerError?) {
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
        playbackOperationStatus = nil
        refreshPlaybackReadout()
        // Continuous playback advances the queue without going through
        // `playEpisode`, so the previous episode's transcript would otherwise
        // stay on screen against the new audio.
        if movedToAnotherEpisode, let itemID {
            currentTranscript = .unavailable
            Task { [weak self] in await self?.loadEpisodeTranscript(itemID: itemID) }
        }
    }

    private func loadLibrary(from store: LocalLibraryStore) async throws
        -> (articles: [WiltedMacArticle], episodes: [WiltedMacEpisode], subscriptions: [WiltedMacSubscription]) {
        var articleValues: [WiltedMacArticle] = []
        for article in try await store.articles() where !article.isDeleted {
            let revision = try await store.readyRevision(for: article.itemID)
            articleValues.append(WiltedMacArticle(
                id: article.itemID.rawValue, title: article.title, source: article.source,
                url: article.canonicalURL, isReady: revision != nil,
                durationSeconds: revision?.revision.durationSeconds, createdAt: article.createdAt.date
            ))
        }
        let feeds = Dictionary(uniqueKeysWithValues: try await store.podcastFeeds().map { ($0.itemID, $0) })
        let allSubscriptions = try await store.subscriptions()
        let subscribed = Set(allSubscriptions.filter(\.enabled).map(\.feedID))
        var episodeCounts: [ItemID: Int] = [:]
        for episode in try await store.podcastEpisodes() { episodeCounts[episode.feedID, default: 0] += 1 }
        let subscriptionValues = allSubscriptions.compactMap { subscription -> WiltedMacSubscription? in
            guard let feed = feeds[subscription.feedID] else { return nil }
            return WiltedMacSubscription(
                id: subscription.feedID.rawValue, title: feed.title, feedURL: feed.canonicalURL,
                episodeCount: episodeCounts[subscription.feedID] ?? 0,
                subscribedAt: subscription.subscribedAt.date, enabled: subscription.enabled
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let downloads = Dictionary(uniqueKeysWithValues: try await store.downloads().map { ($0.episodeID, $0) })
        var episodeValues: [WiltedMacEpisode] = []
        let runs = Dictionary(
            uniqueKeysWithValues: ((try? await store.preparationRuns()) ?? [])
                .filter { $0.requestID.hasPrefix("podcast-prepare|") }
                .map { ($0.itemID, $0) }
        )
        for episode in try await store.podcastEpisodes() where subscribed.contains(episode.feedID) {
            let revision = try await store.readyRevision(for: episode.itemID)
            let playbackState: PlaybackState?
            if let revision {
                playbackState = try await store.playbackState(
                    for: episode.itemID, revisionID: revision.revision.revisionID
                )
            } else {
                playbackState = nil
            }
            let transcript: Transcript?
            if let revision {
                transcript = try? await store.transcript(for: episode.itemID,
                                                         revisionID: revision.revision.revisionID)
            } else {
                transcript = nil
            }
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
            let summary = String((episode.author ?? feedTitle).prefix(180))
            episodeValues.append(WiltedMacEpisode(
                id: episode.itemID.rawValue, title: episode.title, feedTitle: feedTitle,
                summary: summary, artworkURL: episode.artworkURL ?? feeds[episode.feedID]?.artworkURL,
                releasedAt: (episode.publishedTime ?? episode.createdAt).date,
                durationSeconds: revision?.revision.durationSeconds ?? episode.durationSeconds,
                playbackSeconds: playbackState?.positionSeconds ?? 0, downloadState: downloadState,
                preparationState: Self.preparationState(run: runs[episode.itemID], transcript: transcript)
            ))
        }
        return (articleValues, episodeValues, subscriptionValues)
    }

    /// What the library already knows about an episode's preparation.
    ///
    /// The stored transcript is the evidence that survives a relaunch: it says
    /// whether the words are synchronised with the audio. The journal supplies
    /// the rest -- a failure worth showing, or a run this process did not start.
    nonisolated static func preparationState(
        run: PreparationRunSummary?, transcript: Transcript?
    ) -> WiltedMacEpisodePreparationState {
        if let run, !run.isTerminal { return .preparing(stage: "Preparing…") }
        switch transcript?.timing {
        case .published: return .prepared(summary: "Synced transcript from the feed")
        case .aligned: return .prepared(summary: "Synced transcript")
        case .none, .some(.none):
            if let run, run.isTerminal, run.outcome == .failed {
                return .failed(run.detail)
            }
            if transcript?.availability == .available { return .prepared(summary: "Transcript, not synced") }
            return .notPrepared
        }
    }

    private nonisolated static func startupFailure(libraryURL: URL, canRetry: Bool) -> WiltedMacStartupFailure {
        WiltedMacStartupFailure(
            message: "Wilted could not open your larder. The existing library was left in place.",
            retainedV5StoreURL: retainedV5StoreURL(for: libraryURL),
            canRetry: canRetry
        )
    }

    private nonisolated static func retainedV5StoreURL(for libraryURL: URL) -> URL? {
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
            .first?.0
    }
#endif

    private func refresh() {
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let values = try? await self.loadLibrary(from: store) else { return }
            self.articles = values.articles
            self.episodes = values.episodes
            self.subscriptions = values.subscriptions
        }
    }

    private func installFixture(ready: Bool, preparing: Bool = false, podcasts: Bool = false) {
        if preparing {
            let url = URL(string: "https://example.test/wilted-preparing-fixture")!
            guard let itemID = try? ItemID.derive(from: url) else { return }
            articles = [WiltedMacArticle(
                id: itemID.rawValue, title: "Preparing article", source: "Example source",
                url: url, isReady: false, durationSeconds: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
            return
        }
        guard ready, let store else { return }
        let url = URL(string: "https://example.test/wilted-fixture")!
        guard let itemID = try? ItemID.derive(from: url),
              let article = try? Article(
                itemID: itemID, canonicalURL: url, title: "Fixture article", source: "Example source",
                createdAt: Timestamp(Date())
              ),
              let revisionID = try? RevisionID(rawValue: "fixture-revision"),
              let revision = try? AudioRevision(
                itemID: itemID, revisionID: revisionID, durationSeconds: 120, byteCount: 1,
                contentHash: "sha256:\(String(repeating: "0", count: 64))", mediaType: "audio/mp4",
                createdAt: Timestamp(Date()), schemaVersion: 1
              ) else { return }
        let mediaURL = URL(fileURLWithPath: "/tmp/wilted-fixture.m4a")
        fixtureRevision = StoredAudioRevision(revision: revision, mediaURL: mediaURL)
        let fixtureTranscript = try? Transcript(
            itemID: itemID,
            revisionID: revisionID,
            availability: .available,
            text: "This fixture transcript proves saved article text stays readable while listening.",
            updatedAt: Timestamp(Date())
        )
        articles = [WiltedMacArticle(
            id: itemID.rawValue, title: article.title, source: article.source,
            url: article.canonicalURL, isReady: true, durationSeconds: revision.durationSeconds,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        if podcasts { installPodcastFixture(in: store) }
        Task {
            try? await store.save(article: article)
            if let fixtureTranscript {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: fixtureTranscript)
            } else {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL)
            }
        }
    }

    private func installPodcastFixture(in store: LocalLibraryStore) {
        let feedURL = URL(string: "https://fixtures.example.test/field-notes.xml")!
        let enclosureURL = URL(string: "https://fixtures.example.test/media/quiet-machines.mp3")!
        guard let feedID = try? ItemID.derivePodcastFeed(from: feedURL),
              let episodeID = try? ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "fixture-episode-001", enclosureURL: enclosureURL
              ),
              let feed = try? PodcastFeed(
                itemID: feedID, canonicalURL: feedURL, title: "Field Notes",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
              ),
              let episode = try? PodcastEpisode(
                itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "fixture-episode-001",
                title: "Quiet Machines", author: "Field Notes desk",
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_699_827_200)),
                enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", durationSeconds: 1_482,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
              ) else { return }
        episodes = [WiltedMacEpisode(
            id: episodeID.rawValue, title: episode.title, feedTitle: feed.title,
            summary: "Field Notes desk", artworkURL: nil, releasedAt: episode.createdAt.date,
            durationSeconds: episode.durationSeconds, playbackSeconds: 0,
            downloadState: fixtureDownloadFailuresRemaining > 0 ? .notDownloaded : .completed
        )]
        // The Feeds card reads `subscriptions`, which only the store-backed load
        // path populates. Fixture mode assigns the library directly, so it has
        // to supply the same rows -- including a feed the listener has hidden,
        // so the card's hidden-from-Larder state is covered by evidence rather
        // than assumed. The hidden feed is written to the store too, so a
        // reload during a test agrees with what was drawn.
        let hiddenFeedURL = URL(string: "https://fixtures.example.test/quiet-season.xml")!
        let hiddenFeed = try? PodcastFeed(
            itemID: ItemID.derivePodcastFeed(from: hiddenFeedURL), canonicalURL: hiddenFeedURL,
            title: "Quiet Season", createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_740_800))
        )
        subscriptions = [
            WiltedMacSubscription(
                id: feedID.rawValue, title: feed.title, feedURL: feedURL, episodeCount: 1,
                subscribedAt: Date(timeIntervalSince1970: 1_699_827_200), enabled: true
            ),
        ] + (hiddenFeed.map { hidden in
            [WiltedMacSubscription(
                id: hidden.itemID.rawValue, title: hidden.title, feedURL: hiddenFeedURL, episodeCount: 0,
                subscribedAt: Date(timeIntervalSince1970: 1_699_740_800), enabled: false
            )]
        } ?? [])
        let mediaURL = mediaDirectory.appendingPathComponent("fixture-podcast.mp3")
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: mediaURL.path, contents: Data([0]))
        let revision = try? AudioRevision(
            itemID: episodeID, revisionID: RevisionID(rawValue: "fixture-podcast-revision"),
            durationSeconds: 1_482, byteCount: 1,
            contentHash: "sha256:" + String(repeating: "9", count: 64), mediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200)), schemaVersion: 1
        )
        fixturePodcastInstallTask = Task {
            try? await store.save(feed: feed)
            try? await store.save(episode: episode)
            try? await store.save(subscription: PodcastSubscription(
                feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
            ))
            if let hiddenFeed {
                try? await store.save(feed: hiddenFeed)
                try? await store.save(subscription: PodcastSubscription(
                    feedID: hiddenFeed.itemID,
                    subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_699_740_800)), enabled: false
                ))
            }
            if let revision { try? await store.saveReadyRevision(revision, mediaURL: mediaURL) }
        }
    }

    /// Jumps playback to a transcript line the listener picked.
    func seekToTranscriptCue(_ cue: WiltedMacTranscriptCue) {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(to: cue.startSeconds)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#endif
    }

    /// The transcript line the audio is currently in, if the transcript is
    /// synchronised with it.
    var activeTranscriptCueID: Int? {
        currentTranscript?.cueIndex(at: playbackPositionSeconds)
    }

    private func seek(by seconds: TimeInterval) {
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(by: seconds)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
    }

    private func navigatePodcastQueue(previous: Bool) {
#if canImport(WiltedProducer)
        guard let playback, isPodcastPlayback else { return }
        playbackOperationStatus = previous ? "Opening previous episode…" : "Opening next episode…"
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selected = try await (previous
                    ? playback.selectPreviousPodcastQueueEpisode()
                    : playback.selectNextPodcastQueueEpisode())
                if selected {
                    await self.refreshPodcastQueueState()
                    self.refreshPlaybackReadout()
                    self.playbackError = nil
                }
                self.playbackOperationStatus = nil
            } catch {
                self.playbackOperationStatus = nil
                self.playbackError = previous
                    ? "The previous episode is unavailable."
                    : "The next episode is unavailable."
            }
        }
#endif
    }

    private static func stateDirectory(fixtureMode: Bool) -> URL {
        if fixtureMode {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "wilted-ui-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
                )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Wilted", isDirectory: true)
    }
#endif
}

#if canImport(WiltedProducer)
@MainActor
private final class WiltedFixturePlaybackBackend: PlaybackBackend {
    var duration: TimeInterval = 120
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var rate: Float = 1
    var volume: Float = 1
    private(set) var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    func load(url: URL) throws {
        loadedGeneration += 1
        isPlaying = false
        duration = url.lastPathComponent.contains("podcast") ? 1_482 : 120
    }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func finish(successfully: Bool) {
        isPlaying = false
        completionHandler?(loadedGeneration, successfully)
    }
}
#endif
