import Foundation
import WiltedLibrary

/// Words and numbers for the Settings page. Pure, so the formatting is testable without a view.
enum LibrarySettingsFormat {
    static let unavailable = "Unavailable"

    struct StatRow: Equatable {
        let label: String
        let value: String
        let identifier: String
    }

    /// The Mac's four lifetime rows, in the Mac card's order and words. Every value reads
    /// "Unavailable" until the Mac has published a record.
    static func statRows(_ stats: LibraryStats?) -> [StatRow] {
        func row(_ label: String, _ seconds: Double?, _ identifier: String) -> StatRow {
            StatRow(label: label, value: seconds.map(WiltedDuration.spoken) ?? unavailable, identifier: identifier)
        }
        return [
            row(WiltedScreenCopy.audioProcessed, stats?.audioProcessedSeconds, WiltedScreenCopy.audioProcessedIdentifier),
            row(WiltedScreenCopy.speechGenerated, stats?.speechGeneratedSeconds, WiltedScreenCopy.speechGeneratedIdentifier),
            row(WiltedScreenCopy.confirmedAdTimeRemoved, stats?.confirmedAdTimeRemovedSeconds,
                WiltedScreenCopy.confirmedAdTimeRemovedIdentifier),
            row(WiltedScreenCopy.fasterPlaybackTimeSaved, stats?.fasterPlaybackTimeSavedSeconds,
                WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier),
        ]
    }

    /// Under the card title: whose numbers these are and when the Mac last wrote them.
    static func statsScope(_ stats: LibraryStats?) -> String {
        guard let stats else {
            return "\(WiltedScreenCopy.lifetimeStatisticsScope). Not published yet: open Wilted on the Mac with iCloud sync on."
        }
        guard let updatedAt = stats.updatedAt else { return WiltedScreenCopy.lifetimeStatisticsScope }
        return "\(WiltedScreenCopy.lifetimeStatisticsScope). Updated \(date(updatedAt))."
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

    /// Status in words, so state never rests on color alone. Precedence: an account review blocks
    /// everything, then a running fetch, then the last error, then how fresh the mirror is.
    static func sync(isRefreshing: Bool, quarantined: Bool, error: String?, lastRefresh: Date?) -> SyncSummary {
        if quarantined {
            return SyncSummary(status: "Needs review", detail: "The iCloud account changed.", tone: .caution)
        }
        if isRefreshing { return SyncSummary(status: "Syncing", detail: nil, tone: .active) }
        if let error { return SyncSummary(status: "Problem", detail: error, tone: .failure) }
        if lastRefresh != nil { return SyncSummary(status: "Up to date", detail: nil, tone: .positive) }
        return SyncSummary(status: "Not synced yet", detail: nil, tone: .neutral)
    }
}
