import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

extension WiltedMacModel {
    /// The one gate every automatic download and preparation passes: an episode
    /// flagged as a possible duplicate is left alone until the owner answers.
    ///
    /// This answer comes from the list the last library read took, so it is
    /// instant and callable from the synchronous start points. A list that could
    /// not be read blocks: automation waits rather than guesses. The
    /// store re-checks the flag itself wherever it takes a download claim, keeps
    /// a rule or policy from admitting or retiring a flagged row, and a landing
    /// download asks the store afresh, so a flag staged a moment ago is honoured
    /// even before the next library read.
    func automaticWorkIsHeld(_ episodeID: String) -> Bool {
        automaticWorkGate(episodeID) != .clear
    }

    /// What the held list says about one episode. `unknown` (the list could not be read) blocks
    /// like `held`, but it is not evidence about this episode, so callers that would otherwise
    /// give up an episode's waiting work leave it in place until the list can be read again.
    enum AutomaticWorkGate { case clear, held, unknown }

    func automaticWorkGate(_ episodeID: String) -> AutomaticWorkGate {
        if fixtureMode { return .clear }
        guard let held = possibleDuplicateHeldIDs else { return store != nil ? .unknown : .clear }
        return held.contains(episodeID) ? .held : .clear
    }

    /// The same question asked of the store right now. It also refreshes the
    /// list above, and a failed read blocks.
    func automaticWorkIsHeldFresh(_ episodeID: String) async -> Bool {
        if fixtureMode { return false }
        guard let store else { return true }
        return await refreshPossibleDuplicateHolds(from: store).map { $0.contains(episodeID) } ?? true
    }

    /// Reads the held list from the store into the cache. Returns nil, and
    /// empties the cache so automation blocks, when the read fails.
    @discardableResult
    func refreshPossibleDuplicateHolds(from store: LocalLibraryStore) async -> Set<String>? {
        let held = (try? await store.podcastEpisodeIdentityReviewHeldIDs())
            .map { Set($0.map(\.rawValue)) }
        possibleDuplicateHeldIDs = held
        return held
    }

    /// Takes a held episode out of every automatic waiting place so it does not
    /// sit in the queue, or in the off-peak list, until a decision. "Different"
    /// puts it back through the ordinary admission.
    func abandonAutomaticPreparation(for episodeID: String) {
        // Only a flag the list actually shows gives up the waiting work. An unreadable list says
        // nothing about this episode, so its request stays and is tried again once the list reads.
        guard automaticWorkGate(episodeID) == .held else { return }
        removeDeferredAutomaticPreparation(episodeID)
        if preparationRequestSequences[episodeID] != nil {
            withdrawPreparationRequest(for: episodeID)
        }
        updateEpisode(episodeID) {
            if case let .preparing(stage) = $0.preparationState, stage == Self.preparationQueuedStage {
                $0.preparationState = .notPrepared
            }
        }
    }
}
#endif
