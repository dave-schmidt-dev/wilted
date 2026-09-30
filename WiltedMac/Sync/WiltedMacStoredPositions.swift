import Foundation
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// Which durable Mac playback positions are worth handing to another device: a queued,
/// unfinished episode that was started, at the revision the Mac would offer as audio.
///
/// Pure over its inputs, so it is testable without a store. The position comes only from the
/// playback checkpoint of that exact revision: a position is never paired with another
/// revision's id.
enum WiltedMacStoredPositions {
    /// Within this many seconds of the end an episode counts as finished, not resumable.
    static let endMargin: Double = 1
    /// How far a stored position may differ from the adopted one and still count as unmoved.
    static let adoptedEchoTolerance: Double = 0.5

    static func derive(
        queue: [ItemID], retired: Set<ItemID>, readyRevisions: [ItemID: RevisionID],
        playbackStates: [String: PlaybackState], completed: Set<ItemID>,
        adoptedPositions: [ItemID: Double] = [:]
    ) -> [HandoffCoordinator.StoredPosition] {
        var seen = Set<ItemID>()
        var positions: [HandoffCoordinator.StoredPosition] = []
        for id in queue where seen.insert(id).inserted {
            guard !retired.contains(id), !completed.contains(id), let revision = readyRevisions[id],
                  let state = playbackStates["\(id.rawValue)|\(revision.rawValue)"],
                  !state.completed, state.positionSeconds.isFinite, state.positionSeconds > 0 else { continue }
            if state.durationSeconds > 0, state.positionSeconds >= state.durationSeconds - endMargin { continue }
            // A position adopted from the phone and not moved since is the phone's, not the Mac's:
            // publishing it would echo it back a minute later as a newer record of the Mac's own.
            if let adopted = adoptedPositions[id], abs(adopted - state.positionSeconds) < adoptedEchoTolerance { continue }
            positions.append(.init(
                entryID: id, revision: revision, positionSeconds: state.positionSeconds, updatedAt: state.updatedAt.date))
        }
        return positions
    }
}

#if canImport(WiltedProducer)
extension WiltedMacModelHandoffPlayer {
    /// One read of the store's library snapshot and queue; empty when either fails, so a bad read
    /// publishes nothing and the next pass retries.
    func storedPositions() async -> [HandoffCoordinator.StoredPosition] {
        guard let store = model?.store,
              let snapshot = try? await store.podcastLibrarySnapshot(),
              let queue = try? await store.podcastQueueState().episodeIDs else { return [] }
        return WiltedMacStoredPositions.derive(
            queue: queue, retired: Set(snapshot.retiredAtByEpisode.keys),
            readyRevisions: snapshot.readyRevisions.mapValues(\.revision.revisionID),
            playbackStates: snapshot.playbackStates,
            completed: Set(snapshot.listeningStates.values.filter { $0.completedAt != nil }.map(\.episodeID)),
            adoptedPositions: adoptedPositions().mapValues(\.positionSeconds))
    }
}
#endif
