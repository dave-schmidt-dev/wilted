import Foundation
import WiltedDomain
import WiltedLibrary

/// One episode the car can play: already on the phone. Driving-safe text only.
struct CarEpisodeRow: Equatable, Identifiable, Sendable {
    let row: LibraryRow
    var id: ItemID { row.id }
    let title: String
    let detail: String
    /// True for the episode currently playing.
    let isPlaying: Bool
    /// How much has been heard, 0 to 1, for the row's progress bar; nil when nobody has started it.
    var listenedFraction: Double? = nil
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
        rows: [LibraryRow], onPhone: Set<ItemID>,
        playingID: ItemID?, isLoading: Bool, limit: Int = defaultLimit, progress: [ItemID: EpisodeProgress] = [:],
        finished: [ItemID: Date] = [:]
    ) -> CarEpisodeList {
        let listed = LibraryListing.rows(
            rows, offered: [], onPhone: onPhone, filter: .onPhone, query: "", progress: progress, finished: finished)
        let capped = Array(listed.prefix(max(1, limit)))
        guard !capped.isEmpty else {
            return CarEpisodeList(content: .empty(isLoading ? loadingMessage : emptyMessage), totalOnPhone: 0)
        }
        return CarEpisodeList(
            content: .episodes(capped.map {
                CarEpisodeRow(
                    row: $0, title: $0.title, detail: detail(
                        $0, progress: progress[$0.id], completed: LibraryListing.completionDate($0, finished: finished) != nil),
                    isPlaying: $0.id == playingID,
                    listenedFraction: fraction(progress[$0.id], duration: $0.durationSeconds))
            }),
            totalOnPhone: listed.count)
    }

    /// The show, then how much is left when someone is partway through, the full length when it is
    /// untouched (marked "New"), "Played" once completed, and just the show when the feed gave no length.
    static func detail(_ row: LibraryRow, progress: EpisodeProgress?, completed: Bool = false) -> String {
        if completed { return "\(row.showTitle) · Played" }
        guard let duration = row.durationSeconds, duration > 0 else { return row.showTitle }
        if let progress {
            let left = max(0, duration - progress.positionSeconds)
            return "\(row.showTitle) · \(LibraryClockFormat.duration(left)) left"
        }
        return "\(row.showTitle) · \(LibraryClockFormat.duration(duration)) · New"
    }

    static func fraction(_ progress: EpisodeProgress?, duration: Double?) -> Double? {
        guard let progress, let duration, duration > 0 else { return nil }
        return min(1, max(0, progress.positionSeconds / duration))
    }
}

extension CarEpisodeList {
    /// The car list for the model as it stands right now.
    @MainActor
    static func make(model: LibraryAppModel, playingID: ItemID?, limit: Int = defaultLimit) -> CarEpisodeList {
        make(
            rows: model.queued, onPhone: model.preparedIDs.onPhone, playingID: playingID,
            isLoading: model.lastSynchronizedAt == nil && model.isRefreshing, limit: limit, progress: model.progress,
            finished: model.finished)
    }
}
