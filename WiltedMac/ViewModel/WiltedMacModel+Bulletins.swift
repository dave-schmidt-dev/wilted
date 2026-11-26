import Foundation
import Observation
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import WiltedWeather

private let bulletinLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "Bulletins")
private nonisolated(unsafe) var bulletinHubKey: UInt8 = 0

/// Owns what Reports needs beyond the settings file: the location provider, and the
/// `BulletinProducer` that publishes the interruption switches and news headlines.
///
/// The producer runs while interruptions are on, and until the channel it last published is back
/// to all-off, so turning them off reaches the phones. A Mac that never turned them on does no work.
/// Nothing starts for a fixture launch, without a store, or while the model is closing.
///
/// It also feeds this Mac's player: with interruptions on it turns on the controller's spoken
/// interruptions, hands it the producer's headlines in process (not round-tripped through the
/// transport), and runs an `AlertMonitor` at this Mac's own location, but only while playing with
/// alerts on.
@MainActor
@Observable
final class WiltedMacBulletinHub {
    /// Whether the channel last published (or read back) had a switch on. Survives relaunch, so a
    /// Mac that was quit with interruptions on and failed to publish the off state still retries it.
    static let activePreferenceKey = "wilted.bulletins.publishedActive"
    private static let featuredHeadlinePreferenceKey = "wilted.bulletins.featuredHeadlineStoryID"

    /// The latest poll result, for Settings.
    private(set) var status = BulletinProducerStatus()
    private var lastFailure: MacAudioRouteFailureStep?
    var routeProtectionStatus: String? { lastFailure == nil ? nil : Self.unavailableRouteMessage }
    private(set) var hasNewsSource = false
    private(set) var hasCheckedNewsSource = false
    private(set) var isCheckingNewsSource = false
    /// The last headline actually started by this Mac's speaker. The player keeps its matching
    /// story card selected after speech ends, even when a newer feed item arrives.
    private(set) var featuredHeadlineStoryID: String?
    /// The last weather alert that actually started speaking, retained after Now Playing clears it.
    private(set) var lastSpokenWeatherAlert: Bulletin?
    @ObservationIgnored private var newsReadinessRequest = 0
    @ObservationIgnored private weak var newsReadinessStore: LocalLibraryStore?
    @ObservationIgnored private var knownNewsFeedIDs: Set<String> = []
    @ObservationIgnored private var testBulletinSpeaker: (any BulletinSpeaking)?

    @ObservationIgnored private let heardHistory: HeardHeadlineHistory
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private weak var model: WiltedMacModel?
    @ObservationIgnored private var ownedLocation: WiltedLocationProvider?
    @ObservationIgnored private let producerFactory: (@MainActor () -> BulletinProducer)?
    @ObservationIgnored private var producer: BulletinProducer?
    @ObservationIgnored private let makeRouteSource: @MainActor () -> any MacAudioRouteSource
    @ObservationIgnored private let makeSpeaker: (@MainActor () -> any BulletinSpeaking)?
    @ObservationIgnored private let makeHeadlineNarration: @MainActor () -> WiltedMacHeadlineNarration
    @ObservationIgnored private let makeHeadlineAudioPlayer: @MainActor () -> any WiltedMacHeadlineAudioPlaying
    @ObservationIgnored private let renderShortTextNarration: WiltedMacHeadlineBulletinSpeaker.ShortTextNarration
    @ObservationIgnored private let makeWeatherAlertNarration: @MainActor () -> WiltedMacWeatherAlertNarration
    @ObservationIgnored private let makeAlertSource: @MainActor (String?) -> any NWSAlertSource
    @ObservationIgnored private weak var attachedController: PlaybackController?
    @ObservationIgnored private let retrySleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryIndex = 0
    @ObservationIgnored private weak var lastController: PlaybackController?
    @ObservationIgnored private var wasPlaying = false
    @ObservationIgnored private var alertMonitor: AlertMonitor?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var didLoadInitialChannel = false
    @ObservationIgnored private var headlineNarration: WiltedMacHeadlineNarration?
    @ObservationIgnored private var weatherAlertNarration: WiltedMacWeatherAlertNarration?
    /// The headlines of the channel as last published or read back, while headlines are on.
    @ObservationIgnored private(set) var headlines: [Bulletin] = []
    /// Alerts the monitor delivered that are still active here.
    @ObservationIgnored private(set) var activeAlerts: [String: Bulletin] = [:]

