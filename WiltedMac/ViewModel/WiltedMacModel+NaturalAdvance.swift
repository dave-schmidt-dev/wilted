import Foundation
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

extension WiltedMacModel {
    /// Direct completion seam; backend completions capture the owner earlier, at synchronous EOF.
    func handlePodcastPlaybackFinished() {
        if playlistEntryFinished() { return }
        refreshPlaybackReadout()
        guard isPodcastPlayback, let finishedID = currentPodcastEpisodeID,
              playback?.completed == true,
              episodes.first(where: { $0.id == finishedID })?.isAudiobook != true else { return }
        continueNaturalPodcastEnd(finishedID: finishedID, advance: beginAutomaticAdvance(),
                                  keepsFinishedOnPause: isLarderQueuePlayback,
                                  reachedEndAt: logNaturalEnd(finishedID: finishedID))
    }

    /// The controller's natural-end handler for `itemID`, built at synchronous end of file.
    /// Playlist and non-podcast completions get none.
    func naturalPodcastEndHandler(for itemID: ItemID) -> (@MainActor @Sendable () -> Void)? {
        guard isPodcastPlayback, !playlistSessionIsCurrent,
              episodes.first(where: { $0.id == itemID.rawValue })?.isAudiobook != true else { return nil }
        let end = WiltedMacNaturalEnd(
            finishedID: itemID, reachedEndAt: logNaturalEnd(finishedID: itemID.rawValue), model: self)
        libraryFollowUps.pendingNaturalEnd = end
        let advance = beginAutomaticAdvance()
        let keepsFinishedOnPause = isLarderQueuePlayback
        return { [weak self] in
            end.handedOff = true
            self?.continueNaturalPodcastEnd(finishedID: itemID.rawValue, advance: advance,
                                           keepsFinishedOnPause: keepsFinishedOnPause,
                                           reachedEndAt: end.reachedEndAt, end: end)
        }
    }

    /// Starts the first Ready row after a natural end, then queues what the
    /// finished episode owes the library behind that start.
    ///
    /// Before the start: the in-memory Ready rows, the finished episode's
    /// queue removal and the candidate checks. Retirement, admission and the
    /// library reloads run afterwards on `libraryFollowUps`; see that type for
    /// why the finished episode stays durable if the app quits right after the
    /// start. Retirement belongs to the finished item even when a newer command
    /// owns subsequent audio.
    func continueNaturalPodcastEnd(
        finishedID: String, advance: WiltedMacAutomaticAdvance, keepsFinishedOnPause: Bool,
        reachedEndAt: ContinuousClock.Instant, end: WiltedMacNaturalEnd? = nil
    ) {
        enqueuePlaybackEffect { [weak self] in
            guard let self, let playback = self.playback, let store = self.store else { return }
            let finishedItemID = try? ItemID(rawValue: finishedID)
            if let finishedItemID {
                self.undoableRemoval = nil
                // The one store write ahead of the start: while the finished
                // episode is still the durable current entry, playing a
                // successor would checkpoint it again and reinsert it after
                // the successor.
                try? await playback.removePodcastQueueEpisode(finishedItemID)
            }
            // The displayed Ready rows (W-INV-032). One immutable candidate set
            // bounds retries while preserving displayed Ready order.
            let candidates = self.larderUnfilteredEpisodes(in: .playable).filter {
                $0.id != finishedID && !$0.isAudiobook && !self.hiddenEpisodeIDs.contains($0.id)
                    && $0.retiredAt == nil && !$0.isPlayed && self.canPlayEpisode($0)
            }
            for candidate in candidates {
                guard self.automaticAdvanceClaim(advance) == .owns else { break }
                guard let id = try? ItemID(rawValue: candidate.id) else { continue }
                let eligible = (try? await playback.isEpisodeEligible(id)) == true
                guard self.automaticAdvanceClaim(advance) == .owns else { break }
                guard eligible else { continue }
                // The eligibility callback may suspend while this row is dismissed elsewhere.
                let removed = (try? await store.removalKind(for: id)) != nil
                guard self.automaticAdvanceClaim(advance) == .owns else { break }
                guard !removed else { continue }
                do {
                    try await playback.playPodcastQueueEpisodeNow(id, startsIf: {
                        self.automaticAdvanceClaim(advance) == .owns
                    })
                    guard self.automaticAdvanceClaim(advance) == .owns else { break }
                    _ = self.claimAutomaticAdvance(advance)
                    self.isLarderQueuePlayback = false
                    self.currentPodcastEpisodeID = candidate.id
                    self.isPodcastPlayback = true
                    self.isNowPlaying = true
                    self.isPlaying = playback.isPlaying
                    self.currentTranscript = .unavailable
                    self.logAutomaticAdvanceDecision(chosenID: candidate.id, reason: "first_ready_row")
                    self.logNaturalEndStart(chosenID: candidate.id, reachedEndAt: reachedEndAt)
                    self.requestPlaybackPresentation(itemID: id, includesCuts: true, refreshQueue: true)
                    self.enqueueNaturalEndFollowUp(finishedItemID, end: end)
                    return
                } catch PlaybackControllerError.podcastMediaUnavailable {
                    // A removed or missing candidate does not end the Ready walk or flash an error.
                    continue
                } catch PlaybackControllerError.podcastMediaUnreadable {
                    continue
                } catch {
                    guard self.automaticAdvanceClaim(advance) == .owns else { break }
                    self.playbackError = WiltedMacPlaybackCopy.unavailable
                    break
                }
            }
            let claim = self.claimAutomaticAdvance(advance)
            if claim != .owns {
                self.logAutomaticAdvanceDecision(chosenID: nil, reason: claim == .paused ? "paused" : "superseded")
                // Queue-origin Pause retains its loaded item; generic continuation clears the player.
                if claim == .paused, !keepsFinishedOnPause { await self.stopPlaybackForRemovedEpisode() }
                self.enqueueNaturalEndFollowUp(finishedItemID, end: end)
                return
            }
            await self.stopPlaybackForRemovedEpisode()
            self.isLarderQueuePlayback = false
            self.logAutomaticAdvanceDecision(chosenID: nil, reason: "no_eligible_ready_row")
            self.enqueueNaturalEndFollowUp(
                finishedItemID, end: end, suffix: "No other downloaded, prepared episode is ready to play next.")
        }
    }

