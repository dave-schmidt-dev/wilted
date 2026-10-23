import Foundation
import os
import WiltedProducer

extension WiltedMacModel {
    /// Whether the Larder may offer to prepare `episode` again.
    ///
    /// The store decides which episodes kept every advertisement (see
    /// `LocalLibraryStore.podcastEpisodesKeepingAds`); this adds only what the
    /// store cannot see. A run already started, one waiting for the slot, or a
    /// download replacing the source underneath the run would make a second
    /// press either duplicate work or send the pipeline the wrong bytes.
    func canPrepareAgain(_ episode: WiltedMacEpisode) -> Bool {
        guard episodesKeepingAds.contains(episode.id),
              !episode.downloadState.isInFlight,
              !episode.preparationState.isRunning else { return false }
        return podcastPreparationTasks[episode.id] == nil
            && !preparationQueue.itemIDs.contains(episode.id)
            && !deferredAutomaticPreparations.contains { $0.episodeID == episode.id }
    }

    /// Runs the current pipeline over an episode whose earlier preparation kept
    /// every ad.
    ///
    /// Deliberately the same path a row's Prepare uses: `prepareEpisode`
    /// admits the run behind the one preparation slot, and the pipeline's
    /// `carriedPlayback` moves the saved listening position onto the new
    /// revision, so re-preparing never costs the listener their place.
    func prepareAgain(_ episode: WiltedMacEpisode) {
        guard canPrepareAgain(episode) else { return }
        prepareEpisode(episode)
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

    /// Prepares every episode that kept its ads. The preparation gate admits
    /// one run at a time, so the rest queue in `episodesToPrepareAgain` order.
    func prepareAgainAllKeepingAds() {
        guard !isClosingTemporaryState else { return }
        for episode in episodesToPrepareAgain { prepareEpisode(episode) }
    }

    /// Reads the episodes whose preparation kept every advertisement, as part
    /// of a library load.
    ///
    /// A read error is not a loading failure: the rows already on screen are
    /// good, and an empty set only withholds this session's offer to prepare an
    /// episode again. The warning is the one trace, because a control that is
    /// quietly absent is otherwise unexplainable.
    func refreshEpisodesKeepingAds(from store: LocalLibraryStore, readEpoch: UInt64) async {
        do {
            let values = try await store.podcastEpisodesKeepingAds()
            // The read can outlive a newer library load; that load owns the set.
            guard readEpoch == libraryReadEpoch else { return }
            episodesKeepingAds = Set(values.map(\.rawValue))
        } catch {
            guard readEpoch == libraryReadEpoch else { return }
            episodesKeepingAds = []
            Self.prepareAgainLog.warning(
                "kept-ad episodes could not be read: \(LogSafeError.describe(error), privacy: .public)"
            )
        }
    }

    private static let prepareAgainLog = Logger(
        subsystem: "com.zerodelta.wilted.mac", category: "Library"
    )
}