    init(model: WiltedMacModel, location: WiltedLocationProvider? = nil,
         makeSpeaker: (@MainActor () -> any BulletinSpeaking)? = nil,
         makeRouteSource: @escaping @MainActor () -> any MacAudioRouteSource = { MacAudioRouteLossObserver() },
         makeAlertSource: @escaping @MainActor (String?) -> any NWSAlertSource = WiltedMacBulletinHub.nwsClient,
         retrySleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() },
         producerFactory: (@MainActor () -> BulletinProducer)? = nil,
         makeHeadlineNarration: @escaping @MainActor () -> WiltedMacHeadlineNarration = { WiltedMacHeadlineNarration() },
         makeHeadlineAudioPlayer: @escaping @MainActor () -> any WiltedMacHeadlineAudioPlaying = { WiltedMacAVHeadlineAudioPlayer() },
         renderShortTextNarration: @escaping WiltedMacHeadlineBulletinSpeaker.ShortTextNarration = { text, voiceID, outputURL in
             try await ArticleNarrationCoordinator().synthesizeShortText(
                 text, voiceID: voiceID, outputURL: outputURL)
         }, makeWeatherAlertNarration: @escaping @MainActor () -> WiltedMacWeatherAlertNarration = {
             WiltedMacWeatherAlertNarration()
         }) {
        self.producerFactory = producerFactory
        self.now = now
        self.heardHistory = HeardHeadlineHistory(defaults: model.preferences, now: now())
        self.retrySleep = retrySleep
        self.model = model
        featuredHeadlineStoryID = model.preferences.string(forKey: Self.featuredHeadlinePreferenceKey)
        ownedLocation = location
        self.makeRouteSource = makeRouteSource
        self.makeSpeaker = makeSpeaker
        self.makeHeadlineNarration = makeHeadlineNarration
        self.makeHeadlineAudioPlayer = makeHeadlineAudioPlayer
        self.renderShortTextNarration = renderShortTextNarration
        self.makeWeatherAlertNarration = makeWeatherAlertNarration
        self.makeAlertSource = makeAlertSource
    }

    private var narration: WiltedMacHeadlineNarration {
        if let headlineNarration { return headlineNarration }
        let value = makeHeadlineNarration()
        value.onReady = { [weak self] _ in self?.syncPlayer() }
        headlineNarration = value
        return value
    }

    private var weatherNarration: WiltedMacWeatherAlertNarration {
        if let weatherAlertNarration { return weatherAlertNarration }
        let value = makeWeatherAlertNarration()
        value.onReady = { [weak self] _ in self?.syncPlayer() }
        value.onChanged = { [weak self] in self?.syncPlayer() }
        weatherAlertNarration = value
        return value
    }

    var latestHeadlineNarrationStoryID: String? { narration.latestCandidateStoryID }

    /// Returns only a bulletin this Mac currently owns; weather text is never requested from or
    /// uploaded by the phone.
    func localBulletin(id: String) -> Bulletin? {
        if let bulletin = (headlines + Array(activeAlerts.values)).first(where: { $0.id == id }) {
            return bulletin
        }
        return LibraryBulletinAudioTestSample.make(id: id, at: now())
    }

    /// Uses the exact local asset already prepared for the active bulletin and selected voice.
    func narrationAudioURL(for bulletin: Bulletin) -> URL? {
        if bulletin.kind == .headline {
            return narration.audioURL(for: bulletin, accountIdentity: approvedPublicationOwner)
        }
        return weatherAlertNarration?.audioURL(for: bulletin)
    }

    func headlineNarrationState(for storyID: String) -> WiltedMacHeadlineNarrationState {
        narration.state(for: storyID)
    }

    func readingVoiceSelectionChanged() {
        refreshHeadlineNarration(newlyPublished: [])
        refreshWeatherAlertNarration()
        syncPlayer()
    }

    deinit {
        retryTask?.cancel()
        if let producer { Task { await producer.stop() } }
        if let alertMonitor { Task { await alertMonitor.stop() } }
    }

    private static func nwsClient(contact: String?) -> any NWSAlertSource {
        NWSClient(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            repositoryURL: "https://github.com/dave-schmidt-dev/wilted", contact: contact)
    }

    /// The one location provider on this Mac, created on first use. Settings reads it; it is
    /// started in `reconcile` once interruptions or the daily report are on.
    var location: WiltedLocationProvider {
        if let ownedLocation { return ownedLocation }
        let provider = WiltedLocationProvider(manager: WiltedCoreLocationManager(), wifi: WiltedCoreWLANPower())
        ownedLocation = provider
        return provider
    }

    var producerIsRunning: Bool { producer != nil }
    var alertMonitorIsRunning: Bool { alertMonitor != nil }
    var interruptionsAreAttached: Bool { attachedController != nil }
    var testBulletinIsActive: Bool { testBulletinSpeaker != nil }

    /// The current setup lines for the selected bulletin types.
    var readiness: BulletinReadiness {
        let settings = model?.automationSettings
        let location = self.location
        return BulletinReadiness(
            hasNewsSource: hasNewsSource,
            hasWeatherLocation: location.coordinates != nil,
            soundCheckPaused: lastFailure != nil,
            headlinesEnabled: settings?.headlinesEnabled ?? true,
            alertsEnabled: settings?.alertsEnabled ?? true,
            newsCheck: hasCheckedNewsSource ? .checked : (isCheckingNewsSource ? .checking : .unavailable),
            locationAccessDenied: location.authorization == .denied && location.coordinates == nil)
    }

    /// Checks the actual followed article feeds and their saved News choices.
    /// A failed read keeps the last known result instead of claiming no source exists.
    func refreshNewsSourceReadiness() async {
        newsReadinessRequest &+= 1
        let request = newsReadinessRequest
        guard let model, let store = model.store else {
            hasNewsSource = false
            hasCheckedNewsSource = false
            isCheckingNewsSource = false
            newsReadinessStore = nil
            knownNewsFeedIDs = []
            return
        }
        isCheckingNewsSource = true
        defer {
            if request == newsReadinessRequest { isCheckingNewsSource = false }
        }
        do {
            let feeds = try await NewsHeadlineCandidateReader.headlineFeeds(in: store)
            let feedIDs = Set(feeds.map { $0.itemID.rawValue })
            guard request == newsReadinessRequest, model.store === store else { return }
            let sourceListChanged = knownNewsFeedIDs != feedIDs
            knownNewsFeedIDs = feedIDs
            newsReadinessStore = store
            hasNewsSource = !feedIDs.isEmpty
            hasCheckedNewsSource = true
            let wasProducerRunning = producer != nil
            reconcile()
            if sourceListChanged, wasProducerRunning, let producer { Task { await producer.sourcesChanged() } }
        } catch {
            guard request == newsReadinessRequest else { return }
            hasCheckedNewsSource = false
        }
    }

    /// Immediately retries the check that paused bulletins after a sound-output failure.
    func retryBulletinOutputCheck() {
        guard let model, lastFailure != nil else { return }
        reconcileInterruptions(canRun: canRun, settings: model.automationSettings, retryDue: true)
    }

    /// Speaks a short sample through the bulletin speaker without involving playback.
    @discardableResult
    func playTestBulletin() -> Bool {
        testBulletinSpeaker?.stop()
        let speaker = makeSpeaker?() ?? makeInterruptionSpeaker()
        testBulletinSpeaker = speaker
        let playbackVolume = model?.playback?.backend.volume ?? Float(model?.playbackVolume ?? 1)
        let started = speaker.speak(Self.testBulletinText, playbackVolume: playbackVolume) { [weak self, weak speaker] in
            guard let self, self.testBulletinSpeaker === speaker else { return }
            self.testBulletinSpeaker = nil
        }
        if !started { testBulletinSpeaker = nil }
        return started
    }

    static let testBulletinText = "This is a test bulletin."

    private var canRun: Bool {
        guard let model else { return false }
        return model.store != nil && !model.fixtureMode && !model.isClosingTemporaryState
    }

    /// Starts, nudges or stops the producer to match the settings. Safe to call at any time.
    func reconcile() {
        guard let model else { return }
        let settings = model.automationSettings
        let canRun = self.canRun
        refreshHeadlineNarration(newlyPublished: [], enabled: canRun)
        if canRun { scheduleNewsSourceReadinessRefreshIfNeeded() }
        // The morning report needs a location too, even with interruptions off.
        if canRun, settings.interruptionsEnabled || settings.reportEnabled {
            let provider = location
            provider.typedCoordinates = settings.typedCoordinates
            provider.start()
        }
        let wanted = canRun && (settings.interruptionsEnabled || hasNewsSource
            || model.preferences.bool(forKey: Self.activePreferenceKey))
        if wanted {
            if let producer {
                Task { await producer.settingsChanged() }
            } else {
                let made = producerFactory?() ?? makeProducer()
                producer = made
                Task { await made.start() }
            }
        } else if let producer {
            self.producer = nil
            Task { await producer.stop() }
            status = BulletinProducerStatus()
        }
        reconcileInterruptions(canRun: canRun, settings: settings, retryDue: false)
    }

    /// Rechecks the conditions when the scheduled task runs, since an explicit read may finish
    /// after this task is queued but before it starts.
    private func scheduleNewsSourceReadinessRefreshIfNeeded() {
        guard let model, canRun, let store = model.store,
              (!hasCheckedNewsSource || newsReadinessStore !== store), !isCheckingNewsSource else { return }
        Task { @MainActor [weak self] in
            guard let self, let model = self.model, self.canRun, let store = model.store,
                  (!self.hasCheckedNewsSource || self.newsReadinessStore !== store),
                  !self.isCheckingNewsSource else { return }
            await self.refreshNewsSourceReadiness()
        }
    }

    private func makeProducer() -> BulletinProducer {
        makeProducer(
            newsItems: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.newsCandidates()
            },
            fetchPublished: { [weak self] in
                guard let self else { throw CancellationError() }
                let channel = try await self.publisher().fetchBulletins()
                await self.channelUpdated(channel)
                return channel
            },
            publish: { [weak self] bulletins in
                guard let self else { throw CancellationError() }
                try await self.publisher().publishBulletins(bulletins)
                await self.channelUpdated(bulletins)
            },
            onCandidates: { [weak self] candidates in
                guard let self else { throw CancellationError() }
                try await MainActor.run {
                    guard let model = self.model else { throw CancellationError() }
                    try model.headlineCatalogState.mergeCandidates(candidates, at: self.now())
                }
            })
    }

    func makeProducer(
        newsItems: @escaping @Sendable () async throws -> [NewsHeadlineCandidate],
        fetchPublished: @escaping @Sendable () async throws -> LibraryBulletins?,
        publish: @escaping @Sendable (LibraryBulletins) async throws -> Void,
        onCandidates: @escaping @Sendable ([NewsHeadlineCandidate]) async throws -> Void = { _ in }
    ) -> BulletinProducer {
        BulletinProducer(
            settings: { [weak self] in
                await MainActor.run { self?.currentSettings ?? Self.allOff }
            }, newsItems: newsItems, onCandidates: onCandidates,
            fetchPublished: fetchPublished, publish: publish,
            onStatus: { [weak self] status in
                Task { @MainActor in self?.apply(status) }
            }, now: now, heardHeadlines: { [heardHistory, now] in
                await heardHistory.snapshot(at: now())
            })
    }

    private static let allOff = BulletinProducerSettings(
        interruptionsEnabled: false, alertsEnabled: false, headlinesEnabled: false)

    private var currentSettings: BulletinProducerSettings {
        guard let model else { return Self.allOff }
        let settings = model.automationSettings
        return BulletinProducerSettings(
            interruptionsEnabled: settings.interruptionsEnabled, alertsEnabled: settings.alertsEnabled,
            headlinesEnabled: settings.headlinesEnabled,
            publishedActive: model.preferences.bool(forKey: Self.activePreferenceKey),
            topics: HeadlineTopicFilter(skipSports: settings.skipSportsHeadlines, words: settings.skippedHeadlineWords))
    }

    /// The running library publisher, whose transport holds the account gate and the rate limit.
    private func publisher() throws -> WiltedMacLibraryPublisher {
        guard let model, !model.isClosingTemporaryState else { throw CancellationError() }
        guard let controller = model.librarySyncController else {
            throw BulletinProducerUnavailable(reason: "Library sync is not running")
        }
        return controller.publisher
    }

    /// The posts of every followed article feed marked as news. A feed that fails is skipped; the
    /// poll fails only when every feed did.
    private func newsCandidates() async throws -> [NewsHeadlineCandidate] {
        guard let model, let store = model.store else { throw CancellationError() }
        let candidates = try await NewsHeadlineCandidateReader.read(in: store, using: model.podcastFeedClient).candidates
        let projection = try model.headlineCatalogStore.projection(at: now())
        let mutedPublisherIDs = Set(projection.publishers.filter(\.isMuted).map(\.id))
        return candidates.filter { candidate in
            guard let publisherID = candidate.feedID else { return true }
            return !mutedPublisherIDs.contains(publisherID)
        }
    }

    func publisherMuteChanged(_ publisherID: String) {
        headlines.removeAll { $0.publisherID == publisherID }
        refreshHeadlineNarration(newlyPublished: [])
        syncPlayer()
        guard let producer else { return }
        Task { await producer.publisherMuted(publisherID) }
    }

    // MARK: - Spoken interruptions

    /// Attaches or detaches the player and the alert monitor to match settings, playback and location.
    private func reconcileInterruptions(canRun: Bool, settings: WiltedAutomationSettings, retryDue: Bool) {
        let wantsSpeech = canRun && settings.interruptionsEnabled
        let controller = wantsSpeech ? model?.playback : nil
        if let attached = attachedController, attached !== controller {
            attached.disableInterruptions(resuming: canRun)
            attachedController = nil
        }
        let playing = model?.isPlaying == true
        let retryTriggered = retryDue || controller !== lastController || (playing && !wasPlaying)
        lastController = controller
        wasPlaying = playing
        if let controller, attachedController == nil, lastFailure == nil || retryTriggered {
            let source = makeRouteSource()
            if controller.enableInterruptions(
                speaker: makeInterruptionSpeaker(), routeSource: source,
                spokenHeadlineExpiries: heardHistory.snapshot(at: now()).expiries,
                shouldSpeakHeadline: { [weak self, heardHistory, now] headline in
                    let time = now()
                    guard heardHistory.snapshot(at: time).allows(
                        id: headline.id, title: BulletinProducer.headlineTitle(of: headline.text), at: time),
                          let self else { return false }
                    return self.canSpeakHeadline(headline)
                },
                didStartHeadline: { [weak self, heardHistory, now] headline in
                    heardHistory.record(id: headline.id, title: BulletinProducer.headlineTitle(of: headline.text), at: now())
                    guard let self, let storyID = self.storyID(for: headline) else { return }
                    self.narration.didStart(headline)
                    self.featuredHeadlineStoryID = storyID
                    self.model?.preferences.set(storyID, forKey: Self.featuredHeadlinePreferenceKey)
                },
                now: now, protectionFailed: { [weak self] in
                    self?.protectionFailed(at: source.failureStep ?? .defaultOutputRead)
                }) {
                if let lastFailure {
                    bulletinLog.info("Bulletin output monitoring recovered after \(lastFailure.rawValue, privacy: .public)")
                }
                clearFailure()
                attachedController = controller
                syncPlayer()
            } else {
                protectionFailed(at: source.failureStep ?? .registration)
            }
        }
        if !wantsSpeech { clearFailure() }
        if wantsSpeech, settings.alertsEnabled, attachedController != nil, playing {
            startAlerts(contact: settings.nwsContact)
        } else {
            stopAlerts()
        }
        if wantsSpeech { observeChanges() }
    }

    func makeInterruptionSpeaker() -> any BulletinSpeaking {
        let speaker: any BulletinSpeaking
        if let makeSpeaker {
            speaker = makeSpeaker()
        } else {
            speaker = WiltedMacHeadlineBulletinSpeaker(
                audioURL: { [weak self] bulletin in
                    guard let self else { return nil }
                    if bulletin.kind == .headline {
                        return self.narration.audioURL(for: bulletin, accountIdentity: self.approvedPublicationOwner)
                    }
                    return self.weatherAlertNarration?.audioURL(for: bulletin)
                }, audioPlayer: makeHeadlineAudioPlayer(),
                selectedVoice: { [weak self] in self?.model?.readingVoiceSelection.selectedVoice },
                renderShortText: renderShortTextNarration)
        }
        return WiltedMacRememberingWeatherAlertSpeaker(base: speaker) { [weak self] alert in
            self?.lastSpokenWeatherAlert = alert
        }
    }

    private func refreshWeatherAlertNarration() {
        let settings = model?.automationSettings
        let enabled = alertMonitor != nil && model?.isPlaying == true
            && settings?.interruptionsEnabled == true && settings?.alertsEnabled == true
        guard alertMonitor != nil || weatherAlertNarration != nil else { return }
        weatherNarration.update(
            current: Array(activeAlerts.values), enabled: enabled,
            selectedVoice: model?.readingVoiceSelection.selectedVoice)
    }

    private var approvedPublicationOwner: String? {
        model?.librarySyncController?.account?.approvedPublicationOwner
    }

    private func isEligibleHeadline(_ bulletin: Bulletin) -> Bool {
        let time = now()
        guard let model, bulletin.kind == .headline, let storyID = bulletin.headlineStoryID,
              bulletin.id == "headline:\(storyID)", bulletin.expiresAt > time,
              heardHistory.snapshot(at: time).allows(
                id: bulletin.id, title: BulletinProducer.headlineTitle(of: bulletin.text), at: time),
              model.automationSettings.interruptionsEnabled,
              model.automationSettings.headlinesEnabled,
              let projection = try? model.headlineCatalogStore.projection(at: time),
              let story = (projection.recent + projection.saved).first(where: { $0.id == storyID }),
              story.publisherID == bulletin.publisherID,
              story.title == (bulletin.headline ?? BulletinProducer.headlineTitle(of: bulletin.text)),
              story.link == bulletin.link,
              !projection.publishers.contains(where: { $0.id == story.publisherID && $0.isMuted }) else { return false }
        let settings = model.automationSettings
        return !HeadlineTopicFilter(skipSports: settings.skipSportsHeadlines, words: settings.skippedHeadlineWords)
            .skips(title: story.title, link: story.link)
    }

    private func canSpeakHeadline(_ bulletin: Bulletin) -> Bool {
        guard let model, bulletin.kind == .headline,
              bulletin.expiresAt > now(), model.automationSettings.interruptionsEnabled,
              model.automationSettings.headlinesEnabled else { return false }
        return isEligibleHeadline(bulletin)
            && narration.audioURL(for: bulletin, accountIdentity: approvedPublicationOwner) != nil
    }

    private func storyID(for bulletin: Bulletin) -> String? {
        if let storyID = bulletin.headlineStoryID { return storyID }
        guard bulletin.kind == .headline,
              let range = bulletin.id.range(of: "headline:", options: .anchored) else { return nil }
        let storyID = String(bulletin.id[range.upperBound...])
        return storyID.isEmpty ? nil : storyID
    }

    private func refreshHeadlineNarration(newlyPublished: [Bulletin], enabled override: Bool? = nil) {
        let settings = model?.automationSettings
        let enabled = (override ?? canRun) && settings?.interruptionsEnabled == true && settings?.headlinesEnabled == true
        narration.update(
            current: headlines, newlyPublished: newlyPublished, enabled: enabled,
            selectedVoice: model?.readingVoiceSelection.selectedVoice,
            accountIdentity: approvedPublicationOwner,
            isEligible: { [weak self] bulletin in self?.isEligibleHeadline(bulletin) ?? false })
    }

    static let unavailableRouteMessage = BulletinReadiness.Line.sound.text

    private func protectionFailed(at step: MacAudioRouteFailureStep) {
        bulletinLog.error("Bulletin output monitoring failed at \(step.rawValue, privacy: .public)")
        lastFailure = step
        attachedController = nil
        stopAlerts()
        guard retryTask == nil else { return }
        let delays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]
        let delay = delays[retryIndex]
        retryIndex = min(retryIndex + 1, delays.count - 1)
        retryTask = Task { @MainActor [weak self, retrySleep] in
            do { try await retrySleep(delay) } catch { return }
            guard !Task.isCancelled, let self, let model = self.model else { return }
            self.retryTask = nil
            self.reconcileInterruptions(canRun: self.canRun, settings: model.automationSettings, retryDue: true)
        }
    }

    private func clearFailure() {
        retryTask?.cancel()
        retryTask = nil
        retryIndex = 0
        lastFailure = nil
    }

    /// Close and quit cut held speech without the settings toggle's resume behavior.
    func shutdown() {
        clearFailure()
        headlineNarration?.shutdown()
        headlineNarration = nil
        weatherAlertNarration?.shutdown()
        weatherAlertNarration = nil
        testBulletinSpeaker?.stop()
        testBulletinSpeaker = nil
        attachedController?.disableInterruptions(resuming: false)
        attachedController = nil
        stopAlerts()
        if let producer {
            self.producer = nil
            Task { await producer.stop() }
        }
    }

    /// Re-reconciles when playback starts or stops, the player is replaced, or the location moves.
    private func observeChanges() {
        guard !observing, let model else { return }
        observing = true
        let location = location
        withObservationTracking {
            _ = model.isPlaying
            _ = model.playback
            _ = model.libraryAccountStatus
            _ = location.coordinates
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observing = false
                self?.reconcile()
            }
        }
    }

    private func startAlerts(contact: String?) {
        let monitor: AlertMonitor
        if let alertMonitor {
            monitor = alertMonitor
        } else {
            monitor = AlertMonitor(
                source: makeAlertSource(contact),
                deliver: { [weak self] bulletin in Task { @MainActor in self?.receive(alert: bulletin) } },
                onStatus: { [weak self] _ in Task { @MainActor in await self?.dropEndedAlerts() } })
            alertMonitor = monitor
        }
        let coordinates = location.coordinates
        Task {
            if let coordinates {
                await monitor.setCoordinates(lat: coordinates.latitude, lon: coordinates.longitude)
            } else {
                await monitor.clearCoordinates()
            }
            await monitor.start()
        }
    }

    private func stopAlerts() {
        let monitor = alertMonitor
        alertMonitor = nil
        activeAlerts = [:]
        weatherAlertNarration?.update(current: [], enabled: false, selectedVoice: nil)
        if let monitor {
            Task {
                await monitor.stop()
                await monitor.clearCoordinates()
            }
        }
        syncPlayer()
    }

    /// An alert from this Mac's monitor.
    func receive(alert: Bulletin) {
        guard alertMonitor != nil else { return }
        activeAlerts[alert.id] = alert
        refreshWeatherAlertNarration()
        syncPlayer()
    }

    private func dropEndedAlerts() async {
        guard let monitor = alertMonitor else { return }
        let ids = await monitor.activeAlertIDs
        guard monitor === alertMonitor else { return }
        activeAlerts = activeAlerts.filter { ids.contains($0.key) }
        refreshWeatherAlertNarration()
        syncPlayer()
    }

    /// The channel was published, or read back at start.
    func channelUpdated(_ channel: LibraryBulletins?) {
        let previousIDs = Set(headlines.map(\.id))
        let incoming = channel.map { $0.headlinesEnabled ? $0.headlines : [] } ?? []
        let newlyPublished = didLoadInitialChannel ? incoming.filter { !previousIDs.contains($0.id) } : []
        didLoadInitialChannel = true
        headlines = incoming
        let active = channel.map { $0.alertsEnabled || $0.headlinesEnabled } ?? false
        model?.preferences.set(active, forKey: Self.activePreferenceKey)
        refreshHeadlineNarration(newlyPublished: newlyPublished)
        refreshWeatherAlertNarration()
        syncPlayer()
    }

    /// Hands the player the current headlines and tells it which bulletins are still current, so
    /// withdrawn alerts are dropped. Newly rendered candidates remain queued until an ad break.
    private func syncPlayer() {
        guard let controller = attachedController else { return }
        let ready = narration.readyBulletins.filter(canSpeakHeadline)
        let readyAlerts = weatherAlertNarration?.readyBulletins ?? []
        controller.replaceBulletins(ready + readyAlerts)
    }

    private func apply(_ value: BulletinProducerStatus) {
        guard producer != nil else { return }
        status = value
        guard !value.isPolling, value.lastError == nil, value.waitingFor == nil,
              let active = value.publishedActive, let model else { return }
        model.preferences.set(active, forKey: Self.activePreferenceKey)
        if !active, !model.automationSettings.interruptionsEnabled {
            bulletinLog.info("Interruptions are off everywhere; the bulletin producer is idle")
            reconcile()
        }
    }

    /// One line for Settings, or nil while there is nothing to say.
    static func statusLine(_ status: BulletinProducerStatus, now: Date = Date()) -> String? {
        if status.isPolling { return "Checking headline feeds\u{2026}" }
        if let waiting = status.waitingFor { return "Waiting: \(waiting)" }
        if let error = status.lastError {
            let retry = status.nextPollAt.map { " Next try \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            return "\(error)\(retry)"
        }
        if let last = status.lastPollAt { return "Last checked \(last.formatted(date: .omitted, time: .shortened))" }
        return nil
    }
}