    /// The finished episode's retirement (unless a quit drain already took
    /// it), the queue refresh, the reload and the outcome message, behind the
    /// decision. A closing model keeps only the retirement. The message is
    /// the decision's, so one posted by a later action meanwhile wins.
    private func enqueueNaturalEndFollowUp(_ finishedID: ItemID?, end: WiltedMacNaturalEnd?, suffix: String? = nil) {
        let retires = finishedID != nil && (end?.takeRetirement() ?? true)
        let shownAtDecision = podcastOperationMessage
        libraryFollowUps.enqueue { [weak self] in
            guard let self else { return }
            var note: String?
            if retires, let finishedID { note = await self.completeAndRetire(finishedID) }
            guard !self.isClosingTemporaryState else { return }
            await self.refreshPodcastQueueState()
            await self.reloadLibraryRows()
            guard self.podcastOperationMessage == shownAtDecision else { return }
            let parts = [note, suffix].compactMap { $0 }
            self.podcastOperationMessage = parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Logs end of file and returns its instant, so the start can report the gap.
    private func logNaturalEnd(finishedID: String) -> ContinuousClock.Instant {
        let message = "advance.eof finished=\(finishedID) " + episodeLogContext(finishedID)
        Self.playbackLog.notice("\(message, privacy: .public)")
        return .now
    }

    /// End of file to the successor's play call. It times dispatch to the
    /// audio call, not audible output.
    private func logNaturalEndStart(chosenID: String, reachedEndAt: ContinuousClock.Instant) {
        let gap = (ContinuousClock.now - reachedEndAt).components
        let milliseconds = gap.seconds * 1_000 + gap.attoseconds / 1_000_000_000_000_000
        let message = "advance.started chosen=\(chosenID) eof_to_play_call_ms=\(milliseconds)"
        Self.playbackLog.notice("\(message, privacy: .public)")
    }

    /// Observes the emitted decision in serialized hosted model tests.
    static var advanceDecisionLogObserverForTesting: ((String) -> Void)?

    private func logAutomaticAdvanceDecision(chosenID: String?, reason: String) {
        // The chosen episode's feed and title follow, so the line names it (LG-6).
        let message = "advance.decision chosen=\(chosenID ?? "none") reason=\(reason)"
            + (chosenID.map { " " + episodeLogContext($0) } ?? "")
        Self.playbackLog.notice("\(message, privacy: .public)")
        Self.advanceDecisionLogObserverForTesting?(message)
    }
}
#endif
