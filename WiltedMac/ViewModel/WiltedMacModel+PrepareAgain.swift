import Foundation
import os
import WiltedDomain
import WiltedProducer

extension WiltedMacModel {
    /// Whether the Larder may offer to prepare `episode` again.
    ///
    /// The store decides which episodes the current engine has not prepared
    /// (see `LocalLibraryStore.podcastEpisodesToPrepareAgain`); this adds what
    /// the store cannot see. A run already started, one waiting for the slot, or
    /// a download replacing the source underneath the run would make a second
    /// press either duplicate work or send the pipeline the wrong bytes, and the
    /// episode loaded in the player is the audio the listener is hearing: its
    /// cut is not swapped out from under the playhead.
    func canPrepareAgain(_ episode: WiltedMacEpisode) -> Bool {
        guard prepareAgainCandidates[episode.id] != nil,
              currentPodcastEpisodeID != episode.id,
              !episode.downloadState.isInFlight,
              !episode.preparationState.isRunning else { return false }
        return podcastPreparationTasks[episode.id] == nil
            && !preparationQueue.itemIDs.contains(episode.id)
            && !deferredAutomaticPreparations.contains { $0.episodeID == episode.id }
    }

    /// Runs the current pipeline over an episode an older engine prepared.
    ///
    /// Goes through `prepareEpisode`, so the run is admitted behind the one
    /// preparation slot. A cut is prepared from a staged copy of its original
    /// while the old cut stays playable, and the listener's place is carried to
    /// the new cut or the run is declined (see `PodcastPreparationPipeline.prepareAgain`).
    /// An episode that was never cut still holds its original and takes the
    /// ordinary path.
    func prepareAgain(_ episode: WiltedMacEpisode) {
        guard canPrepareAgain(episode), let candidate = prepareAgainCandidates[episode.id] else { return }
        removeDeferredAutomaticPreparation(episode.id)
        _ = prepareEpisode(
            episode, policySnapshot: preparationPolicySnapshot(for: episode),
            again: candidate.isCut && !fixtureMode ? candidate : nil
        )
    }

    /// Every episode that can be prepared again: the Larder's own rows first,
    /// in the order the listener reads them, then any eligible episode the
    /// Larder no longer holds, so a bulk press reaches those too.
    var episodesToPrepareAgain: [WiltedMacEpisode] {
        let larderRows = larderWaitingEpisodes.filter { canPrepareAgain($0) }
        let larderIDs = Set(larderRows.map(\.id))
        let elsewhere = episodes.filter { canPrepareAgain($0) && !larderIDs.contains($0.id) }
        return larderRows + elsewhere
    }

    /// Prepares every offered episode. The preparation gate admits one run at
    /// a time, so the rest queue in `episodesToPrepareAgain` order.
    func prepareAgainAll() {
        guard !isClosingTemporaryState else { return }
        for episode in episodesToPrepareAgain { prepareAgain(episode) }
    }

    /// Whether preparing again would put back a cut made before this show was
    /// marked as having no ads.
    func restoresFullEpisode(_ episode: WiltedMacEpisode) -> Bool {
        guard let candidate = prepareAgainCandidates[episode.id], candidate.isCut else { return false }
        return WiltedMacAdFreeFeedPreference(preferences: preferences).isAdFree(feedID: episode.feedID)
    }

    /// Cut episodes on `feedID` that the Larder may restore now: candidates the
    /// row would offer, with the feed marked ad-free.
    func episodesToRestore(feedID: String) -> [WiltedMacEpisode] {
        episodes.filter {
            $0.feedID == feedID && canPrepareAgain($0) && restoresFullEpisode($0)
        }
    }

    /// Starts a prepare-again run for each cut episode on the feed that can be
    /// restored. No-op while temporary state is closing.
    func restoreCutEpisodes(feedID: String) {
        guard !isClosingTemporaryState else { return }
        for episode in episodesToRestore(feedID: feedID) { prepareAgain(episode) }
    }

    /// Larder context-menu title for an eligible prepare-again row.
    func prepareAgainMenuTitle(for episode: WiltedMacEpisode) -> String {
        restoresFullEpisode(episode) ? "Restore Full Episode" : "Prepare Again"
    }

    /// Re-reads prepare-again candidates after the ad-free set changes, so cuts
    /// on a newly marked show appear and disappear with the switch.
    func adFreeFeedsDidChange() {
        guard let store else { return }
        let readEpoch = libraryReadEpoch
        Task { await refreshEpisodesToPrepareAgain(from: store, readEpoch: readEpoch) }
    }

