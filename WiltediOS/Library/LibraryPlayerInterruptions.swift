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
        engineStoppedAt = nil
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
        guard resume, status == .playing, item != nil else {
            journal?.note(PlaybackJournalRecord(
                source: .phone, event: .bulletinResume, itemID: item?.entryID,
                positionSeconds: position, result: .skipped, isPlaying: isPlaying))
            publishNowPlaying()
            return
        }
        do { try session.activate() } catch {
            journal?.note(PlaybackJournalRecord(
                source: .phone, event: .bulletinResume, itemID: item?.entryID,
                positionSeconds: position, cause: .audioSession, result: .failed))
            _ = fail(.audioSession)
            return
        }
        engineStoppedAt = nil
        guard engine.play() else {
            journal?.note(PlaybackJournalRecord(
                source: .phone, event: .bulletinResume, itemID: item?.entryID,
                positionSeconds: position, cause: .engineRefused, result: .failed))
            _ = fail(.engineRefused)
            return
        }
        journal?.note(PlaybackJournalRecord(
            source: .phone, event: .bulletinResume, itemID: item?.entryID,
            positionSeconds: position, result: .started, isPlaying: true))
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

    /// Lock-screen, headset, steering-wheel and CarPlay commands. Next-track arrives as `.skipForward`, so
    /// while a bulletin is spoken it skips the bulletin instead of seeking; with nothing loaded only play
    /// and play/pause can act (they resume from the library); every command is logged with its result.
    ///
    /// Play and play/pause for an episode that already played to its end are treated as with nothing
    /// loaded: the library picks what to resume, and it never picks a finished episode. Without this a
    /// car that sends Play when it connects started the finished episode again from the beginning
    /// (2026-11-18). The phone's own Play button on that episode still plays it again.
    func handleRemote(_ command: LibraryRemoteCommand) -> Bool {
        let loaded = item != nil
        let handled: Bool
        if speechHold != nil, case .skipForward = command {
            skipSpeech()
            handled = true
        } else if loaded, !resumesFromLibrary(command) {
            handled = handle(command)
        } else {
            handled = handleIdleRemote(command)
        }
        logRemote(command, loaded: loaded, handled: handled)
        return handled
    }

    /// True for a play request while the loaded episode is at its end and a runtime can resume another.
    private func resumesFromLibrary(_ command: LibraryRemoteCommand) -> Bool {
        guard status == .ended, onIdleRemoteCommand != nil else { return false }
        switch command {
        case .play, .togglePlayPause: return true
        default: return false
        }
    }
}

// MARK: - Speech and alert seams

/// The alert monitor as the controller uses it, so a test can watch when it starts and where.
protocol LibraryAlertMonitoring: AnyObject, Sendable {
    func start() async
    func stop() async
    func setCoordinates(lat: Double, lon: Double) async
    func clearCoordinates() async
    var activeAlertIDs: Set<String> { get async }
}

extension AlertMonitor: LibraryAlertMonitoring {}

// MARK: - The controller

