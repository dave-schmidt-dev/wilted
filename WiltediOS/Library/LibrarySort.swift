import Foundation
import WiltedDomain
import WiltedLibrary

/// What the Larder shows by where the audio is.
enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, onPhone, available

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .onPhone: "Downloaded"
        case .available: "Available"
        }
    }
}

/// Which kind of item the Larder shows. Persisted beside the Downloaded / Available filter; the Mac
/// has the same four choices. A kind this build does not know appears under All only, never under
/// a specific choice, and a stored value it does not know reads as All.
enum LibraryKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, podcasts, articles, audiobooks

    nonisolated static let storageKey = "wilted.library.listKind"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .podcasts: "Podcasts"
        case .articles: "Articles"
        case .audiobooks: "Audiobooks"
        }
    }

    static func stored(_ rawValue: String?) -> LibraryKindFilter {
        rawValue.flatMap(LibraryKindFilter.init(rawValue:)) ?? .all
    }

    func includes(_ kind: LibraryKind) -> Bool {
        switch self {
        case .all: true
        case .podcasts: kind == .podcastEpisode
        case .articles: kind == .article
        case .audiobooks: kind == .audiobook
        }
    }
}

/// Which order queued rows are returned in: the phone's shared play order or the Mac's queue order.
enum LibraryListOrder: String, CaseIterable, Identifiable, Sendable {
    case playOrder, mac

    var id: String { rawValue }
}

/// How the Larder list is laid out on screen. In Mac order, playback and Next follow it; other
/// options are display choices only.
enum LibrarySortOption: String, CaseIterable, Identifiable, Sendable {
    case playOrder, macOrder, newest, oldest, shortest, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playOrder: "Play order"
        case .macOrder: "Mac order"
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .shortest: "Shortest"
        case .title: "Title"
        }
    }

    var listOrder: LibraryListOrder {
        switch self {
        case .macOrder: .mac
        default: .playOrder
        }
    }

    /// A stored value this build does not know (hand-edited, or from a later build) is the play order.
    static func stored(_ rawValue: String?) -> LibrarySortOption {
        rawValue.flatMap(LibrarySortOption.init(rawValue:)) ?? .playOrder
    }
}

enum LibraryGroupOption: String, CaseIterable, Identifiable, Sendable {
    case none, feed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No Grouping"
        case .feed: "Feed"
        }
    }

    static func stored(_ rawValue: String?) -> LibraryGroupOption {
        rawValue.flatMap(LibraryGroupOption.init(rawValue:)) ?? .none
    }
}

/// What one Larder toolbar control shows: its label, its symbol, and whether the list is off the
/// control's default. Plain values, so the cue rules are tested away from the bar.
struct LibraryToolbarCue: Equatable, Sendable {
    let label: String
    let symbol: String
    let isActive: Bool
}

/// The Larder toolbar's cues. The bar keeps its two controls, Sort/Group and Filter; a control that
/// is not at its default says so on itself, so no third item is ever needed for the state.
enum LibraryToolbar {
    /// The cap the Larder toolbar holds itself to: Sort/Group and Filter.
    static let maximumControls = 2

    static func sortCue(sort: LibrarySortOption, group: LibraryGroupOption) -> LibraryToolbarCue {
        let isActive = sort != .playOrder || group != .none
        return LibraryToolbarCue(
            label: label(sort: sort, group: group),
            symbol: isActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle",
            isActive: isActive)
    }

    static func filterCue(_ filter: LibraryFilter, kind: LibraryKindFilter = .all) -> LibraryToolbarCue {
        let isActive = filter != .all || kind != .all
        let parts = [filter == .all ? nil : filter.title, kind == .all ? nil : kind.title].compactMap { $0 }
        return LibraryToolbarCue(
            label: isActive ? "Filter: \(parts.joined(separator: " · "))" : "Filter: All",
            symbol: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
            isActive: isActive)
    }

    /// What to show under the Larder sort control. Nil for Play order; explains Mac order and the other sorts.
    static func orderNote(sort: LibrarySortOption) -> String? {
        switch sort {
        case .playOrder:
            return nil
        case .macOrder:
            return "Mac order, as last synced. Playback and Next follow it."
        default:
            return "Sorted by \(sort.label). Playback and Next still follow the play order."
        }
    }

    private static func label(sort: LibrarySortOption, group: LibraryGroupOption) -> String {
        guard sort != .playOrder || group != .none else { return "Sort and group" }
        switch (sort, group) {
        case (.playOrder, let group): return "Group: \(group.label)"
        case (let sort, .none): return "Sort: \(sort.label)"
        case (let sort, let group): return "\(sort.label) · \(group.label)"
        }
    }
}

/// One run of rows under an optional heading; a single untitled section when nothing is grouped.
struct LibraryRowSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let rows: [LibraryRow]

    /// A titled section already names the feed in its header, so its rows leave the show out of the
    /// detail line; the one untitled section has nothing else to name it.
    var namesShowInRows: Bool { title == nil }
}

