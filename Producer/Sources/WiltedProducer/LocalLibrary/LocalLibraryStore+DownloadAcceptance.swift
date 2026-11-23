import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Whether audio may still be recorded for an episode: it exists and is not retired or dismissed on
    /// its own. A member of a linked group keeps its audio for the group, so it still accepts. Retired
    /// and dismissed episodes are cleaned of media (at once, or when a soft Skip's window closes), and a
    /// download that finishes after that must not bring its records back, nor must one for an episode
    /// that has been removed outright, such as by unsubscribing. `allowingUnknown` lets a write for an
    /// episode the library does not have through (callers that seed stores directly); the coordinator
    /// never sets it.
    func episodeAcceptsDownload(_ id: ItemID, in context: ModelContext, allowingUnknown: Bool = false) throws -> Bool {
        let lookup = try EpisodeAssociationReadLookup(in: context)
        guard let episode = lookup.episodes[id.rawValue] else { return allowingUnknown }
        guard episode.removalKind != nil else { return true }
        return (lookup.state(for: id)?.memberIDs.count ?? 1) > 1
    }

    /// The coordinator asks before it moves a finished file into the library, so a refused download
    /// leaves nothing behind.
    public func episodeAcceptsDownload(_ id: ItemID) throws -> Bool {
        try episodeAcceptsDownload(id, in: ModelContext(container), allowingUnknown: false)
    }
}
