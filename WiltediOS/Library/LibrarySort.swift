import Foundation
import WiltedDomain

/// Larder ordering, mirroring the Mac's `WiltedMacMenuSort`: the same six choices with the same
/// tie-breaks. `custom` is the Mac's queue order, the only one the phone lets a person reorder.
enum LibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case custom, newest, oldest, shortest, show, title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom order"
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .shortest: "Length · shortest"
        case .show: "Show · A–Z"
        case .title: "Title · A–Z"
        }
    }

    /// Whether drag-to-reorder makes sense: only the Mac's own order can be edited.
    var allowsReorder: Bool { self == .custom }

    static let preferenceKey = "wilted.library.sort"

    /// The persisted choice, or `custom` when nothing valid is stored.
    static func stored(in defaults: UserDefaults) -> LibrarySortOrder {
        defaults.string(forKey: preferenceKey).flatMap(LibrarySortOrder.init(rawValue:)) ?? .custom
    }
}

/// What the Larder shows by where the audio is.
enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, onPhone, available

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .onPhone: "On phone"
        case .available: "Available"
        }
    }
}

/// The pure part of the Larder list: which queued rows appear and in what order.
enum LibraryListing {
    /// Queued rows the Mac has prepared: a ready offer (or a transfer already under way) or audio
    /// already on the phone, then narrowed by `filter` and `query` and ordered by `sort`.
    /// `rows` arrive in the Mac's queue order, which `custom` keeps.
    static func rows(
        _ rows: [LibraryRow], offered: Set<ItemID>, onPhone: Set<ItemID>,
        sort: LibrarySortOrder, filter: LibraryFilter, query: String
    ) -> [LibraryRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = prepared(rows, offered: offered, onPhone: onPhone).filter { row in
            switch filter {
            case .all: true
            case .onPhone: onPhone.contains(row.id)
            case .available: !onPhone.contains(row.id)
            }
        }.filter { matches($0, query: needle) }
        return sorted(kept, by: sort)
    }

    /// The rows worth listing at all, in queue order.
    static func prepared(_ rows: [LibraryRow], offered: Set<ItemID>, onPhone: Set<ItemID>) -> [LibraryRow] {
        rows.filter { offered.contains($0.id) || onPhone.contains($0.id) }
    }

    /// Title, show and notes, like the Mac's search field; an empty query matches everything.
    static func matches(_ row: LibraryRow, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return row.title.localizedCaseInsensitiveContains(query)
            || row.showTitle.localizedCaseInsensitiveContains(query)
            || row.summary.localizedCaseInsensitiveContains(query)
    }

    static func sorted(_ rows: [LibraryRow], by sort: LibrarySortOrder) -> [LibraryRow] {
        guard sort != .custom else { return rows }
        return rows.sorted { precedes($0, $1, by: sort) }
    }

    private static func precedes(_ lhs: LibraryRow, _ rhs: LibraryRow, by sort: LibrarySortOrder) -> Bool {
        switch sort {
        case .custom:
            return false
        case .newest:
            if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt > rhs.publishedAt }
        case .oldest:
            if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt < rhs.publishedAt }
        case .shortest:
            switch (lhs.durationSeconds, rhs.durationSeconds) {
            case let (left?, right?) where left != right: return left < right
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
        case .show:
            let comparison = lhs.showTitle.localizedStandardCompare(rhs.showTitle)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .title:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