extension WiltedMacModel {
    /// The hub, created on first use and kept for the model's life.
    var bulletinHub: WiltedMacBulletinHub {
        if let hub = objc_getAssociatedObject(self, &bulletinHubKey) as? WiltedMacBulletinHub { return hub }
        let hub = WiltedMacBulletinHub(model: self)
        objc_setAssociatedObject(self, &bulletinHubKey, hub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hub
    }

    /// Called when the store opens or closes and when the settings change.
    /// The bulletin being spoken now, for the player's banner.
    var speakingBulletin: Bulletin? { playback?.speakingBulletin }

    func skipSpokenBulletin() { playback?.skipSpokenBulletin() }

    func installBulletinHubForTesting(_ hub: WiltedMacBulletinHub) {
        objc_setAssociatedObject(self, &bulletinHubKey, hub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func stopBulletinsWithoutResuming() {
        (objc_getAssociatedObject(self, &bulletinHubKey) as? WiltedMacBulletinHub)?.shutdown()
        playback?.disableInterruptions(resuming: false)
    }

    func bulletinLifecycleChanged() {
        let existing = objc_getAssociatedObject(self, &bulletinHubKey) as? WiltedMacBulletinHub
        guard existing != nil || store != nil || automationSettings.interruptionsEnabled || automationSettings.reportEnabled
            || preferences.bool(forKey: WiltedMacBulletinHub.activePreferenceKey) else { return }
        (existing ?? bulletinHub).reconcile()
    }
}
#endif