/// Runs `InterruptionReducer` for the iPhone player: reads the Mac's bulletin channel on each sync tick
/// while playing, runs this iPhone's own alert monitor at its own location, and carries out the
/// reducer's effects (hold, speak, restore, resume). Speech that cannot start is dropped and playback
/// carries on; every speech ends by finishing, a skip, a pause or the watchdog.
@MainActor
final class LibraryInterruptionController: ObservableObject {
    struct Dependencies {
        var speaker: any LibrarySpeaking
        var previewSpeaker: (any LibrarySpeaking)? = nil
        var playingPreviewSpeaker: (any LibrarySpeaking)? = nil
        var preferences = LibraryInterruptionPreferences()
        /// The Mac's published channel; nil before it has published one.
        var fetchBulletins: @Sendable () async throws -> LibraryBulletins?
        var makeMonitor: (@escaping @Sendable (Bulletin) -> Void) -> any LibraryAlertMonitoring
        var location: LibraryLocationProvider?
        /// Prepared ad seams from the synced transcript for this exact audio revision.
        var adBreakSeams: (ItemID, RevisionID) -> [Double] = { _, _ in [] }
        /// Ensures the active entry's transcript and cut seams are available while audio plays.
        var prepareAdBreaks: (ItemID) async -> Void = { _ in }
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
    var observedChannel: LibraryBulletins? { channel }
    /// The story currently being read, when any.
    @Published private(set) var activeSpokenHeadline: Bulletin?
    /// The most recently read story remains available after its speech ends.
    @Published private(set) var lastSpokenHeadline: Bulletin?
    /// An unstarted headline is surfaced only when its audio issue offers a recovery action.
    @Published private(set) var availableHeadline: Bulletin?
    var nowPlayingHeadline: Bulletin? {
        if let activeSpokenHeadline {
            if let availableHeadline, activeSpokenHeadline.id == availableHeadline.id,
               activeSpokenHeadline.text != availableHeadline.text,
               deps.speaker.bulletinAudioIssue(for: availableHeadline) != nil { return availableHeadline }
            return activeSpokenHeadline
        }
        if let availableHeadline,
           deps.speaker.bulletinAudioIssue(for: availableHeadline) != nil { return availableHeadline }
        return lastSpokenHeadline
    }
    /// The alert currently being read, or the last alert read, with its official source text.
    @Published private(set) var activeSpokenWeatherAlert: Bulletin?
    @Published private(set) var lastSpokenWeatherAlert: Bulletin?
    /// The latest fetched alert remains available while its cached clip is prepared.
    @Published private(set) var availableWeatherAlert: Bulletin?
    var nowPlayingWeatherAlert: Bulletin? {
        if let activeSpokenWeatherAlert, let availableWeatherAlert,
           activeSpokenWeatherAlert.id == availableWeatherAlert.id,
           activeSpokenWeatherAlert.text != availableWeatherAlert.text { return availableWeatherAlert }
        return activeSpokenWeatherAlert ?? availableWeatherAlert ?? lastSpokenWeatherAlert
    }
    private(set) var hasCheckedChannel = false
    private(set) var channelCheckFailed = false
    private var alerts: [String: Bulletin] = [:]
    private var activeAlertIDs: Set<String> = []
    private var revision: (entry: ItemID, id: RevisionID)?
    private var hasObservedInitialItem = false
    private var initialPositionNeedsCapture = false
    private var initialPositionEntry: ItemID?
    private var initialLoadCommandGeneration: UInt64?
    private var initialItemStartedAtZero = false
    private var hasObservedFirstPlayForItem = false
    private var zeroSeamCommandGeneration: UInt64?
    private struct PositionSample {
        let entry: ItemID
        let revision: RevisionID
        let position: Double
        let commandGeneration: UInt64
    }
    private var lastPositionSample: PositionSample?
    private var deliveredAdBreaks: Set<String> = []
    private var speechToken: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    private var monitor: (any LibraryAlertMonitoring)?
    private var monitorCoordinates: (lat: Double, lon: Double)?
    private var monitorRunning = false
    private var locationEnabled = false
    private var monitorChain: Task<Void, Never>?

    var state: InterruptionState { reducer.state }
    var locationStatus: LibraryLocationStatus { deps.location?.status ?? .none }
    var canSpeakTestBulletin: Bool {
        guard !player.isHoldingForSpeech else { return false }
        if case .idle = reducer.state { return true }
        return false
    }
    var isMonitorRunning: Bool { monitorRunning }
    /// True once the playing item's revision is known; until then no bulletin is spoken.
    var hasRevision: Bool { revision != nil }

    func bulletinAudioIssue(for bulletin: Bulletin) -> String? {
        deps.speaker.bulletinAudioIssue(for: bulletin)
    }

    /// Requests a fresh clip only. Playback still waits for a real ad break.
    func retryBulletinAudio(_ bulletin: Bulletin) {
        deps.speaker.retryBulletinAudio(bulletin)
        objectWillChange.send()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.deps.speaker.refreshPreparedAudio()
            self.objectWillChange.send()
        }
    }

