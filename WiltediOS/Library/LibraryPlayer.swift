import AVFoundation
import Foundation
import MediaPlayer
import WiltedDomain
import WiltedListener

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

/// A lock-screen or headset control the player understands.
enum LibraryRemoteCommand: Equatable, Sendable {
    case play, pause, togglePlayPause
    case skipForward(TimeInterval)
    case skipBackward(TimeInterval)
    case seek(to: TimeInterval)
}

@MainActor protocol LibraryRemoteCommands: AnyObject {
    /// The handler returns whether the command did anything.
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool)
    func uninstall()
    /// The lengths the lock-screen skip buttons advertise. Optional: doubles need not care.
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval)
}

extension LibraryRemoteCommands {
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval) {}
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
    }

    enum Status: Equatable {
        case idle
        case playing
        case paused
        /// Reached the end; playing again starts over.
        case ended
        case failed(String)
    }

    /// Speeds the picker offers; `AVAudioPlayer` accepts 0.5 through 2.
    static let rates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    nonisolated static let skipBackSeconds: TimeInterval = 15
    nonisolated static let skipForwardSeconds: TimeInterval = 30

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

    var isPlaying: Bool { status == .playing }
    /// False for an engine with no speed control, so the UI can hide the picker.
    var supportsRate: Bool { engine is LibraryRateAdjustable }

    private let engine: any ListenerAudioEngine
    private let session: any ListenerAudioSession
    private let nowPlaying: any ListenerNowPlaying
    private let remoteCommands: any LibraryRemoteCommands
    private let tickInterval: Duration
    private var loadGeneration: UInt64 = 0
    private var resumeAfterInterruption = false
    private var tickTask: Task<Void, Never>?

    init(
        engine: any ListenerAudioEngine,
        session: any ListenerAudioSession,
        nowPlaying: any ListenerNowPlaying,
        remoteCommands: any LibraryRemoteCommands,
        sessionEvents: any LibrarySessionEvents,
        tickInterval: Duration = .milliseconds(500)
    ) {
        self.engine = engine
        self.session = session
        self.nowPlaying = nowPlaying
        self.remoteCommands = remoteCommands
        self.tickInterval = tickInterval
        engine.installCompletionHandler { [weak self] generation in
            Task { @MainActor in self?.engineFinished(generation: generation) }
        }
        sessionEvents.observe { [weak self] event in self?.handle(event) }
    }

    /// The production player: real engine, audio session, Now Playing and system controls.
    static func live() -> LibraryPlayer {
        LibraryPlayer(
            engine: LibraryAudioEngine(), session: AVAudioSessionController(), nowPlaying: MediaPlayerNowPlaying(),
            remoteCommands: MediaPlayerLibraryRemoteCommands(), sessionEvents: AVAudioSessionEvents())
    }

    // MARK: Transport

    /// Loads `item` and, unless `autoplay` is false, starts it at `start`. Returns false and
    /// sets `.failed` when the file cannot be loaded or the session or engine refuses.
    @discardableResult
    func start(_ item: Item, at start: TimeInterval = 0, autoplay: Bool = true) -> Bool {
        stopTicking()
        resumeAfterInterruption = false
        loadGeneration &+= 1
        do {
            try engine.load(url: item.fileURL, completionGeneration: loadGeneration)
        } catch {
            self.item = nil
            position = 0
            duration = 0
            remoteCommands.uninstall()
            return fail("Could not open the audio file")
        }
        self.item = item
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
        return play()
    }

    /// Starts or resumes; after the end, starts over.
    @discardableResult
    func play() -> Bool {
        guard item != nil else { return false }
        do { try session.activate() } catch { return fail("Could not start the audio session") }
        if status == .ended { engine.currentTime = 0 }
        guard engine.play() else { return fail("The audio engine refused to play") }
        status = .playing
        position = engine.currentTime
        startTicking()
        publishNowPlaying()
        return true
    }

    func pause() {
        guard item != nil else { return }
        resumeAfterInterruption = false
        engine.pause()
        stopTicking()
        position = min(engine.currentTime, duration)
        if status == .playing { status = .paused }
        publishNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: TimeInterval) {
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
        skipBackSeconds = preferences.skipBackSeconds
        skipForwardSeconds = preferences.skipForwardSeconds
        remoteCommands.setSkipIntervals(back: TimeInterval(skipBackSeconds), forward: TimeInterval(skipForwardSeconds))
    }

    /// Within what the picker offers, which is what `AVAudioPlayer` accepts.
    private static func clampRate(_ value: Double) -> Double {
        min(max(value, rates.first ?? 0.5), rates.last ?? 2)
    }

    func setRate(_ newRate: Double) {
        guard supportsRate else { return }
        rate = Self.clampRate(newRate)
        applyRateToEngine()
        publishNowPlaying()
    }

    /// Stops and forgets the item; the audio session and system controls are released.
    func stop() {
        guard item != nil || status != .idle else { return }
        engine.pause()
        stopTicking()
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
        guard item != nil else { return }
        position = min(max(0, engine.currentTime), duration)
        // The engine stopped on its own without a completion (something else took the output).
        if status == .playing, !engine.isPlaying {
            status = .paused
            stopTicking()
            publishNowPlaying()
        }
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
            if resume { play() }
        case .routeLost:
            // Never resumes on its own: audio must not jump to the speaker when headphones leave.
            pause()
        }
    }

    @discardableResult
    func handle(_ command: LibraryRemoteCommand) -> Bool {
        guard item != nil else { return false }
        switch command {
        case .play: play()
        case .pause: pause()
        case .togglePlayPause: togglePlayPause()
        case let .skipForward(seconds): skip(by: seconds)
        case let .skipBackward(seconds): skip(by: -seconds)
        case let .seek(seconds): seek(to: seconds)
        }
        return true
    }

    // MARK: Internals

    private func engineFinished(generation: UInt64) {
        guard generation == loadGeneration, item != nil, status == .playing else { return }
        stopTicking()
        position = duration
        status = .ended
        publishNowPlaying()
    }

    @discardableResult
    private func fail(_ message: String) -> Bool {
        stopTicking()
        engine.pause()
        status = .failed(message)
        nowPlaying.clear()
        return false
    }

    private func applyRateToEngine() {
        (engine as? LibraryRateAdjustable)?.rate = Float(rate)
    }

    private func publishNowPlaying() {
        guard let item else { return }
        nowPlaying.update(title: item.title, duration: duration, position: position, rate: isPlaying ? rate : 0)
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

// MARK: - Production adapters

/// `AVAudioPlayer` with speed control and a completion callback per loaded file.
///
/// A separate class from `AVFoundationAudioEngine` because speed needs `enableRate` set before
/// the player prepares, and that engine's player is private to its package.
nonisolated final class LibraryAudioEngine: NSObject, ListenerAudioEngine, LibraryRateAdjustable, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var generation: UInt64 = 0
    private var completion: (@Sendable (UInt64) -> Void)?
    private var desiredRate: Float = 1

    var duration: Double { lock.withLock { player?.duration ?? 0 } }
    var isPlaying: Bool { lock.withLock { player?.isPlaying ?? false } }
    var currentTime: Double {
        get { lock.withLock { player?.currentTime ?? 0 } }
        set { lock.withLock { player?.currentTime = newValue } }
    }
    var rate: Float {
        get { lock.withLock { desiredRate } }
        set { lock.withLock { desiredRate = newValue; player?.rate = newValue } }
    }

    func load(url: URL) throws { try load(url: url, completionGeneration: 0) }

    func load(url: URL, completionGeneration: UInt64) throws {
        let loaded = try AVAudioPlayer(contentsOf: url)
        loaded.delegate = self
        loaded.enableRate = true
        loaded.prepareToPlay()
        lock.withLock {
            player?.stop()
            loaded.rate = desiredRate
            player = loaded
            generation = completionGeneration
        }
    }

    func play() -> Bool { lock.withLock { player?.play() ?? false } }
    func pause() { lock.withLock { player?.pause() } }

    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock { completion = handler }
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        let report: (UInt64, (@Sendable (UInt64) -> Void)?)? = lock.withLock {
            player === finished ? (generation, completion) : nil
        }
        if let (generation, handler) = report { handler?(generation) }
    }
}

