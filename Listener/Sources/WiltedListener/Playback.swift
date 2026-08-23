import AVFoundation
import Foundation
import MediaPlayer
import WiltedDomain
import WiltedSync

public protocol ListenerAudioEngine: AnyObject, Sendable {
    var duration: Double { get }
    var currentTime: Double { get set }
    var isPlaying: Bool { get }
    func load(url: URL) throws
    func play() -> Bool
    func pause()
}

public final class AVFoundationAudioEngine: ListenerAudioEngine, @unchecked Sendable {
    private var player: AVAudioPlayer?
    public init() {}
    public var duration: Double { player?.duration ?? 0 }
    public var currentTime: Double {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }
    public var isPlaying: Bool { player?.isPlaying ?? false }
    public func load(url: URL) throws { player = try AVAudioPlayer(contentsOf: url); player?.prepareToPlay() }
    public func play() -> Bool { player?.play() ?? false }
    public func pause() { player?.pause() }
}

public protocol ListenerAudioSession: Sendable {
    func activate() throws
    func deactivate()
}

public struct AVAudioSessionController: ListenerAudioSession {
    public init() {}
    public func activate() throws {
        #if os(iOS)
        // No options: `allowAirPlay` and `allowBluetoothA2DP` are valid only with
        // `playAndRecord`, and passing them with an output-only category fails the whole
        // activation with OSStatus -50. Both routes are implicitly available for `playback`.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
    public func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

public protocol ListenerNowPlaying: Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double)
    func clear()
}

