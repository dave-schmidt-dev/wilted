import Foundation
import WiltedLibrary

#if canImport(WiltedProducer)
/// Compare all observed values, excluding only the transport's download byte counters.
/// Raw queue slots and association versions stay intact for publication and media reconciliation.
struct WiltedMacLibraryPublicationInputs: Equatable {
    let preparationRequests: [String: WiltedMacPreparationPublication.Request]
    let requestSequences: [String: Int]
    let queue: [String]
    struct Episode: Equatable {
        let row: WiltedMacEpisode
        // Row equality intentionally omits this transient handle; retain it in this projection.
        let manualCompletionOperationID: UUID?
    }

    let episodes: [Episode]
    let associations: [String: LibraryEpisodeAssociation]
    let articles: [WiltedMacArticle]
    let dismissed: [WiltedMacDismissedEpisode]
}

extension WiltedMacModel {
    @MainActor
    func librarySyncPublicationInputs() -> WiltedMacLibraryPublicationInputs {
        WiltedMacLibraryPublicationInputs(
            preparationRequests: preparationPublicationRequests,
            requestSequences: preparationRequestSequences,
            queue: podcastQueueIDs,
            episodes: episodes.map { episode in
                var value = episode
                if case .downloading = value.downloadState {
                    value.downloadState = .downloading(received: 0, expected: nil)
                }
                return .init(row: value, manualCompletionOperationID: episode.manualCompletionOperationID)
            },
            associations: episodeAssociations,
            articles: articles,
            dismissed: dismissedEpisodes
        )
    }
}
#endif
