import Foundation
import WiltedDomain

/// Lets a deletion of episode audio and a load of that audio exclude each other.
///
/// A deletion that reads "is it playing?" and then hops to the library store leaves a gap in which a
/// load can start, open the file and begin playing just before the store removes it. Here the check and the
/// reservation happen in one main-actor step, and a load makes the matching check in one step as well, so
/// whichever comes first wins: a lease is refused while an episode is loaded or loading, and a load of an
/// episode under lease is refused before the backend opens it.
public struct MediaDeletionLease: Equatable, Sendable {
    let id: UUID
    let members: Set<ItemID>
}

extension PlaybackController {
    /// Reserves `ids` for deletion, or returns nil when any of them is loaded or loading right now.
    /// The caller must `release` the lease once its deletion has finished or been given up.
    public func leaseMediaForDeletion(_ ids: Set<ItemID>) -> MediaDeletionLease? {
        if let itemID, ids.contains(itemID) { return nil }
        guard ids.isDisjoint(with: loadsInFlight.keys) else { return nil }
        let lease = MediaDeletionLease(id: UUID(), members: ids)
        mediaLeases[lease.id] = ids
        return lease
    }

    public func release(_ lease: MediaDeletionLease) {
        mediaLeases[lease.id] = nil
    }

    func checkMediaLease(_ id: ItemID) throws {
        if mediaLeases.values.contains(where: { $0.contains(id) }) {
            throw PlaybackControllerError.mediaDeletionInProgress(id)
        }
    }

    func endLoadInFlight(_ id: ItemID) {
        let remaining = (loadsInFlight[id] ?? 1) - 1
        if remaining > 0 { loadsInFlight[id] = remaining } else { loadsInFlight.removeValue(forKey: id) }
    }
}
