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
    /// Downloaded rows genuinely preparing. A row waiting for the off-peak
    /// window carries a queued `.preparing` stage but is not running, and
    /// `menuPreparableEpisodes` already offers it, so it is excluded here.
    var menuPreparationsInFlight: [WiltedMacEpisode] {
        menuUnfilteredEpisodes(in: .downloaded).filter {
            $0.preparationState.isRunning && !isDeferredForOffPeak($0.id)
        }
    }

    /// The Menu's Available bulk action: the row's Download applied to the
    /// whole group, so acting on a group is one click rather than N.
    func downloadAllAvailableMenuEpisodes() {
        for episode in menuDownloadableEpisodes {
            downloadEpisode(episode)
        }
    }

    /// The Menu's Downloaded bulk action: the row's own step applied to the
    /// group. Preparing stays in Downloaded with progress on each row.
    func prepareAllDownloadedMenuEpisodes() {
        for episode in menuPreparableEpisodes {
            if isDeferredForOffPeak(episode.id) {
                _ = prepareDeferredEpisodeNow(episode)
            } else {
                prepareEpisode(episode)
            }
        }
    }

    /// Whether the reader has started an episode: a saved position, a
    /// finished-by-hand record, or it is the one playing right now. The one
    /// definition `skipEpisode` guards on and the row's label reads.
    func hasStartedEpisode(_ episode: WiltedMacEpisode) -> Bool {
        episode.isPlayed || episode.playbackSeconds > 0 || currentPodcastEpisodeID == episode.id
    }

    /// The group action names the queue mutation, not the retirement detail.
    /// Media, prepared cuts, transcripts and listening history are preserved.
    func menuGroupClearLabel(_ group: WiltedMacMenuGroup) -> String {
        let episodes = menuUnfilteredEpisodes(in: group)
        return "Remove all \(episodes.count) from Larder"
    }

    /// Removes exactly the rows the group renders from the Menu, and nothing
    /// else: every row's download, prepared cut and transcript stay where they
    /// are.
    ///
    /// This is queue removal, not Skip or Completed. The whole group leaves
    /// Larder on the next render, then the durable queue is brought in line.
    func clearMenuGroup(_ group: WiltedMacMenuGroup) {
#if canImport(WiltedProducer)
        let episodes = menuUnfilteredEpisodes(in: group)
        guard !episodes.isEmpty else { return }
        let ids = Set(episodes.map(\.id))
        let wasPlaying = currentPodcastEpisodeID.map(ids.contains) ?? false
        // The optimistic half: the whole group leaves the Menu on the next
        // render, exactly as one row's removal does.
        podcastQueueIDs.removeAll { ids.contains($0) }
        // A bulk clear is not one episode's Skip, so nothing single is left
        // for Undo Skip to restore.
        undoableSkip = nil
        podcastOperationMessage = "Removed all \(episodes.count) in \(group.displayName) from Larder. No download, prepared cut, transcript, or listening history was touched."
        Task { [weak self] in
            guard let self else { return }
            for episode in episodes {
                if let playback = self.playback, let id = try? ItemID(rawValue: episode.id) {
                    try? await playback.removePodcastQueueEpisode(id)
                }
            }
            if wasPlaying { await self.stopPlaybackForRemovedEpisode() }
            await self.refreshPodcastQueueState()
            await self.reloadLibraryRows()
        }
#endif
    }

    /// Moves a durable entry before another. Returns false for a payload
    /// that is not one of the Menu's episodes or a no-op destination, so the
    /// drop handler can refuse it rather than claiming a move that never
    /// happened.
    @discardableResult
    func moveMenuEpisode(_ episodeID: String, before destinationID: String) -> Bool {
        guard episodeID != destinationID,
              let source = podcastQueueIDs.firstIndex(of: episodeID),
              let destination = podcastQueueIDs.firstIndex(of: destinationID) else { return false }
        // A drag is an explicit custom order. Leaving a calculated sort
        // selected would immediately redraw the listener's manual move away.
        menuSort = .custom
        moveEpisodeInUpNext(
            from: source,
            to: Self.menuInsertionIndex(source: source, destination: destination)
        )
        return true
    }

    /// Moves a durable entry to the end. The tail strip below the last row
    /// passes the queue's count, which `menuInsertionIndex` reads as "after
    /// the last row".
    @discardableResult
    func moveMenuEpisodeToEnd(_ episodeID: String) -> Bool {
        guard let source = podcastQueueIDs.firstIndex(of: episodeID) else { return false }
        menuSort = .custom
        moveEpisodeInUpNext(
            from: source,
            to: Self.menuInsertionIndex(source: source, destination: podcastQueueIDs.count)
        )
        return true
    }

    /// The insertion index a drop is asking for. `destination` is the index
    /// of the row the dragged episode lands before, or the queue's count for
    /// the tail strip. The answer is in post-removal terms, which is what
    /// `moveEpisodeInUpNext` and the store expect: a tail drop answers with
    /// the position after the remaining rows, which is that queue's count.
    static func menuInsertionIndex(source: Int, destination: Int) -> Int {
        source < destination ? destination - 1 : destination
    }

    func moveMenuEpisode(_ episodeID: String, by offset: Int) {
        guard let source = podcastQueueIDs.firstIndex(of: episodeID) else { return }
        let destination = source + offset
        guard podcastQueueIDs.indices.contains(destination),
              podcastQueueIDs[destination] != currentPodcastEpisodeID else { return }
        menuSort = .custom
        moveEpisodeInUpNext(from: source, to: destination)
    }

    func moveEpisodeInUpNext(from source: Int, to destination: Int) {
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackOperationStatus = "Reordering Larder…"
        Task { [weak self] in
            try? await playback.movePodcastQueueEpisode(from: source, to: destination)
            await self?.refreshPodcastQueueState()
            self?.playbackOperationStatus = nil
        }
#endif
    }

    func setPlaybackRate(_ value: Double) {
        playbackRate = Self.clampPlaybackRate(value)
        preferences.set(playbackRate, forKey: Self.playbackRatePreferenceKey)
#if canImport(WiltedProducer)
        playback?.defaultRate = Float(playbackRate)
        playback?.setRate(Float(playbackRate))
        rescheduleSeamMarker()
        guard isPodcastPlayback, let store, let id = playback?.itemID else { return }
        let selectedRate = playbackRate
        playbackOperationStatus = "Saving playback speed…"
        Task { [weak self] in
            try? await store.save(playbackSpeed: PodcastPlaybackSpeed(
                itemID: id, speed: selectedRate, updatedAt: Timestamp(Date())
            ))
            self?.playbackOperationStatus = nil
        }
#else
        rescheduleSeamMarker()
#endif
    }

    func setPlaybackVolume(_ value: Double) {
        playbackVolume = min(max(value, 0), 1)
#if canImport(WiltedProducer)
        playback?.setVolume(Float(playbackVolume))
#endif
    }

    func scrub(to value: Double) {
        guard value.isFinite else { return }
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(to: value)
                self.refreshPlaybackReadout()
                // A scrub is exactly the jump the system cannot extrapolate,
                // and a short one is inside the drift tolerance.
                self.publishNowPlaying(force: true)
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#else
        playbackPositionSeconds = min(max(value, 0), max(0, playbackDurationSeconds))
#endif
    }

    /// Republishes elapsed/total from the controller.
    ///
    /// `PlaybackController` advances its own position, but nothing observed it
    /// while audio ran, so the producer's readout would freeze at the loaded
    /// value. The player view drives this on a one-second cadence, matching
    /// the listener's `refreshNowPlayingReadout`. A caller that is about to
    /// force its own publish passes `shouldPublishNowPlaying: false`, so the
    /// widget is not handed an intermediate state first.
    func refreshPlaybackReadout(shouldPublishNowPlaying: Bool = true) {
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackDurationSeconds = playback.durationSeconds
        // The live engine read, not the checkpointed one. `positionSeconds`
        // only moves on load, seek, and checkpoint, so polling it left the
        // readout frozen between transport presses.
        playbackPositionSeconds = min(max(0, playback.livePositionSeconds), max(0, playback.durationSeconds))
        isPlaying = playback.liveIsPlaying
        playbackCompleted = playback.completed
        playbackRate = Double(playback.playbackRate)
#endif
        updateCurrentLibraryPlaybackProjection()
        // The one funnel every transport and the player's timer already goes
        // through, so the system readout cannot drift from the on-screen one.
        if shouldPublishNowPlaying { publishNowPlaying() }
        rescheduleSeamMarker()
    }

    /// Replaces the one pending marker with one based on the engine's live state.
    /// The wake-time check below makes a seek or pause harmless even between
    /// the player view's one-second readouts.
    func rescheduleSeamMarker() {
        cancelSeamMarker()

        guard isPodcastPlayback, let episode = currentEpisode else { return }
#if canImport(WiltedProducer)
        let position = playback?.livePositionSeconds ?? playbackPositionSeconds
        let isPlaying = playback?.liveIsPlaying ?? self.isPlaying
        let rate = Double(playback?.playbackRate ?? Float(playbackRate))
#else
        let position = playbackPositionSeconds
        let isPlaying = self.isPlaying
        let rate = playbackRate
#endif
        let effectiveLastMarked = WiltedMacSeamMarkerSchedule.effectiveLastMarked(
            lastMarkedSeam, episodeID: episode.id, position: position
        )
        if effectiveLastMarked == nil {
            lastMarkedSeam = nil
        }
        guard let marker = WiltedMacSeamMarkerSchedule.next(
            seams: currentRemovedSpans.map(\.preparedSeconds),
            position: position,
            rate: rate,
            isPlaying: isPlaying,
            enabled: marksRemovedAds,
            lastMarked: effectiveLastMarked
        ) else { return }

        pendingSeamMarkerForTesting = marker.seam
        let episodeID = episode.id
        seamMarkerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(marker.delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.currentPodcastEpisodeID == episodeID else {
                self.rescheduleSeamMarker()
                return
            }
#if canImport(WiltedProducer)
            let livePosition = self.playback?.livePositionSeconds ?? self.playbackPositionSeconds
            let liveIsPlaying = self.playback?.liveIsPlaying ?? self.isPlaying
            let volume = self.playback?.backend.volume ?? Float(self.playbackVolume)
#else
            let livePosition = self.playbackPositionSeconds
            let liveIsPlaying = self.isPlaying
            let volume = Float(self.playbackVolume)
#endif
            if WiltedMacSeamMarkerSchedule.shouldFire(
                seam: marker.seam, livePosition: livePosition, isPlaying: liveIsPlaying
            ) {
                self.lastMarkedSeam = (episodeID, marker.seam)
                self.seamMarkerOutput.play(volume: volume)
            }
            self.rescheduleSeamMarker()
        }
    }

    func cancelSeamMarker() {
        seamMarkerTask?.cancel()
        seamMarkerTask = nil
        pendingSeamMarkerForTesting = nil
    }

    /// Keeps the outgoing row current when playback moves to another item.
    /// The live total overlays the active playhead; this retained projection
    /// prevents that progress from disappearing as soon as the overlay moves.
    private func updateCurrentLibraryPlaybackProjection() {
        guard isNowPlaying, let id = loadedPlaybackItemID else { return }
        let position = min(max(0, playbackPositionSeconds), max(0, playbackDurationSeconds))
        if let index = episodes.firstIndex(where: { $0.id == id }) {
            episodes[index].playbackSeconds = position
            episodes[index].isPlayed = playbackCompleted
        } else if let index = articles.firstIndex(where: { $0.id == id }) {
            articles[index].playbackSeconds = position
            articles[index].isPlayed = playbackCompleted
        }
    }

    /// The controller changes identity only after a load succeeds. Selection
    /// changes earlier so the destination can render immediately, but it must
    /// never receive the previous item's live position when that load fails.
    private var loadedPlaybackItemID: String? {
#if canImport(WiltedProducer)
        if let id = playback?.itemID?.rawValue { return id }
#endif
        return isPodcastPlayback ? currentPodcastEpisodeID : selectedArticleID
    }

