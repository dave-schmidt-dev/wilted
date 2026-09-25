import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

extension WiltedMacModel {
    /// Pushes the readout to the system, skipping publications that would say
    /// the same thing. `force` is for the moments the system cannot infer:
    /// a seek, a new episode, a stop.
    func publishNowPlaying(force: Bool = false) {
        guard let nowPlayingSink else { return }
        guard let info = currentNowPlayingInfo else {
            guard lastPublishedNowPlaying != nil else { return }
            lastPublishedNowPlaying = nil
            nowPlayingSink.clear()
            remoteCommandSource?.updateQueueAvailability(hasNext: false, hasPrevious: false)
            return
        }
        guard force || info.differsMateriallyFrom(lastPublishedNowPlaying) else { return }
        lastPublishedNowPlaying = info
        nowPlayingSink.publish(info)
        remoteCommandSource?.updateQueueAvailability(hasNext: canSelectNextEpisode,
                                                     hasPrevious: canSelectPreviousEpisode)
    }

    func installRemoteCommands() {
        remoteCommandSource?.install { [weak self] command in
            self?.handleRemoteCommand(command)
        }
    }

    /// Applies a media key, headset button, or widget press.
    ///
    /// Every case routes through the same method the on-screen control calls,
    /// so a media key cannot end up with behaviour of its own — including the
    /// durable checkpoint each of those already writes.
    func handleRemoteCommand(_ command: WiltedRemoteCommand) {
        guard hasCurrentPlayback else { return }
        switch command {
        case .play:
            guard !isPlaying else { return }
            togglePlayback()
        case .pause:
            guard isPlaying else { return }
            togglePlayback()
        case .toggle:
            togglePlayback()
        case .skipForward:
            forward()
        case .skipBackward:
            rewind()
        case .nextTrack:
            guard canSelectNextEpisode else { return }
            nextPlayback()
        case .previousTrack:
            guard canSelectPreviousEpisode else { return }
            previousPlayback()
        case let .seek(position):
            scrub(to: position)
        case let .changeRate(rate):
            setPlaybackRate(rate)
        }
    }

    func togglePlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.toggle()
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#else
        isPlaying.toggle()
#endif
    }

    /// Returns to Library without changing playback state.
    ///
    /// The player no longer draws its own back button — the sidebar is
    /// permanent, so a second way back was redundant and the listener has no
    /// equivalent — but menu and keyboard paths still need the operation.
    func returnToLibrary() {
        selectedNavigation = .menu
    }

    func rewind() { seek(by: -Self.backwardSkipSeconds) }
    func forward() { seek(by: Self.forwardSkipSeconds) }

    func previousPlayback() { navigatePodcastQueue(previous: true) }
    func nextPlayback() { navigatePodcastQueue(previous: false) }

    /// Starts a new playback session and publishes its durable checkpoint.
    func restartPlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.restart()
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.playbackError = "Playback restart is unavailable." }
        }
#endif
    }

    /// Retires the loaded episode without playing the rest of it.
    ///
    /// The listener who is finished at 91% has no other way to close an
    /// episode out: progress is written from where the audio is, so an
    /// abandoned episode stays at 91% for good and the Larder goes on offering
    /// it. Nothing advances — the press says "I am done with this", not "play
    /// the next thing".
    ///
    /// The library is reloaded rather than patched in memory, because the row
    /// reads its played state from the same durable record the player just
    /// wrote, and the two disagreeing is worse than the reload costs. A
    /// finished podcast episode is then retired from the Larder, the same as
    /// one that ran out on its own.
    func markCurrentPlaybackCompleted() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                Self.playbackLog.notice(
                    "markCurrentPlaybackCompleted: episode=\(self.currentPodcastEpisodeID ?? "none", privacy: .public)"
                )
                // Idempotent by halves: a record that already says completed is
                // not rewritten, but the retirement it never got runs anyway.
                // Pressing this on an episode marked finished elsewhere -- an
                // older build, a failed dismissal, another device -- has to
                // mean "take it off the shelf" and not "do nothing".
                if !self.playbackCompleted {
                    try await playback.markCompleted()
                    self.refreshPlaybackReadout()
                    await self.queueCurrentPlaybackCheckpoint()
                    await self.reloadLibraryRows()
                }
                await self.retireFinishedEpisode()
                self.advanceToNextMenuEpisode()
            } catch { self.playbackError = "This episode could not be marked completed." }
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Retires the episode the listener just finished with, taking it off
    /// the Larder shelf without deleting it.
    ///
    /// Playing an episode to its end retires it, on the reasoning that leaving
    /// it there makes the owner clear by hand what finishing it already said.
    /// Saying "I am done with this" at 91% says exactly the same thing, and it
    /// was leaving the row on the shelf: the two ways of finishing an episode
    /// agreed about the durable record and disagreed about the one thing the
    /// listener could see.
    ///
    /// Articles are untouched: they have no Larder retirement on finishing.
    /// Advancing is the caller's job rather than this method's, because this
    /// also runs from the controller's own completion sequence, which has
    /// already advanced by the time it gets here.
    func retireFinishedEpisode() async {
        guard isPodcastPlayback, let finished = currentEpisode,
              let id = try? ItemID(rawValue: finished.id) else { return }
        // Deliberate, so no Undo is offered; and an Undo left over from an
        // earlier Skip must not attach itself to a different episode.
        undoableRemoval = nil
        // Queue membership is this caller's own concern, not
        // `completeAndRetire`'s: that method also runs from inside the
        // controller's own completion sequence, mid-suspension before it
        // re-reads queue state, and a queue mutation there would race that
        // read.
        if let playback {
            try? await playback.removePodcastQueueEpisode(id)
            await refreshPodcastQueueState()
        }
        podcastOperationMessage = await completeAndRetire(id)
            ?? "\(finished.title) could not be marked finished."
        await reloadLibraryRows()
    }

    /// Writes the durable "finished" fact and takes the episode off the
    /// Larder shelf, without touching the podcast queue -- see the doc
    /// comment on `podcastCompletionHandler`'s wiring below for why that is
    /// split out to the callers that can safely do it.
    @discardableResult
    func completeAndRetire(_ episodeID: ItemID) async -> String? {
        guard let store, let episode = episodes.first(where: { $0.id == episodeID.rawValue }) else { return nil }
        do {
            try await store.retireEpisode(episodeID)
            hideEpisode(episode)
            return "Finished \(episode.title)."
        } catch {
            return "\(episode.title) could not be marked finished."
        }
    }
