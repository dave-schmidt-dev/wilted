import Foundation
import WiltedDomain

/// Why an explicit request for audio did not produce it, typed at the one
/// seam that asks the backend to start. A caller can therefore tell a
/// refusal apart from a broken route. Missing or unreadable media keeps its
/// own `PlaybackControllerError` cases, so neither is mistaken for a route
/// fault either.
public enum PlaybackTransportError: Error, Equatable, Sendable {
    /// The backend was asked to start the loaded revision and declined.
    /// Nothing about the route failed and the playhead is unchanged, so an
    /// explicit retry may succeed and no route recovery is warranted.
    case backendRefused(ItemID)
    /// The backend could not be rebuilt for the loaded revision: its output
    /// route or decoder is unavailable. This is the only start failure that
    /// warrants an automatic route recovery.
    case routeUnavailable(ItemID)
}

/// What an explicit start actually did. Playing is reported only from the
/// backend's answer, never inferred from the request.
public enum PlaybackStartOutcome: Equatable, Sendable {
    case started
    case alreadyPlaying
}

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
        _ episodeID: ItemID, playAfterLoad: Bool, expectedGeneration: UInt64? = nil,
        startsIf shouldStart: () -> Bool = { true }
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
        // Queue operations keep their silent autoplay: the queue move must
        // complete whether or not the backend agreed to start. A caller that
        // needs a typed answer follows the operation with `start()`.
        if playAfterLoad, shouldStart() { isPlaying = backend.play(); meterListening() }
        return loadedGeneration
    }

    /// Starts the loaded revision. Throws `PlaybackTransportError` when the
    /// backend declines (`backendRefused`) or cannot be rebuilt after an
    /// engine failure (`routeUnavailable`); the playhead is kept either way.
    public func play() throws {
        guard currentRevision != nil, let loadedItemID = itemID else {
            throw PlaybackControllerError.noLoadedRevision
        }
        if recoverableFault == .playbackFailed(loadedItemID) {
            // A finished AVAudioPlayer no longer has a registered completion
            // callback. Reload to give an explicit retry its own generation.
            guard let mediaURL else { throw PlaybackControllerError.noLoadedRevision }
            let position = clamp(positionSeconds)
            try reloadBackend(from: mediaURL, itemID: loadedItemID)
            completionHandledGeneration = nil
            backend.currentTime = position
            positionSeconds = position
        }
        isPlaying = backend.play()
        meterListening()
        guard isPlaying else { throw PlaybackTransportError.backendRefused(loadedItemID) }
        recoverableFault = nil
    }

    /// The typed explicit start: reports `.alreadyPlaying` without asking the
    /// backend again, otherwise behaves exactly like `play()`.
    @discardableResult
    public func start() throws -> PlaybackStartOutcome {
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        if backend.isPlaying {
            isPlaying = true
            meterListening()
            return .alreadyPlaying
        }
        try play()
        return .started
    }

    public func pause() async throws {
        // Recorded before anything can fail: a Pause pressed in the gap after
        // an episode ends still means "do not start the next one".
        explicitHoldSerial &+= 1
        guard currentRevision != nil else { throw PlaybackControllerError.noLoadedRevision }
        backend.pause()
        isPlaying = false
        meterListening()
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
            // Every caller is an explicit listener seek (scrub, transcript
            // cue, skip-forward). The jump is clamped to the item, so it never
            // exceeds the remaining duration.
            recordManualSkip(seconds: target - current)
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
    public func handlePauseOrQuit() async throws {
        explicitHoldSerial &+= 1
        backend.pause()
        isPlaying = false
        meterListening()
        try await checkpoint()
    }

    /// Rebuilds the backend after an audio route/configuration change. The
    /// exact playhead and whether it was playing are captured before reload.
    public func recoverFromRouteChange() async throws {
        guard let mediaURL, let loadedItemID = itemID else { throw PlaybackControllerError.noLoadedRevision }
        let wasPlaying = backend.isPlaying || isPlaying
        let position = livePositionSeconds
        backend.stop()
        try reloadBackend(from: mediaURL, itemID: loadedItemID)
        completionHandledGeneration = nil
        recoverableFault = nil
        backend.currentTime = position
        positionSeconds = position
        isPlaying = wasPlaying && backend.play()
        meterListening()
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
            guard let mediaURL, let loadedItemID = itemID else { throw PlaybackControllerError.noLoadedRevision }
            backend.stop()
            try self.reloadBackend(from: mediaURL, itemID: loadedItemID)
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
        meterListening()
        try await checkpoint()
    }

    /// Rebuilds the backend for the loaded media. Any failure here is the
    /// output route or decoder, not the file's presence (which was checked
    /// when it loaded), so it is reported as a typed route fault.
    private func reloadBackend(from mediaURL: URL, itemID loadedItemID: ItemID) throws {
        do {
            try backend.load(url: mediaURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlaybackTransportError.routeUnavailable(loadedItemID)
        }
        loadedBackendGeneration = backend.loadedGeneration
    }
}
