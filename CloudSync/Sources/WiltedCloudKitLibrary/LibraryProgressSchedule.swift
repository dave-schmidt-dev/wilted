import Foundation
import WiltedDomain

/// Which progress records one sync round reads, so a round stays one request however long the
/// playback history grows.
///
/// Pure: the transport passes in what it knows and reads the pairs this returns.
enum LibraryProgressSchedule {
    /// The progress pairs to read this round, in order:
    ///
    /// 1. Hot pairs, whose entry a now-playing record named in the last result. Always included,
    ///    even past `slotCount`, because handoff decisions read them.
    /// 2. Pairs never read since the cache was last cleared, seeds included. Always included, so a
    ///    cleared cache is followed by one full read.
    /// 3. Other devices' pairs, least recently read first, in the slots left over.
    ///
    /// This device's own pairs are read only while never read: only this device writes them, so
    /// the transport serves them from its cache afterwards.
    ///
    /// - Parameters:
    ///   - knownPairs: every observed and seeded pair.
    ///   - ownDeviceID: this device.
    ///   - hotEntryIDs: entries named by any device's now-playing record in the last result.
    ///   - neverRead: known pairs with no cached record and not found missing since the last clear.
    ///   - lastReadRound: the round each pair was last read in; a pair without one sorts first.
    ///   - slotCount: names left in the round's first request after its mandatory names.
    static func pairs(
        known knownPairs: Set<LibraryPlaybackPair>,
        ownDeviceID: String,
        hotEntryIDs: Set<ItemID>,
        neverRead: Set<LibraryPlaybackPair>,
        lastReadRound: [LibraryPlaybackPair: Int],
        slotCount: Int
    ) -> [LibraryPlaybackPair] {
        let eligible = knownPairs.filter { $0.deviceID != ownDeviceID || neverRead.contains($0) }
        let hot = eligible.filter { hotEntryIDs.contains($0.entryID) }.sorted(by: byName)
        let fresh = eligible.filter { !hotEntryIDs.contains($0.entryID) && neverRead.contains($0) }.sorted(by: byName)
        let rest = eligible.filter { !hotEntryIDs.contains($0.entryID) && !neverRead.contains($0) }
            .sorted { lhs, rhs in
                let left = lastReadRound[lhs] ?? Int.min, right = lastReadRound[rhs] ?? Int.min
                return left != right ? left < right : byName(lhs, rhs)
            }
        let spare = max(0, slotCount - hot.count - fresh.count)
        return hot + fresh + rest.prefix(spare)
    }

    private static func byName(_ lhs: LibraryPlaybackPair, _ rhs: LibraryPlaybackPair) -> Bool {
        (lhs.deviceID, lhs.entryID.rawValue) < (rhs.deviceID, rhs.entryID.rawValue)
    }
}

/// What the transport remembers about its progress reads since the cache was last cleared.
///
/// A pair counts as read while it has a cached record or sits in `foundMissing`. Everything here
/// is cleared together with the record cache, so a cleared cache forces a full read.
struct LibraryProgressReads {
    /// Progress record names read and not found.
    var foundMissing: Set<String> = []
    /// The poll round each pair was last read in.
    var lastReadRound: [LibraryPlaybackPair: Int] = [:]
    /// Counts polls that read device records.
    var round = 0
    /// Entries named by now-playing records in the last poll result.
    var hotEntries: Set<ItemID> = []
}
