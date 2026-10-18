import Foundation
import SwiftData

/// A playlist as stored.
public struct Playlist: Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: PlaylistKind
    /// All-of when true, any-of when false. Only automatic playlists read it.
    public let matchAll: Bool
    public let sortIndex: Int

    /// Builds a playlist value directly, for an editor's optimistic model.
    public init(id: String, name: String, kind: PlaylistKind, matchAll: Bool, sortIndex: Int) {
        self.id = id; self.name = name; self.kind = kind
        self.matchAll = matchAll; self.sortIndex = sortIndex
    }
}

extension LocalLibraryStore {
    private typealias PlaylistModels = LocalLibrarySchemaV17Models

    /// Fractional key strictly between the neighbours, or nil when none exists.
    /// Mirrors `QueueSlot.sortKey(after:before:)`, which this package cannot import.
    static func playlistSortKey(after lower: Double?, before upper: Double?) -> Double? {
        let key: Double
        switch (lower, upper) {
        case (nil, nil): key = 0
        case let (lower?, nil): key = lower + 1
        case let (nil, upper?): key = upper - 1
        case let (lower?, upper?):
            guard lower < upper else { return nil }
            key = lower + (upper - lower) / 2
        }
        guard key.isFinite else { return nil }
        if let lower, key <= lower { return nil }
        if let upper, key >= upper { return nil }
        return key
    }

    private static func playlist(_ record: PlaylistModels.PlaylistRecord) -> Playlist? {
        guard let kind = PlaylistKind(rawValue: record.kind) else { return nil }
        return Playlist(id: record.id, name: record.name, kind: kind,
                        matchAll: record.matchAll, sortIndex: record.sortIndex)
    }

    // MARK: - Playlists

    /// Creates a playlist after the existing ones. When `initialEntryID` is
    /// given, its manual entry is inserted in the same save, so the playlist
    /// and its first entry appear together or not at all.
    @discardableResult
    public func createPlaylist(id: String = UUID().uuidString, name: String, kind: PlaylistKind,
                               matchAll: Bool = true, initialEntryID: String? = nil) throws -> Playlist {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRecord>())
        guard !existing.contains(where: { $0.id == id }) else {
            throw LocalLibraryStoreError.invalidPodcastState("playlist exists")
        }
        guard initialEntryID == nil || kind == .manual else {
            throw LocalLibraryStoreError.invalidPodcastState("initial entry needs a manual playlist")
        }
        let record = PlaylistModels.PlaylistRecord(
            id: id, name: name, kind: kind.rawValue, matchAll: matchAll,
            sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(record)
        if let initialEntryID {
            context.insert(PlaylistModels.PlaylistEntryRecord(playlistID: id, entryID: initialEntryID, sortKey: 0))
        }
        try context.save()
        return Self.playlist(record)!
    }

