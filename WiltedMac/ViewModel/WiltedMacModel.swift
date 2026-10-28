import Foundation
import Observation
import AppKit
import os
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

/// Main-actor presentation state for the local Mac producer.
@Observable
@MainActor
final class WiltedMacModel {
    static let maximumStartupAttempts = 2

    var startupState: WiltedMacStartupState = .loading(attempt: 0, step: .openingStore)
    /// Feeds selection and disclosure, scroll anchors, Larder filter and search, and the composer
    /// drafts, as one value persisted through `preferences` (see `+NavigationState`).
    var navigationState = WiltedMacNavigationState() {
        didSet { persistNavigationState() }
    }
    var urlDraft: String {
        get { navigationState.urlDraft }
        set { navigationState.urlDraft = newValue }
    }
    var podcastFeedDraft: String {
        get { navigationState.podcastFeedDraft }
        set { navigationState.podcastFeedDraft = newValue }
    }
    /// What the single add box is doing right now. Telling a feed from an
    /// article needs the document, so the button can sit on a network round
    /// trip; an unannounced pause there reads as a control that did nothing.
    var linkDraftStatus: String?
    /// A feed the page just added advertises. Offered, never taken: following a
    /// site's whole feed is a different request from saving one article of it.
    var advertisedFeed: URL?
    var podcastFeedDraftStatus: String?
    var isCheckingPodcastSubscription = false
    /// The current subscription request owns composer feedback until it
    /// finishes or is cancelled; an older task may never overwrite it.
    var podcastSubscriptionRequestID: UUID?
    /// Request-local first-load cap captured before a pasted page is classified.
    /// It never changes the saved automation default.
    var pendingPodcastSubscriptionInitialMetadataCount: Int?
    /// Identifies the in-flight subscription check, so a cancelled one cannot
    /// write over its successor's state when it finally resumes.
    var podcastSubscriptionCheckGeneration = 0
    static let podcastCheckInProgressStatus = "Checking that address\u{2026}"
    static let podcastCheckCancelledStatus = "Podcast check cancelled."
    /// The feed a duplicate subscription attempt pointed back at.
    var selectedPodcastFeedID: String?
    var lastPodcastRefreshNewEpisodeIDs: [String] = []
    /// Episodes the last refresh loaded but did not keep, either because the
    /// feed exceeded the client's episode ceiling or because they published
    /// before the subscription. Reported so a partial view of a feed is never
    /// presented as the whole feed.
    var withheldPodcastEpisodeCount = 0
    /// Feeds ordering. It changes only the inbox scan, never the listening
    /// order the Larder holds.
    var feedsSort: WiltedMacFeedsSort = .newest {
        didSet { preferences.set(feedsSort.rawValue, forKey: Self.feedsSortPreferenceKey) }
    }
    /// The Larder's sort. `custom` is the durable listening order; the rest
    /// reorder every row except the one playing, which holds its place.
    var larderSort: WiltedMacLarderSort = .custom {
        didSet {
            preferences.set(larderSort.canonical.rawValue, forKey: Self.larderSortPreferenceKey)
            if let direction = larderSort.legacyDirection { larderSortDirection = direction }
            guard oldValue != larderSort else { return }
            applyLarderSortIfNeeded()
        }
    }
    var larderSortDirection: WiltedMacLarderSortDirection = .ascending {
        didSet {
            preferences.set(larderSortDirection.rawValue, forKey: Self.larderSortDirectionPreferenceKey)
            guard oldValue != larderSortDirection else { return }
            applyLarderSortIfNeeded()
        }
    }
    /// Section presentation is independent from the queue's selected sort.
    /// Status preserves the Larder's established default for existing users.
    var larderGrouping: WiltedMacLarderGrouping = .status {
        didSet { preferences.set(larderGrouping.rawValue, forKey: Self.larderGroupingPreferenceKey) }
    }
    /// Which kinds the Larder list shows. Presentation only, remembered like sort and grouping; a
    /// stored value this build does not know restores All.
    var larderKind: WiltedMacLarderKind = .all {
        didSet { preferences.set(larderKind.rawValue, forKey: Self.larderKindPreferenceKey) }
    }
    /// The highest preparation request sequence issued so far. Persisted on
    /// every issue as a fallback (see `preparationRequestSequencePreferenceKey`
    /// below), but reseeded from the ticket table's own high-water mark at
    /// every successful `reconcileWorkTickets(in:)`, which is the writer of
    /// record once a store exists.
    var preparationRequestSequence: Int = 0
    /// Requests that have been made but whose preparation run has not started
    /// yet, keyed by episode (or article) id. This is the in-memory PROJECTION
    /// of the click order: a download or article request registers on request
    /// and the run consumes its number when it is admitted. The durable copy
    /// is a `WorkTicket` row (`.pending`/`.deferred`) written through
    /// `recordWorkTicketTransition`; this dictionary is rebuilt from that
    /// table at every successful bootstrap reconcile (see
    /// `reconcileWorkTickets(in:)`), so a request pending at relaunch keeps
    /// its number and its place. Only a store-less run (no ticket table to
    /// rebuild from) loses an in-flight request across a relaunch.
    var preparationRequestSequences: [String: Int] = [:]
    let preferences: UserDefaults
    /// The defaults suite a fixture launch owns; removed when the fixture closes.
    let fixturePreferencesSuite: String?
    /// Whether a quiet marker identifies each advertisement seam during playback.
    var marksRemovedAds = true {
        didSet {
            preferences.set(marksRemovedAds, forKey: Self.marksRemovedAdsPreferenceKey)
            rescheduleSeamMarker()
        }
    }
    /// Automation reads this one validated value, never individual preference keys.
    var automationSettings = WiltedAutomationSettings.defaults { didSet { bulletinLifecycleChanged() } }
    /// Kept observable for Feeds: a successful refresh must redraw its actual
    /// completion time instead of waiting for another unrelated model change.
    var observedLastAutomationRefreshAt: Date?
    /// How much bigger than the system's own text the window draws itself.
    ///
    /// The Mac has no Dynamic Type to inherit, so the app carries this and the
    /// root hands it to every surface through the environment. `.large` is the
    /// default because 13pt is the system's body size and this is a window
    /// read across a room as often as at a desk.
    var textScale: WiltedTheme.TextScale = .large
    /// What automation is doing, so Settings can show it and a listener can stop it.
    var automationStatus: WiltedAutomationStatus = .idle
    /// Whether the address box is open. It is a sheet-like popover now
    /// rather than a card that always held the top of the Larder: the control
    /// is used once a session and was charging the library a card of room for
    /// it every time the reader looked at the list.
    var isPresentingComposer = false
    var playlists = WiltedMacPlaylistsState()
    var selectedNavigation: WiltedMacNavigation = .larder {
        didSet {
            preferences.set(selectedNavigation.rawValue, forKey: Self.selectedNavigationPreferenceKey)
        }
    }
    /// The reader's explicit choice to show or hide the navigation sidebar.
    /// Shown by default; `WiltedMacShellLayout` still turns a shown sidebar
    /// into a rail when the window is narrow.
    var isSidebarVisible = true {
        didSet { preferences.set(isSidebarVisible, forKey: Self.sidebarVisiblePreferenceKey) }
    }
    /// The reader's choice to number the Larder and Feeds rows: ready
    /// episodes beside Larder, episodes still to decide beside Feeds. Off by
    /// default; the sidebar's totals already carry the waiting times.
    var showsSidebarCounts = false {
        didSet { preferences.set(showsSidebarCounts, forKey: Self.sidebarCountsPreferenceKey) }
    }
    var articles: [WiltedMacArticle] = []
    var episodes: [WiltedMacEpisode] = []
    /// Episodes the current engine has not prepared, by id, read from the store
    /// with each library load. The only episodes the Larder offers to prepare
    /// again; each says what the run needs (see `PodcastPrepareAgainCandidate`).
    var prepareAgainCandidates: [String: PodcastPrepareAgainCandidate] = [:]
    /// What a prepare-again run is saying on its Larder row, by episode id.
    var prepareAgainRows: [String: WiltedMacPrepareAgainRow] = [:]
    /// The confirmation before re-preparing every episode that kept its ads.
    var isConfirmingPrepareAgainAll = false
    var episodeAssociations: [String: LibraryEpisodeAssociation] = [:]
    var podcastOperationMessage: String?
    /// The episode an Undo button beside `podcastOperationMessage` would
    /// restore. Set only by `removeEpisode`'s success path, and cleared at the
    /// start of every operation that replaces the message it belongs to, so
    /// Undo never survives to attach itself to an unrelated sentence.
    var undoableRemoval: WiltedMacDismissedEpisode?
    /// The last episode skipped through the reversible path, while its undo is
    /// still offered. Unlike `undoableRemoval` this is a plain in-memory
    /// episode: nothing was dismissed, so the undo needs no feed check.
    var undoableSkip: WiltedMacEpisode?
    var isRefreshingPodcasts = false
    /// An automatic pass is in its feed loop; Feeds shows it like a manual refresh.
    var automaticFeedRefreshInFlight = false
    /// Per-feed progress of the refresh in flight, keyed by feed ID; a feed that is not here is idle.
    var feedRefreshStates: [String: WiltedMacFeedRefreshState] = [:]
    /// The durable write each feed's row is waiting on, set before the write is awaited.
    var pendingFeedWrites: [String: WiltedMacFeedWrite] = [:]
    /// The newest enable value asked for while a write was in flight; written once when it finishes.
    var queuedFeedEnabled: [String: Bool] = [:]
    /// One feed's optimistic Show episodes projection while its durable write
    /// runs. `committed` is the last value the store confirmed; `projected` is
    /// what the row and the Larder show right now. `withheldEpisodes` keeps the
    /// rows a projected hide took off the Larder, so a failed write can put
    /// them back without a store round trip.
    struct WiltedMacFeedEnabledProjection {
        var committed: Bool
        var projected: Bool
        var withheldEpisodes: [WiltedMacEpisode] = []
    }
    /// One Larder completion whose durable write is in flight. `original` is
    /// the row this operation replaced, so a failure restores only the fields
    /// the projection changed; `projectedRetiredAt` is the time the Larder
    /// projects until the store confirms it.
    struct WiltedMacEpisodeCompletionProjection {
        let original: WiltedMacEpisode
        let projectedRetiredAt: Date
    }
    /// Optimistic Show episodes projections, keyed by feed ID. See `setSubscription`.
    var feedEnabledProjections: [String: WiltedMacFeedEnabledProjection] = [:]
    /// Optimistic Larder completions, keyed by episode ID. See `skipEpisode`.
    var episodeCompletionProjections: [String: WiltedMacEpisodeCompletionProjection] = [:]
    var preparation: WiltedMacPreparation?
    /// The article the current preparation row can retry. The Add sheet
    /// clears `urlDraft` as soon as a run starts, so the canonical address
    /// lives here until the row is dismissed or another article replaces it.
    var articlePreparationURL: URL?
    /// Identifies the newest article run. A cancelled older task may only
    /// report a terminal state while it still owns the row.
    var articlePreparationGeneration = 0
    /// The typed cause of each podcast preparation that failed in this
    /// session, keyed by episode id, shown beside the row's Retry control.
    var preparationFailureCauses: [String: String] = [:]
    var selectedArticleID: String?
    var isNowPlaying = false
    var isPlaying = false
    /// Whether what is loaded in the player is already recorded as finished.
    ///
    /// Mirrored from the controller rather than read through it, because the
    /// controller is not observable: a view reading `playback.completed`
    /// directly would render the value it saw when it was last redrawn for
    /// some other reason.
    var playbackCompleted = false
    var playbackError: String?
    /// Readout state the listener already published. The producer's player
    /// showed transports and nothing else, so the Mac could not answer "how
    /// far in am I?" — a question the same audio answers on iPhone.
    var playbackPositionSeconds: TimeInterval = 0
    var playbackDurationSeconds: TimeInterval = 0
    /// Every recorded preparation attempt, newest first.
    var processorRuns: [WiltedMacProcessorRun] = []
    /// Preparations waiting for the single run slot, nearest turn first. The
    /// journal cannot supply this: a waiting run has emitted nothing yet.
    var preparationQueue = WiltedMacPreparationQueue()
    var processorOperationMessage: String?
    /// Progress for an in-flight transcript backfill (W-INV-001: a network
    /// fetch never runs without the surface saying so).
    var transcriptBackfillStatus: String?
    var isBackfillingTranscript = false
    /// Native tests replace extraction text only; production retains the extractor's progress path.
    var transcriptBackfillBodyForTesting: (@MainActor (URL) async throws -> String)?
    var currentTranscript: WiltedMacTranscript?
    var podcastQueueIDs: [String] = []
    var currentPodcastEpisodeID: String?
    /// Removed spans per episode, filled in as each episode's transcript
    /// loads. Keyed rather than held as one current value so that changing
    /// episode cannot leave the previous episode's cuts on screen.
    var removedSpansByEpisode: [String: [WiltedMacRemovedSpan]] = [:]
    /// The listener's ad-removal feedback and its review inbox (`WiltedMacModel+AdFeedback`).
    @ObservationIgnored lazy var adFeedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(
        fileURL: libraryURL.deletingLastPathComponent().appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)))
    var seamMarkerTask: Task<Void, Never>?
    var lastMarkedSeam: (episodeID: String, seconds: TimeInterval)?
    /// The output is injectable for tests. A prior test-host gate played a
    /// 220 Hz tone from the owner's speakers, so tests and fixtures stay silent.
    var seamMarkerOutput: any WiltedMacSeamMarkerOutput
    /// The target of the cancellable marker task, exposed for headless tests.
    var pendingSeamMarkerForTesting: TimeInterval?
    var playbackRate: Double = WiltedMacModel.initialPlaybackRate
    var playbackVolume: Double = 1
    var playbackOperationStatus: String?
    /// Device-local totals derived only from the durable lifetime summary.
    var statisticsState: WiltedMacStatisticsState = .loading
    /// The four legacy totals, once the summary is ready; zeros otherwise.
    var lifetimeStatistics: LifetimeStatistics { statisticsState.summary?.legacy ?? LifetimeStatistics() }
    /// The one background summary load/rebuild. Never awaited by bootstrap.
    var statisticsTask: Task<Void, Never>?
    /// Set only after the one automatic route recovery attempt fails. The
    /// recovery control is gated on this so it is a manual retry, not a second
    /// action competing with the automatic repair.
    var audioRouteFault = false

    let fixtureMode: Bool
    /// The arguments this model was built from. A fixture session can build a
    /// later model inside the same process, so fixture reads use these rather
    /// than the process's own launch arguments.
    let launchArguments: [String]

