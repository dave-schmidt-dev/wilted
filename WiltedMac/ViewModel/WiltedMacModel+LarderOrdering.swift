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
    /// Whether the reader has started an episode: a saved position, a
    /// finished-by-hand record, or it is the one playing right now. The one
    /// definition `skipEpisode` guards on and the row's label reads.
    func hasStartedEpisode(_ episode: WiltedMacEpisode) -> Bool {
        episode.isPlayed || episode.playbackSeconds > 0 || currentPodcastEpisodeID == episode.id
    }

    /// The group action names the queue mutation, not the retirement detail.
    /// Media, prepared cuts, transcripts and listening history are preserved.
    func larderGroupClearLabel(_ group: WiltedMacLarderGroup) -> String {
        let episodes = larderUnfilteredEpisodes(in: group)
        return "Remove all \(episodes.count) from Larder"
    }

    /// Removes exactly the rows the group renders from the Larder, and nothing
    /// else: every row's download, prepared cut and transcript stay where they
    /// are.
    ///
    /// Podcasts use one receipt-backed completion; books keep queue-only
    /// removal. Each affected row leaves the Larder with immediate feedback.
    func clearLarderGroup(_ group: WiltedMacLarderGroup) {
#if canImport(WiltedProducer)
        let episodes = larderUnfilteredEpisodes(in: group)
        guard !episodes.isEmpty else { return }
        let podcasts = episodes.filter { !$0.isAudiobook }
        if !podcasts.isEmpty { finishEpisodes(podcasts) }
        let books = episodes.filter(\.isAudiobook)
        guard !books.isEmpty else { return }
        let ids = Set(books.map(\.id))
        let wasPlaying = currentPodcastEpisodeID.map(ids.contains) ?? false
        // The optimistic half: the whole group leaves the Larder on the next
        // render, exactly as one row's removal does.
        podcastQueueIDs.removeAll { ids.contains($0) }
        // A bulk clear is not one episode's Skip, so nothing single is left
        // for Undo Skip to restore.
        if podcasts.isEmpty {
            podcastOperationMessage = "Removed all \(books.count) in \(group.displayName) from Larder. No download, prepared cut, transcript, or listening history was touched."
        }
        Task { [weak self] in
            guard let self else { return }
            for episode in books {
                if let playback = self.playback, let id = try? ItemID(rawValue: episode.id) {
                    try? await playback.removePodcastQueueEpisode(id)
                }
            }
            if wasPlaying, let current = self.currentPodcastEpisodeID, ids.contains(current) { await self.stopPlaybackForRemovedEpisode() }
            await self.refreshPodcastQueueState()
            await self.reloadLibraryRows()
        }
#endif
    }

    /// The one drop entry point for the Larder: a row passes its own ID, the
    /// strip after the last row passes nil. A drop is accepted only when every
    /// payload is a queued episode and they name one episode (the row's drag
    /// vends exactly one); arbitrary text, unknown IDs and mixed payloads are
    /// refused with the order untouched.
    @discardableResult
    func dropLarderEpisodes(_ payload: [String], before destinationID: String?) -> Bool {
        let dragged = Set(payload)
        guard dragged.count == 1, let draggedID = dragged.first,
              podcastQueueIDs.contains(draggedID) else { return false }
        guard let destinationID else { return moveLarderEpisodeToEnd(draggedID) }
        return moveLarderEpisode(draggedID, before: destinationID)
    }

    /// Moves a durable entry before another. Returns false for a payload
    /// that is not one of the Larder's episodes or a no-op destination, so the
    /// drop handler can refuse it rather than claiming a move that never
    /// happened.
    @discardableResult
    func moveLarderEpisode(_ episodeID: String, before destinationID: String) -> Bool {
        guard episodeID != destinationID,
              let source = podcastQueueIDs.firstIndex(of: episodeID),
              let destination = podcastQueueIDs.firstIndex(of: destinationID) else { return false }
        // A drag is an explicit custom order. Leaving a calculated sort
        // selected would immediately redraw the listener's manual move away.
        larderSort = .custom
        moveEpisodeInUpNext(
            from: source,
            to: Self.larderInsertionIndex(source: source, destination: destination)
        )
        return true
    }

    /// Moves a durable entry to the end. The tail strip below the last row
    /// passes the queue's count, which `larderInsertionIndex` reads as "after
    /// the last row".
    @discardableResult
    func moveLarderEpisodeToEnd(_ episodeID: String) -> Bool {
        guard let source = podcastQueueIDs.firstIndex(of: episodeID) else { return false }
        larderSort = .custom
        moveEpisodeInUpNext(
            from: source,
            to: Self.larderInsertionIndex(source: source, destination: podcastQueueIDs.count)
        )
        return true
    }

    /// The insertion index a drop is asking for. `destination` is the index
    /// of the row the dragged episode lands before, or the queue's count for
    /// the tail strip. The answer is in post-removal terms, which is what
    /// `moveEpisodeInUpNext` and the store expect: a tail drop answers with
    /// the position after the remaining rows, which is that queue's count.
    static func larderInsertionIndex(source: Int, destination: Int) -> Int {
        source < destination ? destination - 1 : destination
    }

    func moveLarderEpisode(_ episodeID: String, by offset: Int) {
        guard let source = podcastQueueIDs.firstIndex(of: episodeID) else { return }
        let destination = source + offset
        guard podcastQueueIDs.indices.contains(destination),
              podcastQueueIDs[destination] != currentPodcastEpisodeID else { return }
        larderSort = .custom
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

    // MARK: - Articles and books in the Larder list

    /// The group an article sits in: Ready once it has audio. One still synthesizing has no lifecycle
    /// group; the presentation lifts it into Active work.
    nonisolated static func larderGroup(for article: WiltedMacArticle) -> WiltedMacLarderGroup? {
        article.isReady ? .playable : nil
    }

    /// The feed-grouping heading of a row: the show, the article's source, or Audiobooks.
    nonisolated static func larderFeedTitle(for item: WiltedMacLibraryItem) -> String {
        switch item {
        case .episode(let value): value.feedTitle
        case .article(let value): value.source
        case .audiobook: "Audiobooks"
        }
    }

    /// The articles the kind filter and the search admit, before the group chip.
    var larderKindArticles: [WiltedMacArticle] {
        larderKind.includesArticles ? larderSearchArticleResults : []
    }

    /// The articles one group shows. Only Ready holds articles; the others hold none.
    func larderArticles(in group: WiltedMacLarderGroup) -> [WiltedMacArticle] {
        larderKindArticles.filter { Self.larderGroup(for: $0) == group }
    }

    /// The rows one group renders: its episodes and books, then its articles. The display step orders
    /// them (an article has no queue position).
    func larderItems(in group: WiltedMacLarderGroup) -> [WiltedMacLibraryItem] {
        larderEpisodes(in: group).map(WiltedMacLibraryItem.init(episode:))
            + larderArticles(in: group).map(WiltedMacLibraryItem.article)
    }

    /// Every row the list shows under the kind filter, search and group chip.
    var larderFilteredItems: [WiltedMacLibraryItem] {
        let episodes = larderFilteredEpisodes.map(WiltedMacLibraryItem.init(episode:))
        let articles = larderKindArticles.filter { article in
            larderFilter.map { Self.larderGroup(for: article) == $0 } ?? true
        }
        return episodes + articles.map(WiltedMacLibraryItem.article)
    }

    /// The count a group chip shows, or the All chip when `group` is nil, counted from the same rows the
    /// list draws so a chip can never label a list it does not match.
    func larderItemCount(in group: WiltedMacLarderGroup?) -> Int {
        guard let group else { return larderSearchResults.count + larderKindArticles.count }
        return larderEpisodes(in: group).count + larderArticles(in: group).count
    }

    // MARK: - Audiobook chapters

    /// The audiobook details of what the player holds, when it holds a book volume with chapter marks.
    private var currentChapterDetails: WiltedMacAudiobookDetails? {
        guard isPodcastPlayback, let details = currentEpisode?.audiobook, !details.chapters.isEmpty else { return nil }
        return details
    }

    /// The title of the chapter under the playhead, or nil when no book is playing.
    var currentChapterTitle: String? {
        guard let details = currentChapterDetails,
              let index = details.chapterIndex(at: playbackPositionSeconds) else { return nil }
        return details.chapters[index].title
    }

    /// `Chapter 3 of 12`, for the player's chapter line.
    var currentChapterPositionLabel: String? {
        guard let details = currentChapterDetails,
              let index = details.chapterIndex(at: playbackPositionSeconds) else { return nil }
        return "Chapter \(index + 1) of \(details.chapters.count)"
    }

    var canSelectPreviousChapter: Bool {
        currentChapterDetails?.previousChapterStart(from: playbackPositionSeconds) != nil
    }

    var canSelectNextChapter: Bool {
        currentChapterDetails?.nextChapterStart(from: playbackPositionSeconds) != nil
    }

    /// Restarts the current chapter, or goes to the one before it from its first seconds. A seek
    /// inside the volume's single file.
    func selectPreviousChapter() {
        guard let start = currentChapterDetails?.previousChapterStart(from: playbackPositionSeconds) else { return }
        scrub(to: start)
    }

    func selectNextChapter() {
        guard let start = currentChapterDetails?.nextChapterStart(from: playbackPositionSeconds) else { return }
        scrub(to: start)
    }

    func setPlaybackRate(_ value: Double) {
        playbackRate = Self.clampPlaybackRate(value)
        preferences.set(playbackRate, forKey: Self.playbackRatePreferenceKey)
#if canImport(WiltedProducer)
        playback?.defaultRate = Float(playbackRate)
        playback?.setRate(Float(playbackRate))
        rescheduleSeamMarker()
        guard isPodcastPlayback, let id = playback?.itemID else { return }
        // The live speed above stays in force whatever the save does; the
        // save reports on its own status line, scoped to this episode.
        savePlaybackSpeed(playbackRate, for: id)
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
        // A scrub is exactly the jump the system cannot extrapolate, and a
        // short one is inside the drift tolerance, so it publishes the jump.
        seekPlayback(publishesJump: true) { try await $0.seek(to: value) }
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
        guard playback?.itemID == itemID, playback?.revisionID == revisionID else { return }
        cancelPlaybackPresentation()
        guard let owner = playbackPresentationOwner(itemID: itemID, revisionID: revisionID) else { return }
        await readPlaybackPresentation(owner, includesCuts: false)
    }
#endif

#if canImport(WiltedProducer)
    /// Uses the revision already loaded into the transport, never a newer catalog revision.
    func loadEpisodeTranscript(itemID: ItemID) async {
        guard playback?.itemID == itemID else { return }
        cancelPlaybackPresentation()
        guard let revisionID = playback?.revisionID,
              let owner = playbackPresentationOwner(itemID: itemID, revisionID: revisionID) else { return }
        await readPlaybackPresentation(owner, includesCuts: true)
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
