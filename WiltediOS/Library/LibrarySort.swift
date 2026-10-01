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
        case .onPhone: "On phone"
        case .available: "Available"
        }
    }
}

/// The pure part of the Larder list: which queued rows appear and in what order. The order is always
/// the shared play order (`InProgressOrdering.playOrder`), the same one CarPlay, Siri and auto-continue
/// use; the phone has no sort choice and no drag-reorder (the Mac keeps its own custom order).
enum LibraryListing {
    /// Queued rows the Mac has prepared: a ready offer (or a transfer already under way) or audio
    /// already on the phone, narrowed by `filter` and `query`, in the play order: episodes someone is
    /// partway through first (newest play first), then not-started ones oldest published first (ties keep
    /// the Mac's queue order, which `rows` arrive in), then completed ones last (`finished` adds those
    /// played to the end but not marked).
    static func rows(
        _ rows: [LibraryRow], offered: Set<ItemID>, onPhone: Set<ItemID>,
        filter: LibraryFilter, query: String,
        progress: [ItemID: EpisodeProgress] = [:], finished: [ItemID: Date] = [:]
    ) -> [LibraryRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = prepared(rows, offered: offered, onPhone: onPhone).filter { row in
            switch filter {
            case .all: true
            case .onPhone: onPhone.contains(row.id)
            case .available: !onPhone.contains(row.id)
            }
        }.filter { matches($0, query: needle) }
        return InProgressOrdering.playOrder(
            kept, progress: progress, id: \.id, publishedAt: \.publishedAt,
            completedAt: { completionDate($0, finished: finished) })
    }

    /// When a row was completed: marked on a device, else played to its end.
    static func completionDate(_ row: LibraryRow, finished: [ItemID: Date]) -> Date? {
        row.completedAt ?? finished[row.id]
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
}
