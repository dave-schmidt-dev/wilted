import Foundation
import SwiftData
import WiltedDomain

/// Where a removed playlist entry sat: its position and the entries on either side at that moment.
public struct PlaylistEntryPlace: Sendable, Equatable {
    public let index: Int
    public let previous: String?
    public let next: String?

    public init(index: Int, previous: String?, next: String?) {
        self.index = index; self.previous = previous; self.next = next
    }
}

extension LocalLibraryStore {
    private typealias EntryRecord = LocalLibrarySchemaV17Models.PlaylistEntryRecord

    /// Removes one entry and returns the place it held, read in the same save, so Undo can put it back.
    /// Returns nil when the entry was not in the playlist.
    public func removePlaylistEntryRememberingPlace(playlistID: String, entryID: String) throws -> PlaylistEntryPlace? {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<EntryRecord>())
            .filter { $0.playlistID == playlistID }
            .sorted { ($0.sortKey, $0.entryID) < ($1.sortKey, $1.entryID) }
        guard let index = rows.firstIndex(where: { $0.entryID == entryID }) else { return nil }
        let place = PlaylistEntryPlace(
            index: index, previous: index > 0 ? rows[index - 1].entryID : nil,
            next: index + 1 < rows.count ? rows[index + 1].entryID : nil
        )
        context.delete(rows[index])
        try context.save()
        return place
    }

    /// Puts a removed entry back in one save and returns the playlist's new order.
    ///
    /// It goes right after the entry that preceded it, or else right before the one that followed it,
    /// or else at its old position, so the order the owner saw comes back even if other entries have
    /// moved or gone. An entry that is back already stays where it is. Throws, leaving the playlist
    /// alone, when the item has left the library or been removed from the shelf since, so Undo never
    /// brings a dismissed or skipped episode back into a playlist.
    public func restorePlaylistEntry(playlistID: String, entryID: String, place: PlaylistEntryPlace) throws -> [String] {
        let context = ModelContext(container)
        guard try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PlaylistRecord>())
            .contains(where: { $0.id == playlistID && $0.kind == PlaylistKind.manual.rawValue }) else {
            throw LocalLibraryStoreError.invalidPodcastState("manual playlist")
        }
        var rows = try context.fetch(FetchDescriptor<EntryRecord>())
            .filter { $0.playlistID == playlistID }
            .sorted { ($0.sortKey, $0.entryID) < ($1.sortKey, $1.entryID) }
        guard !rows.contains(where: { $0.entryID == entryID }) else { return rows.map(\.entryID) }
        let id = try ItemID(rawValue: entryID)
        let present: Bool
        if let episode = try podcastEpisode(for: id) {
            present = try removalKind(for: episode.itemID) == nil
        } else {
            present = try article(for: id) != nil || audiobook(id)?.isRemoved == false
        }
        guard present else { throw LocalLibraryStoreError.invalidPodcastState("missing playlist item") }
        let position: Int
        if let previous = place.previous, let at = rows.firstIndex(where: { $0.entryID == previous }) {
            position = at + 1
        } else if let next = place.next, let at = rows.firstIndex(where: { $0.entryID == next }) {
            position = at
        } else {
            position = min(max(0, place.index), rows.count)
        }
        func neighbours() -> (Double?, Double?) {
            (position > 0 ? rows[position - 1].sortKey : nil, position < rows.count ? rows[position].sortKey : nil)
        }
        var (lower, upper) = neighbours()
        var key = Self.playlistSortKey(after: lower, before: upper)
        if key == nil {
            for (at, row) in rows.enumerated() { row.sortKey = Double(at) }
            (lower, upper) = neighbours()
            key = Self.playlistSortKey(after: lower, before: upper)
        }
        guard let key else { throw LocalLibraryStoreError.invalidPodcastState("playlist sort key") }
        let inserted = EntryRecord(playlistID: playlistID, entryID: entryID, sortKey: key)
        context.insert(inserted)
        rows.insert(inserted, at: position)
        try context.save()
        return rows.map(\.entryID)
    }
}