#endif

    /// Records a playback fault and gives the backend one automatic chance to
    /// rebuild itself before exposing a manual retry.
    func reportAudioRouteFault(_ message: String) {
        playbackError = message
#if canImport(WiltedProducer)
        guard !audioRouteRecoveryAttempted else { return }
        audioRouteRecoveryAttempted = true
        recoverAudioRoute()
#else
        audioRouteFault = false
#endif
    }

    func recoverAudioRoute() {
#if canImport(WiltedProducer)
        guard let playback, !audioRouteRecoveryInFlight else { return }
        audioRouteRecoveryInFlight = true
        audioRouteFault = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.recoverFromRouteChange()
                self.audioRouteFault = false
                self.audioRouteRecoveryAttempted = false
                self.playbackError = nil
                self.refreshPlaybackReadout()
            } catch {
                self.audioRouteFault = true
                self.playbackError = "Audio route recovery failed."
            }
            self.audioRouteRecoveryInFlight = false
        }
#else
        audioRouteFault = false
        playbackError = nil
#endif
    }

    /// Hiding, minimising, or closing the last window. The playhead is written
    /// down and the automation tick stops, but the audio keeps going: a podcast
    /// the owner is listening to does not stop because the window went away.
    ///
    /// This used to call `handlePauseOrQuit`, which paused. That conflated "not
    /// frontmost" with "quitting" and silenced Cmd-H, Cmd-M, and closing the
    /// window. Nothing was gained by it -- `PlaybackState` persists the
    /// position, not whether it was playing -- so the pause only ever cost the
    /// owner their audio.
    func checkpointForBackground() {
        stopAutomationTicker()
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            try? await playback.manualCheckpoint()
            await self.queueCurrentPlaybackCheckpoint()
        }
#endif
    }

    /// Actual termination, which is the one moment stopping is right. The
    /// process is about to exit, and a Now Playing entry left claiming to be
    /// playing outlives it -- the failure `WiltedMacApp.init` records against
    /// test runs, where the machine's media keys ended up pointed at a process
    /// that was gone.
    func pauseForQuit() {
        stopAutomationTicker()
        stopTicketDrainTicker()
        cancelSeamMarker()
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            try? await playback.handlePauseOrQuit()
            await self.queueCurrentPlaybackCheckpoint()
        }
