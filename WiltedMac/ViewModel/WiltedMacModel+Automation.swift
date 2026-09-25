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
    /// Whether these launch arguments drive the app from a fixture.
    ///
    /// Static because the decision is needed before a model exists: the app
    /// consults it to decide whether to hand over the machine's Now Playing
    /// widget and media keys, and a fixture run must not get them.
    static func isFixtureLaunch(arguments: [String]) -> Bool {
        arguments.contains("--wilted-ui-fixture-article-flow")
            || arguments.contains("--wilted-ui-fixture-quarantined")
            || arguments.contains("--wilted-ui-smoke")
            || arguments.contains("--wilted-ui-fixture-ready")
            || arguments.contains("--wilted-ui-fixture-playing")
            || arguments.contains("--wilted-ui-fixture-preparing")
            || arguments.contains("--wilted-ui-fixture-podcasts")
            || arguments.contains("--wilted-ui-fixture-download-failure")
            || arguments.contains("--wilted-ui-fixture-long-transcript")
    }

    /// Whether this process is running the unit tests.
    ///
    /// The unit-test host is the app bundle itself, so the model cannot tell a
    /// test run from a launch by argument alone; XCTest's own environment
    /// variable is the only thing that separates them.
    static var hostsTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

#if canImport(WiltedProducer)
    /// The audio backend this process should own.
    ///
    /// A UI fixture launch gets the scripted backend it has always had. A unit
    /// test host gets the real one with its output silenced, because the tests
    /// run inside this bundle and one that plays an episode plays it aloud on
    /// the owner's machine.
    static func playbackBackend(fixtureMode: Bool) -> any PlaybackBackend {
        if fixtureMode { return WiltedFixturePlaybackBackend() }
        if hostsTests { return WiltedSilentPlaybackBackend() }
        return AVAudioPlayerBackend()
    }
