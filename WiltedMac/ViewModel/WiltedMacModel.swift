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

/// Main-actor presentation state for the local Mac producer.
@Observable
@MainActor
final class WiltedMacModel {
    static let maximumStartupAttempts = 2

    var startupState: WiltedMacStartupState = .loading(attempt: 0, step: .openingStore)
    var urlDraft = ""
    var podcastFeedDraft = ""
    /// What the single add box is doing right now. Telling a feed from an
    /// article needs the document, so the button can sit on a network round
    /// trip; an unannounced pause there reads as a control that did nothing.
    var linkDraftStatus: String?
    /// A feed the page just added advertises. Offered, never taken: following a
    /// site's whole feed is a different request from saving one article of it.
    var advertisedFeed: URL?
    var podcastFeedDraftStatus: String?
    var isCheckingPodcastSubscription = false
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
    /// The retired newest/oldest view of the Larder's order.
    ///
    /// `libraryOrder` used to be a second, independently persisted preference
    /// read by Menu bulk ordering and auto-advance, so those paths could order
    /// episodes differently from the Larder the listener was looking at. It is
    /// now a read/write projection of `larderSort`, the one preference that
    /// orders the shelf: a caller that predates the richer control still works
    /// and can no longer disagree with it.
    var libraryOrder: WiltedMacLibraryOrder {
        get { larderSort == .oldest ? .oldest : .newest }
        set { larderSort = newValue == .oldest ? .oldest : .newest }
    }
    /// The retired `wilted.library.order` key. Read once during restore, only
    /// when no `wilted.queue.larder.sort` has been stored, and written forward
    /// through `larderSort`'s own preference.
    static let libraryOrderPreferenceKey = "wilted.library.order"
    /// Feeds ordering. It changes only the inbox scan, never the listening
    /// order the Menu holds.
    var larderSort: WiltedMacLarderSort = .newest {
        didSet { preferences.set(larderSort.rawValue, forKey: Self.larderSortPreferenceKey) }
    }
    /// The Menu's sort. `custom` is the durable listening order; the rest
    /// reorder every row except the one playing, which holds its place.
    var menuSort: WiltedMacMenuSort = .custom {
        didSet {
            preferences.set(menuSort.rawValue, forKey: Self.menuSortPreferenceKey)
            guard oldValue != menuSort else { return }
            applyMenuSortIfNeeded()
        }
    }
    /// Section presentation is independent from the queue's selected sort.
    /// Status preserves the Larder's established default for existing users.
    var menuGrouping: WiltedMacMenuGrouping = .status {
        didSet { preferences.set(menuGrouping.rawValue, forKey: Self.menuGroupingPreferenceKey) }
    }
    static let larderSortPreferenceKey = "wilted.queue.larder.sort"
    static let menuSortPreferenceKey = "wilted.queue.menu.sort"
    static let menuGroupingPreferenceKey = "wilted.queue.menu.grouping"
    static let marksRemovedAdsPreferenceKey = "wilted.playback.marksRemovedAds"
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
    /// The selected destination. Persisted so a relaunch returns the reader to
    /// where they were; a stored retired name resolves through
    /// `WiltedMacNavigation.restored(from:)`.
    static let selectedNavigationPreferenceKey = "wilted.navigation.selected"
    /// The last speed the owner chose. It seeds every load that has no
    /// per-episode speed of its own, so 1.25× chosen once stays 1.25×.
    static let playbackRatePreferenceKey = "wilted.playback.rate"
    static let initialPlaybackRate = 1.25
    /// The speeds the rate control offers, and the same list the system widget
    /// is told about. One array, because two would drift and the widget would
    /// offer a speed the app refuses.
    static let playbackRateChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// Transport step sizes. Asymmetric on purpose: a listener rewinds to hear
    /// something again and skips forward past an advertisement, and those are
    /// not the same distance. Published to the system so a media key's skip
    /// matches the button's.
    static let backwardSkipSeconds: Double = 15
    static let forwardSkipSeconds: Double = 30
    static let automationSettingsPreferenceKey = "wilted.automation.settings"
    static let deferredAutomaticPreparationsPreferenceKey = "wilted.automation.deferredPreparations"
    /// The monotonic preparation request sequence's fallback home.
    ///
    /// The ticket table (`WorkTicketRecord`, via `LocalLibraryStore`) is now
    /// the writer of record for a request's place in line: a number without a
    /// durable ticket behind it is exactly the bug a relaunch used to hit,
    /// because an unrunnable in-memory request could not survive the process
    /// that made it. Issuing a ticket is already a store write -- the request
    /// it is for already implied one, in the form of the download claim or
    /// the preparation admission it is ordering -- so there is nothing left
    /// for a preferences-only counter to save the reader from.
    ///
    /// This key still exists for the moment before that write lands: a click
    /// must not fail or block waiting on a store transaction, so
    /// `nextPreparationRequestSequence()` still stamps the scalar here
    /// synchronously, and `reconcileWorkTickets(in:)` reads it once as
    /// `sequenceFloor` and clears it once every ticket it names is durable.
    /// A store-less launch has no ticket table to reconcile into, so its
    /// requests live here, in memory and in this preference, for exactly as
    /// long as the process that made them -- the documented degrade, not a
    /// crash.
    static let preparationRequestSequencePreferenceKey = "wilted.preparation.requestSequence"
    static let textScalePreferenceKey = "wilted.appearance.textScale"
    /// When automation last completed a refresh.
    ///
    /// Kept in preferences rather than the store because losing it costs one
    /// extra idempotent refresh and nothing else. Claims, which cannot be
    /// reconstructed, live in the store instead.
    static let lastAutomationRefreshPreferenceKey = "wilted.automation.lastRefreshSuccess"
    let preferences: UserDefaults
    /// Whether a quiet marker identifies each advertisement seam during playback.
    var marksRemovedAds = true {
        didSet {
            preferences.set(marksRemovedAds, forKey: Self.marksRemovedAdsPreferenceKey)
            rescheduleSeamMarker()
        }
    }
    /// Automation reads this one validated value, never individual preference keys.
    var automationSettings = WiltedAutomationSettings.defaults
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
    /// The subscribe box, behind its own button for the same reason the
    /// article one is: a control used once a session should not hold the
    /// top of a page the reader scrolls every day.
    var isPresentingSubscribeComposer = false
    var selectedNavigation: WiltedMacNavigation = .menu {
        didSet {
            preferences.set(selectedNavigation.rawValue, forKey: Self.selectedNavigationPreferenceKey)
        }
    }
    var articles: [WiltedMacArticle] = []
    var episodes: [WiltedMacEpisode] = []
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
    var selectedLibraryItemID: String?
    var preparation: WiltedMacPreparation?
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
    var currentTranscript: WiltedMacTranscript?
    var podcastQueueIDs: [String] = []
    var currentPodcastEpisodeID: String?
    /// Removed spans per episode, filled in as each episode's transcript
    /// loads. Keyed rather than held as one current value so that changing
    /// episode cannot leave the previous episode's cuts on screen.
    var removedSpansByEpisode: [String: [WiltedMacRemovedSpan]] = [:]
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
    /// Device-local totals derived only from the append-only event ledger.
    var lifetimeStatistics = LifetimeStatistics()
    var articlePublicationCount = 0
    var articlePlaybackCheckpointCount = 0
    /// Set only after the one automatic route recovery attempt fails. The
    /// recovery control is gated on this so it is a manual retry, not a second
    /// action competing with the automatic repair.
    var audioRouteFault = false

