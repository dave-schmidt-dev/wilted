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

enum WiltedMacEpisodeDownloadState: Equatable, Sendable {
    case notDownloaded
    case queued
    case downloading(received: Int64, expected: Int64?)
    case completed
    case failed
    case cancelled

    /// Whether the download has been admitted and has not yet settled.
    var isInFlight: Bool {
        switch self {
        case .notDownloaded, .completed, .failed, .cancelled:
            false
        case .queued, .downloading:
            true
        }
    }
}

/// What preparation has done to a downloaded episode, and what it is doing now.
///
/// Preparation is the difference between Wilted and a plain podcast client:
/// the advertisements come out and the transcript is synchronised with what is
/// left. It takes minutes, so the row says which stage it is in rather than
/// going quiet.
enum WiltedMacEpisodePreparationState: Equatable, Sendable {
    case notPrepared
    case preparing(stage: String)
    case prepared(summary: String)
    case failed(String)

    var isRunning: Bool { if case .preparing = self { true } else { false } }

    /// Whether preparation finished successfully. `.notPrepared`, `.preparing`,
    /// and `.failed` all mean the audio behind the row is not the finished
    /// cut, so none of them are safe to hand to continuous playback.
    var isPrepared: Bool { if case .prepared = self { true } else { false } }

    /// The full preparation status, including durable completion summaries.
    /// Surfaces that intentionally suppress completed details use a scoped
    /// presentation such as `larderLabel` instead.
    var label: String? {
        switch self {
        case .notPrepared: nil
        case .preparing(let stage): stage
        case .prepared(let summary): summary
        case .failed(let message): message
        }
    }

    /// The line the Larder row shows under the title.
    ///
    /// A completed summary appears only after the model has matched a successful
    /// terminal journal entry to the audio revision currently ready to play.
    var larderLabel: String? {
        switch self {
        case .notPrepared: nil
        case .preparing(let stage): stage
        case .prepared(let summary): summary
        case .failed(let message): message
        }
    }
}

/// The one primary lifecycle line shown by every episode row.
///
/// Download state owns the line until audio is safely present. This prevents a
/// stale preparation journal from making a queued, failed, or cancelled
/// download look ready to use.
struct WiltedMacEpisodeLifecyclePresentation: Equatable, Sendable {
    let label: String
    let isFailure: Bool

    /// The lifecycle is stable across screens; outcomes are supporting facts,
    /// not a different status for otherwise identical prepared episodes.
    var primaryLabel: String {
        label.components(separatedBy: " · ").first ?? label
    }

    var detailLabel: String? {
        let parts = label.components(separatedBy: " · ")
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: " · ")
    }

    init(
        downloadState: WiltedMacEpisodeDownloadState,
        preparationState: WiltedMacEpisodePreparationState,
        isReadyMediaAvailable: Bool = true
    ) {
        switch downloadState {
        case .notDownloaded:
            label = "Not downloaded"
            isFailure = false
        case .queued:
            label = "Download queued"
            isFailure = false
        case let .downloading(received, expected):
            if let expected, expected > 0 {
                let percent = min(100, max(0, Int((Double(received) / Double(expected)) * 100)))
                label = "Downloading \(percent)%"
            } else if received > 0 {
                label = "Downloading \(received) byte\(received == 1 ? "" : "s")"
            } else {
                label = "Downloading"
            }
            isFailure = false
        case .failed:
            label = "Download failed"
            isFailure = true
        case .cancelled:
            label = "Download cancelled"
            isFailure = false
        case .completed:
            switch preparationState {
            case .notPrepared:
                label = "Downloaded \u{00B7} Ready to prepare"
                isFailure = false
            case let .preparing(stage):
                label = Self.label(primary: "Preparing", detail: stage, removing: "Preparing")
                isFailure = false
            case let .prepared(summary):
                if !isReadyMediaAvailable {
                    label = "Prepared \u{00B7} Local audio missing — Download again"
                    isFailure = true
                } else if summary == "Audio ready · Transcript unavailable" {
                    label = summary
                    isFailure = false
                } else {
                    label = Self.label(primary: "Prepared", detail: summary, removing: "Ready")
                    isFailure = false
                }
            case let .failed(message):
                label = Self.label(primary: "Preparation failed", detail: message, removing: "Preparation failed")
                isFailure = true
            }
        }
    }

    private static func label(primary: String, detail: String, removing prefix: String) -> String {
        var detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix(prefix) {
            detail.removeFirst(prefix.count)
            detail = String(detail.drop(while: { " .:\u{00B7}\u{2026}\t\n".contains($0) }))
        }
        return detail.isEmpty ? primary : "\(primary) \u{00B7} \(detail)"
    }
}

/// One row of the Feeds card: a podcast Wilted follows, and what following it
/// currently yields.
struct WiltedMacSubscription: Identifiable, Hashable, Sendable {
    /// The feed's `ItemID`, which is what the store keys a subscription on.
    let id: String
    let title: String
    let feedURL: URL
    let episodeCount: Int
    let subscribedAt: Date
    var enabled: Bool
}