#if canImport(WiltedProducer)
    func loadTranscript(itemID: ItemID, revisionID: RevisionID) async {
        guard let store else { return }
        guard let stored = try? await store.transcript(for: itemID, revisionID: revisionID) else {
            currentTranscript = WiltedMacTranscript(availability: .absent, text: nil)
            return
        }
        let availability: WiltedMacTranscript.Availability = switch stored.availability {
        case .available: .available
        case .stale: .stale
        case .oversized: .oversized
        case .malformed: .malformed
        case .absent: .absent
        }
        let timingSource: String? = switch stored.timing {
        case .published: "synced from the feed"
        case .aligned: "synced"
        case .none: nil
        }
        currentTranscript = WiltedMacTranscript(
            availability: availability, text: stored.text,
            cues: (stored.cues ?? []).enumerated().map { index, cue in
                WiltedMacTranscriptCue(id: index, startSeconds: cue.startSeconds,
                                       endSeconds: cue.endSeconds, text: cue.text,
                                       speaker: cue.speaker)
            },
            timingSource: timingSource
        )
    }
#endif

#if canImport(WiltedProducer)
    /// Loads the transcript for whichever revision of an episode is ready now.
    ///
    /// The revision cannot be remembered from when the episode was downloaded:
    /// preparation cuts the audio, which changes its bytes and therefore its
    /// identity, so the current one has to be read back from the library.
    func loadEpisodeTranscript(itemID: ItemID) async {
        guard let store, let stored = try? await store.readyRevision(for: itemID) else {
            currentTranscript = .unavailable
            // Spans loaded earlier in the session describe a revision that can
            // no longer be resolved. Leaving them would list cuts under
            // "Transcript unavailable" against audio nothing can vouch for.
            removedSpansByEpisode[itemID.rawValue] = []
            rescheduleSeamMarker()
            return
        }
        await loadTranscript(itemID: itemID, revisionID: stored.revision.revisionID)
        await loadRemovedSpans(itemID: itemID, revisionID: stored.revision.revisionID)
    }

    /// Reads the cuts from the preparation journal rather than from the
    /// transcript.
    ///
    /// A marker written into the transcript itself would have to be re-based
    /// every time the audio was cut again, and would drift from the numbers
    /// Prep reports for the same run. The journal already holds both clocks.
    private func loadRemovedSpans(itemID: ItemID, revisionID: RevisionID) async {
        guard let store else { return }
        guard let timeline = try? await store.latestPreparationTimeline(
            for: itemID, revisionID: revisionID
        ) else {
            removedSpansByEpisode[itemID.rawValue] = []
            rescheduleSeamMarker()
            return
        }
        removedSpansByEpisode[itemID.rawValue] = Self.removedSpans(in: timeline)
        rescheduleSeamMarker()
    }

    /// The removed intervals placed on the prepared clock, in the order a
    /// listener meets them.
    nonisolated static func removedSpans(
        in timeline: PreparationStatus.PreparationTimeline
    ) -> [WiltedMacRemovedSpan] {
        timeline.removed.enumerated().map { index, removed in
            WiltedMacRemovedSpan(
                id: index,
                preparedSeconds: preparedSeam(for: removed, in: timeline),
                originalStartSeconds: removed.originalStartSeconds,
                originalEndSeconds: removed.originalEndSeconds,
                label: removed.label
            )
        }
        .sorted { $0.preparedSeconds < $1.preparedSeconds }
    }
