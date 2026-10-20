import Foundation

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// The ordered background lane for playback checkpoints (W-INV-040).
///
/// Pause and seek answer the person from memory: the audio stops or moves,
/// the readout shows it, and the next command runs without waiting on the
/// store. Their durable checkpoint is written on this lane instead of the
/// command tail.
/// - One entry runs at a time, each after the one before it, so lane writes
///   land in the order they were asked for.
/// - An entry takes its state when it starts, from the live controller, so
///   it never writes a state older than one already written. At most one
///   entry waits to start; a later request for the same item joins it,
///   because it would write the same newest state.
/// - An entry whose item or revision is no longer loaded writes nothing.
/// - Entries live in the `subscriptionWriteTasks` ledger, which close and
///   deinit join, and neither cancellation nor closing drops one, so a
///   Pause right before a quit is still written down.
struct WiltedMacPlaybackCheckpointLane {
    /// The command whose answer line carries a failed write, while that
    /// command is still the newest.
    struct Report: Equatable {
        let token: UInt64
        let message: String
    }

    struct Entry {
        let id: UUID
        let itemID: String
        let revisionID: String
        var report: Report?
    }

    /// The newest entry, running or waiting; its ledger task is the tail.
    var tailToken: UUID?
    /// The entry queued behind the running one, not yet started.
    var waiting: Entry?
}

#if canImport(WiltedProducer)
extension WiltedMacModel {
    /// A seek, scrub, skip or cue jump. The audio moves inside the command,
    /// which makes no store write; the checkpoint follows on the lane.
    /// Superseding a pending start cancels that start, so the result is
    /// paused at the new position rather than playing. `shown` is what the
    /// readout keeps showing until the command settles, so the readout tick
    /// cannot pull a dragged slider back while an earlier command finishes.
    func seekPlayback(publishesJump: Bool = false, shows shown: TimeInterval? = nil,
                      to target: @escaping @MainActor (PlaybackController) -> TimeInterval) {
        guard let playback else { return }
        let cancelsStart = playbackCommands.pending?.command.kind.startsAudio == true
        let command = issuePlaybackCommand(.seek, pending: nil) { [weak self] issued in
            guard let self else { return }
            if cancelsStart, playback.liveIsPlaying { try playback.pauseAudio() }
            try await playback.seek(to: target(playback), checkpointing: false)
            if self.playbackCommands.shownSeek?.token == issued.token { self.playbackCommands.shownSeek = nil }
            self.isPlaying = playback.isPlaying
            self.refreshPlaybackReadout()
            if publishesJump { self.publishNowPlaying(force: true) }
            self.enqueuePlaybackCheckpoint()
        }
        if let shown { playbackCommands.shownSeek = (command.token, shown) }
    }

    /// The scrub target the readout shows while its seek is the newest
    /// command and has not settled.
    var shownSeekSeconds: TimeInterval? {
        guard let shown = playbackCommands.shownSeek, shown.token == playbackCommands.generation else { return nil }
        return shown.seconds
    }

    /// Queues a checkpoint of the loaded revision on the lane. A Pause passes
    /// `report`, so a failed write still says the position was not saved.
    func enqueuePlaybackCheckpoint(reporting report: WiltedMacPlaybackCheckpointLane.Report? = nil) {
        guard let itemID = playback?.itemID?.rawValue, let revisionID = playback?.revisionID?.rawValue else { return }
        if var waiting = playbackCommands.checkpoints.waiting,
           waiting.itemID == itemID, waiting.revisionID == revisionID {
            waiting.report = report
            playbackCommands.checkpoints.waiting = waiting
            return
        }
        let entry = WiltedMacPlaybackCheckpointLane.Entry(
            id: UUID(), itemID: itemID, revisionID: revisionID, report: report)
        let token = entry.id
        let predecessor = playbackCommands.checkpoints.tailToken.flatMap { subscriptionWriteTasks[$0] }
        playbackCommands.checkpoints.waiting = entry
        // Never checks cancellation or closing: close cancels this ledger,
        // and the write it would drop is the one a quit must keep.
        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.subscriptionWriteTasks[token] = nil
                    if self.playbackCommands.checkpoints.tailToken == token {
                        self.playbackCommands.checkpoints.tailToken = nil
                    }
                }
            }
            await predecessor?.value
            await self?.runPlaybackCheckpoint(entry)
        }
        subscriptionWriteTasks[token] = task
        playbackCommands.checkpoints.tailToken = token
    }

    /// Waits until every queued checkpoint has landed. A quit joins the lane
    /// before its own checkpoint, so the quit's write is the last one.
    func joinPlaybackCheckpoints() async {
        while let token = playbackCommands.checkpoints.tailToken, let task = subscriptionWriteTasks[token] {
            await task.value
        }
    }

    private func runPlaybackCheckpoint(_ queued: WiltedMacPlaybackCheckpointLane.Entry) async {
        var entry = queued
        if let waiting = playbackCommands.checkpoints.waiting, waiting.id == queued.id {
            entry = waiting
            playbackCommands.checkpoints.waiting = nil
        }
        // Another item has loaded: its playhead is not this entry's to write.
        guard let playback, playback.itemID?.rawValue == entry.itemID,
              playback.revisionID?.rawValue == entry.revisionID else { return }
        do {
            try await playback.checkpoint()
        } catch {
            Self.playbackLog.error(
                "Playback checkpoint failed: \(self.episodeLogContext(entry.itemID), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            if let report = entry.report, playbackCommands.generation == report.token {
                playbackCommands.failure = WiltedMacPlaybackFailure(
                    kind: .unavailable, itemID: entry.itemID, message: report.message)
                playbackError = report.message
            }
            return
        }
        refreshPlaybackReadout()
        refreshLifetimeStatisticsAfterPlayback()
    }
}
#endif