/// One durable removal shown on Podcast feeds until fresh feed evidence restores it.
struct WiltedMacDismissedEpisode: Identifiable, Hashable, Sendable {
    let id: String
    let feedID: String?
    let title: String
    let feedTitle: String?
    let dismissedAt: Date
    let hasPreparationHistory: Bool
}

struct WiltedMacEpisode: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let feedTitle: String
    /// One line for the row: the notes' opening paragraph when the feed
    /// publishes notes, otherwise the author or the show.
    let summary: String
    /// The feed's show notes in full, for the Now Playing pane.
    var notes: String? = nil
    let artworkURL: URL?
    let releasedAt: Date
    let durationSeconds: TimeInterval?
    var playbackSeconds: TimeInterval
    /// Whether the durable record says this episode is finished.
    ///
    /// Separate from `playbackSeconds` reaching the duration, because the two
    /// answer different questions: audio can stop a few seconds short of the
    /// end and still be finished, and an episode marked finished by hand never
    /// reached the end at all.
    var isPlayed: Bool = false
    /// When the store says this episode left the Larder -- by retirement or
    /// by dismissal, `removalKind` says which. `nil` for an episode still on
    /// the shelf, or for one restored after either removal cleared it.
    var retiredAt: Date? = nil
    /// Which of the two removals took the episode off the shelf, or `nil` if
    /// it is still there. Retirement and dismissal both set `retiredAt`; this
    /// is what distinguishes "finished on its own" rows from "the user
    /// dismissed it" rows now that they share one timestamp.
    var removalKind: PodcastEpisodeRemovalKind? = nil
    var downloadState: WiltedMacEpisodeDownloadState
    var preparationState: WiltedMacEpisodePreparationState = .notPrepared
    /// Whether the ready revision's media file was found on disk the last
    /// time the library loaded. Filesystem-authoritative and deliberately
    /// undurable: no store column backs it, a snapshot just caches a `stat`.
    /// `false` for an episode with no ready revision at all, though that case
    /// never reaches the checks that gate on this flag since those already
    /// require `preparationState.isPrepared`.
    var isReadyMediaAvailable: Bool = true
    /// The feed this episode belongs to, as the store keys it. Optional
    /// because hand-built rows in tests and previews predate the field; the
    /// loaded library always sets it, which is what lets the Feeds card count
    /// the rows the Larder actually draws for one feed.
    var feedID: String? = nil
    /// The feed's canonical subscription URL, when the source record carries
    /// it. Hand-built rows may leave it absent.
    var feedURL: URL? = nil

    var lifecyclePresentation: WiltedMacEpisodeLifecyclePresentation {
        WiltedMacEpisodeLifecyclePresentation(
            downloadState: downloadState,
            preparationState: preparationState,
            isReadyMediaAvailable: isReadyMediaAvailable
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.feedTitle == rhs.feedTitle &&
            lhs.summary == rhs.summary && lhs.notes == rhs.notes && lhs.artworkURL == rhs.artworkURL && lhs.releasedAt == rhs.releasedAt &&
            lhs.durationSeconds == rhs.durationSeconds && lhs.playbackSeconds == rhs.playbackSeconds &&
            lhs.isPlayed == rhs.isPlayed && lhs.retiredAt == rhs.retiredAt && lhs.removalKind == rhs.removalKind &&
            lhs.downloadState == rhs.downloadState && lhs.preparationState == rhs.preparationState &&
            lhs.isReadyMediaAvailable == rhs.isReadyMediaAvailable && lhs.feedID == rhs.feedID &&
            lhs.feedURL == rhs.feedURL
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum WiltedMacLibraryItem: Identifiable, Hashable, Sendable {
    case article(WiltedMacArticle)
    case episode(WiltedMacEpisode)

    var id: String {
        switch self { case .article(let value): value.id; case .episode(let value): value.id }
    }
    var title: String {
        switch self { case .article(let value): value.title; case .episode(let value): value.title }
    }
    var source: String {
        switch self { case .article(let value): value.source; case .episode(let value): value.feedTitle }
    }
    var date: Date {
        switch self { case .article(let value): value.createdAt; case .episode(let value): value.releasedAt }
    }
    /// What a search reads besides the title and the source.
    ///
    /// An episode's show notes are already carried on every row -- the row
    /// leads with their opening paragraph and Now Playing shows the whole of
    /// them -- so they are text the reader has seen and can reasonably expect
    /// to search. An article's body is not carried on the row, so there is
    /// nothing here to match; it is reached instead through the stored
    /// transcript, which is where an article's extracted text lives.
    var searchableDetail: String {
        switch self {
        case .article: ""
        case .episode(let value): value.notes ?? value.summary
        }
    }
    var progress: (position: TimeInterval, duration: TimeInterval?, isPlayed: Bool) {
        switch self {
        case .article(let value): (value.playbackSeconds, value.durationSeconds, value.isPlayed)
        case .episode(let value): (value.playbackSeconds, value.durationSeconds, value.isPlayed)
        }
    }
}

/// Presentation view of one recorded preparation attempt.
///
/// The producer runs one preparation at a time and keeps a journal of every
/// status each attempt emitted. Nothing surfaced that journal, so a run that
/// failed overnight left no trace a reader could find. This is the row shape
/// the Processor destination lists.
