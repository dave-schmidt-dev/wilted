import Foundation
import WiltedDomain

/// One episode the car can play: already on the phone. Driving-safe text only.
struct CarEpisodeRow: Equatable, Identifiable, Sendable {
    let row: LibraryRow
    var id: ItemID { row.id }
    let title: String
    let detail: String
    /// True for the episode currently playing.
    let isPlaying: Bool
}

/// What the car list shows. Never tells the driver to use the phone.
struct CarEpisodeList: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case episodes([CarEpisodeRow])
        /// A plain statement, not an instruction.
        case empty(String)
    }

    static let defaultLimit = 12
    static let emptyMessage = "No episodes on this iPhone"
    static let loadingMessage = "Loading episodes"

    let content: Content
    /// How many episodes are on the phone before the cap.
    let totalOnPhone: Int

    /// Episodes whose audio is already on the phone, in the Larder's order for `sort`, capped to
    /// `limit` (clamped to at least 1). `rows` are the queued rows (`LibraryAppModel.queued`).
    /// Empty result: `loadingMessage` when `isLoading` is true, otherwise `emptyMessage`.
    static func make(
        rows: [LibraryRow], onPhone: Set<ItemID>, sort: LibrarySortOrder,
        playingID: ItemID?, isLoading: Bool, limit: Int = defaultLimit
    ) -> CarEpisodeList {
        let listed = LibraryListing.rows(rows, offered: [], onPhone: onPhone, sort: sort, filter: .onPhone, query: "")
        let capped = Array(listed.prefix(max(1, limit)))
        guard !capped.isEmpty else {
            return CarEpisodeList(content: .empty(isLoading ? loadingMessage : emptyMessage), totalOnPhone: 0)
        }
        return CarEpisodeList(
            content: .episodes(capped.map {
                CarEpisodeRow(row: $0, title: $0.title, detail: detail($0), isPlaying: $0.id == playingID)
            }),
            totalOnPhone: listed.count)
    }

    /// The show title, plus " · " and the duration text when the feed gave one.
    private static func detail(_ row: LibraryRow) -> String {
        row.durationText.map { "\(row.showTitle) · \($0)" } ?? row.showTitle
    }
}

extension CarEpisodeList {
    /// The car list for the model as it stands right now.
    @MainActor
    static func make(model: LibraryAppModel, playingID: ItemID?, limit: Int = defaultLimit) -> CarEpisodeList {
        make(
            rows: model.queued, onPhone: model.preparedIDs.onPhone, sort: model.sort, playingID: playingID,
            isLoading: model.lastSynchronizedAt == nil && model.isRefreshing, limit: limit)
    }
}
