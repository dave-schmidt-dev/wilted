import Foundation
import WiltedDomain

struct PodcastEpisodePossibleDuplicateHold: Sendable {
    let incoming: PodcastEpisode
    let candidateIDs: [ItemID]
    let reasons: Set<PodcastEpisodeIdentityMatcher.AmbiguityReason>
}

extension LocalLibraryStore {
    /// Finds the feed items that look like an earlier episode of the same show.
    ///
    /// Only a newcomer (an ID not yet stored) is checked. It is compared with
    /// every stored episode, whatever its state, and with the newcomers listed
    /// before it in the same refresh, so a run of lookalikes first seen together
    /// is flagged from the second one on and none slips past. Nothing here
    /// changes a stored episode, links two rows, or moves audio or progress: a
    /// lookalike is saved as its own row and flagged for the owner.
    static func possibleDuplicateHolds(
        incoming: [PodcastEpisode],
        existing: [PodcastEpisode],
        existingIDs: Set<String>
    ) -> [PodcastEpisodePossibleDuplicateHold] {
        let newcomers = incoming.filter { !existingIDs.contains($0.itemID.rawValue) }
        guard !newcomers.isEmpty else { return [] }
        // Stored copies plus this refresh's view of every listed item, so an
        // episode listed with corrected details still counts as its old self.
        let index = PodcastEpisodeIdentityIndex(existing + incoming)
        let position = Dictionary(
            newcomers.enumerated().map { ($0.element.itemID, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return newcomers.enumerated().compactMap { offset, episode in
            // A newcomer listed later in this refresh is not "earlier".
            let outcome = index.matchMetadata(episode) { id in
                position[id].map { $0 > offset } ?? false
            }
            switch outcome {
            case .none:
                return nil
            case let .matched(candidateID):
                return PodcastEpisodePossibleDuplicateHold(
                    incoming: episode, candidateIDs: [candidateID], reasons: [.multipleMatches]
                )
            case let .ambiguous(candidateIDs, reasons):
                return PodcastEpisodePossibleDuplicateHold(
                    incoming: episode, candidateIDs: candidateIDs, reasons: reasons
                )
            }
        }
    }
}
