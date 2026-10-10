import AVFoundation
import Combine
import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary
import WiltedWeather

private let interruptionLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryInterruptions")

// MARK: - Settings

/// "Speak interruptions on this iPhone": a per-device choice, on unless switched off. It gates both
/// the spoken bulletins and this iPhone's own weather-alert lookup.
struct LibraryInterruptionPreferences {
    nonisolated static let speakKey = "wilted.library.speakInterruptions"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var speaks: Bool {
        get { defaults.object(forKey: Self.speakKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.speakKey) }
    }
}

// MARK: - The hold

/// What Now Playing and the player show while a bulletin is spoken.
struct LibrarySpeechHold: Equatable, Sendable {
    let title: String
}

extension LibraryPlayer {
    var isHoldingForSpeech: Bool { speechHold != nil }
    /// The player's count of commands (start, play, pause, seek, stop): a checkpoint is current only while it matches.
    var commandGeneration: UInt64 { UInt64(truncatingIfNeeded: transportCount) }

    /// Stops program audio for a spoken bulletin without the pause path: the handoff keeps its ownership,
    /// the session stays active, the status stays `.playing`, the timer keeps running, and the published
    /// position is the checkpoint. Listening time stops counting. Returns false, changing nothing, when
    /// the player is not playing or the session refuses. Holding again only changes the title.
    @discardableResult
    func holdForSpeech(title: String) -> Bool {
        if speechHold != nil { speechHold = LibrarySpeechHold(title: title); publishNowPlaying(); return true }
        guard status == .playing, item != nil, !isRemoteSeeking else { return false }
        do { try session.activate() } catch { return false }
        accrueListening()
        engine.pause()
        lastAccrual = nil
        position = min(max(0, engine.currentTime), duration)
        speechHold = LibrarySpeechHold(title: title)
        publishNowPlaying()
        return true
    }

    /// Puts the position back at the checkpoint without touching the status.
    func restoreFromSpeech(to seconds: TimeInterval) {
        guard item != nil else { return }
        let target = min(max(0, seconds), duration)
        engine.currentTime = target
        position = target
        if speechHold == nil { publishNowPlaying() }
    }

    /// Ends the hold. With `resume`, program audio plays again from the position; if the engine or the
    /// session refuses, the player reports the failure rather than showing a silent "playing".
    func releaseSpeechHold(resume: Bool) {
        guard speechHold != nil else { return }
        speechHold = nil
        guard resume, status == .playing, item != nil else { publishNowPlaying(); return }
        do { try session.activate() } catch { _ = fail(.audioSession); return }
        guard engine.play() else { _ = fail(.engineRefused); return }
        lastAccrual = .now
        publishNowPlaying()
    }

    /// The listener asks to skip the bulletin being spoken.
    func skipSpeech() { if speechHold != nil { onSpeechSkip?() } }

    /// A command that replaces the speech (a seek, a play) first ends it, so nothing is left held.
    func skipSpeechForCommand() {
        guard speechHold != nil else { return }
        onSpeechSkip?()
        if speechHold != nil { releaseSpeechHold(resume: true) }
    }

    /// Lock-screen and headset commands. Next-track arrives as `.skipForward`, so while a bulletin is
    /// spoken it skips the bulletin instead of seeking; at any other time it is unchanged.
    func handleRemote(_ command: LibraryRemoteCommand) -> Bool {
        if speechHold != nil, case .skipForward = command {
            skipSpeech()
            return true
        }
        return handle(command)
    }
}

// MARK: - Speech and alert seams

/// Speaks one bulletin. Injected so tests never speak.
@MainActor
protocol LibrarySpeaking: AnyObject {
    /// Starts speaking and calls `onFinish` once on the main actor when the speech ends or fails.
    /// Returns false, never calling `onFinish`, when speech cannot start.
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool
    /// Stops silently: `onFinish` is not called.
    func stop()
}

/// The alert monitor as the controller uses it, so a test can watch when it starts and where.
protocol LibraryAlertMonitoring: AnyObject, Sendable {
    func start() async
    func stop() async
    func setCoordinates(lat: Double, lon: Double) async
    func clearCoordinates() async
    var activeAlertIDs: Set<String> { get async }
}

extension AlertMonitor: LibraryAlertMonitoring {}

