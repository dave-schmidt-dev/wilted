import AVFoundation
import Foundation
import MediaPlayer
import WiltedLibrary
import WiltedPlayback

// MARK: - Production adapters

/// `AVAudioPlayer` with speed control and a completion callback per loaded file.
///
/// A separate class from `AVFoundationAudioEngine` because speed needs `enableRate` set before
/// the player prepares, and that engine's player is private to its package.
nonisolated final class LibraryAudioEngine: NSObject, ListenerAudioEngine, LibraryRateAdjustable, LibraryAudioUnloading, AVAudioPlayerDelegate, @unchecked Sendable {
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
    func clearAudio() { lock.withLock { player?.stop(); player?.delegate = nil; player = nil; generation &+= 1 } }

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
        add(center.nextTrackCommand) { _ in Self.transportCommand(forward: true, phase: nil) }
        add(center.previousTrackCommand) { _ in Self.transportCommand(forward: false, phase: nil) }
        add(center.seekForwardCommand) { event in
            guard let phase = (event as? MPSeekCommandEvent)?.type else { return nil }
            return Self.transportCommand(forward: true, phase: phase)
        }
        add(center.seekBackwardCommand) { event in
            guard let phase = (event as? MPSeekCommandEvent)?.type else { return nil }
            return Self.transportCommand(forward: false, phase: phase)
        }
        add(center.skipForwardCommand) { event in
            .skipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? LibraryPlayer.skipForwardSeconds)
        }
        add(center.skipBackwardCommand) { event in
            .skipBackward((event as? MPSkipIntervalCommandEvent)?.interval ?? LibraryPlayer.skipBackSeconds)
        }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek(to: $0.positionTime) }
        }
        // CarPlay's speed button follows this command (Apple: CPNowPlayingPlaybackRateButton "uses
        // MPRemoteCommandCenter to observe changes to the playback rate"). Without it enabled and
        // advertising rates, the button reads 0x even while the episode plays.
        center.changePlaybackRateCommand.supportedPlaybackRates = PlaybackSpeeds.all.map { NSNumber(value: $0) }
        add(center.changePlaybackRateCommand) { event in
            (event as? MPChangePlaybackRateCommandEvent).map { .setRate(Double($0.playbackRate)) }
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

    /// The actual public command objects whose targets this adapter currently owns.
    var registeredCommands: [MPRemoteCommand] { installed.map(\.command) }

    /// Shared public phase mapping; MPSeekCommandEvent has no public event constructor.
    nonisolated static func transportCommand(forward: Bool, phase: MPSeekCommandEventType?) -> LibraryRemoteCommand? {
        guard let phase else { return forward ? .skipForward(30) : .skipBackward(15) }
        switch phase {
        case .beginSeeking: return .beginSeeking(forward ? .forward : .backward)
        case .endSeeking: return .endSeeking(forward ? .forward : .backward)
        @unknown default: return nil
        }
    }

    /// Dispatches the same semantic mapping as the installed steering/seek targets.
    func dispatchTransport(_ command: MPRemoteCommand, phase: MPSeekCommandEventType? = nil) -> Bool {
        guard registeredCommands.contains(where: { $0 === command }) else { return false }
        if command === center.seekForwardCommand || command === center.seekBackwardCommand {
            guard phase != nil else { return false }
        }
        let forward: Bool
        if command === center.nextTrackCommand || command === center.seekForwardCommand { forward = true }
        else if command === center.previousTrackCommand || command === center.seekBackwardCommand { forward = false }
        else { return false }
        guard let translated = Self.transportCommand(forward: forward, phase: phase) else { return false }
        return handler?(translated) ?? false
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
