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
///
/// Measured lifetime totals (store V14) are kept here too:
/// - Played time is elapsed active listening on `listeningClock`, measured
///   between transport transitions. It is wall time, so rate does not scale
///   it; replay counts; paused time and seek jumps do not.
/// - Manually skipped time is the positive distance of an explicit forward
///   seek, or the remainder an explicit Next leaves behind, clamped to the
///   item. Feeds Skip, ad cuts, handoff and restore never reach these paths.
/// - Each load opens one attempt whose owner key carries a fresh nonce, so a
///   relaunch that reuses the persisted session never collides with the
///   previous process's high-water mark. Checkpoints write cumulative
///   amounts; the store admits only what exceeds the mark, so repeated
///   checkpoints cannot double count.
///
/// Crash-tail bound: played and skipped time is admitted at every
/// `checkpoint()` (the periodic cadence is
/// `playedTimeCheckpointInterval`, 10 seconds), on pause, completion and
/// item change, and by `flushLifetimeMeasures()`. A process that dies without
/// a terminal flush loses at most the time since the last checkpoint: 10
/// seconds of played time.
@MainActor
extension PlaybackController {
    /// Cadence of the periodic checkpoint, which also bounds unsaved played time.
    public static let playedTimeCheckpointInterval: TimeInterval = 10

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
        try await flushLifetimeMeasures()
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
        try await flushLifetimeMeasures()
    }

    public func startPeriodicCheckpoint(every interval: TimeInterval = playedTimeCheckpointInterval) {
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

    // MARK: - Measured lifetime totals

    /// Admits every measured amount not yet in the store: the loaded
    /// attempt's played and manually skipped time up to now, and anything a
    /// previous attempt left pending. This is the terminal flush the app's
    /// termination coordinator calls after pausing; `checkpoint()` calls it
    /// too. Safe to call repeatedly: a cumulative amount at or below what was
    /// already admitted costs no store write. Throws the first store error and
    /// keeps the unwritten amounts pending for the next call.
    public func flushLifetimeMeasures() async throws {
        meterListening()
        stageCurrentLifetimeAttempt()
        let batch = lifetimeMeter.unflushed.sorted {
            ($0.key.ownerKey, $0.key.kind.rawValue) < ($1.key.ownerKey, $1.key.kind.rawValue)
        }
        for (key, cumulative) in batch {
            guard let amount = LifetimeMeasureAmount.stored(key.kind, baseUnits: cumulative) else { continue }
            try await store.recordLifetimeMeasureCheckpoint(amount, ownerKey: key.ownerKey, at: Date())
            lifetimeMeter.admitted[key] = max(lifetimeMeter.admitted[key] ?? 0, cumulative)
            if lifetimeMeter.unflushed[key] == cumulative { lifetimeMeter.unflushed[key] = nil }
        }
    }

    /// Brings elapsed listening up to now, then re-arms the meter from the
    /// current play state. Call it after every change to `isPlaying`: the time
    /// since the previous call belongs to the state that held until now.
    func meterListening() {
        let now = listeningClock()
        if let since = lifetimeMeter.listeningSince, now > since {
            lifetimeMeter.playedSeconds += now - since
        }
        lifetimeMeter.listeningSince = isPlaying && lifetimeMeter.ownerKey != nil ? now : nil
    }

    /// Closes the outgoing attempt (its totals stay pending until flushed)
    /// and opens one for the revision just loaded into the backend.
    func beginLifetimeAttempt(itemID: ItemID, revisionID: RevisionID) {
        meterListening()
        stageCurrentLifetimeAttempt()
        lifetimeMeter.admitted.removeAll()
        lifetimeMeter.ownerKey = PlaybackLifetimeMeter.ownerKey(
            deviceID: deviceID, itemID: itemID, revisionID: revisionID, nonce: UUID())
        lifetimeMeter.playedSeconds = 0
        lifetimeMeter.skippedSeconds = 0
        lifetimeMeter.listeningSince = nil
    }

    /// Adds an explicit forward seek's distance to the loaded attempt.
    func recordManualSkip(seconds: TimeInterval) {
        guard lifetimeMeter.ownerKey != nil, seconds.isFinite, seconds > 0 else { return }
        lifetimeMeter.skippedSeconds += seconds
    }

    /// The remainder an explicit Next would leave unheard on the loaded
    /// current queue episode, captured before the successor replaces it.
    func manualNextSkip(currentQueueItem: ItemID?) -> PlaybackLifetimeMeter.NextSkip? {
        guard loadedIsPodcastEpisode, currentRevision != nil, itemID == currentQueueItem,
              let ownerKey = lifetimeMeter.ownerKey,
              durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let remainder = max(0, durationSeconds - livePositionSeconds)
        guard remainder > 0 else { return nil }
        return PlaybackLifetimeMeter.NextSkip(ownerKey: ownerKey, seconds: remainder)
    }

    /// Records a Next remainder once its successor has loaded. It is owned by
    /// the outgoing attempt, under its own key, so it is admitted exactly once.
    func recordManualNextSkip(_ skip: PlaybackLifetimeMeter.NextSkip) {
        guard let amount = LifetimeMeasureAmount.time(.manuallySkippedTime, seconds: skip.seconds),
              amount.baseUnits > 0 else { return }
        lifetimeMeter.unflushed[.init(kind: .manuallySkippedTime, ownerKey: skip.ownerKey + "|next")] = amount.baseUnits
    }

    /// Moves the loaded attempt's cumulative totals into the pending set when
    /// they exceed what the store already admitted for them.
    private func stageCurrentLifetimeAttempt() {
        guard let ownerKey = lifetimeMeter.ownerKey else { return }
        for (kind, seconds) in [(LifetimeMeasureKind.playedTime, lifetimeMeter.playedSeconds),
                                (.manuallySkippedTime, lifetimeMeter.skippedSeconds)] {
            guard let amount = LifetimeMeasureAmount.time(kind, seconds: seconds) else { continue }
            let key = PlaybackLifetimeMeter.Key(kind: kind, ownerKey: ownerKey)
            guard amount.baseUnits > max(lifetimeMeter.admitted[key] ?? 0, lifetimeMeter.unflushed[key] ?? 0) else {
                continue
            }
            lifetimeMeter.unflushed[key] = amount.baseUnits
        }
    }
}

/// Measured played and manually skipped time for one playback controller.
struct PlaybackLifetimeMeter {
    struct Key: Hashable {
        let kind: LifetimeMeasureKind
        let ownerKey: String
    }

    struct NextSkip {
        let ownerKey: String
        let seconds: TimeInterval
    }

    /// `playback|<device>|<item>|<revision>|<nonce>`: one per load, so a
    /// relaunch starts a fresh cumulative instead of hiding under the
    /// previous process's high-water mark.
    static func ownerKey(deviceID: String, itemID: ItemID, revisionID: RevisionID, nonce: UUID) -> String {
        "playback|\(deviceID)|\(itemID.rawValue)|\(revisionID.rawValue)|\(nonce.uuidString.lowercased())"
    }

    var ownerKey: String?
    var playedSeconds: TimeInterval = 0
    var skippedSeconds: TimeInterval = 0
    /// Clock reading when audio last started or was last metered while running.
    var listeningSince: TimeInterval?
    /// Cumulative amounts per owner waiting to be admitted.
    var unflushed: [Key: Int64] = [:]
    /// Cumulative amounts the store has admitted for the loaded attempt.
    var admitted: [Key: Int64] = [:]
}
