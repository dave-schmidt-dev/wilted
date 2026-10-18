import Foundation
import WiltedLibrary

/// Adapts each Mac list's rows to the one factual comparator used by WiltedLibrary.
enum WiltedMacEpisodeListOrder {
    static func restoredSort(from rawValue: String) -> WiltedMacLarderSort {
        WiltedMacLarderSort.restored(rawValue)?.0 ?? .custom
    }

    static func restoredDirection(from rawSort: String, direction rawDirection: String) -> WiltedMacLarderSortDirection {
        let restored = WiltedMacLarderSort.restored(rawSort)
        return restored?.1
            ?? WiltedMacLarderSortDirection(rawValue: rawDirection)
            ?? .ascending
    }

    /// One-time Feeds page default migration from its earlier page-specific
    /// sort into the shared Larder sort vocabulary.
    static func legacyFeedsOrdering(
        _ sort: WiltedMacFeedsSort
    ) -> (sort: WiltedMacLarderSort, direction: WiltedMacLarderSortDirection) {
        switch sort {
        case .newest: (.age, .ascending)
        case .oldest: (.age, .descending)
        case .shortest: (.length, .ascending)
        case .show, .title: (.alphabetical, .ascending)
        }
    }

    static func ordered<Value>(
        _ values: [Value],
        key: (Value) -> LibraryEpisodeOrdering.Key,
        sort: WiltedMacLarderSort,
        direction: WiltedMacLarderSortDirection
    ) -> [Value] {
        let mode = librarySort(sort)
        guard mode != .custom else { return values }
        let effectiveDirection = libraryDirection(sort.legacyDirection ?? direction)
        return values.enumerated().sorted { left, right in
            let leftKey = key(left.element)
            let rightKey = key(right.element)
            if LibraryEpisodeOrdering.precedes(leftKey, rightKey, sort: mode, direction: effectiveDirection) {
                return true
            }
            if LibraryEpisodeOrdering.precedes(rightKey, leftKey, sort: mode, direction: effectiveDirection) {
                return false
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    static func key(for episode: WiltedMacEpisode) -> LibraryEpisodeOrdering.Key {
        key(for: episode.presentation, id: episode.id)
    }

    static func key(for item: WiltedMacLibraryItem) -> LibraryEpisodeOrdering.Key {
        switch item {
        case .article(let article):
            // Larder has always used an article's saved date as its age key;
            // this is a role-specific library sort fact, not an episode publish date.
            return LibraryEpisodeOrdering.Key(
                id: article.id, title: article.title,
                durationSeconds: article.durationSeconds, publishedAt: article.createdAt
            )
        case .episode(let episode), .audiobook(let episode):
            return key(for: episode)
        }
    }

    static func key(for presentation: WiltedMacEpisodePresentation, id: String) -> LibraryEpisodeOrdering.Key {
        LibraryEpisodeOrdering.Key(
            id: id,
            title: presentation.title,
            durationSeconds: presentation.sourceDurationSeconds,
            publishedAt: presentation.publishedAt
        )
    }

    static func librarySort(_ sort: WiltedMacLarderSort) -> LibraryEpisodeOrdering.Sort {
        switch sort.canonical {
        case .length: .length
        case .age: .age
        case .alphabetical: .alphabetical
        case .custom, .oldest: .custom
        }
    }

    static func libraryDirection(_ direction: WiltedMacLarderSortDirection) -> LibraryEpisodeOrdering.Direction {
        direction == .ascending ? .ascending : .descending
    }
}
