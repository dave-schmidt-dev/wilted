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
    func load(url: URL, completionGeneration: UInt64) throws
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void)
}

public extension ListenerAudioEngine {
    /// Compatibility bridge for engines that do not expose natural completion.
    func load(url: URL, completionGeneration: UInt64) throws { try load(url: url) }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

/// `nonisolated` because `AVAudioPlayerDelegate` is main-actor-isolated in the
/// iOS 27 SDK, and inheriting that isolation would make every member unable to
/// satisfy the nonisolated `ListenerAudioEngine` requirements. The engine was
/// always meant to be callable from any actor -- it is `@unchecked Sendable`
/// and guards its own mutable state with `completionLock`.
nonisolated public final class AVFoundationAudioEngine: NSObject, ListenerAudioEngine, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private let completionLock = NSLock()
    private var playerGeneration: [ObjectIdentifier: UInt64] = [:]
    private var completionHandler: (@Sendable (UInt64) -> Void)?
    public override init() { super.init() }
    public var duration: Double { player?.duration ?? 0 }
    public var currentTime: Double {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }
    public var isPlaying: Bool { player?.isPlaying ?? false }
    public func load(url: URL) throws {
        try load(url: url, completionGeneration: 0)
    }
    public func load(url: URL, completionGeneration: UInt64) throws {
        let loadedPlayer = try AVAudioPlayer(contentsOf: url)
        loadedPlayer.delegate = self
        loadedPlayer.prepareToPlay()
        completionLock.withLock {
            if let player { playerGeneration.removeValue(forKey: ObjectIdentifier(player)) }
            player = loadedPlayer
            playerGeneration[ObjectIdentifier(loadedPlayer)] = completionGeneration
        }
    }
    public func play() -> Bool { player?.play() ?? false }
    public func pause() { player?.pause() }
    public func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        completionLock.withLock { completionHandler = handler }
    }
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        let completion: (UInt64, (@Sendable (UInt64) -> Void)?)? = completionLock.withLock {
            guard let generation = playerGeneration.removeValue(forKey: ObjectIdentifier(player)) else { return nil }
            return (generation, completionHandler)
        }
        guard let (generation, handler) = completion else { return }
        handler?(generation)
    }
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

public enum ListenerRemoteCommand: Equatable, Sendable { case play, pause, rewind, restart }

public struct ListenerRemoteCommandResult: Equatable, Sendable {
    public let command: ListenerRemoteCommand
    public let state: PlaybackState
    public let isPlaying: Bool

    public init(command: ListenerRemoteCommand, state: PlaybackState, isPlaying: Bool) {
        self.command = command
        self.state = state
        self.isPlaying = isPlaying
    }
}

public protocol ListenerRemoteCommands: Sendable {
    func install(handler: @escaping @Sendable (ListenerRemoteCommand) async -> Void)
}