#endif

    // MARK: - System playback integration

    /// What the system widget should show, or nil when nothing is loaded.
    ///
    /// Articles and episodes both appear. An article is spoken audio with a
    /// duration and a position exactly as an episode is, and a listener who
    /// pressed play on one expects the same media key to pause it.
    var currentNowPlayingInfo: WiltedNowPlayingInfo? {
        guard isNowPlaying else { return nil }
        let identity: (id: String, title: String, show: String, artwork: URL?)
        if let episode = currentEpisode, isPodcastPlayback {
            identity = (episode.id, episode.title, episode.feedTitle, episode.artworkURL)
        } else if let article = currentArticle {
            identity = (article.id, article.title, article.source, nil)
        } else {
            return nil
        }
        return WiltedNowPlayingInfo(
            episodeID: identity.id,
            title: identity.title,
            showTitle: identity.show,
            durationSeconds: max(0, playbackDurationSeconds),
            positionSeconds: min(max(0, playbackPositionSeconds), max(0, playbackDurationSeconds)),
            // Zero while paused. The system advances its own clock from this,
            // so reporting the resume speed of a paused episode would make the
            // widget's scrubber walk forward through silence.
            rate: isPlaying ? playbackRate : 0,
            chosenRate: playbackRate,
            isPlaying: isPlaying,
            artworkURL: identity.artwork
        )
    }

}