    /// All playlists in display order.
    public func playlists() throws -> [Playlist] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRecord>())
            .sorted { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
            .compactMap(Self.playlist)
    }

    public func updatePlaylist(id: String, name: String? = nil, matchAll: Bool? = nil) throws {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRecord>())
            .first(where: { $0.id == id }) else { throw LocalLibraryStoreError.invalidPodcastState("playlist") }
        if let name { record.name = name }
        if let matchAll { record.matchAll = matchAll }
        try context.save()
    }

    /// Deletes a playlist with its entries and rules. Library entries are untouched.
    public func deletePlaylist(id: String) throws {
        let context = ModelContext(container)
        for record in try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRecord>()) where record.id == id {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<PlaylistModels.PlaylistEntryRecord>()) where record.playlistID == id {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRuleRecord>()) where record.playlistID == id {
            context.delete(record)
        }
        try context.save()
    }

    // MARK: - Manual entries

    /// Entry IDs of a manual playlist in order (sort key, then entry ID).
    public func playlistEntryIDs(playlistID: String) throws -> [String] {
        let context = ModelContext(container)
        return Self.orderedEntries(try context.fetch(FetchDescriptor<PlaylistModels.PlaylistEntryRecord>())
            .filter { $0.playlistID == playlistID }).map(\.entryID)
    }

    /// Replaces only the order of a manual playlist's existing entries in one
    /// save. The exact expected order prevents a stale Mac view from
    /// overwriting an intervening edit; the new order must be a permutation,
    /// so this operation cannot add or remove membership.
    public func reorderPlaylistEntries(
        playlistID: String, expectedEntryIDs: [String], orderedEntryIDs: [String]
    ) throws {
        let context = ModelContext(container)
        guard try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRecord>())
            .contains(where: { $0.id == playlistID && $0.kind == PlaylistKind.manual.rawValue }) else {
            throw LocalLibraryStoreError.invalidPodcastState("manual playlist order")
        }
        let rows = Self.orderedEntries(try context.fetch(FetchDescriptor<PlaylistModels.PlaylistEntryRecord>())
            .filter { $0.playlistID == playlistID })
        let current = rows.map(\.entryID)
        guard current == expectedEntryIDs,
              orderedEntryIDs.count == current.count,
              Set(orderedEntryIDs).count == orderedEntryIDs.count,
              Set(orderedEntryIDs) == Set(current) else {
            throw LocalLibraryStoreError.invalidPodcastState("stale playlist order")
        }
        guard orderedEntryIDs != current else { return }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.entryID, $0) })
        for (index, entryID) in orderedEntryIDs.enumerated() {
            byID[entryID]?.sortKey = Double(index)
        }
        try context.save()
    }

    private static func orderedEntries(
        _ records: [PlaylistModels.PlaylistEntryRecord]
    ) -> [PlaylistModels.PlaylistEntryRecord] {
        records.sorted { ($0.sortKey, $0.entryID) < ($1.sortKey, $1.entryID) }
    }

    /// Appends an entry to a manual playlist; an entry already there stays put.
    public func addPlaylistEntry(playlistID: String, entryID: String) throws {
        let context = ModelContext(container)
        guard try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRecord>())
            .contains(where: { $0.id == playlistID && $0.kind == PlaylistKind.manual.rawValue }) else {
            throw LocalLibraryStoreError.invalidPodcastState("manual playlist")
        }
        let rows = try context.fetch(FetchDescriptor<PlaylistModels.PlaylistEntryRecord>())
            .filter { $0.playlistID == playlistID }
        guard !rows.contains(where: { $0.entryID == entryID }) else { return }
        let key = Self.playlistSortKey(after: rows.map(\.sortKey).max(), before: nil) ?? Double(rows.count)
        context.insert(PlaylistModels.PlaylistEntryRecord(playlistID: playlistID, entryID: entryID, sortKey: key))
        try context.save()
    }

    /// Moves an entry so it sits at `index` in the resulting order, rebalancing
    /// the playlist's keys when no distinct key fits. Touches no other store.
    public func movePlaylistEntry(playlistID: String, entryID: String, to index: Int) throws {
        let context = ModelContext(container)
        let rows = Self.orderedEntries(try context.fetch(FetchDescriptor<PlaylistModels.PlaylistEntryRecord>())
            .filter { $0.playlistID == playlistID })
        guard let moving = rows.first(where: { $0.entryID == entryID }), index >= 0, index < rows.count else {
            throw LocalLibraryStoreError.invalidPodcastState("playlist move")
        }
        var others = rows.filter { $0 !== moving }
        func neighbours() -> (Double?, Double?) {
            (index > 0 ? others[index - 1].sortKey : nil, index < others.count ? others[index].sortKey : nil)
        }
        var (lower, upper) = neighbours()
        var key = Self.playlistSortKey(after: lower, before: upper)
        if key == nil {
            for (position, row) in others.enumerated() { row.sortKey = Double(position) }
            (lower, upper) = neighbours()
            key = Self.playlistSortKey(after: lower, before: upper)
        }
        guard let key else { throw LocalLibraryStoreError.invalidPodcastState("playlist sort key") }
        moving.sortKey = key
        try context.save()
    }

    public func removePlaylistEntry(playlistID: String, entryID: String) throws {
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<PlaylistModels.PlaylistEntryRecord>())
        where row.playlistID == playlistID && row.entryID == entryID { context.delete(row) }
        try context.save()
    }

    /// Drops an entry from every manual playlist. Call it when the entry leaves the library.
    public func removeEntryFromAllPlaylists(entryID: String) throws {
        let context = ModelContext(container)
        try stagePlaylistEntryRemoval(entryIDs: [entryID], in: context)
        try context.save()
    }

    /// Stages deletion of every playlist row naming one of `entryIDs` in the
    /// caller's context, so a removal commits it atomically with its own save.
    /// An entry ID is the library item's raw ID: the episode, article or
    /// audiobook volume ID. Returns the number of rows staged.
    @discardableResult
    func stagePlaylistEntryRemoval(entryIDs: Set<String>, in context: ModelContext) throws -> Int {
        guard !entryIDs.isEmpty else { return 0 }
        var staged = 0
        for row in try context.fetch(FetchDescriptor<PlaylistModels.PlaylistEntryRecord>())
        where entryIDs.contains(row.entryID) { context.delete(row); staged += 1 }
        return staged
    }

    // MARK: - Rules

    /// Replaces an automatic playlist's rules, keeping their order, and writes
    /// the playlist's all-of or any-of mode in the same save when `matchAll` is
    /// given. A rejection leaves both the rules and the mode untouched.
    public func setPlaylistRules(playlistID: String, rules: [PlaylistRule], matchAll: Bool? = nil) throws {
        let context = ModelContext(container)
        guard let playlist = try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRecord>())
            .first(where: { $0.id == playlistID && $0.kind == PlaylistKind.automatic.rawValue }) else {
            throw LocalLibraryStoreError.invalidPodcastState("automatic playlist")
        }
        for row in try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRuleRecord>())
        where row.playlistID == playlistID { context.delete(row) }
        for (index, rule) in rules.enumerated() {
            context.insert(PlaylistModels.PlaylistRuleRecord(
                playlistID: playlistID, field: rule.field.rawValue, comparator: rule.comparator.rawValue,
                value: rule.value, sortIndex: index))
        }
        if let matchAll { playlist.matchAll = matchAll }
        try context.save()
    }

    /// An automatic playlist's rules in order. A row this build cannot decode
    /// is a visible error, never a silent drop; the row is left in place so a
    /// later build can repair it.
    public func playlistRules(playlistID: String) throws -> [PlaylistRule] {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<PlaylistModels.PlaylistRuleRecord>())
            .filter { $0.playlistID == playlistID }
            .sorted { ($0.sortIndex, $0.value) < ($1.sortIndex, $1.value) }
        return try rows.map(Self.playlistRule)
    }

    /// Decodes one stored rule row. Expression rows carry their versioned JSON
    /// payload in `value`; flat rows keep their field, comparator and value.
    static func playlistRule(_ row: LocalLibrarySchemaV17Models.PlaylistRuleRecord) throws -> PlaylistRule {
        guard let field = PlaylistRuleField(rawValue: row.field),
              let comparator = PlaylistComparator(rawValue: row.comparator) else {
            throw PlaylistRuleError(reason: "stored rule has an unknown field or comparator")
        }
        if field == .expression {
            guard comparator == .expression else {
                throw PlaylistRuleError(reason: "stored expression rule needs the expression comparator")
            }
            return try PlaylistRule.expression(storedValue: row.value)
        }
        guard comparator != .expression else {
            throw PlaylistRuleError(reason: "stored rule mixes an expression comparator with a flat field")
        }
        return try PlaylistRule(field: field, comparator: comparator, value: row.value)
    }
}
