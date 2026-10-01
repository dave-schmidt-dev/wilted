import Foundation
import WiltedDomain
import WiltedLibrary

/// One show with episodes on the phone, for the car's Shows tab.
struct CarShowRow: Equatable, Identifiable, Sendable {
    let title: String
    /// How many of its episodes are on the phone.
    let downloaded: Int
    let artworkURL: URL?
    var id: String { title }
    var detail: String { "\(downloaded) downloaded" }
}

/// The Shows tab: one row per show that has downloaded episodes, shows with an in-progress episode
/// first, and each show's own episode list in the same row style as the Downloaded tab.
enum CarShowList {
    static let emptyMessage = "No episodes on this iPhone"

    /// Shows in the order of the Downloaded list (so an in-progress episode's show leads), capped to `limit`.
    static func make(
        rows: [LibraryRow], onPhone: Set<ItemID>,
        progress: [ItemID: EpisodeProgress] = [:], finished: [ItemID: Date] = [:], limit: Int = CarEpisodeList.defaultLimit
    ) -> [CarShowRow] {
        let listed = LibraryListing.rows(
            rows, offered: [], onPhone: onPhone, filter: .onPhone, query: "", progress: progress, finished: finished)
        var order: [String] = []
        var counts: [String: Int] = [:]
        var art: [String: URL] = [:]
        for row in listed {
            if counts[row.showTitle] == nil { order.append(row.showTitle) }
            counts[row.showTitle, default: 0] += 1
            if art[row.showTitle] == nil, let url = row.showArtworkURL ?? row.artworkURL { art[row.showTitle] = url }
        }
        var lastPlayed: [String: Date] = [:]
        for row in listed {
            guard let played = progress[row.id]?.lastPlayedAt else { continue }
            lastPlayed[row.showTitle] = max(lastPlayed[row.showTitle] ?? .distantPast, played)
        }
        return InProgressOrdering.orderedShows(order, progressByShow: lastPlayed)
            .prefix(max(1, limit))
            .map { CarShowRow(title: $0, downloaded: counts[$0] ?? 0, artworkURL: art[$0]) }
    }

    /// The episodes of one show on the phone, in the Downloaded tab's order and row style.
    static func episodes(
        of show: String, rows: [LibraryRow], onPhone: Set<ItemID>,
        playingID: ItemID?, progress: [ItemID: EpisodeProgress] = [:], finished: [ItemID: Date] = [:],
        limit: Int = CarEpisodeList.defaultLimit
    ) -> CarEpisodeList {
        CarEpisodeList.make(
            rows: rows.filter { $0.showTitle == show }, onPhone: onPhone, playingID: playingID,
            isLoading: false, limit: limit, progress: progress,
            finished: finished)
    }
}