/// Lock-screen, headset and Control Center transport controls.
@MainActor
final class MediaPlayerLibraryRemoteCommands: LibraryRemoteCommands {
    private let center: MPRemoteCommandCenter
    private var installed: [(command: MPRemoteCommand, token: Any)] = []
    private var skipBack = LibraryPlayer.skipBackSeconds
    private var skipForward = LibraryPlayer.skipForwardSeconds

    init(center: MPRemoteCommandCenter = .shared()) { self.center = center }

    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {
        uninstall()
        publishSkipIntervals()
        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(center.skipForwardCommand) { event in
            .skipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? LibraryPlayer.skipForwardSeconds)
        }
        add(center.skipBackwardCommand) { event in
            .skipBackward((event as? MPSkipIntervalCommandEvent)?.interval ?? LibraryPlayer.skipBackSeconds)
        }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek(to: $0.positionTime) }
        }
        self.handler = handler
    }

    func setSkipIntervals(back: TimeInterval, forward: TimeInterval) {
        skipBack = back
        skipForward = forward
        publishSkipIntervals()
    }

    private func publishSkipIntervals() {
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
    }

    func uninstall() {
        for (command, token) in installed { command.removeTarget(token) }
        installed = []
        handler = nil
    }

    private var handler: (@MainActor (LibraryRemoteCommand) -> Bool)?

    /// The system may call from any thread; the command is delivered on the main actor in order.
    private func add(_ command: MPRemoteCommand, translate: @escaping @Sendable (MPRemoteCommandEvent) -> LibraryRemoteCommand?) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] event in
            guard let translated = translate(event) else { return .commandFailed }
            Task { @MainActor in _ = self?.handler?(translated) }
            return .success
        }
        installed.append((command, token))
    }
}

/// Forwards `AVAudioSession` interruption and route-change notifications.
@MainActor
final class AVAudioSessionEvents: LibrarySessionEvents {
    private var tokens: [NSObjectProtocol] = []

    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {
        #if os(iOS)
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            let event: LibrarySessionEvent = type == .began
                ? .interruptionBegan
                : .interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false)
            MainActor.assumeIsolated { handler(event) }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { handler(.routeLost) }
        })
        #endif
    }
}
