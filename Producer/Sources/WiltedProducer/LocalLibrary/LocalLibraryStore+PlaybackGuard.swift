import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Whether the listener has started an episode, read from the same context a retirement saves in:
    /// it is the queue's current episode, or it has a saved position or a finished record. A rule
    /// Skip deletes the audio, so it consults this inside its own transaction instead of trusting an
    /// earlier read that playback can overtake.
    static func episodeHasStartedPlayback(_ episodeID: ItemID, in context: ModelContext) throws -> Bool {
        let identifier = episodeID.rawValue
        let isQueueCurrent = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
            .contains { $0.episodeID == identifier && $0.position >= podcastCurrentPositionOffset }
        if isQueueCurrent { return true }
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV21Models.PlaybackRecord>())
            .contains { $0.itemID == identifier && ($0.positionSeconds > 0 || $0.completed) }
    }
}
