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

    /// The latest poll result, for Settings.
    private(set) var status = BulletinProducerStatus()
    private var lastFailure: MacAudioRouteFailureStep?
    var routeProtectionStatus: String? { lastFailure == nil ? nil : Self.unavailableRouteMessage }
    private(set) var hasNewsSource = false
    private(set) var hasCheckedNewsSource = false
    private(set) var isCheckingNewsSource = false
    @ObservationIgnored private var newsReadinessRequest = 0
    @ObservationIgnored private var testBulletinSpeaker: (any BulletinSpeaking)?

    @ObservationIgnored private let heardHistory: HeardHeadlineHistory
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private weak var model: WiltedMacModel?
    @ObservationIgnored private var ownedLocation: WiltedLocationProvider?
    @ObservationIgnored private let producerFactory: (@MainActor () -> BulletinProducer)?
    @ObservationIgnored private var producer: BulletinProducer?
    @ObservationIgnored private let makeRouteSource: @MainActor () -> any MacAudioRouteSource
    @ObservationIgnored private let makeSpeaker: @MainActor () -> any BulletinSpeaking
    @ObservationIgnored private let makeAlertSource: @MainActor (String?) -> any NWSAlertSource
    @ObservationIgnored private weak var attachedController: PlaybackController?
    @ObservationIgnored private let retrySleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryIndex = 0
    @ObservationIgnored private weak var lastController: PlaybackController?
    @ObservationIgnored private var wasPlaying = false
    @ObservationIgnored private var attachedWaitLimit = 0
    @ObservationIgnored private var alertMonitor: AlertMonitor?
    @ObservationIgnored private var observing = false
    /// The headlines of the channel as last published or read back, while headlines are on.
    @ObservationIgnored private(set) var headlines: [Bulletin] = []
    /// Alerts the monitor delivered that are still active here.
    @ObservationIgnored private(set) var activeAlerts: [String: Bulletin] = [:]

    init(model: WiltedMacModel, location: WiltedLocationProvider? = nil,
         makeSpeaker: @escaping @MainActor () -> any BulletinSpeaking = { SystemBulletinSpeaker() },
         makeRouteSource: @escaping @MainActor () -> any MacAudioRouteSource = { MacAudioRouteLossObserver() },
         makeAlertSource: @escaping @MainActor (String?) -> any NWSAlertSource = WiltedMacBulletinHub.nwsClient,
         retrySleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() },
         producerFactory: (@MainActor () -> BulletinProducer)? = nil) {
        self.producerFactory = producerFactory
        self.now = now
        self.heardHistory = HeardHeadlineHistory(defaults: model.preferences, now: now())
        self.retrySleep = retrySleep
        self.model = model
        ownedLocation = location
        self.makeRouteSource = makeRouteSource
        self.makeSpeaker = makeSpeaker
        self.makeAlertSource = makeAlertSource
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
            return
        }
        isCheckingNewsSource = true
        defer {
            if request == newsReadinessRequest { isCheckingNewsSource = false }
        }
        do {
            let feeds = try await NewsHeadlineCandidateReader.headlineFeeds(in: store)
            let foundNewsSource = !feeds.isEmpty
            guard request == newsReadinessRequest, model.store === store else { return }
            hasNewsSource = foundNewsSource
            hasCheckedNewsSource = true
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
        let speaker = makeSpeaker()
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
        // The morning report needs a location too, even with interruptions off.
        if canRun, settings.interruptionsEnabled || settings.reportEnabled {
            let provider = location
            provider.typedCoordinates = settings.typedCoordinates
            provider.start()
        }
        let wanted = canRun && (settings.interruptionsEnabled || model.preferences.bool(forKey: Self.activePreferenceKey))
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
            })
    }

    func makeProducer(
        newsItems: @escaping @Sendable () async throws -> [NewsHeadlineCandidate],
        fetchPublished: @escaping @Sendable () async throws -> LibraryBulletins?,
        publish: @escaping @Sendable (LibraryBulletins) async throws -> Void
    ) -> BulletinProducer {
        BulletinProducer(
            settings: { [weak self] in
                await MainActor.run { self?.currentSettings ?? Self.allOff }
            }, newsItems: newsItems, fetchPublished: fetchPublished, publish: publish,
            onStatus: { [weak self] status in
                Task { @MainActor in self?.apply(status) }
            }, now: now, heardHeadlines: { [heardHistory, now] in
                await heardHistory.snapshot(at: now())
            })
    }

    private static let allOff = BulletinProducerSettings(
        interruptionsEnabled: false, alertsEnabled: false, headlinesEnabled: false, headlineMinimumGapMinutes: 30)

    private var currentSettings: BulletinProducerSettings {
        guard let model else { return Self.allOff }
        let settings = model.automationSettings
        return BulletinProducerSettings(
            interruptionsEnabled: settings.interruptionsEnabled, alertsEnabled: settings.alertsEnabled,
            headlinesEnabled: settings.headlinesEnabled, headlineMinimumGapMinutes: settings.headlineMinimumGapMinutes,
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
        return try await NewsHeadlineCandidateReader.read(in: store, using: model.podcastFeedClient).candidates
    }

    // MARK: - Spoken interruptions

    /// Attaches or detaches the player and the alert monitor to match settings, playback and location.
    private func reconcileInterruptions(canRun: Bool, settings: WiltedAutomationSettings, retryDue: Bool) {
        let wantsSpeech = canRun && settings.interruptionsEnabled
        let controller = wantsSpeech ? model?.playback : nil
        let waitLimit = settings.waitLimitSeconds
        if let attached = attachedController, attached !== controller || attachedWaitLimit != waitLimit {
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
                speaker: makeSpeaker(), waitLimit: TimeInterval(waitLimit), routeSource: source,
                spokenHeadlineExpiries: heardHistory.snapshot(at: now()).expiries,
                shouldSpeakHeadline: { [heardHistory, now] headline in
                    let time = now()
                    return heardHistory.snapshot(at: time).allows(
                        id: headline.id, title: BulletinProducer.headlineTitle(of: headline.text), at: time)
                },
                didStartHeadline: { [heardHistory, now] headline in
                    heardHistory.record(id: headline.id, title: BulletinProducer.headlineTitle(of: headline.text), at: now())
                },
                now: now, protectionFailed: { [weak self] in
                    self?.protectionFailed(at: source.failureStep ?? .defaultOutputRead)
                }) {
                if let lastFailure {
                    bulletinLog.info("Bulletin output monitoring recovered after \(lastFailure.rawValue, privacy: .public)")
                }
                clearFailure()
                attachedController = controller
                attachedWaitLimit = waitLimit
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
        guard let monitor = alertMonitor else { return }
        alertMonitor = nil
        activeAlerts = [:]
        Task {
            await monitor.stop()
            await monitor.clearCoordinates()
        }
        syncPlayer()
    }

    /// An alert from this Mac's monitor.
    func receive(alert: Bulletin) {
        guard alertMonitor != nil else { return }
        activeAlerts[alert.id] = alert
        attachedController?.deliverBulletin(alert)
        syncPlayer()
    }

    private func dropEndedAlerts() async {
        guard let monitor = alertMonitor else { return }
        let ids = await monitor.activeAlertIDs
        guard monitor === alertMonitor else { return }
        activeAlerts = activeAlerts.filter { ids.contains($0.key) }
        syncPlayer()
    }

    /// The channel was published, or read back at start.
    func channelUpdated(_ channel: LibraryBulletins?) {
        headlines = channel.map { $0.headlinesEnabled ? $0.headlines : [] } ?? []
        syncPlayer()
    }

    /// Hands the player the current headlines and tells it which bulletins are still current, so
    /// a withdrawn one is dropped.
    private func syncPlayer() {
        guard let controller = attachedController else { return }
        for headline in headlines { controller.deliverBulletin(headline) }
        controller.replaceBulletins(headlines + Array(activeAlerts.values))
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

    /// Called when the store opens or closes and when the settings change. Does nothing, and
    /// creates nothing, for a Mac that has never used interruptions.
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
        guard existing != nil || automationSettings.interruptionsEnabled || automationSettings.reportEnabled
            || preferences.bool(forKey: WiltedMacBulletinHub.activePreferenceKey) else { return }
        (existing ?? bulletinHub).reconcile()
    }
}
#endif