/// The production speaker: `AVSpeechSynthesizer` on the app's own audio session, which the player keeps
/// active. Whether it speaks while the phone plays in the background is unverified (b64 facts, item 10), so
/// it gives up if speech has not started within `startTimeout` and the player keeps playing.
@MainActor
final class LibrarySpeechSynthesizer: NSObject, LibrarySpeaking, AVSpeechSynthesizerDelegate {
    static let startTimeout: Duration = .seconds(3)
    private let synthesizer = AVSpeechSynthesizer()
    private var finish: (@MainActor () -> Void)?
    private var started = false
    private var startWatch: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = self
    }

    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool {
        guard !text.isEmpty else { return false }
        finish = onFinish
        started = false
        synthesizer.speak(AVSpeechUtterance(string: text))
        startWatch = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, !self.started else { return }
            interruptionLog.error("Speech did not start; giving up on this bulletin")
            self.synthesizer.stopSpeaking(at: .immediate)
            self.complete()
        }
        return true
    }

    func stop() {
        finish = nil
        startWatch?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func complete() {
        startWatch?.cancel()
        let callback = finish
        finish = nil
        callback?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.started = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.complete() }
    }
}

// MARK: - The controller

/// Runs `InterruptionReducer` for the iPhone player: reads the Mac's bulletin channel on each sync tick
/// while playing, runs this iPhone's own alert monitor at its own location, and carries out the
/// reducer's effects (hold, speak, restore, resume). Speech that cannot start is dropped and playback
/// carries on; every speech ends by finishing, a skip, a pause or the watchdog.
@MainActor
final class LibraryInterruptionController {
    struct Dependencies {
        var speaker: any LibrarySpeaking
        var preferences = LibraryInterruptionPreferences()
        /// The Mac's published channel; nil before it has published one.
        var fetchBulletins: @Sendable () async throws -> LibraryBulletins?
        var makeMonitor: (@escaping @Sendable (Bulletin) -> Void) -> any LibraryAlertMonitoring
        var location: LibraryLocationProvider?
        /// The synced cues of an entry, for pause points.
        var cues: (ItemID) -> [LibraryTranscriptCue] = { _ in [] }
        var revision: (ItemID) async -> RevisionID?
        var now: () -> Date = Date.init
        var isForeground: () -> Bool = { false }
        var maximumSpeech: Duration = .seconds(120)
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    private let player: LibraryPlayer
    private let deps: Dependencies
    private var reducer = InterruptionReducer()
    private var cancellables = Set<AnyCancellable>()
    private var channel: LibraryBulletins?
    private var alerts: [String: Bulletin] = [:]
    private var activeAlertIDs: Set<String> = []
    private var revision: (entry: ItemID, id: RevisionID)?
    private var pausePoint: Double?
    private var speechToken: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    private var monitor: (any LibraryAlertMonitoring)?
    private var monitorCoordinates: (lat: Double, lon: Double)?
    private var monitorRunning = false
    private var locationEnabled = false
    private var monitorChain: Task<Void, Never>?

    var state: InterruptionState { reducer.state }
    var isMonitorRunning: Bool { monitorRunning }
    /// True once the playing item's revision is known; until then no bulletin is spoken.
    var hasRevision: Bool { revision != nil }

    init(player: LibraryPlayer, dependencies: Dependencies) {
        self.player = player
        self.deps = dependencies
        player.onSpeechHoldEnded = { [weak self] in self?.holdEndedByPlayer() }
        player.onSpeechSkip = { [weak self] in self?.send { .skip($0) } }
        player.$status.removeDuplicates().sink { [weak self] status in
            MainActor.assumeIsolated { self?.statusChanged(to: status) }
        }.store(in: &cancellables)
        player.$position.sink { [weak self] position in
            MainActor.assumeIsolated { self?.positionChanged(to: position) }
        }.store(in: &cancellables)
        player.$item.sink { [weak self] item in
            MainActor.assumeIsolated { self?.itemChanged(to: item) }
        }.store(in: &cancellables)
        itemChanged(to: player.item)
    }

    /// Waits for monitor work already queued. For tests.
    func settleMonitor() async { await monitorChain?.value }

    // MARK: Sync tick

    /// One sync round: reads the channel while playing, applies it and brings the alert monitor in line.
    func syncTick() async {
        if !deps.preferences.speaks {
            if player.isHoldingForSpeech { send { .skip($0) } }
            reconcileMonitor()
            return
        }
        guard player.status == .playing else { reconcileMonitor(); return }
        do {
            channel = try await deps.fetchBulletins()
        } catch {
            interruptionLog.error("Could not read the bulletin channel: \(String(describing: error), privacy: .public)")
        }
        reconcileMonitor()
        await refreshActiveAlerts()
        applyChannel()
    }

