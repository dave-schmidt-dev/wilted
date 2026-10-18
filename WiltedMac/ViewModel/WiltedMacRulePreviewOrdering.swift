import Foundation
import WiltedLibrary

/// Independent remembered sort settings for the two rule-preview surfaces.
enum WiltedMacRulePreviewSortPreferences {
    static let feedRulesPrefix = "wilted.feedRules.preview"
    static let playlistRulesPrefix = "wilted.playlistRules.preview"

    struct Value: Equatable {
        var sort: WiltedMacLarderSort
        var direction: WiltedMacLarderSortDirection
    }

    static func restore(from preferences: UserDefaults, prefix: String) -> Value {
        let rawSort = preferences.string(forKey: "\(prefix).sort") ?? WiltedMacLarderSort.custom.rawValue
        let rawDirection = preferences.string(forKey: "\(prefix).direction")
            ?? WiltedMacLarderSortDirection.ascending.rawValue
        return Value(
            sort: WiltedMacEpisodeListOrder.restoredSort(from: rawSort),
            direction: WiltedMacEpisodeListOrder.restoredDirection(from: rawSort, direction: rawDirection)
        )
    }

    static func store(
        _ value: Value, in preferences: UserDefaults, prefix: String
    ) {
        preferences.set(value.sort.canonical.rawValue, forKey: "\(prefix).sort")
        preferences.set(value.direction.rawValue, forKey: "\(prefix).direction")
    }
}

enum WiltedMacPlaylistRulePreviewOrdering {
    @MainActor
    static func orderedEntries(
        _ entries: [WiltedMacPlaylistRulePreview.Entry],
        model: WiltedMacModel,
        sort: WiltedMacLarderSort,
        direction: WiltedMacLarderSortDirection
    ) -> [WiltedMacPlaylistRulePreview.Entry] {
        guard sort.canonical != .custom else { return entries }
        let keyed = entries.map { entry in
            let key = model.playlistLibraryItem(entry.id).map { WiltedMacEpisodeListOrder.key(for: $0) }
                ?? LibraryEpisodeOrdering.Key(
                    id: entry.id, title: entry.title, durationSeconds: nil, publishedAt: nil)
            return (entry: entry, key: key)
        }
        return WiltedMacEpisodeListOrder.ordered(
            keyed, key: { $0.key }, sort: sort, direction: direction
        ).map { $0.entry }
    }
}
