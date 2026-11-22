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
    /// failure in between picks it up again at the next launch, flag deletion included.
    func clearPossibleDuplicateFlag(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        Task { [weak self] in
            guard let self else { return }
            self.notePossibleDuplicateCatchUp(episode.id, pending: true)
            if await self.finishPossibleDuplicateDifferent(episode.id) {
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
                if await self.finishPossibleDuplicateDifferent(id) {
                    self.notePossibleDuplicateCatchUp(id, pending: false)
                }
            }
        }
#endif
    }

#if canImport(WiltedProducer)
    /// Carries one noted "Different" answer through: the flag is deleted if it is still there (a
    /// quit can land between the note and the delete, and a noted answer is the owner's answer),
    /// then the held work is done. Safe to repeat. False means try again later.
    func finishPossibleDuplicateDifferent(_ episodeID: String) async -> Bool {
        guard let store, let id = try? ItemID(rawValue: episodeID) else { return false }
        do { _ = try await store.clearPodcastEpisodePossibleDuplicate(id) } catch { return false }
        return await catchUpAfterPossibleDuplicateCleared(episodeID)
    }

    /// Does what the flag held back, once, in the way the owner's earlier choices call for. Safe to
    /// repeat. Returns false when it could not finish and should be tried again.
    func catchUpAfterPossibleDuplicateCleared(_ episodeID: String) async -> Bool {
        guard let store, !isClosingTemporaryState, let id = try? ItemID(rawValue: episodeID) else { return false }
        // Unreadable, or still flagged after the answer: not finished, try again later.
        guard let held = await refreshPossibleDuplicateHolds(from: store), !held.contains(episodeID) else { return false }
        await reloadLibraryRows()
        // A model that is closing or has swapped stores has not done the work: keep the note.
        guard !isClosingTemporaryState, self.store === store else { return false }
        guard let episode = episodes.first(where: { $0.id == episodeID }), episode.removalKind == nil,
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
              !current.preparationState.isPrepared, podcastQueueIDs.contains(current.id) else { return true }
        // An unreadable flag list is not an answer: the note stays until preparation is settled.
        switch await automaticPreparationVerdict(for: current) {
        case .unknown: return false
        case .suppressed: return true
        case .allowed: break
        }
        if automationSettings.prepareEverythingDownloaded {
            prepareEpisode(current, automatic: true)
        } else {
            admitAutomaticPreparation(for: current, at: Date())
        }
        return true
    }
#endif
}