    func appBecameActive() {
        guard locationEnabled else { return }
        deps.location?.appBecameActive()
        reconcileMonitor()
    }

    private func applyChannel() {
        guard deps.preferences.speaks, let channel else { return }
        let headlines = channel.headlinesEnabled ? channel.headlines : []
        let local = channel.alertsEnabled ? alerts.values.filter { activeAlertIDs.contains($0.id) } : []
        send { .channelReplaced(headlines + local, $0) }
        for headline in headlines { send { .bulletinArrived(headline, $0) } }
    }

    private func refreshActiveAlerts() async {
        guard let monitor, monitorRunning else { activeAlertIDs = []; return }
        activeAlertIDs = await monitor.activeAlertIDs
    }

    // MARK: Alert monitor

    private var alertsWanted: Bool { deps.preferences.speaks && channel?.alertsEnabled == true }

    /// Starts the monitor at this iPhone's own location only while playing with alerts on; stops it otherwise.
    private func reconcileMonitor(playing: Bool? = nil) {
        guard let location = deps.location else { return }
        if alertsWanted {
            // The location prompt appears only while the app is in front.
            if !locationEnabled, deps.isForeground() {
                location.setAlertsEnabled(true, appIsActive: true)
                locationEnabled = true
            }
        } else if locationEnabled {
            location.setAlertsEnabled(false)
            locationEnabled = false
        }
        guard alertsWanted, playing ?? (player.status == .playing), let fix = location.currentFix else {
            stopMonitor()
            return
        }
        let monitor = ensureMonitor()
        let coordinates = (lat: fix.latitude, lon: fix.longitude)
        let moved = monitorCoordinates?.lat != coordinates.lat || monitorCoordinates?.lon != coordinates.lon
        guard moved || !monitorRunning else { return }
        monitorCoordinates = coordinates
        monitorRunning = true
        enqueueMonitor {
            if moved { await monitor.setCoordinates(lat: coordinates.lat, lon: coordinates.lon) }
            await monitor.start()
        }
    }

    private func stopMonitor() {
        guard monitorRunning, let monitor else { return }
        monitorRunning = false
        monitorCoordinates = nil
        activeAlertIDs = []
        enqueueMonitor {
            await monitor.stop()
            await monitor.clearCoordinates()
        }
    }

    private func ensureMonitor() -> any LibraryAlertMonitoring {
        if let monitor { return monitor }
        let made = deps.makeMonitor { [weak self] bulletin in
            Task { @MainActor in self?.alertArrived(bulletin) }
        }
        monitor = made
        return made
    }

    private func enqueueMonitor(_ work: @escaping @Sendable () async -> Void) {
        let previous = monitorChain
        monitorChain = Task {
            await previous?.value
            await work()
        }
    }

    /// An alert from this iPhone's own monitor.
    func alertArrived(_ bulletin: Bulletin) {
        guard deps.preferences.speaks, channel?.alertsEnabled == true else { return }
        alerts[bulletin.id] = bulletin
        send { .bulletinArrived(bulletin, $0) }
    }

    // MARK: Player events

    private func statusChanged(to status: LibraryPlayer.Status) {
        if status == .playing { deps.location?.playbackStarted(inForeground: deps.isForeground()) }
        send(playing: status == .playing) { .tick($0) }
        reconcileMonitor(playing: status == .playing)
    }

    private func positionChanged(to position: Double) {
        guard player.status == .playing, !player.isHoldingForSpeech else { return }
        if let point = pausePoint, position >= point {
            pausePoint = nil
            send(position: position) { .pausePointReached($0) }
        } else {
            send(position: position) { .tick($0) }
        }
    }

    private func itemChanged(to item: LibraryPlayer.Item?) {
        pausePoint = nil
        perform(reducer.handle(.itemChanged))
        revision = nil
        guard let entry = item?.entryID else { return }
        let lookup = deps.revision
        Task { @MainActor [weak self] in
            guard let id = await lookup(entry), let self, self.player.item?.entryID == entry else { return }
            self.revision = (entry, id)
            self.send { .tick($0) }
        }
    }

    /// The hold ended without the speech finishing: a pause, a route loss, a stop or a new item.
    private func holdEndedByPlayer() {
        if player.item == nil { perform(reducer.handle(.itemChanged)); return }
        send { .userPaused($0) }
    }

