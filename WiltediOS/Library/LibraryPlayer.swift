import AVFoundation
import Combine
import Foundation
import MediaPlayer
import WiltedDomain
import WiltedLibrary
import WiltedPlayback

/// An engine that can also change speed. `ListenerAudioEngine` has no rate, and the legacy
/// article path never needed one; the Larder player does, so speed is an optional capability.
protocol LibraryRateAdjustable: AnyObject {
    var rate: Float { get set }
}

/// Something the system tells the player about its audio session.
enum LibrarySessionEvent: Equatable, Sendable {
    case interruptionBegan
    /// `shouldResume` is the system's own hint that playback may continue.
    case interruptionEnded(shouldResume: Bool)
    /// The output the audio was playing through went away, such as unplugged headphones.
    case routeLost
}

/// Delivers `LibrarySessionEvent`s on the main actor.
@MainActor protocol LibrarySessionEvents: AnyObject {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void)
}

/// Plays one cached episode file at a time through a `ListenerAudioEngine`.
///
/// This is the Larder's own transport: it needs no `WiltedAsset`, article codec or
/// `ListenerRepository`, only a file the media cache already verified. It owns the audio
/// session, Now Playing, the lock-screen commands, and the interruption and route-change
/// responses the legacy controller declares but nothing ever called.
@MainActor
final class LibraryPlayer: ObservableObject {
    /// A cached file ready to play.
    struct Item: Equatable, Sendable {
        let entryID: ItemID
        let title: String
        let showTitle: String
        let fileURL: URL
        /// Where the artwork came from; the player reads only its local copy.
        var artworkURL: URL? = nil
    }

    enum Status: Equatable {
        case idle
        case playing
        case paused
        /// Reached the end; playing again starts over.
        case ended
        case failed(String)
    }

    nonisolated static let skipBackSeconds: TimeInterval = 15
    nonisolated static let skipForwardSeconds: TimeInterval = 30
    private static let maxAccrual: TimeInterval = 5

    @Published private(set) var item: Item?
    @Published private(set) var status: Status = .idle
    /// Seconds into the file. Refreshed on every transport change and on a timer while playing.
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Double = 1
    /// Skip lengths from Settings; the static constants are the untouched defaults.
    @Published private(set) var skipBackSeconds = Int(LibraryPlayer.skipBackSeconds)
    @Published private(set) var skipForwardSeconds = Int(LibraryPlayer.skipForwardSeconds)
    /// The speed a newly started item takes; nil leaves the player's current speed alone.
    private var defaultRate: Double?
    /// Settings: whether a finished item tells `onFinished`, which lets the app pick the next one.
    private var autoPlayNext = true
    /// Called with the entry that just played to its end and whether "Auto-play next episode" is on.
    /// Never called for a pause, a stop, a seek away from the end or a superseded load.
    var onFinished: ((ItemID, _ autoPlayNext: Bool) -> Void)?
    /// Counts every transport action (start, play, pause, seek, stop); `owns(_:)` compares it
    /// with its value when the item finished, so a command given after the end cancels what follows it.
    private var transportCount = 0
    var admissionEpoch: UInt64 = 0
    var admissionTask: Task<Void, Never>?
    var authorizePlayback: (@MainActor (Item) async -> Bool)?
    private var endedAtTransportCount = -1
    /// A natural finish survives unloading an ineligible item, but never a transport command.
    struct NaturalCompletion: Equatable {
        let entryID: ItemID
        let duration: TimeInterval
        let rate: Double
        fileprivate let transportCount: Int
    }
    private var lastNaturalCompletion: NaturalCompletion?

    func naturalCompletion(after entryID: ItemID) -> NaturalCompletion? {
        guard let completion = lastNaturalCompletion, completion.entryID == entryID,
              owns(completion) else { return nil }
        return completion
    }

    func owns(_ completion: NaturalCompletion) -> Bool {
        lastNaturalCompletion == completion && transportCount == completion.transportCount
            && endedAtTransportCount == completion.transportCount
    }
    /// Set by the sleep timer's "end of episode": the next natural end reports auto-play off, once, so the
    /// next episode does not start. Cleared when used, when the timer is cancelled and when playback stops.
    @Published private(set) var stopsAfterCurrentItem = false
    /// Artwork bytes for the loaded item, read once from the local cache when it starts.
    private var artworkData: Data?
    private let artwork: LibraryArtworkCache?
    private var artworkObserver: AnyCancellable?

