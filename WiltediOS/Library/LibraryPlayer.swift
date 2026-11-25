import AVFoundation
import Combine
import Foundation
import MediaPlayer
import OSLog
import WiltedDomain
import WiltedLibrary
import WiltedPlayback

/// An engine that reports whether natural playback completed successfully.
protocol LibraryCompletingAudioEngine: AnyObject {
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64, Bool) -> Void)
}

let playerLog = Logger(subsystem: "com.zerodelta.wilted", category: "Player")

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
        /// Set only for generated headline narration, which keeps progress and
        /// completion in the request ledger rather than episode sync records.
        var storyRequestID: String? = nil
        /// Where the artwork came from; the player reads only its local copy.
        var artworkURL: URL? = nil
        /// An audiobook volume's chapters in start order; empty for everything else.
        var chapters: [AudiobookChapter] = []
        /// Podcast chapters on the exact prepared revision; empty for chapterless and legacy items.
        var podcastChapters: [PodcastChapterMark] = []
        /// The prepared podcast revision the file holds, which ad feedback is about; nil for anything else.
        var feedbackRevisionID: RevisionID? = nil
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
    /// Identity hint needed when several publisher chapters collapse to one prepared-time point.
    @Published private(set) var selectedPodcastChapterIndex: Int?
    @Published private(set) var status: Status = .idle {
        // Anything that leaves `.playing` (pause, stop, a new item, a failure) also ends a spoken-bulletin hold.
        didSet {
            if status != .playing, speechHold != nil { speechHold = nil; onSpeechHoldEnded?() }
            if status != .paused { pausedPositionSetAt = nil } else if oldValue != .paused { pausedPositionSetAt = Date() }
        }
    }
    /// When the phone itself last set the paused position: the pause, or a seek made while paused.
    /// nil unless paused.
    var pausedPositionSetAt: Date?
    /// Set while a spoken bulletin holds program audio: the engine is stopped, status stays `.playing`, the
    /// timer keeps running and the position is the checkpoint. Owned by `LibraryPlayerInterruptions`.
    @Published var speechHold: LibrarySpeechHold?
    /// Told when something other than the speech ended the hold (a pause, a stop, a new item).
    var onSpeechHoldEnded: (@MainActor () -> Void)?
    /// Asks the interruptions to skip the bulletin being spoken (next-track, or a command that replaces it).
    var onSpeechSkip: (@MainActor () -> Void)?
    /// Seconds into the file. Refreshed on every transport change and on a timer while playing.
    @Published var position: TimeInterval = 0
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
    /// Called before a newly loaded item replaces an already loaded one, with the outgoing item's ID and playhead.
    var onWillReplaceItem: ((ItemID, TimeInterval) -> Void)?
    /// Counts every transport action (start, play, pause, seek, stop); `owns(_:)` compares it
    /// with its value when the item finished, so a command given after the end cancels what follows it.
    private(set) var transportCount = 0
    /// Changes when a listener explicitly holds automatic story playback.
    /// Automatic episode starts do not change this fence.
    private(set) var storyAutoStartEpoch: UInt64 = 0
    var onStoryQueueRearm: (@MainActor (UInt64) -> Void)?
    var onStoryQueueHold: (@MainActor (UInt64) -> Void)?
    private var autoPausedAt: (generation: UInt64, transportCount: Int)?
    var admissionEpoch: UInt64 = 0
    var admissionTask: Task<Void, Never>?
    var authorizePlayback: (@MainActor (Item) async -> Bool)?
    /// Asked alongside `authorizePlayback` when a play command resumes the paused item: where
    /// another device has played it on to since, or nil to resume in place.
    var resumePosition: (@MainActor (Item) async -> TimeInterval?)?
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

    let engine: any ListenerAudioEngine
    let session: any ListenerAudioSession
    private let nowPlaying: any ListenerNowPlaying
    let remoteCommands: any LibraryRemoteCommands
    /// True once the system command handlers are registered; they stay registered with nothing loaded.
    var remoteCommandsInstalled = false
    /// Where a play or play/pause command goes when nothing is loaded. Set by the runtime, which knows the library.
    var onIdleRemoteCommand: (@MainActor (LibraryRemoteCommand) -> Bool)?
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
    var lastAccrual: ContinuousClock.Instant?
    /// Told how many real seconds were just played and at what speed, for the phone's own totals.
    var onListened: (@MainActor (_ wall: TimeInterval, _ rate: Double) -> Void)?
    /// Told before every transport command (start, play, pause, seek, stop), so a start still
    /// waiting on its cache lookup knows a newer command replaced it.
    var onCommand: (@MainActor () -> Void)?
    /// Why the last start or play failed; nil once one succeeds.
    private(set) var lastFailure: LibraryStartFailure?
    /// The durable record of commands, starts and stops; nil in tests and previews.
    var journal: LibraryJournal?
    /// Where a start position came from, set by the model when it picks one; used only for that entry.
    var pendingPositionSource: (entryID: ItemID, source: String)?

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
        if let completing = engine as? any LibraryCompletingAudioEngine {
            completing.installCompletionHandler { [weak self] generation, successfully in
                Task { @MainActor in self?.engineFinished(generation: generation, successfully: successfully) }
            }
        } else {
            engine.installCompletionHandler { [weak self] generation in
                Task { @MainActor in self?.engineFinished(generation: generation, successfully: true) }
            }
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
    func start(_ item: Item, at start: TimeInterval = 0, autoplay: Bool = true,
               traceToken: UInt64 = 0, automatic: Bool = false, startingRate: Double? = nil) -> Bool {
        if let old = self.item, old.entryID != item.entryID { journal?.note("stop reason=replaced entry=\(old.entryID.rawValue) position=\(String(format: "%.1f", position))") }
        _ = cancelRemoteSeeking()
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        if !automatic { rearmStoryQueueForExplicitStart() }
        stopTicking()
        resumeAfterInterruption = false
        // "End of this episode" belongs to the episode it was set on, not to whatever plays next.
        if self.item?.entryID != item.entryID { stopsAfterCurrentItem = false }
        if let outgoing = self.item {
            let outgoingTime = holdsOwnPosition ? position : engine.currentTime
            let outgoingPosition = duration > 0 ? min(max(0, outgoingTime), duration) : max(0, outgoingTime)
            position = outgoingPosition
            onWillReplaceItem?(outgoing.entryID, outgoingPosition)
        }
        loadGeneration &+= 1
        do {
            try engine.load(url: item.fileURL, completionGeneration: loadGeneration)
        } catch {
            let nsError = error as NSError
            playerLog.error("Load failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            self.item = nil
            position = 0
            duration = 0
            return fail(.unreadableFile)
        }
        LibraryPlaybackTrace.shared.record(.loadCalled, token: traceToken)
        self.item = item
        selectedPodcastChapterIndex = nil
        journal?.note("start entry=\(item.entryID.rawValue) title=\"\(item.title.prefix(40))\" position=\(String(format: "%.1f", start)) autoplay=\(autoplay) position-source=\(pendingPositionSource?.entryID == item.entryID ? pendingPositionSource?.source ?? "unknown" : start == 0 ? "zero" : "unknown")")
        pendingPositionSource = nil
        artworkData = artwork?.loadedData(for: item.artworkURL)
        if artworkData == nil { loadArtwork(for: item) }
        duration = engine.duration
        if supportsRate, let chosenRate = startingRate ?? defaultRate { rate = Self.clampRate(chosenRate) }
        applyRateToEngine()
        engine.currentTime = min(max(0, start), duration)
        position = engine.currentTime
        status = .paused
        installRemoteCommands()
        guard autoplay else {
            publishNowPlaying()
            return true
        }
        return playAdmitted(traceToken: traceToken)
    }

    /// Starts or resumes; after the end, starts over.
    @discardableResult
    func play() -> Bool {
        authorizePlayback == nil ? playAdmitted() : handle(LibraryRemoteCommand.play)
    }

    /// Synchronous effect consumed only after the model or system boundary admitted this target.
    @discardableResult
    func playAdmitted(traceToken: UInt64 = 0) -> Bool {
        skipSpeechForCommand()
        _ = cancelRemoteSeeking()
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        rearmStoryQueueForExplicitStart()
        autoPausedAt = nil
        guard item != nil else { return false }
        do {
            try session.activate()
        } catch {
            let nsError = error as NSError
            playerLog.error("Audio session activation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            return fail(.audioSession)
        }
        LibraryPlaybackTrace.shared.record(.sessionActivated, token: traceToken)
        if status == .ended { engine.currentTime = 0 } else if holdsOwnPosition { engine.currentTime = position }
        guard engine.play() else { return fail(.engineRefused) }
        journal?.note("play entry=\(item?.entryID.rawValue ?? "") position=\(String(format: "%.1f", engine.currentTime))")
        LibraryPlaybackTrace.shared.record(.playCalled, token: traceToken)
        lastFailure = nil
        status = .playing
        lastAccrual = .now
        position = engine.currentTime
        startTicking()
        publishNowPlaying()
        return true
    }

    func pause(reason: String = "direct") {
        _ = cancelRemoteSeeking()
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        if reason != "interruption" {
            storyAutoStartEpoch &+= 1
            onStoryQueueHold?(storyAutoStartEpoch)
        }
        guard item != nil else { return }
        resumeAfterInterruption = false
        accrueListening()
        engine.pause()
        stopTicking()
        lastAccrual = nil
        if !holdsOwnPosition { position = min(engine.currentTime, duration) }
        journal?.note("stop reason=pause pause-reason=\(reason) entry=\(item?.entryID.rawValue ?? "") position=\(String(format: "%.1f", position))")
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
        skipSpeechForCommand()
        _ = cancelRemoteSeeking(resume: true)
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        guard item != nil else { return }
        selectedPodcastChapterIndex = nil
        let target = min(max(0, seconds), duration)
        engine.currentTime = target
        position = target
        if status == .ended, target < duration { status = .paused } else if status == .paused { pausedPositionSetAt = Date() }
        publishNowPlaying()
    }

    func setSelectedPodcastChapterIndex(_ index: Int?) {
        selectedPodcastChapterIndex = index
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

    func setStopsAfterCurrentItem(_ on: Bool) {
        stopsAfterCurrentItem = on
        if on {
            storyAutoStartEpoch &+= 1
            onStoryQueueHold?(storyAutoStartEpoch)
        } else {
            rearmStoryQueueForExplicitStart()
        }
    }

    func setRate(_ newRate: Double) {
        guard supportsRate else { return }
        rate = Self.clampRate(newRate)
        applyRateToEngine()
        publishNowPlaying()
    }

    /// Stops and forgets the item and releases the audio session. The system command handlers stay
    /// registered, so a play command can still start something from the library.
    func stop() {
        onCommand?()
        transportCount &+= 1; cancelAdmission()
        storyAutoStartEpoch &+= 1
        onStoryQueueHold?(storyAutoStartEpoch)
        clearLoadedItem()
    }

    private func rearmStoryQueueForExplicitStart() {
        storyAutoStartEpoch &+= 1
        onStoryQueueRearm?(storyAutoStartEpoch)
    }

    /// A committed Listen next request is also an explicit release of the stop fence.
    func rearmStoryQueueForExplicitListenNext() {
        rearmStoryQueueForExplicitStart()
    }

    /// Restores the durable queue fence before the player accepts commands after relaunch.
    func restoreStoryAutoStartEpoch(_ epoch: UInt64) {
        storyAutoStartEpoch = max(storyAutoStartEpoch, epoch)
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
        if let item { journal?.note("stop reason=unload entry=\(item.entryID.rawValue) position=\(String(format: "%.1f", position))") }
        item = nil
        status = .idle
        position = 0
        duration = 0
        nowPlaying.clear()
        session.deactivate()
    }

    /// While paused, or loaded after a failed play, the player's own position is the truth and the
    /// engine is never read: after a suspension `AVAudioPlayer` can come back at its last seek instead
    /// of where it paused (2026-11-18). Every resume writes the position back to the engine, and every
    /// seek moves both.
    var holdsOwnPosition: Bool {
        switch status {
        case .paused: true
        case .failed: item != nil
        case .idle, .playing, .ended: false
        }
    }

    /// Syncs the readout with the engine; the timer calls this while playing.
    func refreshPosition() {
        // A spoken bulletin holds the position as the checkpoint and its time is not listening time.
        guard item != nil, !isRemoteSeeking, speechHold == nil, !holdsOwnPosition else { return }
        accrueListening()
        position = min(max(0, engine.currentTime), duration)
        // The engine stopped on its own without a completion (something else took the output).
        if status == .playing, !engine.isPlaying {
            autoPausedAt = (loadGeneration, transportCount)
            status = .paused
            stopTicking()
            lastAccrual = nil
            publishNowPlaying()
        }
    }

    /// Reports the time played since the last report. A gap longer than `maxAccrual` (a suspended
    /// app) is capped rather than counted as listening.
    func accrueListening() {
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
            pause(reason: "interruption")
            resumeAfterInterruption = wasPlaying
        case let .interruptionEnded(shouldResume):
            let resume = resumeAfterInterruption && shouldResume && item != nil
            resumeAfterInterruption = false
            if resume { handle(LibraryRemoteCommand.play) }
        case .routeLost:
            // Never resumes on its own: audio must not jump to the speaker when headphones leave.
            pause(reason: "routeLost")
        }
    }

    // MARK: Internals

    private func engineFinished(generation: UInt64, successfully: Bool) {
        guard generation == loadGeneration, item != nil else { return }
        guard successfully else {
            playerLog.error("Engine completion reported failure for generation \(generation, privacy: .public)")
            if status == .playing {
                status = .paused
                stopTicking()
                lastAccrual = nil
                publishNowPlaying()
            }
            return
        }
        let isAutoPaused = status == .paused && autoPausedAt?.generation == generation && autoPausedAt?.transportCount == transportCount
        guard status == .playing || isAutoPaused else { return }
        autoPausedAt = nil
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
        if let item { journal?.note("stop reason=natural-end entry=\(item.entryID.rawValue) position=\(String(format: "%.1f", duration))") }
        publishNowPlaying()
        let holdAtEnd = stopsAfterCurrentItem
        stopsAfterCurrentItem = false
        if let entryID = item?.entryID { onFinished?(entryID, autoPlayNext && !holdAtEnd) }
    }

    @discardableResult
    func fail(_ failure: LibraryStartFailure) -> Bool {
        playerLog.error("Player failure: \(failure.playerReason, privacy: .public)")
        journal?.note("stop reason=fail failure=\(failure.playerReason) entry=\(item?.entryID.rawValue ?? "") position=\(String(format: "%.1f", position))")
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
        skipSpeechForCommand()
        onCommand?(); transportCount &+= 1; cancelAdmission()
        accrueListening(); engine.pause(); stopTicking(); lastAccrual = nil
        return true
    }

    func moveRemoteSeeking(by distance: TimeInterval) -> Bool {
        let target = min(max(0, position + distance), duration)
        engine.currentTime = target; position = target
        if status == .paused { pausedPositionSetAt = Date() }
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
            title: speechHold?.title ?? item.title, artist: speechHold == nil ? item.showTitle : item.title, duration: duration, position: position,
            rate: isPlaying && !isRemoteSeeking ? rate : 0, defaultRate: rate, artworkData: artworkData))
    }

    func startTicking() {
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

    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