public struct MediaPlayerNowPlaying: ListenerNowPlaying {
    public init() {}
    public func update(title: String, duration: Double, position: Double, rate: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
    }
    public func clear() { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
}

public enum ListenerRemoteCommand: Sendable { case play, pause, rewind, restart }

public protocol ListenerRemoteCommands: Sendable {
    func install(handler: @escaping @Sendable (ListenerRemoteCommand) async -> Void)
}

/// Bridges system remote commands into an injected async handler.
public final class MediaPlayerRemoteCommands: ListenerRemoteCommands, @unchecked Sendable {
    private let center: MPRemoteCommandCenter
    private var handler: (@Sendable (ListenerRemoteCommand) async -> Void)?
    public init(center: MPRemoteCommandCenter = .shared()) { self.center = center }
    public func install(handler: @escaping @Sendable (ListenerRemoteCommand) async -> Void) {
        self.handler = handler
        center.playCommand.addTarget { [weak self] _ in self?.dispatch(.play); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.dispatch(.pause); return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.dispatch(.rewind); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.dispatch(.restart); return .success }
    }
    private func dispatch(_ command: ListenerRemoteCommand) { if let handler { Task { await handler(command) } } }
}

public actor ListenerPlaybackController {
    public nonisolated let statuses: AsyncStream<SyncStatus>
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    private let cache: ListenerAudioCache
    private let engine: any ListenerAudioEngine
    private let session: any ListenerAudioSession
    private let nowPlaying: any ListenerNowPlaying
    private var currentState: PlaybackState?
    private var title = "Wilted"

    public init(cache: ListenerAudioCache, engine: any ListenerAudioEngine,
                session: any ListenerAudioSession = AVAudioSessionController(),
                nowPlaying: any ListenerNowPlaying = MediaPlayerNowPlaying()) {
        self.cache = cache; self.engine = engine; self.session = session; self.nowPlaying = nowPlaying
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = stream; self.statusContinuation = continuation
    }

    public func play(asset: WiltedAsset, title: String, state: PlaybackState) async throws -> PlaybackState {
        emit(.init(phase: .staging, message: "Preparing offline audio"))
        guard let url = await cache.url(for: asset) else { throw ListenerError.cacheUnavailable(asset.assetID) }
        try session.activate()
        try engine.load(url: url)
        self.title = title
        let start: Double
        switch state.intent {
        case .restart: start = 0
        case .rewind: start = min(state.positionSeconds, engine.duration)
        case .progress: start = min(state.positionSeconds, engine.duration)
        }
        engine.currentTime = start
        guard engine.play() else { throw ListenerError.playbackUnavailable("audio engine refused playback") }
        let updatedState = try nextState(from: state, position: start, intent: state.intent, completed: false)
        currentState = updatedState
        nowPlaying.update(title: title, duration: engine.duration, position: start, rate: 1)
        emit(.init(phase: .completed, message: "Offline playback started"))
        return updatedState
    }

    public func pause() throws -> PlaybackState? {
        engine.pause()
        nowPlaying.update(title: title, duration: engine.duration, position: engine.currentTime, rate: 0)
        guard let state = currentState else { return nil }
        let updated = try nextState(from: state, position: engine.currentTime, intent: .progress, completed: false)
        currentState = updated
        emit(.init(phase: .completed, message: "Playback paused"))
        return updated
    }

    public func handle(interruptionBegan: Bool) throws {
        if interruptionBegan { engine.pause(); emit(.init(phase: .idle, message: "Playback interrupted")) }
        else { emit(.init(phase: .idle, message: "Playback interruption ended")) }
    }

    public func handleRouteChange() { engine.pause(); emit(.init(phase: .idle, message: "Audio route changed")) }

    public func cancel() {
        engine.pause()
        emit(.init(phase: .failed, message: ListenerError.cancelled.localizedDescription))
    }

    public func applyRemote(_ incoming: PlaybackState, changeTagMatches: Bool) -> PlaybackMergeResult {
        guard let currentState else {
            self.currentState = incoming
            return mergePlayback(current: incoming, incoming: incoming, changeTagMatches: true)
        }
        let result = mergePlayback(current: currentState, incoming: incoming, changeTagMatches: changeTagMatches)
        if result.acceptedStateIsIncoming { self.currentState = incoming }
        return result
    }

    public func current() -> PlaybackState? { currentState }

    /// Returns a UI-only projection of the active engine position.
    ///
    /// This intentionally does not advance the durable playback sequence. Position snapshots
    /// keep the in-app and system Now Playing readouts current, while persistence remains tied
    /// to explicit lifecycle and playback transitions.
    public func liveReadout() throws -> PlaybackState? {
        guard engine.isPlaying, let state = currentState else { return nil }
        let position = min(max(0, engine.currentTime), state.durationSeconds)
        let readout = try PlaybackState(
            itemID: state.itemID,
            revisionID: state.revisionID,
            sessionID: state.sessionID,
            sequence: state.sequence,
            positionSeconds: position,
            durationSeconds: state.durationSeconds,
            completed: position >= state.durationSeconds,
            intent: .progress,
            deviceID: state.deviceID,
            encodedCloudKitRecordSystemFields: state.encodedCloudKitRecordSystemFields,
            updatedAt: Timestamp(Date())
        )
        nowPlaying.update(title: title, duration: engine.duration, position: position, rate: 1)
        return readout
    }

    public func enterBackground() throws -> PlaybackState? {
        let position = engine.currentTime
        nowPlaying.update(title: title, duration: engine.duration, position: position, rate: engine.isPlaying ? 1 : 0)
        guard let state = currentState else {
            emit(.init(phase: .idle, message: "Playback background state published"))
            return nil
        }
        let updated = try nextState(from: state, position: position, intent: .progress, completed: false)
        currentState = updated
        emit(.init(phase: .idle, message: "Playback background state published"))
        return updated
    }

    public func install(remoteCommands: any ListenerRemoteCommands) {
        remoteCommands.install { [weak self] command in
            await self?.handleRemote(command)
        }
    }

    private func handleRemote(_ command: ListenerRemoteCommand) async {
        switch command {
        case .pause:
            engine.pause()
            _ = try? advanceRemote(position: engine.currentTime, intent: .progress, newSession: false, rate: 0)
        case .play:
            _ = engine.play()
            _ = try? advanceRemote(position: engine.currentTime, intent: .progress, newSession: false, rate: 1)
        case .rewind:
            engine.currentTime = max(0, engine.currentTime - 15)
            _ = try? advanceRemote(position: engine.currentTime, intent: .rewind, newSession: true, rate: 1)
        case .restart:
            engine.currentTime = 0
            _ = try? advanceRemote(position: 0, intent: .restart, newSession: true, rate: 1)
        }
    }

    @discardableResult
    private func advanceRemote(position: Double, intent: PlaybackIntent, newSession: Bool, rate: Double) throws -> PlaybackState? {
        guard let state = currentState else { return nil }
        let sessionID = newSession ? "remote-\(state.sequence + 1)" : state.sessionID
        let updated = try PlaybackState(itemID: state.itemID, revisionID: state.revisionID, sessionID: sessionID,
                                        sequence: state.sequence + 1, positionSeconds: max(0, position),
                                        durationSeconds: state.durationSeconds, completed: false, intent: intent,
                                        deviceID: state.deviceID, encodedCloudKitRecordSystemFields: state.encodedCloudKitRecordSystemFields,
                                        updatedAt: Timestamp(Date()))
        currentState = updated
        nowPlaying.update(title: title, duration: engine.duration, position: updated.positionSeconds, rate: rate)
        emit(.init(phase: .completed, message: "Remote playback command applied"))
        return updated
    }

    private func nextState(from state: PlaybackState, position: Double, intent: PlaybackIntent, completed: Bool) throws -> PlaybackState {
        try PlaybackState(itemID: state.itemID, revisionID: state.revisionID, sessionID: state.sessionID,
                          sequence: state.sequence + 1, positionSeconds: max(0, position), durationSeconds: state.durationSeconds,
                          completed: completed, intent: intent, deviceID: state.deviceID,
                          encodedCloudKitRecordSystemFields: state.encodedCloudKitRecordSystemFields, updatedAt: Timestamp(Date()))
    }

    private func emit(_ status: SyncStatus) { statusContinuation.yield(status) }
}