    let fixtureMode: Bool

#if canImport(WiltedProducer)
    var store: LocalLibraryStore?
    var coordinator: PreparationCoordinator?
    var playback: PlaybackController?
    var syncLifecycle: WiltedMacSyncLifecycle?
    /// Podcast feeds Wilted follows, newest subscription first.
    var subscriptions: [WiltedMacSubscription] = []
    /// Durable removals remain visible even when no feed is subscribed.
    var dismissedEpisodes: [WiltedMacDismissedEpisode] = []

    let libraryURL: URL
    let mediaDirectory: URL
    let syncTransportFactory: WiltedMacSyncTransportFactory?
    let assetResolver: LocalLibraryAssetResolver
    let storeBootstrap: WiltedMacStoreBootstrap
    let pipelineFingerprint: String?
    /// Awaited at the fingerprint step, never on the launch path.
    ///
    /// Tests inject a value through `pipelineFingerprint` and get a resolution
    /// that returns it immediately; the app injects the real resolver.
    let pipelineFingerprintResolution: @Sendable () async -> String?
    let invalidateStalePreparations: WiltedMacStaleInvalidation
    private let invalidationRules: [PodcastPreparationInvalidationRule]
    let retainedArtifactPresenter: (URL) -> Void
    var startupAttemptCount = 0
    var startupTask: Task<Void, Never>?
    var pendingSyncReconciliation = false
    var preparationRun: PreparationRun?
    var preparationTask: Task<Void, Never>?
    var syncReconciliationTask: Task<Void, Never>?
    var podcastRefreshTask: Task<Void, Never>?
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
    /// Set while a Menu sort is writing itself to the durable queue.
    /// `applyMenuSortIfNeeded` refreshes the queue after that write, and the
    /// refresh applies the sort again -- which is mutual recursion the moment
    /// the write fails or the store does not round-trip the order verbatim:
    /// the re-read disagrees with the sort forever, one store write and one
    /// store read per turn. The flag makes the refresh that a sort caused
    /// decline to start another one.
    var isApplyingMenuSort = false
    /// Durable Menu admissions whose write raised. Kept in memory for the
    /// process's lifetime so the next reload can retry them; a relaunch
    /// re-derives arrivals from the store, and the failure was about this
    /// process's write, not a durable intent.
    var pendingMenuAdditions: Set<String> = []
    /// The in-flight automatic Menu admission, so a test can await the pass
    /// it triggered instead of polling the rows.
    var menuAdditionTask: Task<Void, Never>?
    /// Replaces the durable per-episode admission for tests that need it to
    /// raise. Production always goes through `playback`.
    var menuAdmissionForTesting: (@Sendable (ItemID) async throws -> Void)?
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
    let podcastFeedClient: PodcastFeedClient
    let mediaAvailabilityChecker: any WiltedMacMediaAvailabilityChecking
    let pastedLinkClassifier: PastedLinkClassifier
    var linkClassificationTask: Task<Void, Never>?
    var podcastSubscriptionClassificationTask: Task<Void, Never>?
    var fixtureRevision: StoredAudioRevision?
    var fixturePodcastInstallTask: Task<Void, Never>?
    var playbackOperationTask: Task<Void, Never>?
    var audioRouteRecoveryInFlight = false
    var audioRouteRecoveryAttempted = false
    var isPodcastPlayback = false
#endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         syncTransportFactory: WiltedMacSyncTransportFactory? = nil,
         assetResolver: @escaping LocalLibraryAssetResolver = { _, _ in nil },
         stateDirectoryOverride: URL? = nil,
         storeBootstrap: WiltedMacStoreBootstrap? = nil,
         podcastDownloadTransportFactory: WiltedMacPodcastDownloadTransportFactory? = nil,
         podcastMediaValidatorFactory: WiltedMacPodcastMediaValidatorFactory? = nil,
         podcastPipelineRunnerFactory: WiltedMacPodcastPipelineRunnerFactory? = nil,
         pipelineFingerprint: String? = nil,
         pipelineFingerprintResolution: (@Sendable () async -> String?)? = nil,
         staleInvalidationOverride: WiltedMacStaleInvalidation? = nil,
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
        self.nowPlayingSink = nowPlayingSink
        self.remoteCommandSource = remoteCommandSource
        // Required rather than defaulted to `.standard`: the unit-test host is
        // the app bundle itself, so a defaulted `.standard` let tests write
        // into the daily driver's own preferences.
        self.preferences = usesFixtureMode ? Self.fixturePreferences() : preferences
        // Read before the fixture install below, which builds its deferral's
        // policy snapshot from these settings; the rest of the stored
        // preferences are read after it.
        automationSettings = Self.loadAutomationSettings(from: self.preferences)

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
        self.podcastDownloadTransportFactory = podcastDownloadTransportFactory
        self.podcastMediaValidatorFactory = podcastMediaValidatorFactory
        self.podcastPipelineRunnerFactory = podcastPipelineRunnerFactory
        self.pipelineFingerprint = pipelineFingerprint
        self.pipelineFingerprintResolution = pipelineFingerprintResolution ?? { pipelineFingerprint }
        self.invalidationRules = invalidationRules
        let rules = invalidationRules
        self.invalidateStalePreparations = staleInvalidationOverride ?? { store, fingerprint in
            try await store.invalidateStalePodcastPreparations(
                currentFingerprint: fingerprint, rules: rules
            )
        }
        self.retainedArtifactPresenter = retainedArtifactPresenter ?? { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        self.podcastFeedClient = podcastFeedClient
        self.mediaAvailabilityChecker = mediaAvailabilityChecker
        self.pastedLinkClassifier = pastedLinkClassifier
        fixtureDownloadFailuresRemaining = arguments.contains("--wilted-ui-fixture-download-failure") ? 1 : 0
        fixtureEpisodeIsPrepared = arguments.contains("--wilted-ui-fixture-prepared")
        fixtureEpisodeHasLongTranscript = arguments.contains("--wilted-ui-fixture-long-transcript")
        fixtureEpisodeIsDeferred = arguments.contains("--wilted-ui-fixture-deferred")
        seamMarkerOutput = (Self.hostsTests || usesFixtureMode)
            ? WiltedMacSilentSeamMarkerOutput()
            : WiltedMacAVSeamMarkerOutput()

        if usesFixtureMode {
            let configuredStore = try? LocalLibraryStore(url: self.libraryURL)
            configureStoreDependencies(configuredStore)
            startupState = configuredStore == nil
                ? .failed(Self.startupFailure(canRetry: false))
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
                // Not `openNowPlaying` followed by `togglePlayback()`: the
                // load runs in a task, so the toggle used to arrive first and
                // fault the rail with "Audio route recovery failed." before the
                // window was even on screen.
                openNowPlaying(for: firstArticle, autoplay: true)
            }
        }
#else
        _ = arguments
#endif
        selectedNavigation = WiltedMacNavigation.restored(
            from: self.preferences.string(forKey: Self.selectedNavigationPreferenceKey)
        )
        if let stored = self.preferences.string(forKey: Self.larderSortPreferenceKey),
           let sort = WiltedMacLarderSort(rawValue: stored) {
            larderSort = sort
        } else if let stored = self.preferences.string(forKey: Self.libraryOrderPreferenceKey),
                  let order = WiltedMacLibraryOrder(rawValue: stored),
                  order == .oldest {
            // The retired preference is read once here, at the upgrade that
            // predates the richer queue sort control, and written forward under
            // the surviving key so this host never consults it again.
            larderSort = .oldest
            self.preferences.set(WiltedMacLarderSort.oldest.rawValue,
                                 forKey: Self.larderSortPreferenceKey)
        }
        if let stored = self.preferences.string(forKey: Self.menuSortPreferenceKey),
           let sort = WiltedMacMenuSort(rawValue: stored) {
            menuSort = sort
        }
        if let stored = self.preferences.string(forKey: Self.menuGroupingPreferenceKey),
           let grouping = WiltedMacMenuGrouping(rawValue: stored) {
            menuGrouping = grouping
        }
        preparationRequestSequence = self.preferences.integer(
            forKey: Self.preparationRequestSequencePreferenceKey
        )
        if self.preferences.object(forKey: Self.playbackRatePreferenceKey) != nil {
            playbackRate = Self.clampPlaybackRate(self.preferences.double(forKey: Self.playbackRatePreferenceKey))
        }
        marksRemovedAds = self.preferences.object(forKey: Self.marksRemovedAdsPreferenceKey) as? Bool ?? true
        // `installFixture` above seeds the deferral a fixture launch is meant
        // to show, and a fixture host has nothing stored under this key, so
        // reading the preference here would erase the seed before the first
        // render. `automationSettings` is read before the fixture install
        // instead, because the fixture builds its policy snapshot from it.
        if deferredAutomaticPreparations.isEmpty {
            deferredAutomaticPreparations = Self.loadDeferredAutomaticPreparations(from: self.preferences)
        }
        textScale = Self.loadTextScale(from: self.preferences)
#if canImport(WiltedProducer)
        // Fixture launches build their controller above, before the stored
        // rate is known; production builds it later, in
        // `configureStoreDependencies`, which reads the rate itself.
        playback?.defaultRate = Float(playbackRate)
#endif
        installRemoteCommands()
    }

#if canImport(WiltedProducer)
    /// Test seam: every bootstrap step as it is announced, so a test can
    /// assert the readout walks the awaited steps in order.
    var startupStepObserverForTesting: ((WiltedMacStartupStep) -> Void)?

#endif
    /// The selected Menu group filter, or nil for "All waiting".
    var menuFilter: WiltedMacMenuGroup?

    /// The Menu's search text. Every change reschedules the transcript
    /// search, which is the one part of matching that cannot be answered from
    /// what the list already carries.
    var librarySearchQuery = "" {
        didSet {
            guard librarySearchQuery != oldValue else { return }
            scheduleTranscriptSearch()
        }
    }

    /// Items whose stored transcript contains the current query. Empty until
    /// the store answers, so a row matching only in its transcript arrives a
    /// moment after the rows matching text the list already holds.
    var transcriptSearchMatches: Set<String> = []

    /// A search that reaches disk has to say so rather than let the list grow
    /// under the reader with no explanation (INV-1).
    var isSearchingTranscripts = false
    var transcriptSearchTask: Task<Void, Never>?

}
