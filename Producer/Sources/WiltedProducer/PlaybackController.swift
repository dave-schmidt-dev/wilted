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
    var rate: Float { get set }
    var volume: Float { get set }
    var loadedGeneration: UInt64 { get }
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)? { get set }

    func load(url: URL) throws
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

/// AVFoundation implementation used by the Mac producer at runtime.
@MainActor
public final class AVAudioPlayerBackend: NSObject, PlaybackBackend, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var playerGenerations: [ObjectIdentifier: UInt64] = [:]
    public private(set) var loadedGeneration: UInt64 = 0
    public var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    public var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    public var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

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
        next.delegate = self
        next.enableRate = true
        next.rate = rate
        next.volume = volume
        next.prepareToPlay()
        loadedGeneration &+= 1
        playerGenerations[ObjectIdentifier(next)] = loadedGeneration
        player = next
    }

    @discardableResult
    public func play() -> Bool { player?.play() ?? false }
    public func pause() { player?.pause() }
    public func stop() { player?.stop(); player = nil }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let generation = self.playerGenerations.removeValue(forKey: playerID) else {
                return
            }
            self.completionHandler?(generation, flag)
        }
    }
}

public enum PlaybackControllerError: Error, Equatable, Sendable {
    case revisionBelongsToDifferentItem
    case noLoadedRevision
    case invalidSeek(TimeInterval)
    case podcastMediaUnavailable(ItemID)
    case podcastMediaUnreadable(ItemID)
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
    /// The playhead as the audio engine reports it right now.
    ///
    /// `positionSeconds` is checkpoint state: it moves only when something
    /// causal happens (load, seek, checkpoint), because that is the value
    /// that gets persisted and synced. A readout that polls it while audio
    /// runs therefore sees it frozen at the last checkpoint, which is why the
    /// producer's elapsed time only moved when a transport button was
    /// pressed. These two are the display reads, and they write nothing.
    public var livePositionSeconds: TimeInterval { clamp(backend.currentTime) }
    public var liveIsPlaying: Bool { backend.isPlaying }
    public var playbackRate: Float { backend.rate }

    public private(set) var sessionID: String?
    public private(set) var sequence: Int64 = 1
    public private(set) var intent: PlaybackIntent = .progress
    public private(set) var completed = false
    public private(set) var recoverableFault: PlaybackControllerError?
    @ObservationIgnored public var podcastStateHandler: (@MainActor @Sendable (ItemID?, PlaybackControllerError?) -> Void)?

    private var currentRevision: AudioRevision?
    private var checkpointTask: Task<Void, Never>?
    private var completionHandledGeneration: UInt64?
    private var loadedBackendGeneration: UInt64?

    public init(
        store: LocalLibraryStore,
        backend: any PlaybackBackend = AVAudioPlayerBackend(),
        deviceID: String = "mac"
    ) {
        self.store = store
        self.backend = backend
        self.deviceID = deviceID
        self.backend.completionHandler = { [weak self] generation, successfully in
            Task { @MainActor [weak self] in
                await self?.handleBackendCompletion(generation: generation, successfully: successfully)
            }
        }
    }

    /// Loads one immutable revision and only resumes a persisted state with
    /// the exact same item and revision identifiers.
    public func load(_ storedRevision: StoredAudioRevision) async throws {
        try await load(revision: storedRevision.revision, mediaURL: storedRevision.mediaURL)
    }

    public func load(revision: AudioRevision, mediaURL: URL) async throws {
        try await loadRevision(revision, mediaURL: mediaURL)
    }

    private func loadRevision(_ revision: AudioRevision, mediaURL: URL) async throws {
        let persisted = try await store.playbackState(
            for: revision.itemID,
            revisionID: revision.revisionID
        )
        try backend.load(url: mediaURL)
        checkpointTask?.cancel()
        loadedBackendGeneration = backend.loadedGeneration
        setRate(1)

        currentRevision = revision
        itemID = revision.itemID
        revisionID = revision.revisionID
        self.mediaURL = mediaURL
        durationSeconds = revision.durationSeconds
        if backend.duration > 0 { durationSeconds = backend.duration }

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
        recoverableFault = nil
        completionHandledGeneration = nil
    }

    /// Restores the durable current queue item without starting a duplicate
    /// playback session. Loading the exact revision reuses its saved session.
    public func restorePodcastQueue() async {
        guard let current = try? await store.podcastQueueState().currentEpisodeID else { return }
        do { try await loadQueuedEpisode(current, playAfterLoad: false) }
        catch { podcastStateHandler?(current, recoverableFault) }
    }

    public func replacePodcastQueue(_ state: PodcastQueueState) async throws {
        try await store.replacePodcastQueue(state)
    }

    public func addPodcastQueueEpisode(_ episodeID: ItemID) async throws {
        try await store.addPodcastQueueEpisode(episodeID)
    }

    public func removePodcastQueueEpisode(_ episodeID: ItemID) async throws {
        try await store.removePodcastQueueEpisode(episodeID)
    }

    public func movePodcastQueueEpisode(from source: Int, to destination: Int) async throws {
        try await store.movePodcastQueueEpisode(from: source, to: destination)
    }

    public func selectPodcastQueueEpisode(_ episodeID: ItemID, autoplay: Bool = false) async throws {
        try await loadQueuedEpisode(episodeID, playAfterLoad: autoplay)
        try await store.addPodcastQueueEpisode(episodeID)
        try await store.setCurrentPodcastQueueEpisode(episodeID)
        podcastStateHandler?(episodeID, nil)
    }

