import Foundation
import os
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

    /// Reads the episodes the current engine has not prepared, as part of a
    /// library load.
    ///
    /// A read error is not a loading failure: the rows already on screen are
    /// good, and an empty set only withholds this session's offer to prepare an
    /// episode again. The warning is the one trace, because a control that is
    /// quietly absent is otherwise unexplainable.
    func refreshEpisodesToPrepareAgain(from store: LocalLibraryStore, readEpoch: UInt64) async {
        do {
            let values = try await store.podcastEpisodesToPrepareAgain()
            // The read can outlive a newer library load; that load owns the set.
            guard readEpoch == libraryReadEpoch else { return }
            prepareAgainCandidates = Dictionary(
                values.map { ($0.episodeID.rawValue, $0) }, uniquingKeysWith: { first, _ in first }
            )
        } catch {
            guard readEpoch == libraryReadEpoch else { return }
            prepareAgainCandidates = [:]
            Self.prepareAgainLog.warning(
                "prepare-again candidates could not be read: \(LogSafeError.describe(error), privacy: .public)"
            )
        }
    }

    private static let prepareAgainLog = Logger(
        subsystem: "com.zerodelta.wilted.mac", category: "Library"
    )
}
