import Foundation
import WiltedDomain
import WiltedLibrary

/// A source identity is kept separate from its visible title so same-named shows remain distinct.
enum CarShowIdentity: Hashable, Sendable {
    case source(ItemID)
    case title(String)
}

/// One show with episodes on the phone, for the car's Shows tab.
struct CarShowRow: Equatable, Identifiable, Sendable {
    let identity: CarShowIdentity
    let title: String
    let publisher: String?
    let downloaded: Int
    let sameTitleCount: Int
    let artworkURL: URL?
    var id: CarShowIdentity { identity }
    var detail: String {
        let count = "\(downloaded) downloaded"
        guard sameTitleCount > 1 else { return count }
        return "\(publisher ?? "Unknown publisher") · \(count)"
    }
}

/// The Shows tab: one row per show that has downloaded episodes, shows with an in-progress episode
/// first, and each show's own episode list in the same row style as the Downloaded tab.
enum CarShowList {
    /// Shows in the order of the Downloaded list, capped to `limit`. In Play order an in-progress
    /// episode's show leads; in Mac order shows follow first appearance in the Mac's order, none pinned.
    static func make(
        rows: [LibraryRow], onPhone: Set<ItemID>,
        progress: [ItemID: EpisodeProgress] = [:], finished: [ItemID: Date] = [:], limit: Int = CarEpisodeList.defaultLimit,
        order: LibraryListOrder = .playOrder
    ) -> [CarShowRow] {
        let listed = LibraryListing.rows(
            rows, offered: [], onPhone: onPhone, filter: .onPhone, query: "", progress: progress, finished: finished,
            order: order)
        let groups = Dictionary(grouping: listed, by: identity(for:))
        var showOrder: [CarShowIdentity] = []
        var seen = Set<CarShowIdentity>()
        for row in listed {
            let identity = identity(for: row)
            if seen.insert(identity).inserted { showOrder.append(identity) }
        }
        var sameTitleCounts: [String: Int] = [:]
        for identity in showOrder {
            if let title = groups[identity]?.first?.showTitle { sameTitleCounts[title, default: 0] += 1 }
        }
        let orderedShows: [CarShowIdentity]
        switch order {
        case .playOrder:
            var lastPlayed: [CarShowIdentity: Date] = [:]
            for row in listed {
                guard let played = progress[row.id]?.lastPlayedAt else { continue }
                let key = identity(for: row)
                lastPlayed[key] = max(lastPlayed[key] ?? .distantPast, played)
            }
            orderedShows = InProgressOrdering.orderedShows(showOrder, progressByShow: lastPlayed)
        case .mac:
            orderedShows = showOrder
        }
        return orderedShows
            .prefix(max(1, limit))
            .compactMap { identity in
                guard let episodes = groups[identity], let first = episodes.first else { return nil }
                return CarShowRow(
                    identity: identity, title: first.showTitle, publisher: first.showPublisher,
                    downloaded: episodes.count, sameTitleCount: sameTitleCounts[first.showTitle] ?? 1,
                    artworkURL: episodes.compactMap { $0.showArtworkURL ?? $0.artworkURL }.first)
            }
    }

    /// The episodes of one show on the phone, in the Downloaded tab's order and row style.
    static func episodes(
        of showIdentity: CarShowIdentity, rows: [LibraryRow], onPhone: Set<ItemID>,
        playingID: ItemID?, progress: [ItemID: EpisodeProgress] = [:], finished: [ItemID: Date] = [:],
        limit: Int = CarEpisodeList.defaultLimit, isLoading: Bool = false,
        order: LibraryListOrder = .playOrder
    ) -> CarEpisodeList {
        CarEpisodeList.make(
            rows: rows.filter { identity(for: $0) == showIdentity },
            onPhone: onPhone, playingID: playingID,
            isLoading: isLoading, limit: limit, progress: progress,
            finished: finished, order: order)
    }

    private static func identity(for row: LibraryRow) -> CarShowIdentity {
        row.showID.map(CarShowIdentity.source) ?? .title(row.showTitle)
    }
}
