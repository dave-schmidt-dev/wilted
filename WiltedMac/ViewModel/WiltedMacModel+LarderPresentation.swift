import Foundation
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// Larder and Feeds presentation state projections, the persisted-preference keys,
/// and the launch-time fixture install and stored-preference restore.
extension WiltedMacModel {
    /// The retired newest/oldest view of the Larder's order.
    ///
    /// `libraryOrder` used to be a second, independently persisted preference
    /// read by Larder bulk ordering and auto-advance, so those paths could order
    /// episodes differently from the Larder the listener was looking at. It is
    /// now a read/write projection of `feedsSort`, the one preference that
    /// orders the shelf: a caller that predates the richer control still works
    /// and can no longer disagree with it.
    var libraryOrder: WiltedMacLibraryOrder {
        get { feedsSort == .oldest ? .oldest : .newest }
        set { feedsSort = newValue == .oldest ? .oldest : .newest }
    }
    /// The retired `wilted.library.order` key. Read once during restore, only
    /// when no `wilted.queue.larder.sort` has been stored, and written forward
    /// through `feedsSort`'s own preference.
    static let libraryOrderPreferenceKey = "wilted.library.order"

    static let feedsSortPreferenceKey = "wilted.queue.larder.sort"
    static let larderSortPreferenceKey = "wilted.queue.menu.sort"
    static let larderSortDirectionPreferenceKey = "wilted.queue.menu.sort.direction"

    static let larderGroupingPreferenceKey = "wilted.queue.menu.grouping"
    static let larderKindPreferenceKey = "wilted.queue.menu.kind"
    static let marksRemovedAdsPreferenceKey = "wilted.playback.marksRemovedAds"
    static let podcastPlaybackOriginPreferenceKeyPrefix = "wilted.playback.origin."

    /// The selected destination. Persisted so a relaunch returns the reader to
    /// where they were; a stored retired name resolves through
    /// `WiltedMacNavigation.restored(from:)`.
    static let selectedNavigationPreferenceKey = "wilted.navigation.selected"
    /// The last speed the owner chose. It seeds every load that has no
    /// per-episode speed of its own, so 1.25× chosen once stays 1.25×.
    static let playbackRatePreferenceKey = "wilted.playback.rate"
    static let initialPlaybackRate = 1.25
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

    /// The selected Larder group filter, or nil for "All waiting".
    var larderFilter: WiltedMacLarderGroup? {
        get { navigationState.larderFilter.flatMap(WiltedMacLarderGroup.init(rawValue:)) }
        set { navigationState.larderFilter = newValue?.rawValue }
    }

    /// The Larder's search text. Every change reschedules the transcript
    /// search, which is the one part of matching that cannot be answered from
    /// what the list already carries.
    var librarySearchQuery: String {
        get { navigationState.librarySearchQuery }
        set {
            guard newValue != navigationState.librarySearchQuery else { return }
            navigationState.librarySearchQuery = newValue
            scheduleTranscriptSearch()
        }
    }