#endif
    }

    /// Deterministic model-test seam for the same checkpoint path used by
    /// transport actions. It never contacts a live service.
    func checkpointCurrentPlaybackForTesting() async {
#if canImport(WiltedProducer)
        try? await playback?.checkpoint()
        await queueCurrentPlaybackCheckpoint()
#endif
    }

    func completePodcastPlaybackForTesting(successfully: Bool = true) {
#if canImport(WiltedProducer)
        (playback?.backend as? WiltedFixturePlaybackBackend)?.finish(successfully: successfully)
#endif
    }

    func failNextAudioRouteRecoveryForTesting() {
#if canImport(WiltedProducer)
        (playback?.backend as? WiltedFixturePlaybackBackend)?.failNextLoad = true
#endif
    }

    /// Moves fixture or test playback to `seconds` and refreshes the readout, as a
    /// transport seek does. Test seam only.
    func seekPlaybackForTesting(to seconds: TimeInterval) async {
#if canImport(WiltedProducer)
        try? await playback?.seek(to: seconds)
        if let playback {
            isPlaying = playback.isPlaying
        }
        refreshPlaybackReadout()
#endif
    }

    func waitForPlaybackOperationForTesting() async {
#if canImport(WiltedProducer)
        await playbackOperationTask?.value
#endif
    }

    /// What the engine and the checkpoint counter each did, so a test can tell
    /// "the playhead was written down" apart from "the audio stopped". Those
    /// were one call until hiding the window was found to silence the episode,
    /// and asserting on the model's own mirrored `isPlaying` would not catch a
    /// regression: it lags the engine by an observation.
    func playbackCheckpointStateForTesting() -> (isPlaying: Bool, sequence: Int64)? {
#if canImport(WiltedProducer)
        guard let playback else { return nil }
        return (playback.liveIsPlaying, playback.sequence)
#else
        return nil
#endif
    }

    /// What the audio backend would actually play at, so a test can assert the
    /// silencing above is in force. The backend type is file-private, and the
    /// volume is the property the silencing is about.
    func playbackOutputVolumeForTesting() -> Float? {
#if canImport(WiltedProducer)
        playback?.backend.volume
#else
        nil
#endif
    }

    /// Puts the model in the state a real load leaves behind, so the system
    /// integration can be asserted on without an audio engine.
    ///
    /// The readout properties are `private(set)` because only the engine may
    /// move them, and that is the right rule; this is the one seam that lets a
    /// test stand in for the engine rather than relaxing it.
    func installPlaybackStateForTesting(episode: WiltedMacEpisode? = nil,
                                        article: WiltedMacArticle? = nil,
                                        isPlaying: Bool,
                                        position: TimeInterval,
                                        duration: TimeInterval,
                                        queue: [String] = []) {
        if let episode {
            installEpisodeForTesting(episode)
            currentPodcastEpisodeID = episode.id
            selectedArticleID = nil
            podcastQueueIDs = queue.isEmpty ? [episode.id] : queue
#if canImport(WiltedProducer)
            isPodcastPlayback = true
#endif
        }
        if let article {
            if !articles.contains(where: { $0.id == article.id }) { articles.append(article) }
            selectedArticleID = article.id
            currentPodcastEpisodeID = nil
#if canImport(WiltedProducer)
            isPodcastPlayback = false
#endif
        }
        isNowPlaying = episode != nil || article != nil
        self.isPlaying = isPlaying
        playbackPositionSeconds = position
        playbackDurationSeconds = duration
    }

    /// Simulates article playback while a stale podcast marker still names a
    /// queue row. The marker must not make that row borrow the article's live
    /// playhead when deciding whether to show In Progress.
    func installArticlePlaybackWithPodcastMarkerForTesting(
        episodeID: String, position: TimeInterval, duration: TimeInterval
    ) {
        isNowPlaying = true
        isPlaying = true
        currentPodcastEpisodeID = episodeID
        playbackPositionSeconds = position
        playbackDurationSeconds = duration
#if canImport(WiltedProducer)
        isPodcastPlayback = false
#endif
    }

    func clearPlaybackStateForTesting() {
        cancelSeamMarker()
        isNowPlaying = false
        isPlaying = false
        currentPodcastEpisodeID = nil
        selectedArticleID = nil
        playbackPositionSeconds = 0
        playbackDurationSeconds = 0
    }

    func installEpisodeForTesting(_ episode: WiltedMacEpisode) {
        guard !episodes.contains(where: { $0.id == episode.id }) else { return }
        episodes.append(episode)
    }

    /// Stands in for the store's transcript answer, so the Menu's union of
    /// visible text and transcript matches can be asserted without writing
    /// transcript rows to disk first.
    func installTranscriptSearchMatchesForTesting(_ ids: Set<String>) {
        transcriptSearchMatches = ids
    }

    /// Replaces the durable per-episode admission so a test can make one
    /// raise; passing nil restores the real playback path.
    func installMenuAdmissionForTesting(_ operation: (@Sendable (ItemID) async throws -> Void)?) {
        menuAdmissionForTesting = operation
    }

    /// Test seam: the one preparation slot, so ordering can be driven without
    /// a worker.
    var preparationGateForTesting: WiltedPreparationGate { preparationGate }

    /// Awaits one library reload and the automatic Menu admission it may have
    /// started, so a retry can be asserted after it settles.
    func reloadLibraryRowsForTesting() async {
        await reloadLibraryRows()
        await menuAdditionTask?.value
    }

    func installArticleForTesting(_ article: WiltedMacArticle) {
        guard !articles.contains(where: { $0.id == article.id }) else { return }
        articles.append(article)
    }

    func beginArticlePlaybackTransitionForTesting(_ article: WiltedMacArticle) {
        beginArticlePlaybackTransition(article)
    }

}
