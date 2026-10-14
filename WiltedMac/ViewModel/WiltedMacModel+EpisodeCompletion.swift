import Foundation
import WiltedLibrary
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
    /// Marks an episode the listener has started completed, deleting nothing.
    ///
    /// The row's Skip button used to call `removeEpisode`, which erased the
    /// episode's records and needed a network feed check to bring anything
    /// back. The accepted Larder mockup asks for a reversible exclusion instead:
    /// a started episode is marked finished through the same listening record
    /// every other completion writes, and taken off the playback queue, while
    /// its media, preparation outcome, transcript and identity all stay on
    /// disk. `undoSkipEpisode` therefore restores it entirely offline. An
    /// episode never started has nothing to finish, and its state is left
    /// exactly as it was.
    ///
    /// `requireStarted` is false only for the phone's Mark completed, where the listening
    /// happened on the phone and the Mac has no saved position of its own.
    func skipEpisode(_ episode: WiltedMacEpisode, requireStarted: Bool = true) {
#if canImport(WiltedProducer)
        guard !requireStarted || hasStartedEpisode(episode) else {
            podcastOperationMessage = "\(episode.title) was not started, so nothing was marked completed."
            return
        }
        // One completion per episode: a repeat tap while the write runs must
        // not start a second writer, and Undo must not race the one in flight.
        guard episodeCompletionProjections[episode.id] == nil else { return }
        guard let id = try? ItemID(rawValue: episode.id) else {
            podcastOperationMessage = "\(episode.title) could not be marked completed."
            return
        }
        guard let store, !isClosingTemporaryState else { return }
        undoableRemoval = nil
        undoableSkip = nil
        let projectedRetiredAt = Date()
        episodeCompletionProjections[episode.id] = WiltedMacEpisodeCompletionProjection(
            original: episode, projectedRetiredAt: projectedRetiredAt
        )
        if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
            episodes[index].isPlayed = true
            episodes[index].retiredAt = projectedRetiredAt
            episodes[index].removalKind = .retired
        }
        invalidateProjectedLibraryReads()
        podcastOperationMessage = "Saving \(episode.title) as completed\u{2026}"
        trackSubscriptionWrite { [weak self] in
            guard let self else { return }
            defer { self.episodeCompletionProjections[episode.id] = nil }
            let skipped: Bool
            do {
                try await self.subscriptionWriteHookForTesting?()
                // `lastRevisionID` stays nil on purpose: a skip is not
                // evidence about the revision's audio. The store persists this
                // listening shape and the retirement together, so Feeds never
                // sees the completed row as active between two saves.
                skipped = try await store.completeAndRetireEpisode(listening: PodcastListeningState(
                    episodeID: id, completedAt: Timestamp(Date()),
                    lastRevisionID: nil, updatedAt: Timestamp(Date())
                ))
            } catch {
                self.rollbackEpisodeCompletionProjection(episode.id, title: episode.title)
                return
            }
            guard skipped else {
                self.rollbackEpisodeCompletionProjection(episode.id, title: episode.title)
                return
            }
            // The completion is durable. Nothing past this point rolls it back
            // or reports the write as failed, whatever a reread does.
            self.episodeCompletionProjections[episode.id] = nil
            self.withdrawPreparationRequest(for: episode.id)
            // The listener's own decision: automatic admission must not reverse it.
            let recorded = await self.recordOwnerDecision(.skip, for: episode.id, store: store)
            self.undoableSkip = episode
            self.podcastOperationMessage = recorded
                ? "Marked \(episode.title) completed. Undo completion restores it."
                : "Marked \(episode.title) completed, but the choice could not be saved. Undo completion restores it."
            if let playback = self.playback {
                try? await playback.removePodcastQueueEpisode(id)
                await self.refreshPodcastQueueState()
            }
            // Stop only the episode this operation completed; playback that
            // another command started while the write ran is left alone.
            if self.currentPodcastEpisodeID == episode.id { await self.stopPlaybackForRemovedEpisode() }
            await self.releaseWaitingEpisodesAfterRetirement(of: episode)
        }
#endif
    }

    /// The row the Larder draws while a completion is being written.
    nonisolated static func projectedCompletion(
        _ row: WiltedMacEpisode, retiredAt: Date
    ) -> WiltedMacEpisode {
        var value = row
        value.isPlayed = true
        value.retiredAt = retiredAt
        value.removalKind = .retired
        return value
    }

    /// Reapplies in-flight completion projections to freshly loaded rows, so a
    /// reload cannot resurrect an episode whose completion is still writing.
    nonisolated static func applyingPendingEpisodeCompletions(
        _ loaded: [WiltedMacEpisode],
        projections: [String: WiltedMacEpisodeCompletionProjection]
    ) -> [WiltedMacEpisode] {
        guard !projections.isEmpty else { return loaded }
        return loaded.map { row in
            guard let projection = projections[row.id] else { return row }
            return Self.projectedCompletion(row, retiredAt: projection.projectedRetiredAt)
        }
    }

    /// Puts a failed completion back exactly as this operation found it. Only
    /// the completion fields are unprojected, so a download or preparation
    /// that advanced while the write ran keeps its progress, and no unrelated
    /// hidden episode or playback command is touched.
    func rollbackEpisodeCompletionProjection(_ episodeID: String, title: String) {
        if let projection = episodeCompletionProjections[episodeID],
           let index = episodes.firstIndex(where: { $0.id == episodeID }) {
            episodes[index].isPlayed = projection.original.isPlayed
            episodes[index].retiredAt = projection.original.retiredAt
            episodes[index].removalKind = projection.original.removalKind
        }
        episodeCompletionProjections[episodeID] = nil
        undoableSkip = nil
        podcastOperationMessage = "\(title) could not be marked completed."
    }

    /// Reverses `skipEpisode`'s local completion from local state alone.
    ///
    /// The listening record is cleared and the episode plays again from the
    /// media already on disk; no feed is consulted, which is the acceptance
    /// bar the owner set for a mistaken Skip.
    func undoSkipEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        // Undo is offered only after the completion is durable, but a direct
        // call must not race the completion writer either.
        guard episodeCompletionProjections[episode.id] == nil else { return }
        undoableSkip = nil
        podcastOperationMessage = "Restoring \(episode.title)…"
        trackSubscriptionWrite { [weak self] in
            guard let self, let store = self.store, let id = try? ItemID(rawValue: episode.id) else { return }
            do {
                let restored = try await store.undoCompletedAndRetiredEpisode(id)
                guard restored else {
                    self.podcastOperationMessage = "\(episode.title) could not be restored."
                    return
                }
                let recorded = await self.recordOwnerDecision(.keep, for: episode.id, store: store)
                await self.reloadLibraryRows()
                self.podcastOperationMessage = recorded
                    ? "Restored \(episode.title)."
                    : "Restored \(episode.title), but the choice could not be saved."
                if let restored = self.episodes.first(where: { $0.id == episode.id }) {
                    self.playEpisode(restored)
                }
            } catch {
                self.podcastOperationMessage = "\(episode.title) could not be restored."
            }
        }
#endif
    }
}
