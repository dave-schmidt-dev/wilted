import Foundation
import WiltedDomain
import WiltedLibrary

/// Everything the Mac publishes about its library at one instant.
///
/// The publisher is pure over this value: it never reads `WiltedMacModel` or the local
/// store, so the model (or a store adapter) supplies it through `LibraryStateSource`.
struct LibraryStateSnapshot: Sendable, Equatable {
    /// Podcast feeds, published as library sources.
    var feeds: [LibrarySource]
    /// Episodes as library entries. Active episodes carry `removal == .none`; episodes the
    /// Mac retired or dismissed stay in the list with that state so the removal replicates.
    var episodes: [LibraryEntry]
    /// Larder queue order, first to last. Ids without a matching episode are ignored.
    var queue: [ItemID]
    /// Completion state per episode.
    var listening: [ListeningRecord]
    /// What the Mac is playing or last paused on, if anything.
    var currentPlayback: DevicePlaybackPosition?

    init(
        feeds: [LibrarySource] = [],
        episodes: [LibraryEntry] = [],
        queue: [ItemID] = [],
        listening: [ListeningRecord] = [],
        currentPlayback: DevicePlaybackPosition? = nil
    ) {
        self.feeds = feeds
        self.episodes = episodes
        self.queue = queue
        self.listening = listening
        self.currentPlayback = currentPlayback
    }

    /// Replicated content for `LibraryStateDiffer`. Queue position becomes the slot sort key.
    func replicatedContent() throws -> LibrarySnapshot {
        let known = Set(episodes.map(\.id))
        var seen = Set<ItemID>()
        var slots: [QueueSlot] = []
        for id in queue where known.contains(id) && seen.insert(id).inserted {
            slots.append(try QueueSlot(entryID: id, sortKey: Double(slots.count)))
        }
        return LibrarySnapshot(sources: feeds, entries: episodes, slots: slots, listening: listening)
    }
}

/// Supplies the Mac's current library state on demand.
protocol LibraryStateSource: Sendable {
    func currentState() async throws -> LibraryStateSnapshot
}

/// Receives follower intents relayed by the publisher.
///
/// The publisher delivers each intent id at most once per publisher lifetime and retries an
/// intent whose delivery threw. The sink owns durable idempotency across restarts, because
/// a fresh publisher sees every intent still on the server again.
protocol LibraryIntentSink: Sendable {
    func receive(_ intent: LibraryIntent) async throws
}
