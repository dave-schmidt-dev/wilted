import Foundation
import WiltedDomain
import WiltedLibrary

/// One Larder row, already resolved to display strings.
struct LibraryRow: Identifiable, Equatable, Sendable {
    let id: ItemID
    let title: String
    let showTitle: String
    let durationText: String?
    /// The duration in seconds, for the shortest-first sort; nil when the feed gave none.
    var durationSeconds: Double?
    let removal: LibraryRemoval
    let publishedAt: Date
    /// "Retired on Mac" or "Dismissed on Mac"; nil while the entry is live.
    let removalText: String?
    /// "Paused on Mac at mm:ss (as of hh:mm)" from the Mac's last checkpoint for this entry.
    let checkpointText: String?
    /// True when some device has started the episode and it is not completed; the only rows
    /// that offer Mark done.
    var isStarted: Bool = false
    /// When the episode was marked completed on any device; nil while it is not.
    var completedAt: Date?
    /// The episode notes the Mac published; searched, never shown in the row.
    var summary: String = ""
    /// Artwork location as published by the Mac; nil when the episode has none.
    var artworkURL: URL?
    /// The show's own artwork (from its source), for lists of shows; nil when the Mac published none.
    var showArtworkURL: URL?
    /// Where Play should begin: the Mac's last observed position, nil to begin at the start.
    var resumeSeconds: Double?
}

/// Fixed-format clock and duration text, so labels do not shift with the device locale.
struct LibraryClockFormat: Sendable {
    let timeZone: TimeZone

    func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `mm:ss`, or `h:mm:ss` from one hour up.
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Pure projection from mirrored content to rows.
enum LibraryRowBuilder {
    /// Queued entries in slot order. The phone shows no other entries: New, retired and
    /// dismissed episodes belong to the Mac.
    static func rows(
        content: LibrarySnapshot,
        checkpoints: [ItemID: ObservedPlayback],
        clock: LibraryClockFormat,
        started: Set<ItemID> = []
    ) -> [LibraryRow] {
        content.queue.compactMap { content.entries[$0.entryID] }.map {
            makeRow($0, content: content, checkpoints: checkpoints, clock: clock, started: started)
        }
    }

    private static func makeRow(
        _ entry: LibraryEntry, content: LibrarySnapshot, checkpoints: [ItemID: ObservedPlayback],
        clock: LibraryClockFormat, started: Set<ItemID>
    ) -> LibraryRow {
        LibraryRow(
            id: entry.id,
            title: entry.title,
            showTitle: content.sources[entry.sourceID]?.title ?? "Unknown show",
            durationText: entry.durationSeconds.map(LibraryClockFormat.duration),
            durationSeconds: entry.durationSeconds,
            removal: entry.removal,
            publishedAt: entry.publishedAt,
            removalText: removalText(entry.removal),
            checkpointText: checkpoints[entry.id].map { checkpointText($0, clock: clock) },
            isStarted: started.contains(entry.id) && content.listening[entry.id]?.isCompleted != true,
            completedAt: content.listening[entry.id]?.completedAt,
            summary: entry.summary,
            artworkURL: artworkURL(entry.artworkRef),
            showArtworkURL: artworkURL(content.sources[entry.sourceID]?.artworkRef),
            resumeSeconds: resumeSeconds(checkpoints[entry.id], duration: entry.durationSeconds)
        )
    }

    /// Only web addresses load; anything else the Mac might publish shows the placeholder.
    static func artworkURL(_ reference: String?) -> URL? {
        guard let reference, let url = URL(string: reference), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// The Mac's last observed position, unless it is at the start or at the very end, where
    /// resuming would land after the last word and playing from the top is the useful choice.
    static func resumeSeconds(_ observed: ObservedPlayback?, duration: Double?) -> Double? {
        guard let position = observed?.record.positionSeconds, position.isFinite, position > 0 else { return nil }
        if let duration, duration > 0, position >= duration - 1 { return nil }
        return position
    }

    static func removalText(_ removal: LibraryRemoval) -> String? {
        switch removal {
        case .none: nil
        case .retired: "Retired on Mac"
        case .dismissed: "Dismissed on Mac"
        }
    }

    static func checkpointText(_ observed: ObservedPlayback, clock: LibraryClockFormat) -> String {
        let state = observed.record.isPlaying ? "Playing" : "Paused"
        let position = LibraryClockFormat.duration(observed.record.positionSeconds)
        return "\(state) on Mac at \(position) (as of \(clock.clock(observed.serverModifiedAt)))"
    }
}