    // MARK: Reducer plumbing

    private func snapshot(playing: Bool? = nil, position: Double? = nil) -> PlaybackSnapshot? {
        guard let item = player.item, let revision, revision.entry == item.entryID else { return nil }
        return PlaybackSnapshot(
            entryID: item.entryID, revisionID: revision.id, positionSeconds: position ?? player.position,
            commandGeneration: player.commandGeneration, isPlaying: playing ?? (player.status == .playing),
            now: deps.now())
    }

    private func send(
        playing: Bool? = nil, position: Double? = nil, _ event: (PlaybackSnapshot) -> InterruptionEvent
    ) {
        guard let snapshot = snapshot(playing: playing, position: position) else { return }
        perform(reducer.handle(event(snapshot)))
    }

    private func perform(_ effects: [InterruptionEffect]) {
        for effect in effects {
            switch effect {
            case .awaitPausePoint: awaitPausePoint()
            case let .speak(bulletin, _): speak(bulletin)
            case .stopSpeech: stopSpeaker()
            case let .restore(checkpoint): player.restoreFromSpeech(to: checkpoint.positionSeconds)
            case .resume: player.releaseSpeechHold(resume: true)
            }
        }
        // Whatever the reducer decided, a hold with nothing left to speak must not outlive it.
        if player.isHoldingForSpeech, case .speaking = reducer.state {} else if player.isHoldingForSpeech {
            stopSpeaker()
            player.releaseSpeechHold(resume: true)
        }
    }

    /// The end of the cue now playing is the pause point; with no cue the bulletin waits for its deadline.
    private func awaitPausePoint() {
        let cues = player.item.map { deps.cues($0.entryID) } ?? []
        let position = player.position
        guard !cues.isEmpty else { pausePoint = nil; return }
        if let index = LibraryTranscriptFollow.currentIndex(in: cues, at: position) {
            pausePoint = max(position, cues[index].end)
        } else {
            pausePoint = position
        }
        if let point = pausePoint, position >= point {
            pausePoint = nil
            send { .pausePointReached($0) }
        }
    }

    // MARK: Speaking

    private func speak(_ bulletin: Bulletin) {
        stopSpeaker()
        let token = speechToken
        let title = bulletin.kind == .alert ? "Weather alert" : "News headline"
        guard player.holdForSpeech(title: title) else {
            interruptionLog.error("Could not hold playback for a bulletin; dropped")
            send { .speechFinished($0) }
            return
        }
        let started = deps.speaker.speak(bulletin.text) { [weak self] in self?.speechEnded(token) }
        guard started else {
            interruptionLog.error("Speech could not start; dropped")
            send { .speechFinished($0) }
            return
        }
        let (limit, sleep) = (deps.maximumSpeech, deps.sleep)
        watchdog = Task { @MainActor [weak self] in
            try? await sleep(limit)
            guard !Task.isCancelled else { return }
            self?.speechEnded(token)
        }
    }

    private func speechEnded(_ token: UInt64) {
        guard token == speechToken else { return }
        stopSpeaker()
        send { .speechFinished($0) }
    }

    private func stopSpeaker() {
        speechToken &+= 1
        watchdog?.cancel()
        watchdog = nil
        deps.speaker.stop()
    }
}

// MARK: - Live wiring

extension LibraryInterruptionController {
    /// The production stack for `model`'s player: the system speaker, the NWS-backed alert monitor, this
    /// iPhone's location, the model's transport and its synced transcripts.
    static func live(player: LibraryPlayer, model: LibraryAppModel) -> LibraryInterruptionController {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let transport = model.transport
        return LibraryInterruptionController(
            player: player,
            dependencies: Dependencies(
                speaker: LibrarySpeechSynthesizer(),
                fetchBulletins: { try await transport.fetchBulletins() },
                makeMonitor: { deliver in
                    AlertMonitor(
                        source: NWSClient(appVersion: version, repositoryURL: "https://github.com/dave-schmidt-dev/wilted"),
                        deliver: deliver)
                },
                location: LibraryLocationProvider(manager: LibraryCoreLocationManager()),
                cues: { [weak model] in model?.transcript(for: $0)?.cues ?? [] },
                revision: { [weak model] in await model?.mediaCache.cachedEntries()[$0]?.revisionID },
                now: { [weak model] in model?.now() ?? Date() },
                isForeground: { [weak model] in model?.tickState.sceneActive ?? false }))
    }
}