/// The pure part of the Larder list: which queued rows appear and in what order. `rows` returns either
/// the shared play order or the Mac's queue order (`LibraryListOrder`). `organize` is a display transform
/// over those rows (Sort and Group); for `macOrder` rows stay in arriving order.
enum LibraryListing {
    /// `rows` laid out for display. Every sort is stable against the incoming play order, so ties keep
    /// it; rows with no duration sort last under Shortest. Grouping by feed keeps the sorted order
    /// inside each group and orders the groups by their first row.
    static func organize(
        _ rows: [LibraryRow], sort: LibrarySortOption, group: LibraryGroupOption
    ) -> [LibraryRowSection] {
        let ordered = sorted(rows, by: sort)
        switch group {
        case .none:
            return [LibraryRowSection(id: "all", title: nil, rows: ordered)]
        case .feed:
            var order: [String] = []
            var byFeed: [String: [LibraryRow]] = [:]
            for row in ordered {
                let name = feedName(row)
                if byFeed[name] == nil { order.append(name) }
                byFeed[name, default: []].append(row)
            }
            return order.map { LibraryRowSection(id: "feed|\($0)", title: $0, rows: byFeed[$0] ?? []) }
        }
    }

    static func feedName(_ row: LibraryRow) -> String {
        let show = row.showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return show.isEmpty ? "Show unknown" : show
    }

    private static func sorted(_ rows: [LibraryRow], by sort: LibrarySortOption) -> [LibraryRow] {
        guard sort != .playOrder && sort != .macOrder else { return rows }
        let precedes: (LibraryRow, LibraryRow) -> Bool? = { left, right in
            switch sort {
            case .playOrder, .macOrder: nil
            case .newest: left.publishedAt == right.publishedAt ? nil : left.publishedAt > right.publishedAt
            case .oldest: left.publishedAt == right.publishedAt ? nil : left.publishedAt < right.publishedAt
            case .shortest:
                switch (left.durationSeconds, right.durationSeconds) {
                case let (l?, r?): l == r ? nil : l < r
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): nil
                }
            case .title:
                switch LibrarySortKey.title(left.title).localizedStandardCompare(LibrarySortKey.title(right.title)) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: nil
                }
            }
        }
        return rows.enumerated().sorted { left, right in
            precedes(left.element, right.element) ?? (left.offset < right.offset)
        }.map(\.element)
    }

    /// Queued rows the Mac has prepared: a ready offer (or a transfer already under way) or audio
    /// already on the phone, narrowed by `filter` and `query`. In `.playOrder`, episodes someone is
    /// partway through list first, then not-started ones oldest published first, then completed ones last.
    /// In `.mac`, rows arrive in the Mac's queue order with completed ones moved to the end.
    static func rows(
        _ rows: [LibraryRow], offered: Set<ItemID>, onPhone: Set<ItemID>,
        filter: LibraryFilter, kind: LibraryKindFilter = .all, query: String,
        progress: [ItemID: EpisodeProgress] = [:], finished: [ItemID: Date] = [:],
        preparationIDs: Set<ItemID> = [],
        order: LibraryListOrder = .playOrder
    ) -> [LibraryRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = rows.filter { row in
            offered.contains(row.id) || onPhone.contains(row.id) || (filter == .all && preparationIDs.contains(row.id))
        }.filter { row in
            switch filter {
            case .all: true
            case .onPhone: onPhone.contains(row.id)
            case .available: !onPhone.contains(row.id)
            }
        }.filter { kind.includes($0.kind) }.filter { matches($0, query: needle) }
        let projected = kept.map { $0.withMediaAvailability(offered: offered, onPhone: onPhone) }
        switch order {
        case .playOrder:
            return InProgressOrdering.playOrder(
                projected, progress: progress, id: \.id, publishedAt: \.publishedAt,
                completedAt: { completionDate($0, finished: finished) })
        case .mac:
            var uncompleted: [LibraryRow] = []
            var completed: [LibraryRow] = []
            for row in projected {
                if completionDate(row, finished: finished) != nil {
                    completed.append(row)
                } else {
                    uncompleted.append(row)
                }
            }
            return uncompleted + completed
        }
    }

    /// When a row was completed: marked on a device, else played to its end.
    static func completionDate(_ row: LibraryRow, finished: [ItemID: Date]) -> Date? {
        row.completedAt ?? finished[row.id]
    }

    /// Title, show and notes, like the Mac's search field; an empty query matches everything.
    static func matches(_ row: LibraryRow, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return row.title.localizedCaseInsensitiveContains(query)
            || row.showTitle.localizedCaseInsensitiveContains(query)
            || row.summary.localizedCaseInsensitiveContains(query)
    }
}