#endif

    static func clampPlaybackRate(_ value: Double) -> Double {
        min(max(value.isFinite ? value : initialPlaybackRate, 0.5), 2)
    }

    /// Stores only a complete, current settings envelope for a later automation coordinator.
    func setAutomationSettings(_ settings: WiltedAutomationSettings) {
        guard settings.isValid, let data = try? JSONEncoder().encode(settings) else { return }
        let previous = automationSettings
        automationSettings = settings
        preferences.set(data, forKey: Self.automationSettingsPreferenceKey)
        // Turning an override on acts on the Menu the reader is looking at,
        // through the same bulk admission the matching Menu button uses.
        // Without this the setting would only ever affect later arrivals.
        if settings.downloadEverythingOnMenu, !previous.downloadEverythingOnMenu {
            downloadAllAvailableMenuEpisodes()
        }
        if settings.prepareEverythingDownloaded, !previous.prepareEverythingDownloaded {
            prepareAllDownloadedMenuEpisodes()
        }
    }

    /// Settings always replaces the complete validated envelope. Work already
    /// admitted by automation owns its policy snapshot, so this is deliberately
    /// a preference for later work rather than a mutation of a queued job.
    func updateAutomationSettings(_ update: (WiltedAutomationSettings) -> WiltedAutomationSettings) {
        setAutomationSettings(update(automationSettings))
    }

    func setTextScale(_ scale: WiltedTheme.TextScale) {
        textScale = scale
        preferences.set(scale.rawValue, forKey: Self.textScalePreferenceKey)
    }

    /// An absent or unrecognised value takes the default rather than the
    /// smallest step, so a preference written by a later version that named a
    /// step this one does not know does not silently shrink the window.
    static func loadTextScale(from preferences: UserDefaults) -> WiltedTheme.TextScale {
        guard let raw = preferences.string(forKey: textScalePreferenceKey),
              let scale = WiltedTheme.TextScale(rawValue: raw) else { return .large }
        return scale
    }

    static func loadAutomationSettings(from preferences: UserDefaults) -> WiltedAutomationSettings {
        guard let data = preferences.data(forKey: automationSettingsPreferenceKey),
              let settings = try? JSONDecoder().decode(WiltedAutomationSettings.self, from: data),
              settings.isValid else {
            return .defaults
        }
        return settings
    }

    // MARK: - App-open automation

    var lastAutomationRefreshAt: Date? {
        preferences.object(forKey: Self.lastAutomationRefreshPreferenceKey) as? Date
    }

    /// The Feeds header's persisted success boundary. `nil` is intentionally
    /// presented as Never: cancellation and failure never write this value.
    var lastPodcastRefreshAt: Date? { lastAutomationRefreshAt }

    var lastPodcastRefreshText: String {
        guard let lastPodcastRefreshAt else { return "Never" }
        return lastPodcastRefreshAt.formatted(date: .abbreviated, time: .shortened)
    }

    func setLastAutomationRefresh(_ date: Date) {
        preferences.set(date, forKey: Self.lastAutomationRefreshPreferenceKey)
    }

    private func setAutomationStatus(_ status: WiltedAutomationStatus) {
        automationStatus = status
    }

    /// How often an open window re-evaluates the policy.
    ///
    /// Coarse on purpose: the evaluation is a pure function of settings and a
    /// stored timestamp, and this exists only so a window left open overnight
    /// still notices the next due refresh.
    static let automationTickInterval: TimeInterval = 900

    /// How often the ticket-drain tick evaluates admission for whatever
    /// non-terminal work tickets exist -- currently, off-peak-deferred
    /// automatic preparation. Shorter than `automationTickInterval` on
    /// purpose: this is the only evaluation left running while the window is
    /// hidden (see `startTicketDrainTicker`), so a window that opens and
    /// closes without ever coming to the foreground should not leave an
    /// eligible off-peak job waiting a full 15 minutes to be noticed.
    static let ticketDrainTickInterval: TimeInterval = 120

    /// How often playback progress is written to the store while audio runs.
    ///
    /// Progress was persisted only on an explicit transport press or a clean
    /// quit, so anything that ended the process without one -- an installer
    /// replacing the app, a force quit, a crash, a power loss -- rewound the
    /// listener to wherever they last pressed a button. Ten seconds bounds
    /// what such an exit can cost. It is a local store write, and only an
    /// article's checkpoint is queued for sync, so the tick does not touch
    /// CloudKit.
    static let playbackCheckpointInterval: TimeInterval = 10

    /// Resumes last session's claims, then evaluates this launch.
    ///
    /// Sequential, and started only once the library has loaded. The coordinator
    /// runs one pass at a time, so firing both concurrently would drop one, and
    /// resuming a claim before `episodes` is populated would fault every
    /// recovered download.
    func startAutomationOnLaunch() {
#if canImport(WiltedProducer)
        guard !fixtureMode, let coordinator = automationCoordinator() else { return }
        automationTask = Task {
            await coordinator.reconcile()
            await coordinator.run(trigger: .launch)
        }
#endif
    }

    /// Starts the open-window tick. Idempotent, so repeated scene callbacks are
    /// harmless.
    func startAutomationTicker(interval: TimeInterval = WiltedMacModel.automationTickInterval) {
#if canImport(WiltedProducer)
        guard !fixtureMode, automationTicker == nil, store != nil else { return }
        automationTicker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                self?.startEligibleAutomaticPreparations()
                self?.runAutomation(trigger: .openWindowTick)
            }
        }