/// Bridges system remote commands into an injected async handler.
public final class MediaPlayerRemoteCommands: NSObject, ListenerRemoteCommands, @unchecked Sendable {
    private let center: MPRemoteCommandCenter
    private let handlerLock = NSLock()
    private var handler: (@Sendable (ListenerRemoteCommand) async -> Void)?
    private var deliveryTail: Task<Void, Never>?
    private var installedTargets = false
    public init(center: MPRemoteCommandCenter = .shared()) {
        self.center = center
        super.init()
    }
    public func install(handler: @escaping @Sendable (ListenerRemoteCommand) async -> Void) {
        let shouldInstallTargets = handlerLock.withLock {
            self.handler = handler
            guard !installedTargets else { return false }
            installedTargets = true
            return true
        }
        guard shouldInstallTargets else { return }
        center.playCommand.addTarget(self, action: #selector(receivePlay(_:)))
        center.pauseCommand.addTarget(self, action: #selector(receivePause(_:)))
        center.skipBackwardCommand.addTarget(self, action: #selector(receiveRewind(_:)))
        center.nextTrackCommand.addTarget(self, action: #selector(receiveRestart(_:)))
    }

    deinit {
        center.playCommand.removeTarget(self)
        center.pauseCommand.removeTarget(self)
        center.skipBackwardCommand.removeTarget(self)
        center.nextTrackCommand.removeTarget(self)
    }

    @objc func receivePlay(_ event: MPRemoteCommandEvent?) -> MPRemoteCommandHandlerStatus {
        enqueue(.play)
    }

    @objc func receivePause(_ event: MPRemoteCommandEvent?) -> MPRemoteCommandHandlerStatus {
        enqueue(.pause)
    }

    @objc func receiveRewind(_ event: MPRemoteCommandEvent?) -> MPRemoteCommandHandlerStatus {
        enqueue(.rewind)
    }

    @objc func receiveRestart(_ event: MPRemoteCommandEvent?) -> MPRemoteCommandHandlerStatus {
        enqueue(.restart)
    }

    private func enqueue(_ command: ListenerRemoteCommand) -> MPRemoteCommandHandlerStatus {
        handlerLock.withLock {
            guard let handler else { return .noActionableNowPlayingItem }
            let preceding = deliveryTail
            deliveryTail = Task {
                await preceding?.value
                await handler(command)
            }
            return .success
        }
    }
}

public actor ListenerPlaybackController {
    public nonisolated let statuses: AsyncStream<SyncStatus>
    public nonisolated let durableCheckpoints: AsyncStream<PlaybackState>
    public nonisolated let remoteCommandResults: AsyncStream<ListenerRemoteCommandResult>
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    private let checkpointContinuation: AsyncStream<PlaybackState>.Continuation
    private let remoteCommandContinuation: AsyncStream<ListenerRemoteCommandResult>.Continuation
    private let cache: ListenerAudioCache
    private let engine: any ListenerAudioEngine
    private let session: any ListenerAudioSession
    private let nowPlaying: any ListenerNowPlaying
    private var installedRemoteCommands: (any ListenerRemoteCommands)?
    private var currentState: PlaybackState?
    private var title = "Wilted"
    private var playbackGeneration: UInt64 = 0

    public init(cache: ListenerAudioCache, engine: any ListenerAudioEngine,
                session: any ListenerAudioSession = AVAudioSessionController(),
                nowPlaying: any ListenerNowPlaying = MediaPlayerNowPlaying()) {
        self.cache = cache; self.engine = engine; self.session = session; self.nowPlaying = nowPlaying
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = stream; self.statusContinuation = continuation
        let (checkpoints, checkpointContinuation) = AsyncStream<PlaybackState>.makeStream()
        self.durableCheckpoints = checkpoints
        self.checkpointContinuation = checkpointContinuation
        let (remoteCommands, remoteCommandContinuation) = AsyncStream<ListenerRemoteCommandResult>.makeStream()
        self.remoteCommandResults = remoteCommands
        self.remoteCommandContinuation = remoteCommandContinuation
        engine.installCompletionHandler { [weak self] generation in
            Task { await self?.completeNaturally(generation: generation) }
        }
    }

    public func play(asset: WiltedAsset, title: String, state: PlaybackState) async throws -> PlaybackState {
        emit(.init(phase: .staging, message: "Preparing offline audio"))
        guard let url = await cache.url(for: asset) else { throw ListenerError.cacheUnavailable(asset.assetID) }
        try session.activate()
        playbackGeneration &+= 1
        let generation = playbackGeneration
        try engine.load(url: url, completionGeneration: generation)
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

    /// Moves a loaded, paused item without starting playback again.
    ///
    /// A backward seek establishes a fresh causal session, while a forward seek
    /// continues the current session. The caller supplies that sync intent so
    /// this transport operation does not alter codec or merge behavior.
    public func seek(position: Double, intent: PlaybackIntent, newSession: Bool) throws -> PlaybackState? {
        guard let state = currentState else { return nil }
        let boundedPosition = min(max(0, position), min(state.durationSeconds, engine.duration))
        engine.currentTime = boundedPosition
        let updated = try PlaybackState(
            itemID: state.itemID,
            revisionID: state.revisionID,
            sessionID: newSession ? UUID().uuidString : state.sessionID,
            sequence: newSession ? 1 : state.sequence + 1,
            positionSeconds: boundedPosition,
            durationSeconds: state.durationSeconds,
            completed: false,
            intent: intent,
            deviceID: state.deviceID,
            encodedCloudKitRecordSystemFields: state.encodedCloudKitRecordSystemFields,
            updatedAt: Timestamp(Date())
        )
        currentState = updated
        nowPlaying.update(
            title: title,
            duration: engine.duration,
            position: boundedPosition,
            rate: engine.isPlaying ? 1 : 0
        )
        emit(.init(phase: .completed, message: "Playback seek applied"))
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
        guard engine.isPlaying, let state = currentState, !state.completed else {
            emit(.init(phase: .idle, message: "Playback background state published"))
            return nil
        }
        let updated = try nextState(from: state, position: position, intent: .progress, completed: false)
        currentState = updated
        emit(.init(phase: .idle, message: "Playback background state published"))
        return updated
    }

    /// Captures an actively playing engine position without pausing or changing the readout.
    /// Callers use this only at durable lifecycle boundaries such as item switches and the
    /// bounded background interval.
    public func liveCheckpoint() throws -> PlaybackState? {
        guard engine.isPlaying, let state = currentState, !state.completed else { return nil }
        let updated = try nextState(from: state, position: engine.currentTime, intent: .progress, completed: false)
        currentState = updated
        return updated
    }

    public func install(remoteCommands: any ListenerRemoteCommands) {
        installedRemoteCommands = remoteCommands
        remoteCommands.install { [weak self] command in
            await self?.handleRemote(command)
        }
    }

    private func handleRemote(_ command: ListenerRemoteCommand) async {
        let updated: PlaybackState?
        switch command {
        case .pause:
            engine.pause()
            updated = try? advanceRemote(position: engine.currentTime, intent: .progress, newSession: false, rate: 0)
        case .play:
            guard engine.play() else {
                emit(.init(phase: .failed, message: ListenerError.playbackUnavailable("audio engine refused playback").localizedDescription))
                return
            }
            updated = try? advanceRemote(position: engine.currentTime, intent: .progress, newSession: false, rate: 1)
        case .rewind:
            engine.currentTime = max(0, engine.currentTime - 15)
            updated = try? advanceRemote(position: engine.currentTime, intent: .rewind, newSession: true,
                                         rate: engine.isPlaying ? 1 : 0)
        case .restart:
            engine.currentTime = 0
            updated = try? advanceRemote(position: 0, intent: .restart, newSession: true,
                                         rate: engine.isPlaying ? 1 : 0)
        }
        if let updated {
            remoteCommandContinuation.yield(.init(command: command, state: updated, isPlaying: engine.isPlaying))
        }
    }

    private func completeNaturally(generation: UInt64) {
        guard generation == playbackGeneration, let state = currentState, !state.completed,
              let completed = try? nextState(
                  from: state,
                  position: state.durationSeconds,
                  intent: .progress,
                  completed: true
              ) else { return }
        currentState = completed
        nowPlaying.update(
            title: title,
            duration: engine.duration,
            position: completed.positionSeconds,
            rate: 0
        )
        checkpointContinuation.yield(completed)
        emit(.init(phase: .completed, message: "Playback completed"))
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