    var isPlaying: Bool { status == .playing }
    /// False for an engine with no speed control, so the UI can hide the picker.
    var supportsRate: Bool { engine is LibraryRateAdjustable }

    private let engine: any ListenerAudioEngine
    private let session: any ListenerAudioSession
    private let nowPlaying: any ListenerNowPlaying
    private let remoteCommands: any LibraryRemoteCommands
    private let tickInterval: Duration
    private var loadGeneration: UInt64 = 0
    private let seekInstanceID = UUID()
    var seekSessionID: String? { item == nil ? nil : "\(seekInstanceID.uuidString):\(loadGeneration)" }
    var ownedSeekRequest: (id: UUID, direction: LibrarySeekDirection, sessionID: String, epoch: UInt64)?
    private var resumeAfterInterruption = false
    private var tickTask: Task<Void, Never>?
    var remoteSeekState: LibraryRemoteSeekState?
    let remoteSeekSleep: @Sendable (Duration) async throws -> Void
    let remoteSeekNow: @Sendable () -> TimeInterval
    /// When listening was last counted; nil unless playing.
    private var lastAccrual: ContinuousClock.Instant?
    /// Told how many real seconds were just played and at what speed, for the phone's own totals.
    var onListened: (@MainActor (_ wall: TimeInterval, _ rate: Double) -> Void)?
    /// Told before every transport command (start, play, pause, seek, stop), so a start still
    /// waiting on its cache lookup knows a newer command replaced it.
    var onCommand: (@MainActor () -> Void)?
    /// Why the last start or play failed; nil once one succeeds.
    private(set) var lastFailure: LibraryStartFailure?

