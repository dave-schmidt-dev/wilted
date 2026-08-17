import AVFoundation
import Foundation
import Observation
import WiltedDomain

/// The small audio surface needed by the controller.  Keeping AVFoundation
/// behind this protocol makes all playback state tests deterministic.
@MainActor
public protocol PlaybackBackend: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }

    func load(url: URL) throws
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

/// AVFoundation implementation used by the Mac producer at runtime.
@MainActor
public final class AVAudioPlayerBackend: NSObject, PlaybackBackend {
    private var player: AVAudioPlayer?

    public override init() {
        super.init()
    }

    public var duration: TimeInterval { player?.duration ?? 0 }
    public var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = max(0, newValue) }
    }
    public var isPlaying: Bool { player?.isPlaying ?? false }

    public func load(url: URL) throws {
        let next = try AVAudioPlayer(contentsOf: url)
        next.prepareToPlay()
        player = next
    }

    @discardableResult
    public func play() -> Bool { player?.play() ?? false }
    public func pause() { player?.pause() }
    public func stop() { player?.stop(); player = nil }
}

public enum PlaybackControllerError: Error, Equatable, Sendable {
    case revisionBelongsToDifferentItem
    case noLoadedRevision
    case invalidSeek(TimeInterval)
}

/// Main-actor playback orchestration and durable resume state.
@Observable
@MainActor
public final class PlaybackController {
    @ObservationIgnored private let store: LocalLibraryStore
    @ObservationIgnored public let backend: any PlaybackBackend
    public let deviceID: String

    public private(set) var itemID: ItemID?
    public private(set) var revisionID: RevisionID?
    public private(set) var mediaURL: URL?
    public private(set) var positionSeconds: TimeInterval = 0
    public private(set) var durationSeconds: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var sessionID: String?
    public private(set) var sequence: Int64 = 1
    public private(set) var intent: PlaybackIntent = .progress
    public private(set) var completed = false

    private var currentRevision: AudioRevision?
    private var checkpointTask: Task<Void, Never>?

    public init(
        store: LocalLibraryStore,
        backend: any PlaybackBackend = AVAudioPlayerBackend(),
        deviceID: String = "mac"
    ) {
        self.store = store
        self.backend = backend
        self.deviceID = deviceID
    }

    /// Loads one immutable revision and only resumes a persisted state with
    /// the exact same item and revision identifiers.
    public func load(_ storedRevision: StoredAudioRevision) async throws {
        try await load(revision: storedRevision.revision, mediaURL: storedRevision.mediaURL)
    }

    public func load(revision: AudioRevision, mediaURL: URL) async throws {
        guard revision.itemID == itemID || itemID == nil else {
            throw PlaybackControllerError.revisionBelongsToDifferentItem
        }
        checkpointTask?.cancel()
        backend.stop()
        try backend.load(url: mediaURL)

        currentRevision = revision
        itemID = revision.itemID
        revisionID = revision.revisionID
        self.mediaURL = mediaURL
        durationSeconds = revision.durationSeconds
        if backend.duration > 0 { durationSeconds = backend.duration }

        let persisted = try await store.playbackState(for: revision.itemID, revisionID: revision.revisionID)
        if let persisted {
            sessionID = persisted.sessionID
            sequence = persisted.sequence
            intent = persisted.intent
            completed = persisted.completed
            positionSeconds = clamp(persisted.positionSeconds)
        } else {
            sessionID = Self.newSessionID()
            sequence = 1
            intent = .progress
            completed = false
            positionSeconds = 0
        }
        backend.currentTime = positionSeconds
        isPlaying = false
    }

    public func play() throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        isPlaying = backend.play()
    }

    public func pause() async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        backend.pause()
        isPlaying = false
        try await checkpoint()
    }

    public func toggle() async throws {
        if backend.isPlaying || isPlaying { try await pause() } else { try play() }
    }

    /// Moves the playhead while preserving the current session for ordinary
    /// forward movement. Any backward movement is an explicit rewind intent.
    public func seek(by offset: TimeInterval) async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        guard offset.isFinite else { throw PlaybackControllerError.invalidSeek(offset) }
        let target = clamp(positionSeconds + offset)
        if target < positionSeconds {
            try await beginNewSession(intent: .rewind, position: target)
        } else {
            backend.currentTime = target
            positionSeconds = target
            completed = target >= durationSeconds
            intent = .progress
            try await checkpoint()
        }
    }

    public func seekForward(seconds: TimeInterval = 15) async throws { try await seek(by: abs(seconds)) }
    public func seekBackward(seconds: TimeInterval = 15) async throws { try await seek(by: -abs(seconds)) }
    public func rewind(seconds: TimeInterval = 15) async throws { try await seekBackward(seconds: seconds) }

    /// Explicit restart is causally distinct from progress and starts a new
    /// session even when the playhead is already at zero.
    public func restart() async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        try await beginNewSession(intent: .restart, position: 0)
    }

    public func checkpoint() async throws {
        guard let revision = currentRevision, let itemID, let revisionID, let sessionID else {
            throw PlaybackControllerError.noLoadedRevision
        }
        positionSeconds = clamp(backend.currentTime)
        isPlaying = backend.isPlaying
        completed = positionSeconds >= durationSeconds
        sequence = max(1, sequence + 1)
        let state = try PlaybackState(
            itemID: itemID,
            revisionID: revisionID,
            sessionID: sessionID,
            sequence: sequence,
            positionSeconds: positionSeconds,
            durationSeconds: revision.durationSeconds,
            completed: completed,
            intent: intent,
            deviceID: deviceID,
            updatedAt: Timestamp(Date())
        )
        try await store.save(playback: state)
    }

    public func manualCheckpoint() async throws { try await checkpoint() }
    public func pauseAndCheckpoint() async throws { try await pause() }
    public func handlePauseOrQuit() async throws { backend.pause(); isPlaying = false; try await checkpoint() }

    /// Rebuilds the backend after an audio route/configuration change. The
    /// exact playhead and whether it was playing are captured before reload.
    public func recoverFromRouteChange() async throws {
        guard let mediaURL else { throw PlaybackControllerError.noLoadedRevision }
        let wasPlaying = backend.isPlaying || isPlaying
        let position = clamp(backend.currentTime)
        backend.stop()
        try backend.load(url: mediaURL)
        backend.currentTime = position
        positionSeconds = position
        isPlaying = wasPlaying && backend.play()
    }

    public func startPeriodicCheckpoint(every interval: TimeInterval = 5) {
        checkpointTask?.cancel()
        guard interval > 0, interval.isFinite else { return }
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                    guard let self else { return }
                    try await self.checkpoint()
                } catch is CancellationError { return }
                catch { /* a later manual checkpoint remains available */ }
            }
        }
    }

    public func stopPeriodicCheckpoint() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    private func beginNewSession(intent: PlaybackIntent, position: TimeInterval) async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        sessionID = Self.newSessionID()
        sequence = 0
        self.intent = intent
        completed = false
        let target = clamp(position)
        backend.currentTime = target
        positionSeconds = target
        try await checkpoint()
    }

    private func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value.isFinite ? value : 0, 0), max(durationSeconds, 0))
    }

    private static func newSessionID() -> String {
        "session-\(UUID().uuidString.lowercased())"
    }
}
