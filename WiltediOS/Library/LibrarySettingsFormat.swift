import Foundation
import WiltedLibrary

/// Words and numbers for the Settings page. Pure, so the formatting is testable without a view.
enum LibrarySettingsFormat {
    static let unavailable = "Unavailable"

    struct StatRow: Equatable {
        let label: String
        let value: String
        let symbol: String
        let identifier: String
    }

    /// This phone's three lifetime rows. Zero reads as "None" so a fresh install is not a wall of zeros.
    static func phoneStatRows(_ stats: LibraryPhoneStats) -> [StatRow] {
        func time(_ seconds: Double) -> String { seconds >= 1 ? WiltedDuration.spoken(seconds) : "None" }
        return [
            StatRow(label: "Listening time", value: time(stats.listenedSeconds), symbol: "headphones",
                    identifier: "wilted-library-settings-stat-listened"),
            StatRow(label: "Downloaded from Mac",
                    value: stats.downloadedBytes > 0
                        ? ByteCountFormatter.string(fromByteCount: stats.downloadedBytes, countStyle: .file) : "None",
                    symbol: "arrow.down.circle", identifier: "wilted-library-settings-stat-downloaded"),
            StatRow(label: "Time saved at faster speeds", value: time(stats.savedSeconds), symbol: "hare",
                    identifier: "wilted-library-settings-stat-saved"),
        ]
    }

    static func date(_ value: Date?) -> String {
        value.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"
    }

    /// "1.25x", "2x".
    static func speed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))x" : String(format: "%gx", value)
    }

    static func skip(_ seconds: Int) -> String { "\(seconds) seconds" }

    /// "3 episodes · 41.2 MB"; "None" when nothing is cached.
    static func storage(count: Int, bytes: Int64) -> String {
        guard count > 0 else { return "None" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(count) episode\(count == 1 ? "" : "s") · \(size)"
    }

    /// "0.2.8 (7)", from the bundle's info dictionary.
    static func version(_ info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return "Build \(build)"
        default: return "Unknown"
        }
    }

    struct SyncSummary: Equatable {
        let status: String
        let detail: String?
        let tone: WiltedStatusTone
    }

    /// Labels the idle fetch time as this phone's own read. The phone cannot see what the Mac has
    /// published since, so nothing here claims the two match.
    static let phoneFetchNote = "Fetch time reports this phone’s last successful library read."

    /// One line for the sync row: the status, and, once idle after a fetch, when this phone last fetched.
    static func syncLine(_ summary: SyncSummary, lastRefresh: Date?) -> String {
        guard summary.tone == .positive, let lastRefresh else { return summary.status }
        return "\(summary.status) · \(date(lastRefresh))"
    }

    /// Status in words, so state never rests on color alone. Precedence: an account review blocks
    /// everything, then iCloud rate limiting, then a running fetch, then the last error, then whether
    /// this phone has fetched. A fetch says nothing about the Mac's newest publication, so the idle
    /// state names the phone's fetch and never claims the library matches the Mac.
    static func sync(
        isRefreshing: Bool, quarantined: Bool, error: String?, lastRefresh: Date?, throttleNotice: String? = nil,
        throttleRetrying: Bool = false
    ) -> SyncSummary {
        if quarantined {
            return SyncSummary(status: "Needs review", detail: "The iCloud account changed.", tone: .caution)
        }
        if let throttleNotice {
            return throttleRetrying
                ? SyncSummary(status: "Retrying", detail: throttleNotice, tone: .active)
                : SyncSummary(status: "Paused", detail: throttleNotice, tone: .caution)
        }
        if isRefreshing { return SyncSummary(status: "Syncing", detail: nil, tone: .active) }
        if let error { return SyncSummary(status: "Problem", detail: error, tone: .failure) }
        if lastRefresh != nil { return SyncSummary(status: "Fetched", detail: phoneFetchNote, tone: .positive) }
        return SyncSummary(status: "Not synced yet", detail: nil, tone: .neutral)
    }
}