    /// Restores the stored Feeds sort, Larder sort, grouping and kind. Called once from `init`,
    /// in the order they were read inline.
    func restoreLarderPresentation() {
        if let stored = preferences.string(forKey: Self.feedsSortPreferenceKey),
           let sort = WiltedMacFeedsSort(rawValue: stored) {
            feedsSort = sort
        } else if let stored = preferences.string(forKey: Self.libraryOrderPreferenceKey),
                  let order = WiltedMacLibraryOrder(rawValue: stored),
                  order == .oldest {
            // The retired preference is read once here, at the upgrade that
            // predates the richer queue sort control, and written forward under
            // the surviving key so this host never consults it again.
            feedsSort = .oldest
            preferences.set(WiltedMacFeedsSort.oldest.rawValue,
                                forKey: Self.feedsSortPreferenceKey)
        }
        let storedLarderDirection = preferences.string(forKey: Self.larderSortDirectionPreferenceKey)
            .flatMap(WiltedMacLarderSortDirection.init(rawValue:))
        if let stored = preferences.string(forKey: Self.larderSortPreferenceKey),
           let (sort, migratedDirection) = WiltedMacLarderSort.restored(stored) {
            larderSort = sort
            larderSortDirection = migratedDirection ?? storedLarderDirection ?? .ascending
        } else if let direction = storedLarderDirection {
            larderSortDirection = direction
        }
        if let stored = preferences.string(forKey: Self.larderGroupingPreferenceKey),
           let grouping = WiltedMacLarderGrouping(rawValue: stored) {
            larderGrouping = grouping
        }
        if let stored = preferences.string(forKey: Self.larderKindPreferenceKey),
           let kind = WiltedMacLarderKind(rawValue: stored) {
            larderKind = kind
        }
    }

#if canImport(WiltedProducer)
    /// The fixture half of `init`: opens the fixture store and installs the scenario the launch
    /// arguments name. Runs before the stored preferences are restored.
    func launchFixture(arguments: [String], larderDemo: Bool) {
        let configuredStore = try? LocalLibraryStore(url: self.libraryURL)
        configureStoreDependencies(configuredStore)
        startupState = configuredStore == nil
            ? .failed(Self.startupFailure(canRetry: false))
            : .ready
        // Production starts this from bootstrap; fixtures do it here so
        // Settings settles instead of waiting on the card's `.task`.
        beginLifetimeStatisticsLoad()
        installFixture(
            ready: arguments.contains("--wilted-ui-fixture-ready") || arguments.contains("--wilted-ui-fixture-playing")
                || larderDemo,
            preparing: arguments.contains("--wilted-ui-fixture-preparing"),
            podcasts: arguments.contains("--wilted-ui-fixture-podcasts") || fixtureLarderDemo
        )
        if fixtureLarderDemo, let first = episodes.first { playEpisode(first) }
        if let scenario = WiltedMacLibrarySyncFixtureScenario.scenario(in: arguments) {
            installLibrarySyncFixture(scenario)
        }
        if arguments.contains("--wilted-ui-fixture-playing"), let firstArticle = articles.first(where: { $0.isReady }) {
            // Not `openNowPlaying` followed by `togglePlayback()`: the
            // load runs in a task, so the toggle used to arrive first and
            // fault the rail with "Audio route recovery failed." before the
            // window was even on screen.
            openNowPlaying(for: firstArticle, autoplay: true)
        }
    }
#endif

    /// Restores every stored preference `init` reads after the fixture install, in the order
    /// they were read inline.
    func restoreStoredPreferences() {
        selectedNavigation = WiltedMacNavigation.restored(
            from: preferences.string(forKey: Self.selectedNavigationPreferenceKey)
        )
        isSidebarVisible = preferences.object(forKey: Self.sidebarVisiblePreferenceKey) as? Bool ?? true
        restoreNavigationState()
        restoreLarderPresentation()
        preparationRequestSequence = preferences.integer(
            forKey: Self.preparationRequestSequencePreferenceKey
        )
        if preferences.object(forKey: Self.playbackRatePreferenceKey) != nil {
            playbackRate = Self.clampPlaybackRate(preferences.double(forKey: Self.playbackRatePreferenceKey))
        }
        marksRemovedAds = preferences.object(forKey: Self.marksRemovedAdsPreferenceKey) as? Bool ?? true
        // `installFixture` seeds the deferral a fixture launch is meant
        // to show, and a fixture host has nothing stored under this key, so
        // reading the preference here would erase the seed before the first
        // render. `automationSettings` is read before the fixture install
        // instead, because the fixture builds its policy snapshot from it.
        if deferredAutomaticPreparations.isEmpty {
            deferredAutomaticPreparations = Self.loadDeferredAutomaticPreparations(from: preferences)
        }
        textScale = Self.loadTextScale(from: preferences)
    }
}