    /// Selects the queue item before the current episode, if one exists.
    @discardableResult
    public func selectPreviousPodcastQueueEpisode(autoplay: Bool = true) async throws -> Bool {
        let state = try await store.podcastQueueState()
        guard let currentIndex = state.currentIndex, currentIndex > state.episodeIDs.startIndex else {
            return false
        }
        let previous = state.episodeIDs[state.episodeIDs.index(before: currentIndex)]
        try await selectPodcastQueueEpisode(previous, autoplay: autoplay)
        return true
    }

    /// Selects the queue item after the current episode, if one exists.
    @discardableResult
    public func selectNextPodcastQueueEpisode(autoplay: Bool = true) async throws -> Bool {
        let state = try await store.podcastQueueState()
        guard let next = state.nextEpisodeID else { return false }
        try await selectPodcastQueueEpisode(next, autoplay: autoplay)
        return true
    }

    public func setRate(_ value: Float) {
        backend.rate = min(max(value.isFinite ? value : 1, 0.5), 2)
    }

    public func setVolume(_ value: Float) {
        backend.volume = min(max(value.isFinite ? value : 1, 0), 1)
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
        try await seek(to: backend.currentTime + offset)
    }

    /// Moves directly to a bounded media time. Backward movement starts a new
    /// causal playback run so a delayed completion from the old run is stale.
    public func seek(to value: TimeInterval) async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        guard value.isFinite else { throw PlaybackControllerError.invalidSeek(value) }
        let current = clamp(backend.currentTime)
        let target = clamp(value)
        if target < current {
            try await beginNewSession(intent: .rewind, position: target, reloadBackend: true)
        } else {
            backend.currentTime = target
            positionSeconds = target
            completed = target >= durationSeconds
            intent = .progress
            try await checkpoint()
        }
    }

    public func seekForward(seconds: TimeInterval = 30) async throws { try await seek(by: abs(seconds)) }
    public func seekBackward(seconds: TimeInterval = 15) async throws { try await seek(by: -abs(seconds)) }
    public func rewind(seconds: TimeInterval = 15) async throws { try await seekBackward(seconds: seconds) }

    /// Explicit restart is causally distinct from progress and starts a new
    /// session even when the playhead is already at zero.
    public func restart() async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        try await beginNewSession(intent: .restart, position: 0, reloadBackend: true)
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
        loadedBackendGeneration = backend.loadedGeneration
        backend.currentTime = position
        positionSeconds = position
        isPlaying = wasPlaying && backend.play()
    }

    private func handleBackendCompletion(generation: UInt64, successfully: Bool) async {
        guard generation == loadedBackendGeneration, successfully,
              completionHandledGeneration != generation else { return }
        completionHandledGeneration = generation
        backend.pause()
        isPlaying = false
        do { try await checkpointCompletedRevision() }
        catch { return }
        guard let state = try? await store.podcastQueueState(), state.currentEpisodeID == itemID else {
            return
        }
        guard let next = state.nextEpisodeID else {
            podcastStateHandler?(itemID, nil)
            return
        }
        do {
            try await loadQueuedEpisode(next, playAfterLoad: true)
            try await store.setCurrentPodcastQueueEpisode(next)
            podcastStateHandler?(next, nil)
        } catch {
            backend.pause()
            isPlaying = false
            podcastStateHandler?(itemID, recoverableFault)
        }
    }

    private func checkpointCompletedRevision() async throws {
        guard let revision = currentRevision, let itemID, let revisionID, let sessionID else {
            throw PlaybackControllerError.noLoadedRevision
        }
        backend.currentTime = durationSeconds
        positionSeconds = durationSeconds
        completed = true
        sequence = max(1, sequence + 1)
        try await store.save(playback: PlaybackState(
            itemID: itemID,
            revisionID: revisionID,
            sessionID: sessionID,
            sequence: sequence,
            positionSeconds: durationSeconds,
            durationSeconds: revision.durationSeconds,
            completed: true,
            intent: intent,
            deviceID: deviceID,
            updatedAt: Timestamp(Date())
        ))
    }

    private func loadQueuedEpisode(_ episodeID: ItemID, playAfterLoad: Bool) async throws {
        guard let stored = try await store.readyRevision(for: episodeID),
              FileManager.default.fileExists(atPath: stored.mediaURL.path) else {
            recoverableFault = .podcastMediaUnavailable(episodeID)
            throw PlaybackControllerError.podcastMediaUnavailable(episodeID)
        }
        do {
            try await loadRevision(stored.revision, mediaURL: stored.mediaURL)
        } catch {
            recoverableFault = .podcastMediaUnreadable(episodeID)
            throw PlaybackControllerError.podcastMediaUnreadable(episodeID)
        }
        let savedRate = try await store.playbackSpeed(for: episodeID)?.speed ?? 1
        setRate(Float(savedRate))
        if playAfterLoad { isPlaying = backend.play() }
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

    private func beginNewSession(
        intent: PlaybackIntent,
        position: TimeInterval,
        reloadBackend: Bool = false
    ) async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        let wasPlaying = backend.isPlaying || isPlaying
        if reloadBackend {
            guard let mediaURL else { throw PlaybackControllerError.noLoadedRevision }
            backend.stop()
            try backend.load(url: mediaURL)
            loadedBackendGeneration = backend.loadedGeneration
            completionHandledGeneration = nil
        }
        sessionID = Self.newSessionID()
        sequence = 0
        self.intent = intent
        completed = false
        let target = clamp(position)
        backend.currentTime = target
        positionSeconds = target
        isPlaying = wasPlaying && backend.play()
        try await checkpoint()
    }

    private func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value.isFinite ? value : 0, 0), max(durationSeconds, 0))
    }

    private static func newSessionID() -> String {
        "session-\(UUID().uuidString.lowercased())"
    }
}
