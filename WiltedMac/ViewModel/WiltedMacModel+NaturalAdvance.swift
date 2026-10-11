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
                                  keepsFinishedOnPause: isLarderQueuePlayback)
    }

    /// Retirement belongs to the finished item even when a newer command owns subsequent audio.
    func continueNaturalPodcastEnd(
        finishedID: String, advance: WiltedMacAutomaticAdvance, keepsFinishedOnPause: Bool
    ) {
        enqueuePlaybackEffect { [weak self] in
            guard let self, let playback = self.playback, let store = self.store else { return }
            await self.reloadLibraryRows()
            var note: String?
            if let id = try? ItemID(rawValue: finishedID) {
                self.undoableRemoval = nil
                try? await playback.removePodcastQueueEpisode(id)
                await self.refreshPodcastQueueState()
                note = await self.completeAndRetire(id)
            }
            await self.reloadLibraryRows()
            // One immutable candidate set bounds retries while preserving displayed Ready order.
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
                    self.larderSort = .custom
                    self.isLarderQueuePlayback = false
                    self.currentPodcastEpisodeID = candidate.id
                    self.isPodcastPlayback = true
                    self.isNowPlaying = true
                    self.isPlaying = playback.isPlaying
                    self.currentTranscript = .unavailable
                    self.logAutomaticAdvanceDecision(chosenID: candidate.id, reason: "first_ready_row")
                    self.podcastOperationMessage = note
                    await self.refreshPodcastQueueState()
                    await self.loadEpisodeTranscript(itemID: id)
                    self.refreshPlaybackReadout()
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
                await self.reloadLibraryRows()
                self.podcastOperationMessage = note
                return
            }
            await self.stopPlaybackForRemovedEpisode()
            await self.reloadLibraryRows()
            self.isLarderQueuePlayback = false
            self.logAutomaticAdvanceDecision(chosenID: nil, reason: "no_eligible_ready_row")
            self.podcastOperationMessage = [note, "No other downloaded, prepared episode is ready to play next."]
                .compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Observes the emitted decision in serialized hosted model tests.
    static var advanceDecisionLogObserverForTesting: ((String) -> Void)?

    private func logAutomaticAdvanceDecision(chosenID: String?, reason: String) {
        let message = "advance.decision chosen=\(chosenID ?? "none") reason=\(reason)"
        Self.playbackLog.notice("\(message, privacy: .public)")
        Self.advanceDecisionLogObserverForTesting?(message)
    }
}
#endif