    /// Reads the episodes the current engine has not prepared, as part of a
    /// library load.
    ///
    /// A read error is not a loading failure: the rows already on screen are
    /// good, and an empty set only withholds this session's offer to prepare an
    /// episode again. The warning is the one trace, because a control that is
    /// quietly absent is otherwise unexplainable.
    ///
    /// `feedMeta` is the feed title, address and custom name for routing when
    /// the caller's snapshot is newer than `subscriptions` (a library load);
    /// nil reads those from the model.
    func refreshEpisodesToPrepareAgain(
        from store: LocalLibraryStore,
        readEpoch: UInt64,
        feedMeta: [String: LabelledDigestFeedMeta]? = nil
    ) async {
        let restoring = Set(
            WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs
                .compactMap { try? ItemID(rawValue: $0) }
        )
        let digestLookup = labelledDigestInForceLookup(feedMeta: feedMeta)
        // Reads can finish out of order (a switch flipped twice, a load beside
        // a switch): only the newest one started read the current ad-free set.
        // A read already behind a newer library load would be dropped below;
        // it must not also retire the read that load started.
        guard readEpoch == libraryReadEpoch else { return }
        prepareAgainRefreshGeneration &+= 1
        let generation = prepareAgainRefreshGeneration
        do {
            let values = try await store.podcastEpisodesToPrepareAgain(
                restoringCutsOnFeeds: restoring,
                labelledDigestInForce: digestLookup
            )
            // The read can outlive a newer library load; that load owns the set.
            guard readEpoch == libraryReadEpoch, generation == prepareAgainRefreshGeneration else { return }
            prepareAgainCandidates = Dictionary(
                values.map { ($0.episodeID.rawValue, $0) }, uniquingKeysWith: { first, _ in first }
            )
        } catch {
            guard readEpoch == libraryReadEpoch, generation == prepareAgainRefreshGeneration else { return }
            prepareAgainCandidates = [:]
            Self.prepareAgainLog.warning(
                "prepare-again candidates could not be read: \(LogSafeError.describe(error), privacy: .public)"
            )
        }
    }

    /// Feed facts the labelled digest-in-force lookup needs for one show.
    struct LabelledDigestFeedMeta: Sendable {
        let feedURL: URL?
        let feedTitle: String
        let customTitle: String?
    }

    /// Builds the digest-in-force lookup from a main-actor value snapshot: each
    /// feed's policy snapshot and routing facts, the labeller preferences and
    /// key presence. The closure runs on the store's actor and touches no model state.
    func labelledDigestInForceLookup(
        feedMeta: [String: LabelledDigestFeedMeta]? = nil
    ) -> @Sendable (ItemID, URL) -> String? {
        let settings = automationSettings
        let labeller = AdLabellerPreferences(preferences: preferences)
        let hasKey = adFinding.hasKey
        let feeds: [String: LabelledDigestFeedMeta]
        if let feedMeta {
            feeds = feedMeta
        } else {
            feeds = Dictionary(subscriptions.map {
                ($0.id, LabelledDigestFeedMeta(
                    feedURL: $0.feedURL,
                    feedTitle: $0.publisherTitle ?? $0.title,
                    customTitle: $0.displayName))
            }, uniquingKeysWith: { first, _ in first })
        }
        let policies = Dictionary(uniqueKeysWithValues: feeds.keys.map {
            ($0, Self.preparationPolicySnapshot(from: settings, feedID: $0, preferences: preferences))
        })
        return { feedID, audioURL in
            // A feed the snapshot does not know cannot be routed, so it reads as local.
            guard let meta = feeds[feedID.rawValue], let policy = policies[feedID.rawValue] else { return nil }
            return Self.labelledDigestInForce(
                feedID: feedID.rawValue, audioURL: audioURL, meta: meta,
                policy: policy, labeller: labeller, hasKey: hasKey)
        }
    }

    /// The labelled digest a fresh cut of this feed and audio would store, or nil when local.
    nonisolated static func labelledDigestInForce(
        feedID: String,
        audioURL: URL,
        meta: LabelledDigestFeedMeta,
        policy: PodcastPreparationPolicySnapshot,
        labeller: AdLabellerPreferences,
        hasKey: Bool
    ) -> String? {
        LabelledPolicyDigestInForce.digest(
            policy: policy,
            input: RemoteLabellingInput(
                feedID: feedID, feedURL: meta.feedURL, feedTitle: meta.feedTitle,
                customTitle: meta.customTitle, audioURL: audioURL, removeAds: policy.removeAds),
            preferences: labeller,
            hasKey: hasKey)
    }

    private static let prepareAgainLog = Logger(
        subsystem: "com.zerodelta.wilted.mac", category: "Library"
    )
}
