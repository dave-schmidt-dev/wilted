import Foundation
import WiltedDomain
import WiltedProducer

/// What Settings knows about this Mac's lifetime totals.
///
/// Statistics are observed state, never a startup prerequisite: a slow, failed
/// or still-rebuilding summary changes only this value. It never changes
/// `startupState`, so it cannot look like a larder that would not open.
enum WiltedMacStatisticsState: Equatable, Sendable {
    /// The durable summary has not been read yet.
    case loading
    /// The summary is being rebuilt from the ledgers after a migration.
    case rebuilding(WiltedMacStatisticsProgress?)
    /// Seven totals from one durable summary.
    case ready(LifetimeStatisticsSummary)
    /// The summary could not be read or rebuilt. `detail` is diagnostic only.
    case unavailable(detail: String)

    /// The summary's totals, or nil whenever they would be untrue to show.
    var summary: LifetimeStatisticsSummary? {
        if case .ready(let summary) = self { return summary }
        return nil
    }
}

/// Rebuild progress as a share of the ledger rows read so far.
struct WiltedMacStatisticsProgress: Equatable, Sendable {
    let processedEvents: Int
    let totalEvents: Int

    /// 0...1, or nil while the total is unknown or zero. Rows appended during
    /// the rebuild can push `processedEvents` past the total, so it is clamped.
    var fraction: Double? {
        guard totalEvents > 0 else { return nil }
        return min(1, max(0, Double(processedEvents) / Double(totalEvents)))
    }
}

/// The two store operations behind `WiltedMacStatisticsState`, injectable so a
/// delayed, corrupt or failing summary can be driven without a broken store.
struct WiltedMacStatisticsOperations: Sendable {
    /// The O(1) durable summary read.
    let summary: @Sendable (LocalLibraryStore) async throws -> LifetimeStatisticsSummary
    /// The ledger rebuild, reporting progress as it goes.
    let rebuild: @Sendable (
        LocalLibraryStore, @escaping @Sendable (WiltedMacStatisticsProgress) -> Void
    ) async throws -> LifetimeStatisticsSummary

    static let live = WiltedMacStatisticsOperations(
        summary: { store in try await store.lifetimeStatisticsSummary() },
        rebuild: { store, progress in
            try await store.rebuildLifetimeStatisticsSummary { event in
                progress(WiltedMacStatisticsProgress(
                    processedEvents: event.processedEvents, totalEvents: event.totalEvents
                ))
            }
        }
    )
}

/// Copy, identifiers and unit formatting for the seven totals.
///
/// Units are derived from the stored base units (milliseconds, bytes) here and
/// nowhere else, so the displayed value always matches the typed measure.
enum WiltedMacStatisticsCopy {
    static let playedTime = "Time played"
    static let downloaded = "Downloaded"
    static let manuallySkipped = "Time skipped by hand"
    static let playedTimeIdentifier = "wilted-lifetime-played-time"
    static let downloadedIdentifier = "wilted-lifetime-downloaded"
    static let manuallySkippedIdentifier = "wilted-lifetime-skipped-time"
    static let trackingStartIdentifier = "wilted-lifetime-tracking-start"
    static let statusIdentifier = "wilted-lifetime-statistics-status"
    static let retryIdentifier = "wilted-lifetime-statistics-retry"

    static let loading = "Loading lifetime statistics\u{2026}"
    static let rebuilding = "Updating lifetime statistics after the library update\u{2026}"
    static let unavailable = "Lifetime statistics could not be loaded. Your library and playback are not affected."
    static let retry = "Try again"
    static let empty = "Nothing measured yet. Played time, downloads and skips appear here as you use Wilted."
    static let trackingNotStarted = "Measuring has not started on this Mac yet."

    /// Whole minutes, rounded down so a total is never overstated; a nonzero
    /// total under a minute reads "<1 min".
    static func minutes(milliseconds: Int64, locale: Locale = .current) -> String {
        guard milliseconds > 0 else { return "0 min" }
        guard milliseconds >= 60_000 else { return "<1 min" }
        return "\(grouped(Double(milliseconds / 60_000), fractionDigits: 0, locale: locale)) min"
    }

    /// Decimal gigabytes (10^9 bytes) to two places, rounded down; a nonzero
    /// total under 0.01 GB reads "<0.01 GB".
    static func gigabytes(bytes: Int64, locale: Locale = .current) -> String {
        guard bytes > 0 else { return "0 GB" }
        let hundredths = bytes / 10_000_000
        guard hundredths > 0 else { return "<0.01 GB" }
        return "\(grouped(Double(hundredths) / 100, fractionDigits: 2, locale: locale)) GB"
    }

    /// When measuring began, stated as a fact about the data: history before
    /// this date was never measured and is not reconstructed.
    static func trackingStart(_ date: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date else { return trackingNotStarted }
        let style = Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: locale,
            calendar: Calendar(identifier: .gregorian), timeZone: timeZone
        )
        return "Played time, downloads and skips are counted from \(date.formatted(style)). "
            + "Earlier listening was not measured."
    }

    /// True when no total has anything to show.
    static func isEmpty(_ summary: LifetimeStatisticsSummary) -> Bool {
        let legacy = summary.legacy
        return summary.measured == LifetimeMeasuredTotals()
            && legacy.audioProcessedSeconds == 0 && legacy.speechGeneratedSeconds == 0
            && legacy.confirmedAdTimeRemovedSeconds == 0 && legacy.fasterPlaybackTimeSavedSeconds == 0
    }

    private static func grouped(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .floor
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
