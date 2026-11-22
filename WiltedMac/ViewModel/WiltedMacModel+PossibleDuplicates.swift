import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

extension WiltedMacModel {
    /// "Same episode": the newcomer leaves the library. A row still waiting in Feeds is skipped, which
    /// keeps every record; a row already in the Larder is removed. Nothing is linked to the earlier
    /// episode and no state is shared between the two.
    func removePossibleDuplicate(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        if podcastQueueIDs.contains(episode.id) {
            hideEpisode(episode)
            Task { [weak self] in _ = await self?.dismissEpisode(episode) }
        } else {
            skipFeedEpisode(episode)
        }
#endif
    }

    /// "Different": the flag is cleared and nothing else is changed about the episode. The work the
    /// flag held back is then done as it would have been without it. The answer is noted first
    /// in the preferences and struck off only once that work has been handled, so a quit or a
    /// failure in between picks it up again at the next launch.
    func clearPossibleDuplicateFlag(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard let store, let id = try? ItemID(rawValue: episode.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            self.notePossibleDuplicateCatchUp(episode.id, pending: true)
            guard (try? await store.clearPodcastEpisodePossibleDuplicate(id)) == true else {
                self.notePossibleDuplicateCatchUp(episode.id, pending: false)
                return
            }
            if await self.catchUpAfterPossibleDuplicateCleared(episode.id) {
                self.notePossibleDuplicateCatchUp(episode.id, pending: false)
            }
        }
#endif
    }

    /// Answers whose held work has not been confirmed done, kept across launches.
    static let possibleDuplicateCatchUpKey = "wilted.possibleDuplicateCatchUps"

    func notePossibleDuplicateCatchUp(_ episodeID: String, pending: Bool) {
        var ids = Set(preferences.stringArray(forKey: Self.possibleDuplicateCatchUpKey) ?? [])
        if pending { ids.insert(episodeID) } else { ids.remove(episodeID) }
        preferences.set(ids.sorted(), forKey: Self.possibleDuplicateCatchUpKey)
    }

    /// Finishes, after a relaunch, the work of any "Different" answer that was not confirmed done.
    func resumePossibleDuplicateCatchUps() {
#if canImport(WiltedProducer)
        guard !isClosingTemporaryState, !fixtureMode else { return }
        for id in (preferences.stringArray(forKey: Self.possibleDuplicateCatchUpKey) ?? []).sorted() {
            Task { [weak self] in
                guard let self else { return }
                if await self.catchUpAfterPossibleDuplicateCleared(id) {
                    self.notePossibleDuplicateCatchUp(id, pending: false)
                }
            }
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Does what the flag held back, once, in the way the owner's earlier choices call for. Safe to
    /// repeat. Returns false when it could not finish and should be tried again.
    func catchUpAfterPossibleDuplicateCleared(_ episodeID: String) async -> Bool {
        guard let store, !isClosingTemporaryState, let id = try? ItemID(rawValue: episodeID) else { return false }
        // Unreadable: try again later. Still flagged: the owner has not answered, so nothing is owed.
        guard let held = await refreshPossibleDuplicateHolds(from: store) else { return false }
        if held.contains(episodeID) { return true }
        await reloadLibraryRows()
        guard !isClosingTemporaryState, self.store === store,
              let episode = episodes.first(where: { $0.id == episodeID }), episode.removalKind == nil,
              let rawFeedID = episode.feedID, let feedID = try? ItemID(rawValue: rawFeedID) else { return true }
        do {
            if podcastQueueIDs.contains(episodeID) {
                // Kept by the owner while flagged: the download that Keep asked for was held back.
                let claims = Set(try await store.unfinishedPodcastDownloads().map(\.episodeID.rawValue)
                    + (try await store.resumablePodcastDownloads()).map(\.episodeID.rawValue))
                if claims.contains(episodeID) {
                    startClaimedDownloads([episodeID])
                } else if Self.larderGroup(for: episode) == .available {
                    let policy = try await store.feedAutomationPolicy(for: feedID)
                    if EpisodeAdmissionService.shouldDownloadAfterManualKeep(
                        feedPolicy: policy, globalDownloadEverything: automationSettings.downloadEverythingOnLarder
                    ), try await store.claimPodcastDownload(episodeID: id) {
                        startClaimedDownloads([episodeID])
                    }
                }
            } else {
                let admitted = try await admitAutomatically(
                    feedID: feedID, feedEpisodes: episodes.filter { $0.feedID == rawFeedID },
                    newlySaved: [episodeID], store: store
                )
                await refreshPodcastQueueState()
                if !admitted.ruleSkipped.isEmpty { await reloadLibraryRows() }
                startClaimedDownloads(admitted.downloads)
            }
        } catch {
            return false
        }
        guard let current = episodes.first(where: { $0.id == episodeID }),
              current.removalKind == nil, current.downloadState == .completed,
              !current.preparationState.isPrepared, podcastQueueIDs.contains(current.id),
              !(await automaticPreparationSuppressed(for: current)) else { return true }
        if automationSettings.prepareEverythingDownloaded {
            prepareEpisode(current, automatic: true)
        } else {
            admitAutomaticPreparation(for: current, at: Date())
        }
        return true
    }
#endif
}