#endif
    }

    func stopAutomationTicker() {
#if canImport(WiltedProducer)
        automationTicker?.cancel()
        automationTicker = nil
#endif
    }

    /// Whether the open-window tick is live. Read by tests, because the scene
    /// stops the ticker when the app is hidden and has to start it again on the
    /// way back, and nothing else makes that visible.
    var automationTickerIsRunning: Bool {
#if canImport(WiltedProducer)
        automationTicker != nil
#else
        false
#endif
    }

    /// Starts the ticket-drain tick. Idempotent, like the other tickers.
    ///
    /// `checkpointForBackground` stops `automationTicker` (the open-window
    /// tick) when the window is hidden, but download bytes are not stopped
    /// with it -- their `Task`s keep running, so bytes already keep growing
    /// while hidden. Admission did not have the same guarantee: nothing
    /// re-evaluated an off-peak window opening while hidden, because the only
    /// ticker that did so was the one `checkpointForBackground` stops. This
    /// ticker is that missing evaluation, kept deliberately separate from
    /// `automationTicker` rather than folded into it, and deliberately never
    /// stopped by `checkpointForBackground` -- only by actual termination
    /// (`pauseForQuit`), the one moment stopping every ticker is correct.
    ///
    /// A tick with no non-terminal ticket in the store is a no-op: there is
    /// nothing to admit, so `startEligibleAutomaticPreparations` is not even
    /// called.
    func startTicketDrainTicker(interval: TimeInterval = WiltedMacModel.ticketDrainTickInterval) {
#if canImport(WiltedProducer)
        guard !fixtureMode, ticketDrainTicker == nil, store != nil else { return }
        ticketDrainTicker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard let self else { return }
                guard await self.hasNonTerminalWorkTicket() else { continue }
                self.startEligibleAutomaticPreparations()
            }
        }
#endif
    }

    func stopTicketDrainTicker() {
#if canImport(WiltedProducer)
        ticketDrainTicker?.cancel()
        ticketDrainTicker = nil
#endif
    }

    /// Read by tests: the one thing distinguishing "hidden and still
    /// draining" from "hidden and stalled."
    var ticketDrainTickerIsRunning: Bool {
#if canImport(WiltedProducer)
        ticketDrainTicker != nil
#else
        false
#endif
    }

#if canImport(WiltedProducer)
    private func hasNonTerminalWorkTicket() async -> Bool {
        guard let store else { return false }
        guard let tickets = try? await store.workTickets() else { return false }
        return tickets.contains { !$0.state.isTerminal }
    }
#endif

    /// Starts the playback progress tick. Idempotent.
    ///
    /// Deliberately not stopped when the app loses focus, unlike the
    /// automation tick: audio keeps running with the window closed, and that
    /// is precisely when nothing else is checkpointing.
    func startPlaybackCheckpointTicker(interval: TimeInterval = WiltedMacModel.playbackCheckpointInterval) {
#if canImport(WiltedProducer)
        guard !fixtureMode, playbackCheckpointTicker == nil, store != nil else { return }
        playbackCheckpointTicker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                await self?.checkpointPlaybackIfAdvancing()
            }
        }
#endif
    }

    func stopPlaybackCheckpointTicker() {
#if canImport(WiltedProducer)
        playbackCheckpointTicker?.cancel()
        playbackCheckpointTicker = nil
#endif
    }

    var playbackCheckpointTickerIsRunning: Bool {
#if canImport(WiltedProducer)
        playbackCheckpointTicker != nil
#else
        false
#endif
    }

    /// One tick. Writes only while the engine is actually advancing, so a
    /// paused or finished item does not rewrite the same row every interval.
    func checkpointPlaybackIfAdvancing() async {
#if canImport(WiltedProducer)
        guard let playback, playback.liveIsPlaying else { return }
        do {
            try await playback.checkpoint()
            await refreshLifetimeStatistics()
        } catch { /* a later checkpoint remains available */ }
#endif
    }

    /// Evaluates the automation policy and runs one pass if it is due.
    ///
    /// Called when the window opens and on the open-window tick. Both go through
    /// the same coordinator, so the policy is decided in one place rather than
    /// at each call site.
    func runAutomation(trigger: WiltedAutomationTrigger) {
#if canImport(WiltedProducer)
        guard !fixtureMode, let coordinator = automationCoordinator() else { return }
        automationTask = Task { await coordinator.run(trigger: trigger) }
#endif
    }

    /// Resumes claims that outlived the process that made them.
    func reconcileAutomation() {
#if canImport(WiltedProducer)
        guard !fixtureMode, let coordinator = automationCoordinator() else { return }
        automationTask = Task { await coordinator.reconcile() }
#endif
    }

    /// Stops the pass in flight. Claims stay durable and the next launch
    /// reconciles them, so stopping loses no eligibility.
    func cancelAutomation() {
#if canImport(WiltedProducer)
        let coordinator = automation
        automationTask?.cancel()
        automationTask = nil
        Task { await coordinator?.cancel() }
        automationStatus = .cancelled
#endif
    }

    /// Deterministic test seam; production does not wait on this task.
    func waitForAutomation() async {
#if canImport(WiltedProducer)
        await automationTask?.value
#endif
    }