    init(
        engine: any ListenerAudioEngine,
        session: any ListenerAudioSession,
        nowPlaying: any ListenerNowPlaying,
        remoteCommands: any LibraryRemoteCommands,
        sessionEvents: any LibrarySessionEvents,
        artwork: LibraryArtworkCache? = nil,
        tickInterval: Duration = .milliseconds(500),
        remoteSeekSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        remoteSeekNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.artwork = artwork
        self.engine = engine
        self.session = session
        self.nowPlaying = nowPlaying
        self.remoteCommands = remoteCommands
        self.tickInterval = tickInterval
        self.remoteSeekSleep = remoteSeekSleep
        self.remoteSeekNow = remoteSeekNow
        engine.installCompletionHandler { [weak self] generation in
            Task { @MainActor in self?.engineFinished(generation: generation) }
        }
        sessionEvents.observe { [weak self] event in self?.handle(event) }
        // Artwork the app finishes caching after this item started still reaches Now Playing.
        artworkObserver = NotificationCenter.default.publisher(for: LibraryArtworkCache.didCache)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let item = self.item, self.artworkData == nil,
                          let url = note.object as? URL, url == item.artworkURL else { return }
                    self.loadArtwork(for: item)
                }
            }
    }

    /// The production player: real engine, audio session, Now Playing and system controls.
    static func live() -> LibraryPlayer {
        LibraryPlayer(
            engine: LibraryAudioEngine(), session: AVAudioSessionController(), nowPlaying: MediaPlayerNowPlaying(),
            remoteCommands: MediaPlayerLibraryRemoteCommands(), sessionEvents: AVAudioSessionEvents(),
            artwork: .shared)
    }

    // MARK: Transport

    /// Loads `item` and, unless `autoplay` is false, starts it at `start`. Returns false and
    /// sets `.failed` when the file cannot be loaded or the session or engine refuses.
    @discardableResult
    func start(_ item: Item, at start: TimeInterval = 0, autoplay: Bool = true) -> Bool {
        _ = cancelRemoteSeeking()
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        stopTicking()
        resumeAfterInterruption = false
        // "End of this episode" belongs to the episode it was set on, not to whatever plays next.
        if self.item?.entryID != item.entryID { stopsAfterCurrentItem = false }
        loadGeneration &+= 1
        do {
            try engine.load(url: item.fileURL, completionGeneration: loadGeneration)
        } catch {
            self.item = nil
            position = 0
            duration = 0
            remoteCommands.uninstall()
            return fail(.unreadableFile)
        }
        self.item = item
        artworkData = artwork?.loadedData(for: item.artworkURL)
        if artworkData == nil { loadArtwork(for: item) }
        duration = engine.duration
        if supportsRate, let defaultRate { rate = Self.clampRate(defaultRate) }
        applyRateToEngine()
        engine.currentTime = min(max(0, start), duration)
        position = engine.currentTime
        status = .paused
        remoteCommands.install { [weak self] command in self?.handle(command) ?? false }
        guard autoplay else {
            publishNowPlaying()
            return true
        }
        return playAdmitted()
    }

    /// Starts or resumes; after the end, starts over.
    @discardableResult
    func play() -> Bool {
        authorizePlayback == nil ? playAdmitted() : handle(LibraryRemoteCommand.play)
    }

    /// Synchronous effect consumed only after the model or system boundary admitted this target.
    @discardableResult
    func playAdmitted() -> Bool {
        _ = cancelRemoteSeeking()
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        guard item != nil else { return false }
        do { try session.activate() } catch { return fail(.audioSession) }
        if status == .ended { engine.currentTime = 0 }
        guard engine.play() else { return fail(.engineRefused) }
        lastFailure = nil
        status = .playing
        lastAccrual = .now
        position = engine.currentTime
        startTicking()
        publishNowPlaying()
        return true
    }

    func pause() {
        _ = cancelRemoteSeeking()
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        guard item != nil else { return }
        resumeAfterInterruption = false
        accrueListening()
        engine.pause()
        stopTicking()
        lastAccrual = nil
        position = min(engine.currentTime, duration)
        if status == .playing { status = .paused }
        publishNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: TimeInterval) {
        if authorizePlayback != nil, remoteSeekState?.wasPlaying == true { _ = handle(.seek(to: seconds)); return }
        seekAdmitted(to: seconds)
    }

    func seekAdmitted(to seconds: TimeInterval) {
        _ = cancelRemoteSeeking(resume: true)
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        guard item != nil else { return }
        let target = min(max(0, seconds), duration)
        engine.currentTime = target
        position = target
        if status == .ended, target < duration { status = .paused }
        publishNowPlaying()
    }

    func skip(by seconds: TimeInterval) { seek(to: position + seconds) }
    func skipBack() { skip(by: -TimeInterval(skipBackSeconds)) }
    func skipForward() { skip(by: TimeInterval(skipForwardSeconds)) }

    /// Takes the phone's Settings: the default speed applies from the next item started, the skip
    /// lengths apply at once, to the buttons and to the lock-screen commands.
    func apply(_ preferences: LibraryPlaybackPreferences) {
        defaultRate = preferences.defaultSpeed
        autoPlayNext = preferences.autoPlayNext
        skipBackSeconds = preferences.skipBackSeconds
        skipForwardSeconds = preferences.skipForwardSeconds
        remoteCommands.setSkipIntervals(back: TimeInterval(skipBackSeconds), forward: TimeInterval(skipForwardSeconds))
    }

    /// Within what the picker offers, which is what `AVAudioPlayer` accepts.
    private static func clampRate(_ value: Double) -> Double {
        min(max(value, PlaybackSpeeds.range.lowerBound), PlaybackSpeeds.range.upperBound)
    }

    /// The next speed up from `current`, wrapping from the fastest to the slowest. `current` need not
    /// be one of `PlaybackSpeeds.all` (a Settings speed the picker lacks): it steps to the next offered one above it.
    static func nextRate(after current: Double) -> Double {
        PlaybackSpeeds.all.first { $0 > current + 0.001 } ?? PlaybackSpeeds.all[0]
    }

    func setStopsAfterCurrentItem(_ on: Bool) { stopsAfterCurrentItem = on }

    func setRate(_ newRate: Double) {
        guard supportsRate else { return }
        rate = Self.clampRate(newRate)
        applyRateToEngine()
        publishNowPlaying()
    }

    /// Stops and forgets the item; the audio session and system controls are released.
    func stop() {
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        clearLoadedItem()
    }

    /// Library eligibility loss clears resume access immediately. An untouched natural finish
    /// still owns its automatic successor; unloading it is not a listener transport command.
    func invalidateLoadedItem() {
        guard let entryID = item?.entryID, naturalCompletion(after: entryID) != nil else {
            stop()
            return
        }
        clearLoadedItem()
    }

    private func clearLoadedItem() {
        _ = cancelRemoteSeeking()
        stopsAfterCurrentItem = false
        guard item != nil || status != .idle else { return }
        accrueListening()
        engine.pause()
        (engine as? LibraryAudioUnloading)?.clearAudio()
        cancelAdmission()
        stopTicking()
        lastAccrual = nil
        resumeAfterInterruption = false
        item = nil
        status = .idle
        position = 0
        duration = 0
        nowPlaying.clear()
        remoteCommands.uninstall()
        session.deactivate()
    }

    /// Syncs the readout with the engine; the timer calls this while playing.
    func refreshPosition() {
        guard item != nil, !isRemoteSeeking else { return }
        accrueListening()
        position = min(max(0, engine.currentTime), duration)
        // The engine stopped on its own without a completion (something else took the output).
        if status == .playing, !engine.isPlaying {
            status = .paused
            stopTicking()
            lastAccrual = nil
            publishNowPlaying()
        }
    }

    /// Reports the time played since the last report. A gap longer than `maxAccrual` (a suspended
    /// app) is capped rather than counted as listening.
    private func accrueListening() {
        guard status == .playing, let last = lastAccrual else { return }
        let now = ContinuousClock.now
        lastAccrual = now
        let gap = last.duration(to: now).components
        let wall = min(Double(gap.seconds) + Double(gap.attoseconds) / 1e18, Self.maxAccrual)
        onListened?(wall, rate)
    }

    // MARK: System events

    func handle(_ event: LibrarySessionEvent) {
        switch event {
        case .interruptionBegan:
            let wasPlaying = isPlaying
            pause()
            resumeAfterInterruption = wasPlaying
        case let .interruptionEnded(shouldResume):
            let resume = resumeAfterInterruption && shouldResume && item != nil
            resumeAfterInterruption = false
            if resume { handle(LibraryRemoteCommand.play) }
        case .routeLost:
            // Never resumes on its own: audio must not jump to the speaker when headphones leave.
            pause()
        }
    }

    // MARK: Internals

    private func engineFinished(generation: UInt64) {
        guard generation == loadGeneration, item != nil, status == .playing else { return }
        if isRemoteSeeking {
            position = min(max(0, engine.currentTime), duration)
            _ = cancelRemoteSeeking()
            return
        }
        stopTicking()
        endedAtTransportCount = transportCount
        lastNaturalCompletion = item.map {
            NaturalCompletion(entryID: $0.entryID, duration: duration, rate: rate, transportCount: transportCount)
        }
        position = duration
        status = .ended
        publishNowPlaying()
        let holdAtEnd = stopsAfterCurrentItem
        stopsAfterCurrentItem = false
        if let entryID = item?.entryID { onFinished?(entryID, autoPlayNext && !holdAtEnd) }
    }

    @discardableResult
    private func fail(_ failure: LibraryStartFailure) -> Bool {
        _ = cancelRemoteSeeking()
        stopTicking()
        engine.pause()
        if item == nil { (engine as? LibraryAudioUnloading)?.clearAudio() }
        cancelAdmission()
        lastFailure = failure
        status = .failed(failure.playerReason)
        nowPlaying.clear()
        return false
    }

    /// Pauses the engine so shuttling cannot produce a natural end or accrue listening time.
    func prepareRemoteSeeking() -> Bool {
        guard item != nil, status == .playing || status == .paused, duration.isFinite, duration > 0 else { return false }
        onCommand?(); transportCount &+= 1; cancelAdmission()
        accrueListening(); engine.pause(); stopTicking(); lastAccrual = nil
        return true
    }

    func moveRemoteSeeking(by distance: TimeInterval) -> Bool {
        let target = min(max(0, position + distance), duration)
        engine.currentTime = target; position = target
        publishNowPlaying()
        return target > 0 && target < duration
    }

    func restoreRemoteSeekingPlayback(resume: Bool) -> Bool {
        if resume, status == .playing {
            guard engine.play() else { return fail(.engineRefused) }
            lastAccrual = .now; startTicking()
        } else if status == .playing { status = .paused }
        publishNowPlaying()
        return true
    }

    private func applyRateToEngine() {
        (engine as? LibraryRateAdjustable)?.rate = Float(rate)
    }

    /// Reads the item's cached artwork off the main actor, then republishes. Never blocks the start and
    /// never reaches the network; no cached image means Now Playing simply has none.
    private func loadArtwork(for item: Item) {
        guard let artwork, let url = item.artworkURL else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let data = artwork.data(for: url) else { return }
            await MainActor.run {
                guard let self, self.item?.artworkURL == url, self.artworkData == nil else { return }
                self.artworkData = data
                self.publishNowPlaying()
            }
        }
    }

    func publishNowPlaying() {
        guard let item else { return }
        nowPlaying.update(ListenerNowPlayingInfo(
            title: item.title, artist: item.showTitle, duration: duration, position: position,
            rate: isPlaying && !isRemoteSeeking ? rate : 0, defaultRate: rate, artworkData: artworkData))
    }

    private func startTicking() {
        stopTicking()
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.refreshPosition()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