    init(player: LibraryPlayer, dependencies: Dependencies) {
        self.player = player
        self.deps = dependencies
        dependencies.location?.onStatusChange = { [weak self] in self?.objectWillChange.send() }
        player.onSpeechHoldEnded = { [weak self] in self?.holdEndedByPlayer() }
        player.onSpeechSkip = { [weak self] in self?.send { .skip($0) } }
        player.$status.removeDuplicates().sink { [weak self] status in
            MainActor.assumeIsolated { self?.statusChanged(to: status) }
        }.store(in: &cancellables)
        player.$position.sink { [weak self] position in
            MainActor.assumeIsolated { self?.positionChanged(to: position) }
        }.store(in: &cancellables)
        player.$item.sink { [weak self] item in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isInitial = !self.hasObservedInitialItem
                self.hasObservedInitialItem = true
                self.itemChanged(to: item, mayReadZeroSeam: !isInitial)
            }
        }.store(in: &cancellables)
    }

    /// Waits for monitor work already queued. For tests.
    func settleMonitor() async { await monitorChain?.value }

    /// Uses the same speaker as bulletins without pausing, seeking, or changing the player.
    func speakTestBulletin() {
        guard canSpeakTestBulletin else { return }
        let preview = player.status == .playing ? deps.playingPreviewSpeaker : deps.previewSpeaker
        _ = (preview ?? deps.speaker).speak("This is a test bulletin.", onFinish: {})
    }

    func stopTestBulletin() {
        deps.previewSpeaker?.stop()
        deps.playingPreviewSpeaker?.stop()
    }

    // MARK: Sync tick

    /// One sync round: reads the channel while playing, applies it and brings the alert monitor in line.
    func syncTick() async {
        if !deps.preferences.speaks {
            lastPositionSample = nil
            discardBulletins { _ in true }
            reconcileMonitor()
            return
        }
        guard player.status == .playing else { reconcileMonitor(); return }
        let previousChannel = channel
        let previousCheck = hasCheckedChannel
        let previousFailure = channelCheckFailed
        do {
            channel = try await deps.fetchBulletins()
            hasCheckedChannel = true
            channelCheckFailed = false
        } catch {
            interruptionLog.error("Could not read the bulletin channel: \(String(describing: error), privacy: .public)")
            channelCheckFailed = true
        }
        if channel != previousChannel || hasCheckedChannel != previousCheck || channelCheckFailed != previousFailure {
            objectWillChange.send()
        }
        reconcileMonitor()
        await refreshActiveAlerts()
        applyChannel()
        await deps.speaker.refreshPreparedAudio()
        objectWillChange.send()
    }

    func appBecameActive() {
        guard locationEnabled else { return }
        deps.location?.appBecameActive()
        reconcileMonitor()
    }

    private func applyChannel() {
        guard deps.preferences.speaks, let channel else { return }
        discardDisabledBulletins()
        let headlines = channel.headlinesEnabled ? channel.headlines : []
        let local = channel.alertsEnabled ? alerts.values.filter { activeAlertIDs.contains($0.id) } : []
        availableHeadline = headlines.first
        for bulletin in headlines + local { deps.speaker.prepare(bulletin) }
        send { .channelReplaced(headlines + local, $0) }
        for headline in headlines { send { .bulletinArrived(headline, $0) } }
    }

    private func refreshActiveAlerts() async {
        guard let monitor, monitorRunning else { activeAlertIDs = []; return }
        activeAlertIDs = await monitor.activeAlertIDs
        if let availableWeatherAlert, !activeAlertIDs.contains(availableWeatherAlert.id) {
            self.availableWeatherAlert = nil
        }
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
        availableWeatherAlert = bulletin
        deps.speaker.prepare(bulletin)
        send { .bulletinArrived(bulletin, $0) }
    }

    // MARK: Player events

    private func statusChanged(to status: LibraryPlayer.Status) {
        if status == .playing { deps.location?.playbackStarted(inForeground: deps.isForeground()) }
        if status == .playing, !hasObservedFirstPlayForItem {
            hasObservedFirstPlayForItem = true
            if initialItemStartedAtZero,
               let initialLoadCommandGeneration,
               player.commandGeneration == initialLoadCommandGeneration &+ 1 {
                zeroSeamCommandGeneration = player.commandGeneration
            }
        } else if status != .playing {
            // A pause before the first forward sample means a later resume is not the original
            // zero-second crossing.
            zeroSeamCommandGeneration = nil
        }
        lastPositionSample = nil
        reconcileMonitor(playing: status == .playing)
    }

    private func positionChanged(to position: Double) {
        guard deps.preferences.speaks else {
            lastPositionSample = nil
            zeroSeamCommandGeneration = nil
            discardBulletins { _ in true }
            return
        }
        if initialPositionNeedsCapture, player.item?.entryID == initialPositionEntry {
            initialPositionNeedsCapture = false
            initialItemStartedAtZero = position == 0
        }
        discardDisabledBulletins()
        guard player.status == .playing, !player.isHoldingForSpeech,
              let item = player.item, let revision, revision.entry == item.entryID,
              let snapshot = snapshot(position: position), position.isFinite
        else {
            lastPositionSample = nil
            return
        }

        let sample = PositionSample(
            entry: item.entryID, revision: revision.id, position: position,
            commandGeneration: player.commandGeneration)
        defer { lastPositionSample = sample }
        if zeroSeamCommandGeneration != nil, zeroSeamCommandGeneration != sample.commandGeneration {
            zeroSeamCommandGeneration = nil
        }
        // A zero-second cut is eligible only when we observed this newly loaded item's first
        // playback command and then saw position zero before continuous forward movement.
        if lastPositionSample == nil, position != 0, zeroSeamCommandGeneration == sample.commandGeneration {
            zeroSeamCommandGeneration = nil
        }
        guard let previous = lastPositionSample,
              previous.entry == sample.entry, previous.revision == sample.revision,
              previous.commandGeneration == sample.commandGeneration,
              position >= previous.position, position - previous.position <= 3 else {
            return
        }

        let crossedInitialZero = previous.position == 0 && position > 0
            && zeroSeamCommandGeneration == sample.commandGeneration
        let availableSeams = deps.adBreakSeams(item.entryID, revision.id)
        let crossedSeam = availableSeams
            .filter {
                $0.isFinite && (($0 > previous.position && $0 <= position)
                    || ($0 == 0 && crossedInitialZero))
            }
            .sorted()
            .first { deliveredAdBreaks.insert(Self.adBreakIdentity(item.entryID, revision.id, $0)).inserted }
        if crossedInitialZero { zeroSeamCommandGeneration = nil }
        if crossedSeam != nil {
            perform(reducer.handle(.adBreakReached(snapshot)))
        }
    }

    private func itemChanged(to item: LibraryPlayer.Item?, mayReadZeroSeam: Bool) {
        lastPositionSample = nil
        deliveredAdBreaks = []
        perform(reducer.handle(.itemChanged))
        revision = nil
        initialPositionNeedsCapture = mayReadZeroSeam && item != nil
        initialPositionEntry = mayReadZeroSeam ? item?.entryID : nil
        initialLoadCommandGeneration = mayReadZeroSeam && item != nil ? player.commandGeneration : nil
        initialItemStartedAtZero = false
        hasObservedFirstPlayForItem = false
        zeroSeamCommandGeneration = nil
        guard let entry = item?.entryID else { return }
        let lookup = deps.revision
        Task { @MainActor [weak self] in
            guard let id = await lookup(entry), let self, self.player.item?.entryID == entry else { return }
            self.revision = (entry, id)
            self.lastPositionSample = nil
            await self.deps.prepareAdBreaks(entry)
            guard !Task.isCancelled, self.player.item?.entryID == entry,
                  self.revision?.id == id else { return }
        }
    }

    /// The hold ended without the speech finishing: a pause, a route loss, a stop or a new item.
    private func holdEndedByPlayer() {
        if player.item == nil { perform(reducer.handle(.itemChanged)); return }
        send { .userPaused($0) }
    }

    // MARK: Reducer plumbing

    private func snapshot(position: Double? = nil) -> PlaybackSnapshot? {
        guard let item = player.item, let revision, revision.entry == item.entryID else { return nil }
        return PlaybackSnapshot(
            entryID: item.entryID, revisionID: revision.id, positionSeconds: position ?? player.position,
            commandGeneration: player.commandGeneration, isPlaying: player.status == .playing,
            now: deps.now())
    }

    private func send(_ event: (PlaybackSnapshot) -> InterruptionEvent) {
        guard let snapshot = snapshot() else { return }
        perform(reducer.handle(event(snapshot)))
    }

    private func perform(_ effects: [InterruptionEffect]) {
        for effect in effects {
            switch effect {
            case let .speak(bulletin, _): speak(bulletin)
            case .stopSpeech: stopSpeaker()
            case let .restore(checkpoint):
                // A speaker may be unavailable before the hold starts. In that case the engine
                // never stopped, so restoring the checkpoint would rewind audible playback.
                if player.isHoldingForSpeech || player.status != .playing {
                    player.restoreFromSpeech(to: checkpoint.positionSeconds)
                }
            case .resume: player.releaseSpeechHold(resume: true)
            }
        }
        // Whatever the reducer decided, a hold with nothing left to speak must not outlive it.
        if player.isHoldingForSpeech, case .speaking = reducer.state {} else if player.isHoldingForSpeech {
            stopSpeaker()
            player.releaseSpeechHold(resume: true)
        }
    }

    private func discardDisabledBulletins() {
        guard let channel else { return }
        discardBulletins { bulletin in
            (bulletin.kind == .headline && !channel.headlinesEnabled)
                || (bulletin.kind == .alert && !channel.alertsEnabled)
        }
    }

    private func discardBulletins(where shouldDiscard: (Bulletin) -> Bool) {
        let queued = reducer.pending + reducer.remainingInBatch
        var ids = Set(queued.filter(shouldDiscard).map(\.id))
        if case let .speaking(bulletin, _) = reducer.state, shouldDiscard(bulletin) {
            ids.insert(bulletin.id)
        }
        guard !ids.isEmpty else { return }
        reducer.removePendingBulletins(withIDs: ids)
        if case let .speaking(bulletin, _) = reducer.state, ids.contains(bulletin.id) {
            send { .skip($0) }
        }
    }

    private static func adBreakIdentity(_ entry: ItemID, _ revision: RevisionID, _ seam: Double) -> String {
        "\(entry.rawValue)|\(revision.rawValue)|\(seam.bitPattern)"
    }

    // MARK: Speaking

    private func speak(_ bulletin: Bulletin) {
        stopSpeaker()
        let token = speechToken
        let title = bulletin.kind == .alert ? "Weather alert" : "News headline"
        guard deps.speaker.canSpeak(bulletin) else {
            interruptionLog.info("Prepared bulletin audio is unavailable; leaving it queued")
            send { .speechStartFailed($0) }
            return
        }
        guard player.holdForSpeech(title: title) else {
            interruptionLog.error("Could not hold playback for a bulletin; keeping it queued")
            send { .speechStartFailed($0) }
            return
        }
        let started = deps.speaker.speak(bulletin) { [weak self] in self?.speechEnded(token) }
        guard started else {
            interruptionLog.error("Speech could not start; keeping it queued")
            send { .speechStartFailed($0) }
            return
        }
        if bulletin.kind == .headline { lastSpokenHeadline = bulletin }
        if bulletin.kind == .alert { lastSpokenWeatherAlert = bulletin }
        if token == speechToken, bulletin.kind == .headline { activeSpokenHeadline = bulletin }
        if token == speechToken, bulletin.kind == .alert { activeSpokenWeatherAlert = bulletin }
        let (limit, sleep) = (speechWatchdogLimit(for: bulletin), deps.sleep)
        watchdog = Task { @MainActor [weak self] in
            try? await sleep(limit)
            guard !Task.isCancelled else { return }
            self?.speechEnded(token)
        }
    }

    private func speechWatchdogLimit(for bulletin: Bulletin) -> Duration {
        if let duration = deps.speaker.expectedPlaybackDuration, duration.isFinite, duration > 0 {
            return max(deps.maximumSpeech, .seconds(duration + 15))
        }
        let words = max(1, bulletin.text.split(whereSeparator: \.isWhitespace).count)
        return max(deps.maximumSpeech, .seconds(Double(words + 15)))
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
        activeSpokenHeadline = nil
        activeSpokenWeatherAlert = nil
        deps.speaker.stop()
    }
}
