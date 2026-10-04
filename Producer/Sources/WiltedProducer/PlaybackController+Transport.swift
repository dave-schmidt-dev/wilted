import Foundation
import WiltedDomain

/// Transport, start and route-recovery operations: loading a revision or a
/// queued episode, play/pause/toggle, seeking, restart, the pause-or-quit
/// checkpoints, and rebuilding the backend after an audio route change.
/// Every call that asks the backend to start audio lives here, so start
/// outcomes have one seam. Durable checkpoint writing, completion handling
/// and speed accounting stay in `PlaybackController.swift`.
@MainActor
extension PlaybackController {
    /// Loads one immutable revision and only resumes a persisted state with
    /// the exact same item and revision identifiers.
    public func load(_ storedRevision: StoredAudioRevision) async throws {
        try await load(revision: storedRevision.revision, mediaURL: storedRevision.mediaURL)
    }

    public func load(revision: AudioRevision, mediaURL: URL) async throws {
        try await loadRevision(revision, mediaURL: mediaURL)
    }

    @discardableResult
    func loadQueuedEpisode(
        _ episodeID: ItemID, playAfterLoad: Bool, expectedGeneration: UInt64? = nil
    ) async throws -> UInt64 {
        if let expectedGeneration, loadedBackendGeneration != expectedGeneration {
            throw CancellationError()
        }
        guard try await isEpisodeEligible(episodeID) else {
            recoverableFault = .podcastMediaUnavailable(episodeID)
            throw PlaybackControllerError.podcastMediaUnavailable(episodeID)
        }
        let ready = try await store.readyRevision(for: episodeID)
        if let expectedGeneration, loadedBackendGeneration != expectedGeneration {
            throw CancellationError()
        }
        guard let stored = ready,
              FileManager.default.fileExists(atPath: stored.mediaURL.path) else {
            recoverableFault = .podcastMediaUnavailable(episodeID)
            throw PlaybackControllerError.podcastMediaUnavailable(episodeID)
        }
        let savedRate = try await store.playbackSpeed(for: episodeID).map { Float($0.speed) } ?? defaultRate
        if let expectedGeneration, loadedBackendGeneration != expectedGeneration {
            throw CancellationError()
        }
        let loadedGeneration: UInt64
        do {
            loadedGeneration = try await loadRevision(
                stored.revision, mediaURL: stored.mediaURL, expectedGeneration: expectedGeneration, isPodcast: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recoverableFault = .podcastMediaUnreadable(episodeID)
            throw PlaybackControllerError.podcastMediaUnreadable(episodeID)
        }
        guard loadedBackendGeneration == loadedGeneration, itemID == episodeID else {
            throw CancellationError()
        }
        setRate(savedRate)
        if playAfterLoad { isPlaying = backend.play() }
        return loadedGeneration
    }

    public func play() throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        if let itemID, recoverableFault == .playbackFailed(itemID) {
            // A finished AVAudioPlayer no longer has a registered completion
            // callback. Reload to give an explicit retry its own generation.
            guard let mediaURL else { throw PlaybackControllerError.noLoadedRevision }
            let position = clamp(positionSeconds)
            try backend.load(url: mediaURL)
            loadedBackendGeneration = backend.loadedGeneration
            completionHandledGeneration = nil
            backend.currentTime = position
            positionSeconds = position
        }
        isPlaying = backend.play()
        if isPlaying { recoverableFault = nil }
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
        try await seek(to: livePositionSeconds + offset)
    }

    /// Moves directly to a bounded media time. Backward movement starts a new
    /// causal playback run so a delayed completion from the old run is stale.
    public func seek(to value: TimeInterval) async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        guard value.isFinite else { throw PlaybackControllerError.invalidSeek(value) }
        let current = livePositionSeconds
        let target = clamp(value)
        stageSpeedInterval(endingAt: current)
        if target < current {
            try await beginNewSession(intent: .rewind, position: target, reloadBackend: true)
        } else {
            backend.currentTime = target
            positionSeconds = target
            speedSavingsBaselineSeconds = target
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

    public func manualCheckpoint() async throws { try await checkpoint() }
    public func pauseAndCheckpoint() async throws { try await pause() }
    public func handlePauseOrQuit() async throws { backend.pause(); isPlaying = false; try await checkpoint() }

    /// Rebuilds the backend after an audio route/configuration change. The
    /// exact playhead and whether it was playing are captured before reload.
    public func recoverFromRouteChange() async throws {
        guard let mediaURL else { throw PlaybackControllerError.noLoadedRevision }
        let wasPlaying = backend.isPlaying || isPlaying
        let position = livePositionSeconds
        backend.stop()
        try backend.load(url: mediaURL)
        loadedBackendGeneration = backend.loadedGeneration
        completionHandledGeneration = nil
        recoverableFault = nil
        backend.currentTime = position
        positionSeconds = position
        isPlaying = wasPlaying && backend.play()
    }

    private func beginNewSession(
        intent: PlaybackIntent,
        position: TimeInterval,
        reloadBackend: Bool = false
    ) async throws {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        stageSpeedInterval(endingAt: livePositionSeconds)
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
        recoverableFault = nil
        let target = clamp(position)
        backend.currentTime = target
        positionSeconds = target
        speedSavingsBaselineSeconds = target
        isPlaying = wasPlaying && backend.play()
        try await checkpoint()
    }
}
