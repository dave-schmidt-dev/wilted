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
#if canImport(WiltedProducer)
    /// The durable half of a removal, awaited rather than fired off so a
    /// caller with something to do afterwards can do it in order.
    ///
    /// Returns whether the dismissal stuck. The optimistic hide is rolled back
    /// here when it did not. A committed dismissal still needs undo and capacity
    /// follow-up even if its manual record fails; that failure gets accurate copy.
    func dismissEpisode(_ episode: WiltedMacEpisode) async -> Bool {
        guard let store, let id = try? ItemID(rawValue: episode.id) else { return false }
        do {
            try await store.dismissPodcastEpisode(id)
            let recorded = await recordOwnerDecision(.skip, for: episode.id, store: store)
            if let playback {
                try? await playback.removePodcastQueueEpisode(id)
                await refreshPodcastQueueState()
            }
            let values = try await loadLibrary(from: store)
            articles = values.articles
            applyEpisodes(values.episodes)
            subscriptions = values.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: store)
            if !recorded {
                podcastOperationMessage = "Removed \(episode.title), but the choice could not be saved."
            }
            return true
        } catch {
            hiddenEpisodeIDs.remove(episode.id)
            return false
        }
    }
#endif

    /// Restores a removed episode. The row never left the store, so this
    /// needs no feed evidence -- unlike the old dismiss-deleted-the-row
    /// design, there is nothing to re-match against a re-fetched feed.
    func restoreEpisode(_ dismissal: WiltedMacDismissedEpisode) {
#if canImport(WiltedProducer)
        guard podcastRestoreTasks[dismissal.id] == nil,
              let store, let episodeID = try? ItemID(rawValue: dismissal.id) else { return }
        undoableRemoval = nil
        podcastOperationMessage = "Restoring \(dismissal.title)…"
        podcastRestoreTasks[dismissal.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.podcastRestoreTasks[dismissal.id] = nil }
            await self.restoreEpisode(dismissal, episodeID: episodeID, store: store)
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Clears the optimistic hide once the store confirms the episode is
    /// restored, so the row can actually reappear this session.
    ///
    /// Reported 2026-09-05: skipping the Waveform episode, then restoring it
    /// in the same session, left the store saying "Restored X to Larder."
    /// while the row stayed off screen until the app relaunched. `removeEpisode`
    /// inserts the id into `hiddenEpisodeIDs` immediately, ahead of the store
    /// round-trip, and the shelf's visible set filters on that id. The store-side
    /// restore was working the whole time; nothing ever told the hide set the
    /// row was no longer hidden. Both branches below -- the store reporting a
    /// fresh restore, and the store reporting the episode was already
    /// restored on an earlier attempt -- have to clear the id, because either
    /// one means the store no longer considers the episode removed.
    ///
    /// The row never left the store under dismissal or retirement, so unlike
    /// the old design, restoring needs no re-fetched feed to prove identity --
    /// it is the same store operation `restoreSkippedFeedEpisode` uses.
    func restoreEpisode(
        _ dismissal: WiltedMacDismissedEpisode, episodeID: ItemID, store: LocalLibraryStore
    ) async {
        do {
            let restored = try await store.restoreEpisode(episodeID)
            if !restored, try await store.podcastEpisode(for: episodeID) == nil {
                podcastOperationMessage = "\(dismissal.title) could not be restored because it is no longer in the library."
                return
            }
            let recorded = await recordOwnerDecision(.keep, for: dismissal.id, store: store)
            hiddenEpisodeIDs.remove(dismissal.id)
            let values = try await loadLibrary(from: store)
            articles = values.articles
            applyEpisodes(values.episodes)
            subscriptions = values.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: store)
            podcastOperationMessage = recorded
                ? (restored ? "Restored \(dismissal.title) to Feeds." : "\(dismissal.title) was already restored.")
                : "Restored \(dismissal.title), but the choice could not be saved."
        } catch {
            podcastOperationMessage = "\(dismissal.title) could not be restored. Retry Restore."
        }
    }
#endif

#if canImport(WiltedProducer)
    /// Records the owner's Skip or Restore after the store write it describes
    /// has committed. Follow-up work still runs on failure; callers must not
    /// confirm success until this returns true, including an already-at-target retry.
    @discardableResult
    func recordOwnerDecision(_ decision: EpisodeDecision, for episodeID: String, store: LocalLibraryStore) async -> Bool {
        do {
            try await recordManualDecisions(decision, for: [episodeID], at: Timestamp(Date()), store: store)
            guard let id = try? ItemID(rawValue: episodeID),
                  let recorded = try await store.episodeDecision(for: id),
                  recorded.decision == decision, recorded.source == .manual, recorded.ruleID == nil else {
                removalLog.error("Manual decision record was not persisted")
                return false
            }
            return true
        } catch {
            removalLog.error("Manual decision record failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

#endif
}
