import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

struct WiltedMacArticle: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let source: String
    let url: URL
    let isReady: Bool
    /// Present once audio exists. The library row states how long an article
    /// takes to listen to, which is the one fact that decides whether to
    /// start it now, and it was the only list in the app that withheld it.
    let durationSeconds: TimeInterval?
    var playbackSeconds: TimeInterval
    /// Whether the durable record says this article is finished.
    var isPlayed: Bool = false
    let createdAt: Date

    init(
        id: String,
        title: String,
        source: String,
        url: URL,
        isReady: Bool,
        durationSeconds: TimeInterval?,
        playbackSeconds: TimeInterval = 0,
        isPlayed: Bool = false,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.url = url
        self.isReady = isReady
        self.durationSeconds = durationSeconds
        self.playbackSeconds = playbackSeconds
        self.isPlayed = isPlayed
        self.createdAt = createdAt
    }
}

enum WiltedMacLibraryOrder: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest"
    case oldest = "Oldest"
    var id: Self { self }
}

/// The Menu's fixed reading order, not a chooser: what can be played right
/// now first, what needs one more step next, what needs two last. The groups
/// are ordered because "available can be downloaded, downloaded can be
/// prepared, prepared can be played" (David, 2026-09-17). `playable` is named
/// for what it means; "Ready" is its on-screen label.
enum WiltedMacMenuGroup: String, CaseIterable, Identifiable, Sendable {
    case playable = "Ready"
    case downloaded = "Downloaded"
    case available = "Available"

    var id: Self { self }

    /// Keep case names stable while using the accepted listener-facing label.
    var displayName: String { self == .available ? "Not downloaded" : rawValue }

    /// The one-line explanation under the group heading.
    var detail: String {
        switch self {
        case .playable: "downloaded and prepared, playable right now"
        case .downloaded: "on this Mac, still to be prepared"
        case .available: "waiting to be downloaded"
        }
    }
}

/// The whole of what a Feeds episode row offers. Feeds asks one question --
/// keep this or skip it -- so every other decision belongs where the episode
/// waits, on the Menu. Declaration order is the row's action order.
enum WiltedMacFeedsAction: String, CaseIterable, Identifiable, Sendable {
    case keep = "Keep"
    case skip = "Skip"

    var id: Self { self }
}

/// Ordering for the Feeds inbox, which is a scan of what arrived, not the
/// listening order the Menu keeps.
enum WiltedMacLarderSort: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest"
    case oldest = "Oldest"
    case shortest = "Length · shortest"
    case show = "Show · A–Z"
    case title = "Title · A–Z"

    var id: Self { self }
}

/// Menu ordering. `custom` is the explicit listening order; every other
/// choice reorders every row except the one playing, which holds its place.
enum WiltedMacMenuSort: String, CaseIterable, Identifiable, Sendable {
    case custom = "Listening order"
    case newest = "Newest"
    case oldest = "Oldest"
    case shortest = "Length · shortest"
    case show = "Show · A–Z"
    case title = "Title · A–Z"

    var id: Self { self }

    /// Keep the persisted raw value stable while presenting the accepted name.
    var displayName: String { self == .custom ? "Custom order" : rawValue }
}

/// How the Larder draws section boundaries. Grouping is presentation only;
/// the durable queue and its independent sort remain the listening order.
enum WiltedMacMenuGrouping: String, CaseIterable, Identifiable, Sendable {
    case feed = "Feed"
    case date = "Date"
    case status = "Status"

    var id: Self { self }
}

struct WiltedMacMenuSection: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
    let statusGroup: WiltedMacMenuGroup?
    let episodes: [WiltedMacEpisode]
}

/// A known-duration total for one queue or status group. Unknown durations
/// stay visible in the count rather than being silently treated as zero.
struct WiltedMacQueueAudioSummary: Equatable, Sendable {
    let seconds: TimeInterval
    let unknownCount: Int

    init(durations: [TimeInterval?]) {
        var seconds = 0.0
        var unknownCount = 0
        for duration in durations {
            guard let duration, duration.isFinite, duration > 0 else {
                unknownCount += 1
                continue
            }
            seconds += duration
        }
        self.seconds = seconds
        self.unknownCount = unknownCount
    }

    init(episodes: [WiltedMacEpisode]) {
        self.init(durations: episodes.map(\.durationSeconds))
    }

    /// Compact, queue-header copy: whole minutes for short queues and hours
    /// plus minutes once the total is long enough to benefit from both.
    var label: String {
        let minutes = Int(ceil(max(0, seconds) / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 { return "\(hours)h \(remainder)m" }
        return "\(minutes)m"
    }

    var detailLabel: String {
        unknownCount == 0 ? label : "\(label) · \(unknownCount) unknown"
    }
}

/// The bounded refresh cadence used while the Mac app remains open.