#if canImport(WiltedProducer)
    private func automationCoordinator() -> WiltedAutomationCoordinator? {
        if let automation { return automation }
        guard store != nil else { return nil }
        let coordinator = WiltedAutomationCoordinator(
            operations: .init(
                enabledFeedURLs: { [weak self] in
                    guard let self else { return [] }
                    return try await self.automationFeedURLs()
                },
                refreshFeed: { [weak self] url, limit in
                    guard let self else { return [] }
                    return try await self.automaticRefresh(url, claimingNewest: limit)
                },
                startDownload: { [weak self] episodeID in
                    guard let self else { return }
                    try await self.startClaimedDownload(episodeID)
                },
                unfinishedClaims: { [weak self] in
                    guard let self else { return [] }
                    return try await self.unfinishedAutomationClaims()
                }
            ),
            settings: { [weak self] in await self?.automationSettings ?? .defaults },
            lastRefreshSuccess: { [weak self] in await self?.lastAutomationRefreshAt },
            recordRefreshSuccess: { [weak self] date in await self?.setLastAutomationRefresh(date) },
            report: { [weak self] status in await self?.setAutomationStatus(status) }
        )
        automation = coordinator
        return coordinator
    }

    private func automationFeedURLs() async throws -> [URL] {
        guard let store else { throw CancellationError() }
        var urls: [URL] = []
        for subscription in try await store.subscriptions().filter(\.enabled) {
            if let url = try await store.podcastFeed(for: subscription.feedID)?.canonicalURL {
                urls.append(url)
            }
        }
        return urls
    }

    func unfinishedAutomationClaims() async throws -> [String] {
        guard let store else { throw CancellationError() }
        let unfinished = try await store.unfinishedPodcastDownloads().map(\.episodeID.rawValue)
        // `.queued`/`.downloading` (unfinished) and `.failed`/`.retryable`
        // (resumable) are disjoint statuses, but a `Set` costs nothing and
        // means a future status change here can't silently double-claim.
        let resumable = try await store.resumablePodcastDownloads().map(\.episodeID.rawValue)
        return Self.keptDownloadClaims(Set(unfinished + resumable), queueIDs: podcastQueueIDs)
    }

    /// Only Keep grants authority to resume a durable download claim. This
    /// leaves claims created by the retired automatic-download policy inert
    /// while still recovering an interrupted download for a Larder episode.
    static func keptDownloadClaims(_ claims: Set<String>, queueIDs: [String]) -> [String] {
        let kept = Set(queueIDs)
        return claims.filter(kept.contains).sorted()
    }

    /// Refreshes one feed and saves only its metadata. This deliberately uses
    /// the non-claiming store path: automated refresh has no authority to turn
    /// an undecided Feeds episode into download or preparation work.
    private func automaticRefresh(_ url: URL, claimingNewest limit: Int) async throws -> [String] {
        guard let store else { throw CancellationError() }
        let loaded = try await podcastFeedClient.load(url)
        try await store.save(feed: loaded.feed)
        _ = try await store.savePodcastEpisodes(loaded.episodes, admission: .incremental)
        let values = try await loadLibrary(from: store)
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
        dismissedEpisodes = try await loadDismissedEpisodes(from: store)
        _ = limit // Kept for coordinator ABI compatibility; always zero by policy.
        return []
    }

    /// Wraps a terminal (or cancelled/not-found) download failure so
    /// `withRetries` never retries it and `drain` treats it as one claim
    /// done, not the automation pass stopping. `underlying` is kept for
    /// whatever wants the original reason; nothing on the automation path
    /// currently reads it.
    struct WiltedAutomationNonRetryableDownloadFailure: Error, WiltedAutomationNonRetryable {
        let underlying: PodcastDownloadCoordinatorError
    }

#endif
}
