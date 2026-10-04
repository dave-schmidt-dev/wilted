import Foundation
import WiltedDomain

/// Durable checkpoint and playback-statistics accounting: writing the
/// resumable playhead (with `lastWritten` keeping an unchanged idle
/// checkpoint's original time), the terminal completed record, the periodic
/// checkpoint timer, and speed-savings intervals. An interval is staged from
/// `speedSavingsBaselineSeconds` to a played position at the current rate and
/// persisted against the revision's durable high-water mark, so replayed
/// audio is not counted twice and skipped audio is never counted. The stored
/// state these methods use lives on `PlaybackController` itself, because
/// extensions cannot add stored properties.
@MainActor
extension PlaybackController {
    struct PendingSpeedInterval {
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let rate: Double
    }

    public func checkpoint() async throws { try await checkpoint(markCompletedAtEnd: true) }

    /// Writes the current playhead without inferring a terminal record unless
    /// the caller is handling an actual audio completion. Manual Next uses the
    /// non-terminal form until its successor has loaded successfully.
    func checkpoint(markCompletedAtEnd: Bool) async throws {
        guard let revision = currentRevision, let itemID, let revisionID, let sessionID else {
            throw PlaybackControllerError.noLoadedRevision
        }
        let livePosition = clamp(backend.currentTime)
        positionSeconds = recoverableFault == .playbackFailed(itemID)
            ? max(positionSeconds, livePosition) : livePosition
        isPlaying = backend.isPlaying
        completed = markCompletedAtEnd && positionSeconds >= durationSeconds
            && recoverableFault != .playbackFailed(itemID)
        sequence = max(1, sequence + 1)
        let unchanged = !backend.isPlaying && lastWritten.map {
            $0.sessionID == sessionID && $0.position == positionSeconds && $0.completed == completed && $0.intent == intent
        } == true
        let stamp = unchanged ? lastWritten?.at ?? Date() : Date()
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
            updatedAt: Timestamp(stamp)
        )
        try await store.save(playback: state)
        lastWritten = (state.sessionID, state.positionSeconds, state.completed, state.intent, stamp)
        stageSpeedInterval(endingAt: positionSeconds)
        try await persistPendingSpeedIntervals(revisionID: revisionID)
    }

    func checkpointCompletedRevision(accountPlaybackToEnd: Bool) async throws {
        guard let revision = currentRevision, let itemID, let revisionID, let sessionID else {
            throw PlaybackControllerError.noLoadedRevision
        }
        let accountingEnd = accountPlaybackToEnd ? durationSeconds : clamp(backend.currentTime)
        backend.currentTime = durationSeconds
        positionSeconds = durationSeconds
        completed = true
        sequence = max(1, sequence + 1)
        let now = Timestamp(Date())
        let playbackState = try PlaybackState(
            itemID: itemID,
            revisionID: revisionID,
            sessionID: sessionID,
            sequence: sequence,
            positionSeconds: durationSeconds,
            durationSeconds: revision.durationSeconds,
            completed: true,
            intent: intent,
            deviceID: deviceID,
            updatedAt: now
        )
        if loadedIsPodcastEpisode {
            try await store.save(playback: playbackState, listening: PodcastListeningState(
                episodeID: itemID, completedAt: now, lastRevisionID: revisionID, updatedAt: now
            ))
        } else {
            try await store.save(playback: playbackState)
        }
        stageSpeedInterval(endingAt: accountingEnd)
        try await persistPendingSpeedIntervals(revisionID: revisionID)
        speedSavingsBaselineSeconds = durationSeconds
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

    func stageSpeedInterval(endingAt position: TimeInterval) {
        let end = clamp(position)
        guard end > speedSavingsBaselineSeconds else { return }
        pendingSpeedIntervals.append(PendingSpeedInterval(
            startSeconds: speedSavingsBaselineSeconds,
            endSeconds: end,
            rate: speedSavingsRate
        ))
        speedSavingsBaselineSeconds = end
    }

    private func persistPendingSpeedIntervals(revisionID: RevisionID) async throws {
        let intervals = pendingSpeedIntervals
        guard !intervals.isEmpty else { return }
        for interval in intervals {
            try await store.recordPlaybackSpeedCheckpoint(
                revisionID: revisionID,
                from: interval.startSeconds,
                to: interval.endSeconds,
                rate: interval.rate
            )
        }
        pendingSpeedIntervals.removeFirst(min(intervals.count, pendingSpeedIntervals.count))
    }
}