#if canImport(WiltedProducer)
    /// Explicit fixture failures survive SwiftUI rebuilding their source closures.
    @ObservationIgnored var fixtureEpisodeInfoReadCounts: [String: WiltedMacFixtureEpisodeInfoReadCounts] = [:]
    /// Ownership exists only for fixture roots this model created itself.
    /// Injected roots belong to their caller (the app, a test, or a relaunch
    /// scenario) and are never removed by this model.
    let temporaryState: WiltedMacTemporaryState?
    /// A root created by the central XCTest helper. Its helper closes every
    /// registered model before its final per-test removal.
    let registeredTestRoot: URL?
    var isClosingTemporaryState = false
    var temporaryStateCloseTask: Task<Void, Never>?
    @ObservationIgnored var manualCompletionNow: @MainActor () -> Date = { Date() }
    @ObservationIgnored var manualCompletionSleep: @MainActor (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
    var manualCompletionExpiryTask: Task<Void, Never>?
    var manualCompletionExpiryDeadline: Date?
    var manualCompletionExpiryGeneration = UUID()
    var manualCompletionRecoveryTask: Task<Void, Never>?
    var store: LocalLibraryStore? {
        didSet {
            bulletinLifecycleChanged()
            manualCompletionRecoveryTask?.cancel()
            guard store != nil, !isClosingTemporaryState else { return }
            manualCompletionRecoveryTask = Task { [weak self] in
                // Bootstrap first establishes the queue and current library rows.
                await self?.startupTask?.value
                guard let self, !Task.isCancelled, !self.isClosingTemporaryState else { return }
                await self.recoverManualCompletionWindows()
            }
        }
    }
    var coordinator: PreparationCoordinator?
    var playback: PlaybackController?
    /// Why CloudKit calls are paused (rate limited, unavailable) and until when; nil while they run.
    /// Set by the library sync's shared gate, shown in the Sync settings card.
    var libraryThrottle: TransportGateState?
    /// Whether library sync may send for the signed-in iCloud account (Task 5.0); nil while off.
    var libraryAccountStatus: WiltedMacLibraryAccountStatus?
    /// The library publisher's and inbound poller's own results on this Mac (Task 5.2).
    var librarySyncActivity = WiltedMacLibrarySyncActivity()
    /// Podcast feeds Wilted follows, newest subscription first.
    var subscriptions: [WiltedMacSubscription] = []
    /// Per-feed optimistic names survive reloads until their tracked writer settles.
    var pendingFeedRenames: [String: WiltedMacFeedRenameState] = [:]
    var feedRenameReadEpoch: UInt64 = 0
    var feedRenameNeedsReload = false
    /// Read-order metadata only. A committed Feed decision advances this
    /// boundary so a snapshot that began beforehand cannot publish over it.
    var libraryReadEpoch: UInt64 = 0
    var lastAppliedLibraryReadEpoch: UInt64 = 0
    /// Exact Feed rows whose durable decision has started. This is separate
    /// from Larder admission retry state because a decision failure stays
    /// selected and retryable instead of becoming an automatic arrival.
    var pendingFeedDecisionIDs: Set<String> = []
    var failedFeedDecisionIDs: Set<String> = []
    /// Posts of followed article feeds that no rule or policy decided: the Feeds inbox lists them
    /// beside podcast episodes. In memory; the next refresh offers them again.
    var offeredArticles: [WiltedMacOfferedArticle] = []
    /// The final Feed writer in admission order. Feed decisions await this
    /// chain, while unrelated subscription work remains independently live.
    var feedDecisionWriteTailToken: UUID?
    /// Nil in production. Regression tests use these deterministic seams to
    /// observe the pre-write and committed-but-not-published boundaries.
    var feedDecisionBeforeCommitForTesting: (@Sendable () async throws -> Void)?
    var feedDecisionAfterDurableCommitForTesting: (@Sendable () async -> Void)?
    var podcastQueueReadBarrierForTesting: (@Sendable () async -> Void)?
    var librarySnapshotReadBarrierForTesting: (@Sendable () async -> Void)?
    /// Runs before each Larder queue write the owner drives -- sort, reorder,
    /// or group clear; a test holds it open to delay the write, or throws to
    /// fail it.
    var larderSortWriteHookForTesting: (@Sendable () async throws -> Void)?
    /// Runs before feed enable or rename writes; a test holds it open or throws to fail the write.
    var subscriptionWriteHookForTesting: (@Sendable () async throws -> Void)?
    /// Nil in production. Regression tests can fail only the episode-admission
    /// step after the real feed and subscription writes have committed.
    var podcastEpisodeAdmissionOperationForTesting: (@Sendable (
        [PodcastEpisode], LocalLibraryStore.PodcastEpisodeAdmission, Int?
    ) async throws -> LocalLibraryStore.PodcastEpisodeAdmissionResult)?
    /// Durable removals remain visible even when no feed is subscribed.
    var dismissedEpisodes: [WiltedMacDismissedEpisode] = []

    let libraryURL: URL
    let mediaDirectory: URL
    let storeBootstrap: WiltedMacStoreBootstrap
    let pipelineFingerprint: String?
    /// Awaited at the fingerprint step, never on the launch path.
    ///
    /// Tests inject a value through `pipelineFingerprint` and get a resolution
    /// that returns it immediately; the app injects the real resolver.
    let pipelineFingerprintResolution: @Sendable () async -> String?
    let invalidateStalePreparations: WiltedMacStaleInvalidation
    /// The launch storage sweep, injectable so a failing or observed sweep can
    /// be exercised apart from a store that will not open.
    let reclaimStorage: WiltedMacMediaReclaim
    /// Injectable so a delayed or failing summary can be exercised apart from
    /// a store that will not open.
    let statisticsOperations: WiltedMacStatisticsOperations
    private let invalidationRules: [PodcastPreparationInvalidationRule]
    /// Whether launch invalidation has anything to evaluate. A rule can
    /// condemn a preparation; an explicit override substitutes the whole
    /// invalidator, so the launch must still resolve a fingerprint for it.
    /// With neither, there is no comparison to make and startup must not hash
    /// the worker and Python trees.
    let requiresLaunchFingerprintResolution: Bool
    let retainedArtifactPresenter: (URL) -> Void
    var startupAttemptCount = 0
    var startupTask: Task<Void, Never>?
    var preparationRun: PreparationRun?
    var preparationTask: Task<Void, Never>?
    var podcastRefreshTask: Task<Void, Never>?
    /// Every refresh task carries this identity so a cancelled predecessor
    /// cannot clear a replacement's visible work state when it returns late.
    var podcastRefreshOperationID: UUID?
    var bootstrapRecoveryTask: Task<Void, Never>?
    /// The system's media widget, and the media keys that drive it. Both are
    /// injected and both are optional: they are process-global system state, so
    /// a unit test or a UI fixture that built them for real would repoint the
    /// machine's Now Playing widget at a fixture and capture its media keys.
    let nowPlayingSink: (any WiltedNowPlayingSink)?
    let remoteCommandSource: (any WiltedRemoteCommandSource)?
    /// The last thing published, so an unchanged readout is not republished
    /// once a second for the life of an episode.
    var lastPublishedNowPlaying: WiltedNowPlayingInfo?
#if canImport(WiltedProducer)
    var automation: WiltedAutomationCoordinator?
    var automationTask: Task<Void, Never>?
    var automationTicker: Task<Void, Never>?
    var playbackCheckpointTicker: Task<Void, Never>?
    var ticketDrainTicker: Task<Void, Never>?
#endif
    var podcastDownloadTasks: [String: Task<PodcastDownloadResult, Error>] = [:]
    var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    var podcastPreparationPipeline: PodcastPreparationPipeline?
    /// Real-wiring seams for tests and fixtures: nil means "use the coordinator's
    /// and pipeline's own network/subprocess defaults," which is every production
    /// launch. A test or fixture that supplies one gets a real coordinator/pipeline
    /// running a substitute transport, validator, or runner instead of a parallel
    /// implementation that never touches them.
    let podcastDownloadTransportFactory: WiltedMacPodcastDownloadTransportFactory?
    let podcastMediaValidatorFactory: WiltedMacPodcastMediaValidatorFactory?
    let podcastPipelineRunnerFactory: WiltedMacPodcastPipelineRunnerFactory?
    var podcastPreparationTasks: [String: Task<Void, Never>] = [:]
    /// The journal is written by the preparation actor, so it can be a few
    /// hops behind the action that admitted a run. Keep the active run the
    /// model just accepted visible until the journal catches up.
    var projectedProcessorRuns: [String: WiltedMacProcessorRun] = [:]
    var processorRunsRefreshGeneration: UInt64 = 0
    /// Queue reads are independent actor calls. A late read from an older
    /// mutation must not overwrite the snapshot published for a newer one.
    var podcastQueueRefreshGeneration: UInt64 = 0
    /// Set while a Larder sort is writing itself to the durable queue.
    /// `applyLarderSortIfNeeded` refreshes the queue after that write, and the
    /// refresh applies the sort again -- which is mutual recursion the moment
    /// the write fails or the store does not round-trip the order verbatim:
    /// the re-read disagrees with the sort forever, one store write and one
    /// store read per turn. The flag makes the refresh that a sort caused
    /// decline to start another one.
    var isApplyingLarderSort = false
    /// Durable Larder admissions whose write raised. Kept in memory for the
    /// process's lifetime so the next reload can retry them; a relaunch
    /// re-derives arrivals from the store, and the failure was about this
    /// process's write, not a durable intent.
    var pendingLarderAdditions: Set<String> = []
    /// The in-flight automatic Larder admission, so a test can await the pass
    /// it triggered instead of polling the rows.
    var larderAdditionTask: Task<Void, Never>?
    /// Replaces the durable per-episode admission for tests that need it to
    /// raise. Production always goes through `playback`.
    var larderAdmissionForTesting: (@Sendable (ItemID) async throws -> Void)?
    /// Automatic work that was admitted while its off-peak window was closed.
    /// The snapshot belongs to the job rather than Settings, so changing a
    /// preference cannot rewrite work already waiting for its window.
    var deferredAutomaticPreparations: [DeferredAutomaticPreparation] = []
    /// One preparation runs at a time; the rest queue. See
    /// `WiltedPreparationGate` for why concurrent runs cost work rather
    /// than saving time.
    let preparationGate = WiltedPreparationGate()
    var podcastRestoreTasks: [String: Task<Void, Never>] = [:]
    /// Removing advertisements is why preparation exists. Read once, when the
    /// pipeline is built, so this is not a switch: a Settings control would
    /// have to rebuild the pipeline to mean anything, and none exists yet.
    let removesAdvertisements = true
    var hiddenEpisodeIDs: Set<String> = []
    /// Whether an article preparation is started but has not yet finished.
    ///
    /// `preparationTask` cannot answer this: it is never cleared, so it stays
    /// non-nil for the rest of the session after the first article.
    var articlePreparationIsPending = false
    var fixtureDownloadFailuresRemaining = 0
    /// The podcast fixture episode starts out prepared, so the UI test can
    /// prove a prepared row still offers a way to prepare again.
    var fixtureEpisodeIsPrepared = false
    /// A long prepared episode used only by the scrolling UI regression.
    var fixtureEpisodeHasLongTranscript = false
    /// Seeds one episode deferred to off-peak, so the UI leg has a row whose
    /// only way forward is the override.
    var fixtureEpisodeIsDeferred = false
    /// Ten Larder episodes, two part played, the first open in Now Playing.
    var fixtureLarderDemo = false
    /// Cover art for fixture rows. The store accepts only https artwork, so a
    /// fixture that wants art without the network supplies it at load time.
    var fixtureArtworkURL: URL?
    /// Host-only owner-feedback fixture; production keeps the injected client.
    let fixtureSubscriptionIntakeMode: Bool
    let podcastFeedClient: PodcastFeedClient
    let mediaAvailabilityChecker: any WiltedMacMediaAvailabilityChecking
    let pastedLinkClassifier: PastedLinkClassifier
    var linkClassificationTask: Task<Void, Never>?
    var podcastSubscriptionClassificationTask: Task<Void, Never>?
    var fixtureRevision: StoredAudioRevision?
    var fixtureInstallTask: Task<Void, Never>?
    var fixturePodcastInstallTask: Task<Void, Never>?
    var playbackOperationTask: Task<Void, Never>?
    /// Every finite subscription, Feed-decision, Restore, or playback
    /// statistics refresh writer. Close and deinit cancel and drain this
    /// ledger before an owned fixture root goes.
    var subscriptionWriteTasks: [UUID: Task<Void, Never>] = [:]
    /// The final playback statistics refresh in issue order, so refreshes
    /// never read the summary out of order.
    var lifetimeStatisticsRefreshTailToken: UUID?
    var audioRouteRecoveryInFlight = false
    var audioRouteRecoveryAttempted = false
    /// The playback command owner: token order, pending and failure state,
    /// the serialized effect tail, and the speed-save line.
    var playbackCommands = WiltedMacPlaybackCommandState()
    var playbackPresentationGeneration: UInt64 = 0
    var playbackPresentationTaskID: UUID?
    /// Presentation joins teardown but never becomes a durable-write predecessor.
    var playbackPresentationTasks: [UUID: Task<Void, Never>] = [:]
    var playbackPresentationReadBarrierForTesting: (@MainActor () async -> Void)?
    var isPodcastPlayback = false {
        didSet {
            if oldValue && !isPodcastPlayback { clearPodcastPlaybackOrigin() }
        }
    }
    var isRestoringPodcastPlayback = false
    /// Whether the podcast session now loaded belongs to the Larder's own
    /// durable queue -- started through `playLarderEpisode`, or restored from
    /// the queue at launch -- rather than a generic Play.
    ///
    /// This is bookkeeping, not a second queue: it decides only what happens
    /// when the durable queue's suffix runs out. A Larder-origin session stops
    /// there, because the queue's order is the order the listener chose; a
    /// generic play keeps the older Larder-wide search, which is how a listen
    /// started anywhere else has always continued. The mode survives the
    /// controller's own within-queue advances and pause/resume, changes only
    /// when a new start succeeds, and is left untouched by a start that
    /// fails -- the outgoing session keeps its mode.
    var isLarderQueuePlayback = false
#endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         stateDirectoryOverride: URL? = nil,
         storeBootstrap: WiltedMacStoreBootstrap? = nil,
         podcastDownloadTransportFactory: WiltedMacPodcastDownloadTransportFactory? = nil,
         podcastMediaValidatorFactory: WiltedMacPodcastMediaValidatorFactory? = nil,
         podcastPipelineRunnerFactory: WiltedMacPodcastPipelineRunnerFactory? = nil,
         pipelineFingerprint: String? = nil,
         pipelineFingerprintResolution: (@Sendable () async -> String?)? = nil,
         staleInvalidationOverride: WiltedMacStaleInvalidation? = nil,
         reclaimOverride: WiltedMacMediaReclaim? = nil,
         statisticsOperations: WiltedMacStatisticsOperations = .live,
         invalidationRules: [PodcastPreparationInvalidationRule] = PodcastPreparationPipeline.invalidationRules,
         retainedArtifactPresenter: ((URL) -> Void)? = nil,
         podcastFeedClient: PodcastFeedClient = PodcastFeedClient(),
         mediaAvailabilityChecker: any WiltedMacMediaAvailabilityChecking = FileManager.default,
         pastedLinkClassifier: PastedLinkClassifier = PastedLinkClassifier(),
         nowPlayingSink: (any WiltedNowPlayingSink)? = nil,
         remoteCommandSource: (any WiltedRemoteCommandSource)? = nil,
         preferences: UserDefaults) {
        let usesFixtureMode = Self.isFixtureLaunch(arguments: arguments)
        fixtureMode = usesFixtureMode
        launchArguments = arguments
        self.nowPlayingSink = nowPlayingSink
        self.remoteCommandSource = remoteCommandSource
        // Required rather than defaulted to `.standard`: the unit-test host is
        // the app bundle itself, so a defaulted `.standard` let tests write
        // into the daily driver's own preferences.
        let fixtureSuite = usesFixtureMode ? Self.fixturePreferencesSuiteName() : nil
        fixturePreferencesSuite = fixtureSuite
        self.preferences = fixtureSuite.map { Self.fixturePreferences(suiteName: $0) } ?? preferences
        // Read before the fixture install below, which builds its deferral's
        // policy snapshot from these settings; the rest of the stored
        // preferences are read after it.
        automationSettings = Self.loadAutomationSettings(from: self.preferences)
        observedLastAutomationRefreshAt = self.preferences.object(
            forKey: Self.lastAutomationRefreshPreferenceKey
        ) as? Date

#if canImport(WiltedProducer)
        let stateDirectory: URL
        if let stateDirectoryOverride = stateDirectoryOverride ?? Self.fixtureStateDirectoryOverride(arguments: arguments) {
            temporaryState = nil
            stateDirectory = stateDirectoryOverride
            registeredTestRoot = WiltedMacTemporaryState.markedTestRoot(containing: stateDirectoryOverride)
        } else if usesFixtureMode {
            let state = Self.makeOwnedFixtureState()
            temporaryState = state
            stateDirectory = state.directory
            registeredTestRoot = nil
        } else {
            temporaryState = nil
            stateDirectory = Self.stateDirectory(fixtureMode: false)
            registeredTestRoot = nil
        }
        self.libraryURL = stateDirectory.appendingPathComponent("library.sqlite")
        self.mediaDirectory = stateDirectory.appendingPathComponent("media", isDirectory: true)
        self.storeBootstrap = storeBootstrap ?? { url in
            try await Task.detached(priority: .userInitiated) {
                try LocalLibraryStore(url: url)
            }.value
        }
        self.podcastDownloadTransportFactory = podcastDownloadTransportFactory
        self.podcastMediaValidatorFactory = podcastMediaValidatorFactory
        self.podcastPipelineRunnerFactory = podcastPipelineRunnerFactory
        self.pipelineFingerprint = pipelineFingerprint
        self.pipelineFingerprintResolution = pipelineFingerprintResolution ?? { pipelineFingerprint }
        self.invalidationRules = invalidationRules
        self.requiresLaunchFingerprintResolution =
            !invalidationRules.isEmpty || staleInvalidationOverride != nil
        self.statisticsOperations = statisticsOperations
        let rules = invalidationRules
        self.invalidateStalePreparations = staleInvalidationOverride ?? { store, fingerprint in
            try await store.invalidateStalePodcastPreparations(
                currentFingerprint: fingerprint, rules: rules
            )
        }
        self.reclaimStorage = reclaimOverride ?? { store, directories, excluded in
            try await store.sweepUnreferencedMedia(in: directories, excluding: excluded)
        }
        self.retainedArtifactPresenter = retainedArtifactPresenter ?? { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        fixtureSubscriptionIntakeMode = arguments.contains("--wilted-ui-fixture-subscription-intake-26")
        self.podcastFeedClient = Self.subscriptionIntakeFixtureClient(
            enabled: fixtureSubscriptionIntakeMode, fallback: podcastFeedClient
        )
        self.mediaAvailabilityChecker = mediaAvailabilityChecker
        self.pastedLinkClassifier = pastedLinkClassifier
        fixtureDownloadFailuresRemaining = arguments.contains("--wilted-ui-fixture-download-failure") ? 1 : 0
        let larderDemo = arguments.contains(Self.larderDemoFlag)
        fixtureLarderDemo = larderDemo
        fixtureEpisodeIsPrepared = arguments.contains("--wilted-ui-fixture-prepared") || larderDemo
        fixtureEpisodeHasLongTranscript = arguments.contains("--wilted-ui-fixture-long-transcript")
        fixtureEpisodeIsDeferred = arguments.contains("--wilted-ui-fixture-deferred")
        seamMarkerOutput = (Self.hostsTests || usesFixtureMode)
            ? WiltedMacSilentSeamMarkerOutput()
            : WiltedMacAVSeamMarkerOutput()

        if usesFixtureMode { launchFixture(arguments: arguments, larderDemo: larderDemo) }
#else
        _ = arguments
#endif
        restoreStoredPreferences()
#if canImport(WiltedProducer)
        // Fixture launches build their controller above, before the stored
        // rate is known; production builds it later, in
        // `configureStoreDependencies`, which reads the rate itself.
        playback?.defaultRate = Float(playbackRate)
#endif
        installRemoteCommands()
#if canImport(WiltedProducer)
        if let registeredTestRoot {
            WiltedMacTemporaryState.register(self, forTestRoot: registeredTestRoot)
        }
#endif
    }

    isolated deinit {
#if canImport(WiltedProducer)
        // Deinitialization cannot await. Capture task and root values only,
        // then let a post-model task settle writers before deleting an owned
        // root. The closures do not capture `self`, so this cannot resurrect
        // the model while a fixture store finishes a cancellation-ignoring
        // write.
        isClosingTemporaryState = true
        let temporaryState = temporaryState
        let fixtureSuite = fixturePreferencesSuite
        let voidTasks = [
            startupTask,
            preparationTask,
            podcastRefreshTask,
            bootstrapRecoveryTask,
            statisticsTask,
            linkClassificationTask,
            podcastSubscriptionClassificationTask,
            fixturePodcastInstallTask,
            fixtureInstallTask,
            playbackOperationTask,
            manualCompletionRecoveryTask,
            manualCompletionExpiryTask,
            larderAdditionTask,
            automationTask,
            automationTicker,
            ticketDrainTicker,
            playbackCheckpointTicker
        ].compactMap { $0 }
            + Array(podcastPreparationTasks.values)
            + Array(podcastRestoreTasks.values)
            + Array(subscriptionWriteTasks.values)
            + Array(playbackPresentationTasks.values)
        let downloadTasks = Array(podcastDownloadTasks.values)
        let automation = automation
        cancelPendingTemporaryStateWork()
        Task { @MainActor in
            await closeOwnedTemporaryStateAfterDeinit(
                temporaryState,
                voidTasks: voidTasks,
                downloadTasks: downloadTasks,
                automation: automation,
                preferencesSuite: fixtureSuite
            )
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Test seam: every bootstrap step as it is announced, so a test can
    /// assert the readout walks the awaited steps in order.
    var startupStepObserverForTesting: ((WiltedMacStartupStep) -> Void)?

#endif

    /// Items whose stored transcript contains the current query. Empty until
    /// the store answers, so a row matching only in its transcript arrives a
    /// moment after the rows matching text the list already holds.
    var transcriptSearchMatches: Set<String> = []

    /// A search that reaches disk has to say so rather than let the list grow
    /// under the reader with no explanation (INV-1).
    var isSearchingTranscripts = false
    var transcriptSearchTask: Task<Void, Never>?

}
