import Foundation
import Observation
import AppKit

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
    let createdAt: Date

    init(
        id: String,
        title: String,
        source: String,
        url: URL,
        isReady: Bool,
        durationSeconds: TimeInterval?,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.url = url
        self.isReady = isReady
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

enum WiltedMacLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case unplayed = "Unplayed"
    case inProgress = "In Progress"
    case finished = "Finished"
    var id: Self { self }
}

enum WiltedMacLibraryOrder: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest"
    case oldest = "Oldest"
    var id: Self { self }
}

/// The bounded refresh cadence used while the Mac app remains open.
enum WiltedAutomationRefreshPolicy: Equatable, Sendable, Codable {
    case manual
    case onLaunch
    case whileOpen(everyHours: Int)

    private enum CodingKeys: String, CodingKey { case kind, everyHours }
    private enum Kind: String, Codable { case manual, onLaunch, whileOpen }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manual: self = .manual
        case .onLaunch: self = .onLaunch
        case .whileOpen:
            let hours = try container.decode(Int.self, forKey: .everyHours)
            guard Self.allowedIntervals.contains(hours) else {
                throw DecodingError.dataCorruptedError(forKey: .everyHours, in: container,
                                                       debugDescription: "Refresh intervals must be 6, 12, or 24 hours.")
            }
            self = .whileOpen(everyHours: hours)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        case .onLaunch:
            try container.encode(Kind.onLaunch, forKey: .kind)
        case let .whileOpen(everyHours: hours):
            guard Self.allowedIntervals.contains(hours) else {
                throw EncodingError.invalidValue(hours, .init(codingPath: encoder.codingPath,
                                                               debugDescription: "Refresh intervals must be 6, 12, or 24 hours."))
            }
            try container.encode(Kind.whileOpen, forKey: .kind)
            try container.encode(hours, forKey: .everyHours)
        }
    }

    var isValid: Bool {
        if case let .whileOpen(everyHours: hours) = self { return Self.allowedIntervals.contains(hours) }
        return true
    }

    private static let allowedIntervals: Set<Int> = [6, 12, 24]
}

/// The bounded automatic-download choices; manual download remains available in every case.
enum WiltedAutomationDownloadPolicy: String, Equatable, Sendable, Codable {
    case manual
    case newestOnePerEnabledFeed
    case newestThreePerEnabledFeed
    case allNewlyAdmittedUpToTwenty

    var maximumEpisodesPerRefresh: Int? {
        if case .allNewlyAdmittedUpToTwenty = self { return 20 }
        return nil
    }
}

/// A local wall-clock time suitable for an off-peak processing window.
struct WiltedAutomationLocalTime: Equatable, Sendable, Codable {
    let hour: Int
    let minute: Int

    private enum CodingKeys: String, CodingKey { case hour, minute }

    init?(hour: Int, minute: Int) {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hour = try container.decode(Int.self, forKey: .hour)
        let minute = try container.decode(Int.self, forKey: .minute)
        guard let time = Self(hour: hour, minute: minute) else {
            throw DecodingError.dataCorruptedError(forKey: .hour, in: container,
                                                   debugDescription: "Local times must use a 24-hour clock.")
        }
        self = time
    }
}

/// A non-empty local processing window. Windows may cross midnight.
struct WiltedAutomationOffPeakWindow: Equatable, Sendable, Codable {
    let start: WiltedAutomationLocalTime
    let end: WiltedAutomationLocalTime

    private enum CodingKeys: String, CodingKey { case start, end }

    init?(start: WiltedAutomationLocalTime, end: WiltedAutomationLocalTime) {
        guard start != end else { return nil }
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(WiltedAutomationLocalTime.self, forKey: .start)
        let end = try container.decode(WiltedAutomationLocalTime.self, forKey: .end)
        guard let window = Self(start: start, end: end) else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: container,
                                                   debugDescription: "Off-peak start and end times must differ.")
        }
        self = window
    }
}

/// When downloaded audio is allowed to enter local preparation.
enum WiltedAutomationProcessingPolicy: Equatable, Sendable, Codable {
    case immediate
    case manual
    case offPeak(WiltedAutomationOffPeakWindow)

    private enum CodingKeys: String, CodingKey { case kind, window }
    private enum Kind: String, Codable { case immediate, manual, offPeak }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .immediate: self = .immediate
        case .manual: self = .manual
        case .offPeak: self = .offPeak(try container.decode(WiltedAutomationOffPeakWindow.self, forKey: .window))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .immediate:
            try container.encode(Kind.immediate, forKey: .kind)
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        case let .offPeak(window):
            try container.encode(Kind.offPeak, forKey: .kind)
            try container.encode(window, forKey: .window)
        }
    }
}

/// The transcript source order selected for future podcast preparation.
enum WiltedAutomationTranscriptPolicy: String, Equatable, Sendable, Codable {
    case bestAvailable
    case alwaysTranscribe
    case noLocalSTT
}

/// Versioned, Mac-local automation preferences. Invalid or newer stored values fall back to `defaults`.
struct WiltedAutomationSettings: Equatable, Sendable, Codable {
    static let currentVersion = 1
    static let defaults = Self(
        refreshPolicy: .manual,
        downloadPolicy: .manual,
        processingPolicy: .immediate,
        transcriptPolicy: .bestAvailable,
        removeAds: true,
        readableTranscriptPass: true
    )

    let version: Int
    let refreshPolicy: WiltedAutomationRefreshPolicy
    let downloadPolicy: WiltedAutomationDownloadPolicy
    let processingPolicy: WiltedAutomationProcessingPolicy
    let transcriptPolicy: WiltedAutomationTranscriptPolicy
    let removeAds: Bool
    let readableTranscriptPass: Bool

    init(refreshPolicy: WiltedAutomationRefreshPolicy, downloadPolicy: WiltedAutomationDownloadPolicy,
         processingPolicy: WiltedAutomationProcessingPolicy, transcriptPolicy: WiltedAutomationTranscriptPolicy,
         removeAds: Bool, readableTranscriptPass: Bool) {
        version = Self.currentVersion
        self.refreshPolicy = refreshPolicy
        self.downloadPolicy = downloadPolicy
        self.processingPolicy = processingPolicy
        self.transcriptPolicy = transcriptPolicy
        self.removeAds = removeAds
        self.readableTranscriptPass = readableTranscriptPass
    }

    private enum CodingKeys: String, CodingKey {
        case version, refreshPolicy, downloadPolicy, processingPolicy, transcriptPolicy, removeAds, readableTranscriptPass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                                                   debugDescription: "Unsupported automation settings version.")
        }
        let refreshPolicy = try container.decode(WiltedAutomationRefreshPolicy.self, forKey: .refreshPolicy)
        guard refreshPolicy.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .refreshPolicy, in: container,
                                                   debugDescription: "Invalid refresh policy.")
        }
        self.version = version
        self.refreshPolicy = refreshPolicy
        downloadPolicy = try container.decode(WiltedAutomationDownloadPolicy.self, forKey: .downloadPolicy)
        processingPolicy = try container.decode(WiltedAutomationProcessingPolicy.self, forKey: .processingPolicy)
        transcriptPolicy = try container.decode(WiltedAutomationTranscriptPolicy.self, forKey: .transcriptPolicy)
        removeAds = try container.decode(Bool.self, forKey: .removeAds)
        readableTranscriptPass = try container.decode(Bool.self, forKey: .readableTranscriptPass)
    }

    func encode(to encoder: Encoder) throws {
        guard version == Self.currentVersion, refreshPolicy.isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                          debugDescription: "Automation settings must be current and valid."))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(refreshPolicy, forKey: .refreshPolicy)
        try container.encode(downloadPolicy, forKey: .downloadPolicy)
        try container.encode(processingPolicy, forKey: .processingPolicy)
        try container.encode(transcriptPolicy, forKey: .transcriptPolicy)
        try container.encode(removeAds, forKey: .removeAds)
        try container.encode(readableTranscriptPass, forKey: .readableTranscriptPass)
    }

    var isValid: Bool { version == Self.currentVersion && refreshPolicy.isValid }
}

enum WiltedMacEpisodeDownloadState: Equatable, Sendable {
    case notDownloaded
    case queued
    case downloading(received: Int64, expected: Int64?)
    case completed
    case failed
    case cancelled
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

    /// The line the row shows under the title, or nil when there is nothing
    /// worth saying.
    var label: String? {
        switch self {
        case .notPrepared: nil
        case .preparing(let stage): stage
        case .prepared(let summary): summary
        case .failed(let message): message
        }
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
    let playbackSeconds: TimeInterval
    /// Whether the durable record says this episode is finished.
    ///
    /// Separate from `playbackSeconds` reaching the duration, because the two
    /// answer different questions: audio can stop a few seconds short of the
    /// end and still be finished, and an episode marked finished by hand never
    /// reached the end at all.
    var isPlayed: Bool = false
    var downloadState: WiltedMacEpisodeDownloadState
    var preparationState: WiltedMacEpisodePreparationState = .notPrepared

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.feedTitle == rhs.feedTitle &&
            lhs.summary == rhs.summary && lhs.notes == rhs.notes && lhs.artworkURL == rhs.artworkURL && lhs.releasedAt == rhs.releasedAt &&
            lhs.durationSeconds == rhs.durationSeconds && lhs.playbackSeconds == rhs.playbackSeconds &&
            lhs.isPlayed == rhs.isPlayed &&
            lhs.downloadState == rhs.downloadState && lhs.preparationState == rhs.preparationState
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
    var progress: (position: TimeInterval, duration: TimeInterval?) {
        switch self {
        case .article(let value): (0, value.durationSeconds)
        case .episode(let value): (value.playbackSeconds, value.durationSeconds)
        }
    }
}

/// Presentation view of one recorded preparation attempt.
///
/// The producer runs one preparation at a time and keeps a journal of every
/// status each attempt emitted. Nothing surfaced that journal, so a run that
/// failed overnight left no trace a reader could find. This is the row shape
/// the Processor destination lists.
struct WiltedMacProcessorRun: Identifiable, Equatable, Sendable {
    enum Outcome: String, Sendable {
        case running, succeeded, failed, cancelled
    }

    let id: String
    /// The item the run prepared; a podcast run's is an episode id.
    let itemID: String
    let isPodcast: Bool
    let title: String
    let source: String
    let stage: String
    /// The last thing the run said, in the pipeline's own words.
    let detail: String
    /// The last thing the run said, in the listener's words: "Finding
    /// advertisements…" rather than `ads.detect.calls`.
    let narrative: String
    let fraction: Double?
    let outcome: Outcome
    let updatedAt: Date
    /// Everything the run journalled, oldest first. Shown when the reader has
    /// asked for the detailed log.
    let events: [WiltedMacProcessorEvent]
    /// The original-to-prepared mapping from a successful podcast terminal.
    /// It is intentionally sourced from the journal, not reconstructed from
    /// summary prose after a relaunch.
    let timeline: PreparationStatus.PreparationTimeline?

    init(id: String, itemID: String, isPodcast: Bool, title: String, source: String, stage: String,
         detail: String, narrative: String? = nil, fraction: Double?, outcome: Outcome, updatedAt: Date,
         events: [WiltedMacProcessorEvent] = [], timeline: PreparationStatus.PreparationTimeline? = nil) {
        self.id = id
        self.itemID = itemID
        self.isPodcast = isPodcast
        self.title = title
        self.source = source
        self.stage = stage
        self.detail = detail
        self.narrative = narrative ?? detail
        self.fraction = fraction
        self.outcome = outcome
        self.updatedAt = updatedAt
        self.events = events
        self.timeline = timeline
    }

    /// Colour is emphasis only; `outcomeLabel` always states the outcome.
    var tone: WiltedStatusTone {
        switch outcome {
        case .running: .active
        case .succeeded: .positive
        case .cancelled: .neutral
        case .failed: .failure
        }
    }

    var outcomeLabel: String {
        switch outcome {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// One journalled status of a preparation run.
struct WiltedMacProcessorEvent: Identifiable, Equatable, Sendable {
    let id: String
    let at: Date
    /// The pipeline's own stage name, such as `ads.detect.calls`.
    let stage: String
    let detail: String
    let fraction: Double?

    /// "stage · detail", or just the stage when the run said nothing more.
    var line: String {
        detail.isEmpty || detail == stage ? stage : "\(stage) · \(detail)"
    }
}

/// Presentation view of a stored transcript.
///
/// The domain `Transcript` lives behind `canImport(WiltedProducer)`, so the
/// producer keeps a local shape here for the same reason `WiltedMacArticle`
/// exists: the views stay compilable without the producer package, and UI code
/// never handles a domain type directly.
/// One timed line of a transcript, in the audio's own clock.
struct WiltedMacTranscriptCue: Identifiable, Equatable, Sendable {
    /// Position in the transcript. Start times can repeat across cues in a
    /// published caption file, so the index is what identifies a row.
    let id: Int
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
}

struct WiltedMacTranscript: Equatable, Sendable {
    enum Availability: String, Sendable {
        case available
        case stale
        case oversized
        case malformed
        case absent
    }

    let availability: Availability
    let text: String?
    /// Empty unless the transcript's timing was measured against this exact
    /// audio. An estimate is not timing and never appears here.
    var cues: [WiltedMacTranscriptCue] = []
    /// Whether the timing came from the publisher or from Wilted's own pass.
    var timingSource: String?

    /// A transcript that can follow the playback clock.
    var isSynchronized: Bool { isReadable && !cues.isEmpty }

    /// The cue covering `seconds`, for a reader following playback.
    ///
    /// Binary search rather than a scan: this runs on every readout tick, and
    /// a three-hour episode carries thousands of cues.
    func cueIndex(at seconds: TimeInterval) -> Int? {
        guard !cues.isEmpty, seconds >= cues[0].startSeconds else { return nil }
        var low = 0, high = cues.count - 1, found = 0
        while low <= high {
            let middle = (low + high) / 2
            if cues[middle].startSeconds <= seconds { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return found
    }

    var isReadable: Bool {
        (availability == .available || availability == .stale) && !(text ?? "").isEmpty
    }

    /// Says why text is missing instead of silently showing nothing. The
    /// listener already did this; the producer showed no transcript at all.
    var unavailableLabel: String {
        switch availability {
        case .oversized: "Transcript unavailable: article text is too large"
        case .malformed: "Transcript unavailable: article text could not be read"
        case .absent, .available, .stale: "Transcript unavailable"
        }
    }

    var disclosureTitle: String {
        if availability == .stale { return "Transcript (may be outdated)" }
        guard let timingSource else { return "Transcript" }
        return "Transcript · \(timingSource)"
    }

    /// The listener always shows this row and explains why text is missing.
    /// The producer rendered nothing at all when it had no transcript loaded,
    /// so this is what a missing one resolves to.
    static let unavailable = WiltedMacTranscript(availability: .absent, text: nil)
}

/// One advertisement preparation cut out of an episode, placed where the cut
/// shows up in the audio the listener is actually hearing.
///
/// The seam is on the prepared clock because that is what the transcript and
/// the scrubber are counting in; the span is on the original clock because
/// that is what the cut removed, and it is what Prep reports for the same run.
struct WiltedMacRemovedSpan: Identifiable, Equatable, Sendable {
    let id: Int
    /// Where the cut lands in the prepared audio.
    let preparedSeconds: TimeInterval
    let originalStartSeconds: TimeInterval
    let originalEndSeconds: TimeInterval
    /// The worker's normalized name for what it removed.
    let label: String

    var durationSeconds: TimeInterval { max(0, originalEndSeconds - originalStartSeconds) }

    /// Reads as one line in the transcript, where it stands between two spoken
    /// lines and has to say what is missing without being mistaken for speech.
    var summary: String {
        "Ad removed · \(WiltedDuration.clock(durationSeconds))"
            + " · original \(WiltedDuration.clock(originalStartSeconds))–\(WiltedDuration.clock(originalEndSeconds))"
    }
}

struct WiltedMacPreparation: Equatable, Sendable {
    enum Phase: String, Sendable {
        case preparing
        case extracting
        case synthesizing
        case assembling
        case saving
        case cancelling
        case completed
        case cancelled
        case failed

        var title: String {
            switch self {
            case .preparing: "Preparing article"
            case .extracting: "Extracting article"
            case .synthesizing: "Generating speech"
            case .assembling: "Assembling audio"
            case .saving: "Saving revision"
            case .cancelling: "Cancelling preparation"
            case .completed: "Ready to play"
            case .cancelled: "Preparation cancelled"
            case .failed: "Preparation failed"
            }
        }

        /// A finished run. The Processor destination shows the active card
        /// only while work is genuinely in flight.
        var isTerminal: Bool {
            switch self {
            case .completed, .cancelled, .failed: true
            default: false
            }
        }
    }

    let phase: Phase
    let detail: String
    let fraction: Double?
    let cancellable: Bool
}

/// The producer's permanent destinations.
///
/// Library, feeds, preparation, and settings remain work destinations.
/// Playback is owned by the persistent bottom rail instead of competing for
/// navigation. Feeds is its own destination because Larder is for the things
/// worth reading and listening to; which sources supply them is upkeep, and it
/// was pushing the actual library below the fold.
enum WiltedMacNavigation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case library
    case feeds
    case processor
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .library: WiltedScreenCopy.library
        case .feeds: WiltedScreenCopy.feeds
        case .processor: WiltedScreenCopy.processor
        case .settings: WiltedScreenCopy.settings
        }
    }

    var symbolName: String {
        switch self {
        case .library: WiltedSymbol.larder.rawValue
        case .feeds: WiltedSymbol.broccoli.rawValue
        case .processor: WiltedSymbol.prep.rawValue
        case .settings: "gearshape"
        }
    }
}

#if canImport(WiltedProducer)
typealias WiltedMacStoreBootstrap = @Sendable (URL) async throws -> LocalLibraryStore
#endif

struct WiltedMacStartupFailure: Equatable, Sendable {
    let message: String
    let detail: String?
    let retainedV5StoreURL: URL?
    let canRetry: Bool
}

enum WiltedMacStartupState: Equatable, Sendable {
    case loading(attempt: Int)
    case ready
    case failed(WiltedMacStartupFailure)
}

/// Main-actor presentation state for the local Mac producer.
@Observable
@MainActor
final class WiltedMacModel {
    private static let maximumStartupAttempts = 2

    private(set) var startupState: WiltedMacStartupState = .loading(attempt: 0)
    var urlDraft = ""
    var podcastFeedDraft = ""
    /// What the single add box is doing right now. Telling a feed from an
    /// article needs the document, so the button can sit on a network round
    /// trip; an unannounced pause there reads as a control that did nothing.
    private(set) var linkDraftStatus: String?
    /// A feed the page just added advertises. Offered, never taken: following a
    /// site's whole feed is a different request from saving one article of it.
    private(set) var advertisedFeed: URL?
    private(set) var podcastFeedDraftStatus: String?
    private(set) var isCheckingPodcastSubscription = false
    /// Identifies the in-flight subscription check, so a cancelled one cannot
    /// write over its successor's state when it finally resumes.
    private var podcastSubscriptionCheckGeneration = 0
    static let podcastCheckInProgressStatus = "Checking that address\u{2026}"
    static let podcastCheckCancelledStatus = "Podcast check cancelled."
    /// The feed a duplicate subscription attempt pointed back at.
    private(set) var selectedPodcastFeedID: String?
    private(set) var lastPodcastRefreshNewEpisodeIDs: [String] = []
    /// Episodes the last refresh loaded but did not keep, either because the
    /// feed exceeded the client's episode ceiling or because they published
    /// before the subscription. Reported so a partial view of a feed is never
    /// presented as the whole feed.
    var withheldPodcastEpisodeCount = 0
    var librarySearchQuery = ""
    var libraryFilter: WiltedMacLibraryFilter = .all
    /// Survives relaunch: a listener who reads the Larder oldest-first should
    /// not have to say so again every time the app opens.
    var libraryOrder: WiltedMacLibraryOrder = .newest {
        didSet { preferences.set(libraryOrder.rawValue, forKey: Self.libraryOrderPreferenceKey) }
    }
    static let libraryOrderPreferenceKey = "wilted.library.order"
    /// The last speed the owner chose. It seeds every load that has no
    /// per-episode speed of its own, so 1.25× chosen once stays 1.25×.
    static let playbackRatePreferenceKey = "wilted.playback.rate"
    static let initialPlaybackRate = 1.25
    /// The speeds the rate control offers, and the same list the system widget
    /// is told about. One array, because two would drift and the widget would
    /// offer a speed the app refuses.
    static let playbackRateChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// Transport step sizes. Asymmetric on purpose: a listener rewinds to hear
    /// something again and skips forward past an advertisement, and those are
    /// not the same distance. Published to the system so a media key's skip
    /// matches the button's.
    static let backwardSkipSeconds: Double = 15
    static let forwardSkipSeconds: Double = 30
    static let automationSettingsPreferenceKey = "wilted.automation.settings"
    static let textScalePreferenceKey = "wilted.appearance.textScale"
    /// When automation last completed a refresh.
    ///
    /// Kept in preferences rather than the store because losing it costs one
    /// extra idempotent refresh and nothing else. Claims, which cannot be
    /// reconstructed, live in the store instead.
    static let lastAutomationRefreshPreferenceKey = "wilted.automation.lastRefreshSuccess"
    private let preferences: UserDefaults
    /// Automation reads this one validated value, never individual preference keys.
    private(set) var automationSettings = WiltedAutomationSettings.defaults
    /// How much bigger than the system's own text the window draws itself.
    ///
    /// The Mac has no Dynamic Type to inherit, so the app carries this and the
    /// root hands it to every surface through the environment. `.large` is the
    /// default because 13pt is the system's body size and this is a window
    /// read across a room as often as at a desk.
    private(set) var textScale: WiltedTheme.TextScale = .large
    /// What automation is doing, so Settings can show it and a listener can stop it.
    private(set) var automationStatus: WiltedAutomationStatus = .idle
    var selectedNavigation: WiltedMacNavigation = .library
    private(set) var articles: [WiltedMacArticle] = []
    private(set) var episodes: [WiltedMacEpisode] = []
    private(set) var podcastOperationMessage: String?
    private(set) var isRefreshingPodcasts = false
    private(set) var selectedLibraryItemID: String?
    private(set) var preparation: WiltedMacPreparation?
    private(set) var selectedArticleID: String?
    private(set) var isNowPlaying = false
    private(set) var isPlaying = false
    /// Whether what is loaded in the player is already recorded as finished.
    ///
    /// Mirrored from the controller rather than read through it, because the
    /// controller is not observable: a view reading `playback.completed`
    /// directly would render the value it saw when it was last redrawn for
    /// some other reason.
    private(set) var playbackCompleted = false
    private(set) var playbackError: String?
    /// Readout state the listener already published. The producer's player
    /// showed transports and nothing else, so the Mac could not answer "how
    /// far in am I?" — a question the same audio answers on iPhone.
    private(set) var playbackPositionSeconds: TimeInterval = 0
    private(set) var playbackDurationSeconds: TimeInterval = 0
    /// Every recorded preparation attempt, newest first.
    private(set) var processorRuns: [WiltedMacProcessorRun] = []
    /// Preparations waiting for the single run slot, nearest turn first. The
    /// journal cannot supply this: a waiting run has emitted nothing yet.
    private(set) var preparationQueue = WiltedMacPreparationQueue()
    private(set) var processorOperationMessage: String?
    /// Progress for an in-flight transcript backfill (W-INV-001: a network
    /// fetch never runs without the surface saying so).
    private(set) var transcriptBackfillStatus: String?
    private(set) var isBackfillingTranscript = false
    private(set) var currentTranscript: WiltedMacTranscript?
    private(set) var podcastQueueIDs: [String] = []
    private(set) var currentPodcastEpisodeID: String?
    /// Removed spans per episode, filled in as each episode's transcript
    /// loads. Keyed rather than held as one current value so that changing
    /// episode cannot leave the previous episode's cuts on screen.
    private var removedSpansByEpisode: [String: [WiltedMacRemovedSpan]] = [:]
    private(set) var playbackRate: Double = WiltedMacModel.initialPlaybackRate
    private(set) var playbackVolume: Double = 1
    private(set) var playbackOperationStatus: String?
    private(set) var articlePublicationCount = 0
    private(set) var articlePlaybackCheckpointCount = 0
    /// Set only when a route operation actually failed. The recovery control
    /// is gated on this so it does not advertise a fix for a fault that has
    /// not happened, matching how every other recovery control here behaves.
    private(set) var audioRouteFault = false

    let fixtureMode: Bool

#if canImport(WiltedProducer)
    private var store: LocalLibraryStore?
    private var coordinator: PreparationCoordinator?
    private var playback: PlaybackController?
    private var syncLifecycle: WiltedMacSyncLifecycle?
    /// Podcast feeds Wilted follows, newest subscription first.
    var subscriptions: [WiltedMacSubscription] = []
    /// Durable removals remain visible even when no feed is subscribed.
    private(set) var dismissedEpisodes: [WiltedMacDismissedEpisode] = []

    private let libraryURL: URL
    private let mediaDirectory: URL
    private let syncTransportFactory: WiltedMacSyncTransportFactory?
    private let assetResolver: LocalLibraryAssetResolver
    private let storeBootstrap: WiltedMacStoreBootstrap
    private let retainedArtifactPresenter: (URL) -> Void
    private var startupAttemptCount = 0
    private var startupTask: Task<Void, Never>?
    private var pendingSyncReconciliation = false
    private var preparationRun: PreparationRun?
    private var preparationTask: Task<Void, Never>?
    private var syncReconciliationTask: Task<Void, Never>?
    private var podcastRefreshTask: Task<Void, Never>?
    /// The system's media widget, and the media keys that drive it. Both are
    /// injected and both are optional: they are process-global system state, so
    /// a unit test or a UI fixture that built them for real would repoint the
    /// machine's Now Playing widget at a fixture and capture its media keys.
    private let nowPlayingSink: (any WiltedNowPlayingSink)?
    private let remoteCommandSource: (any WiltedRemoteCommandSource)?
    /// The last thing published, so an unchanged readout is not republished
    /// once a second for the life of an episode.
    private var lastPublishedNowPlaying: WiltedNowPlayingInfo?
#if canImport(WiltedProducer)
    private var automation: WiltedAutomationCoordinator?
    private var automationTask: Task<Void, Never>?
    private var automationTicker: Task<Void, Never>?
    private var playbackCheckpointTicker: Task<Void, Never>?
#endif
    private var podcastDownloadTasks: [String: Task<Void, Never>] = [:]
    private var podcastDownloadCoordinator: PodcastDownloadCoordinator?
    private var podcastPreparationPipeline: PodcastPreparationPipeline?
    private var podcastPreparationTasks: [String: Task<Void, Never>] = [:]
    /// One preparation runs at a time; the rest queue. See
    /// `WiltedPreparationGate` for why concurrent runs cost work rather
    /// than saving time.
    private let preparationGate = WiltedPreparationGate()
    private var podcastRestoreTasks: [String: Task<Void, Never>] = [:]
    /// Removing advertisements is why preparation exists. Read once, when the
    /// pipeline is built, so this is not a switch: a Settings control would
    /// have to rebuild the pipeline to mean anything, and none exists yet.
    private let removesAdvertisements = true
    private var hiddenEpisodeIDs: Set<String> = []
    private var fixtureDownloadFailuresRemaining = 0
    /// The podcast fixture episode starts out prepared, so the UI test can
    /// prove a prepared row still offers a way to prepare again.
    private var fixtureEpisodeIsPrepared = false
    private let podcastFeedClient: PodcastFeedClient
    private let pastedLinkClassifier: PastedLinkClassifier
    private var linkClassificationTask: Task<Void, Never>?
    private var podcastSubscriptionClassificationTask: Task<Void, Never>?
    private var fixtureRevision: StoredAudioRevision?
    private var fixturePodcastInstallTask: Task<Void, Never>?
    private var playbackOperationTask: Task<Void, Never>?
    private var isPodcastPlayback = false
#endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         syncTransportFactory: WiltedMacSyncTransportFactory? = nil,
         assetResolver: @escaping LocalLibraryAssetResolver = { _, _ in nil },
         stateDirectoryOverride: URL? = nil,
         storeBootstrap: WiltedMacStoreBootstrap? = nil,
         retainedArtifactPresenter: ((URL) -> Void)? = nil,
         podcastFeedClient: PodcastFeedClient = PodcastFeedClient(),
         pastedLinkClassifier: PastedLinkClassifier = PastedLinkClassifier(),
         nowPlayingSink: (any WiltedNowPlayingSink)? = nil,
         remoteCommandSource: (any WiltedRemoteCommandSource)? = nil,
         preferences: UserDefaults) {
        let usesFixtureMode = Self.isFixtureLaunch(arguments: arguments)
        fixtureMode = usesFixtureMode
        self.nowPlayingSink = nowPlayingSink
        self.remoteCommandSource = remoteCommandSource
        // Required rather than defaulted to `.standard`: the unit-test host is
        // the app bundle itself, so a defaulted `.standard` let tests write
        // into the daily driver's own preferences.
        self.preferences = usesFixtureMode ? Self.fixturePreferences() : preferences

#if canImport(WiltedProducer)
        let stateDirectory = stateDirectoryOverride ?? Self.stateDirectory(fixtureMode: usesFixtureMode)
        self.libraryURL = stateDirectory.appendingPathComponent("library.sqlite")
        self.mediaDirectory = stateDirectory.appendingPathComponent("media", isDirectory: true)
        self.syncTransportFactory = syncTransportFactory
        self.assetResolver = assetResolver
        self.storeBootstrap = storeBootstrap ?? { url in
            try await Task.detached(priority: .userInitiated) {
                try LocalLibraryStore(url: url)
            }.value
        }
        self.retainedArtifactPresenter = retainedArtifactPresenter ?? { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        self.podcastFeedClient = podcastFeedClient
        self.pastedLinkClassifier = pastedLinkClassifier
        fixtureDownloadFailuresRemaining = arguments.contains("--wilted-ui-fixture-download-failure") ? 1 : 0
        fixtureEpisodeIsPrepared = arguments.contains("--wilted-ui-fixture-prepared")

        if usesFixtureMode {
            let configuredStore = try? LocalLibraryStore(url: self.libraryURL)
            configureStoreDependencies(configuredStore)
            startupState = configuredStore == nil
                ? .failed(Self.startupFailure(canRetry: false))
                : .ready
            installFixture(
                ready: arguments.contains("--wilted-ui-fixture-ready") || arguments.contains("--wilted-ui-fixture-playing"),
                preparing: arguments.contains("--wilted-ui-fixture-preparing"),
                podcasts: arguments.contains("--wilted-ui-fixture-podcasts")
            )
            if arguments.contains("--wilted-ui-fixture-quarantined") {
                syncLifecycle?.quarantineAccount()
            }
            if arguments.contains("--wilted-ui-fixture-playing"), let firstArticle = articles.first(where: { $0.isReady }) {
                openNowPlaying(for: firstArticle)
                togglePlayback()
            }
        }
#else
        _ = arguments
#endif
        if let stored = self.preferences.string(forKey: Self.libraryOrderPreferenceKey),
           let order = WiltedMacLibraryOrder(rawValue: stored) {
            libraryOrder = order
        }
        if self.preferences.object(forKey: Self.playbackRatePreferenceKey) != nil {
            playbackRate = Self.clampPlaybackRate(self.preferences.double(forKey: Self.playbackRatePreferenceKey))
        }
        automationSettings = Self.loadAutomationSettings(from: self.preferences)
        textScale = Self.loadTextScale(from: self.preferences)
#if canImport(WiltedProducer)
        // Fixture launches build their controller above, before the stored
        // rate is known; production builds it later, in
        // `configureStoreDependencies`, which reads the rate itself.
        playback?.defaultRate = Float(playbackRate)
#endif
        installRemoteCommands()
    }

    /// Whether these launch arguments drive the app from a fixture.
    ///
    /// Static because the decision is needed before a model exists: the app
    /// consults it to decide whether to hand over the machine's Now Playing
    /// widget and media keys, and a fixture run must not get them.
    static func isFixtureLaunch(arguments: [String]) -> Bool {
        arguments.contains("--wilted-ui-fixture-article-flow")
            || arguments.contains("--wilted-ui-fixture-quarantined")
            || arguments.contains("--wilted-ui-smoke")
            || arguments.contains("--wilted-ui-fixture-ready")
            || arguments.contains("--wilted-ui-fixture-playing")
            || arguments.contains("--wilted-ui-fixture-preparing")
            || arguments.contains("--wilted-ui-fixture-podcasts")
            || arguments.contains("--wilted-ui-fixture-download-failure")
    }

    /// Whether this process is running the unit tests.
    ///
    /// The unit-test host is the app bundle itself, so the model cannot tell a
    /// test run from a launch by argument alone; XCTest's own environment
    /// variable is the only thing that separates them.
    static var hostsTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

#if canImport(WiltedProducer)
    /// The audio backend this process should own.
    ///
    /// A UI fixture launch gets the scripted backend it has always had. A unit
    /// test host gets the real one with its output silenced, because the tests
    /// run inside this bundle and one that plays an episode plays it aloud on
    /// the owner's machine.
    private static func playbackBackend(fixtureMode: Bool) -> any PlaybackBackend {
        if fixtureMode { return WiltedFixturePlaybackBackend() }
        if hostsTests { return WiltedSilentPlaybackBackend() }
        return AVAudioPlayerBackend()
    }
#endif

    private static func clampPlaybackRate(_ value: Double) -> Double {
        min(max(value.isFinite ? value : initialPlaybackRate, 0.5), 2)
    }

    /// Stores only a complete, current settings envelope for a later automation coordinator.
    func setAutomationSettings(_ settings: WiltedAutomationSettings) {
        guard settings.isValid, let data = try? JSONEncoder().encode(settings) else { return }
        automationSettings = settings
        preferences.set(data, forKey: Self.automationSettingsPreferenceKey)
    }

    func setTextScale(_ scale: WiltedTheme.TextScale) {
        textScale = scale
        preferences.set(scale.rawValue, forKey: Self.textScalePreferenceKey)
    }

    /// An absent or unrecognised value takes the default rather than the
    /// smallest step, so a preference written by a later version that named a
    /// step this one does not know does not silently shrink the window.
    static func loadTextScale(from preferences: UserDefaults) -> WiltedTheme.TextScale {
        guard let raw = preferences.string(forKey: textScalePreferenceKey),
              let scale = WiltedTheme.TextScale(rawValue: raw) else { return .large }
        return scale
    }

    private static func loadAutomationSettings(from preferences: UserDefaults) -> WiltedAutomationSettings {
        guard let data = preferences.data(forKey: automationSettingsPreferenceKey),
              let settings = try? JSONDecoder().decode(WiltedAutomationSettings.self, from: data),
              settings.isValid else {
            return .defaults
        }
        return settings
    }

    // MARK: - App-open automation

    var lastAutomationRefreshAt: Date? {
        preferences.object(forKey: Self.lastAutomationRefreshPreferenceKey) as? Date
    }

    private func setLastAutomationRefresh(_ date: Date) {
        preferences.set(date, forKey: Self.lastAutomationRefreshPreferenceKey)
    }

    private func setAutomationStatus(_ status: WiltedAutomationStatus) {
        automationStatus = status
    }

    /// How often an open window re-evaluates the policy.
    ///
    /// Coarse on purpose: the evaluation is a pure function of settings and a
    /// stored timestamp, and this exists only so a window left open overnight
    /// still notices the next due refresh.
    static let automationTickInterval: TimeInterval = 900

    /// How often playback progress is written to the store while audio runs.
    ///
    /// Progress was persisted only on an explicit transport press or a clean
    /// quit, so anything that ended the process without one -- an installer
    /// replacing the app, a force quit, a crash, a power loss -- rewound the
    /// listener to wherever they last pressed a button. Ten seconds bounds
    /// what such an exit can cost. It is a local store write, and only an
    /// article's checkpoint is queued for sync, so the tick does not touch
    /// CloudKit.
    static let playbackCheckpointInterval: TimeInterval = 10

    /// Resumes last session's claims, then evaluates this launch.
    ///
    /// Sequential, and started only once the library has loaded. The coordinator
    /// runs one pass at a time, so firing both concurrently would drop one, and
    /// resuming a claim before `episodes` is populated would fault every
    /// recovered download.
    func startAutomationOnLaunch() {
#if canImport(WiltedProducer)
        guard !fixtureMode, let coordinator = automationCoordinator() else { return }
        automationTask = Task {
            await coordinator.reconcile()
            await coordinator.run(trigger: .launch)
        }
#endif
    }

    /// Starts the open-window tick. Idempotent, so repeated scene callbacks are
    /// harmless.
    func startAutomationTicker(interval: TimeInterval = WiltedMacModel.automationTickInterval) {
#if canImport(WiltedProducer)
        guard !fixtureMode, automationTicker == nil, store != nil else { return }
        automationTicker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                self?.runAutomation(trigger: .openWindowTick)
            }
        }
#endif
    }

    func stopAutomationTicker() {
#if canImport(WiltedProducer)
        automationTicker?.cancel()
        automationTicker = nil
#endif
    }

    /// Whether the open-window tick is live. Read by tests, because the scene
    /// stops the ticker when the app is hidden and has to start it again on the
    /// way back, and nothing else makes that visible.
    var automationTickerIsRunning: Bool {
#if canImport(WiltedProducer)
        automationTicker != nil
#else
        false
#endif
    }

    /// Starts the playback progress tick. Idempotent.
    ///
    /// Deliberately not stopped when the app loses focus, unlike the
    /// automation tick: audio keeps running with the window closed, and that
    /// is precisely when nothing else is checkpointing.
    func startPlaybackCheckpointTicker(interval: TimeInterval = WiltedMacModel.playbackCheckpointInterval) {
#if canImport(WiltedProducer)
        guard !fixtureMode, playbackCheckpointTicker == nil, store != nil else { return }
        playbackCheckpointTicker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                await self?.checkpointPlaybackIfAdvancing()
            }
        }
#endif
    }

    func stopPlaybackCheckpointTicker() {
#if canImport(WiltedProducer)
        playbackCheckpointTicker?.cancel()
        playbackCheckpointTicker = nil
#endif
    }

    var playbackCheckpointTickerIsRunning: Bool {
#if canImport(WiltedProducer)
        playbackCheckpointTicker != nil
#else
        false
#endif
    }

    /// One tick. Writes only while the engine is actually advancing, so a
    /// paused or finished item does not rewrite the same row every interval.
    func checkpointPlaybackIfAdvancing() async {
#if canImport(WiltedProducer)
        guard let playback, playback.liveIsPlaying else { return }
        try? await playback.checkpoint()
#endif
    }

    /// Evaluates the automation policy and runs one pass if it is due.
    ///
    /// Called when the window opens and on the open-window tick. Both go through
    /// the same coordinator, so the policy is decided in one place rather than
    /// at each call site.
    func runAutomation(trigger: WiltedAutomationTrigger) {
#if canImport(WiltedProducer)
        guard !fixtureMode, let coordinator = automationCoordinator() else { return }
        automationTask = Task { await coordinator.run(trigger: trigger) }
#endif
    }

    /// Resumes claims that outlived the process that made them.
    func reconcileAutomation() {
#if canImport(WiltedProducer)
        guard !fixtureMode, let coordinator = automationCoordinator() else { return }
        automationTask = Task { await coordinator.reconcile() }
#endif
    }

    /// Stops the pass in flight. Claims stay durable and the next launch
    /// reconciles them, so stopping loses no eligibility.
    func cancelAutomation() {
#if canImport(WiltedProducer)
        let coordinator = automation
        automationTask?.cancel()
        automationTask = nil
        Task { await coordinator?.cancel() }
        automationStatus = .cancelled
#endif
    }

    /// Deterministic test seam; production does not wait on this task.
    func waitForAutomation() async {
#if canImport(WiltedProducer)
        await automationTask?.value
#endif
    }

#if canImport(WiltedProducer)
    private func automationCoordinator() -> WiltedAutomationCoordinator? {
        if let automation { return automation }
        guard store != nil else { return nil }
        let coordinator = WiltedAutomationCoordinator(
            operations: .init(
                enabledFeedURLs: { [weak self] in
                    guard let self else { return [] }
                    return try await self.automationFeedURLs()
                },
                refreshFeed: { [weak self] url, limit in
                    guard let self else { return [] }
                    return try await self.automaticRefresh(url, claimingNewest: limit)
                },
                startDownload: { [weak self] episodeID in
                    guard let self else { return }
                    try await self.startClaimedDownload(episodeID)
                },
                unfinishedClaims: { [weak self] in
                    guard let self else { return [] }
                    return try await self.unfinishedAutomationClaims()
                }
            ),
            settings: { [weak self] in await self?.automationSettings ?? .defaults },
            lastRefreshSuccess: { [weak self] in await self?.lastAutomationRefreshAt },
            recordRefreshSuccess: { [weak self] date in await self?.setLastAutomationRefresh(date) },
            report: { [weak self] status in await self?.setAutomationStatus(status) }
        )
        automation = coordinator
        return coordinator
    }

    private func automationFeedURLs() async throws -> [URL] {
        guard let store else { throw CancellationError() }
        var urls: [URL] = []
        for subscription in try await store.subscriptions().filter(\.enabled) {
            if let url = try await store.podcastFeed(for: subscription.feedID)?.canonicalURL {
                urls.append(url)
            }
        }
        return urls
    }

    private func unfinishedAutomationClaims() async throws -> [String] {
        guard let store else { throw CancellationError() }
        return try await store.unfinishedPodcastDownloads().map(\.episodeID.rawValue)
    }

    /// Refreshes one feed and claims a bounded subset of the episodes that exact
    /// refresh admitted, in one store save.
    private func automaticRefresh(_ url: URL, claimingNewest limit: Int) async throws -> [String] {
        guard let store else { throw CancellationError() }
        let loaded = try await podcastFeedClient.load(url)
        try await store.save(feed: loaded.feed)
        let result = try await store.admitPodcastEpisodes(
            loaded.episodes, admission: .incremental, claimingNewest: limit
        )
        let values = try await loadLibrary(from: store)
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
        dismissedEpisodes = try await loadDismissedEpisodes(from: store)
        return result.claimed.map(\.rawValue)
    }

    /// Starts one already-claimed episode and waits for it to settle.
    ///
    /// Waiting is what makes the coordinator's queue serial. The claim is
    /// durable, so nothing is lost by taking them one at a time, and a listener
    /// on a domestic connection would rather have one episode finish than six
    /// crawl.
    private func startClaimedDownload(_ episodeID: String) async throws {
        // Throwing, never returning. Automation only runs once the library has
        // loaded, so a claim with no episode behind it is a genuine fault. A
        // silent return would count it as downloaded and clear a claim that no
        // transfer ever serviced.
        guard let episode = episodes.first(where: { $0.id == episodeID }) else {
            throw WiltedAutomationFault.claimedEpisodeMissing(episodeID)
        }
        downloadEpisode(episode, alreadyClaimed: true)
        await podcastDownloadTasks[episodeID]?.value
    }
#endif

    /// Fixture launches share the daily driver's bundle identifier, so they
    /// get their own defaults domain, emptied on every launch: a UI test must
    /// neither inherit the owner's choices nor leave its own behind.
    private static func fixturePreferences() -> UserDefaults {
        let suite = "com.zerodelta.wilted.mac.ui-fixture"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    var libraryItems: [WiltedMacLibraryItem] {
        let query = librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = articles.map(WiltedMacLibraryItem.article) +
            episodes.filter { !hiddenEpisodeIDs.contains($0.id) }.map(WiltedMacLibraryItem.episode)
        let filtered = combined.filter { item in
            let matchesQuery = query.isEmpty || item.title.localizedCaseInsensitiveContains(query) ||
                item.source.localizedCaseInsensitiveContains(query)
            guard matchesQuery else { return false }
            let progress = item.progress
            let finished = progress.duration.map { $0 > 0 && progress.position >= $0 * 0.95 } ?? false
            switch libraryFilter {
            case .all: return true
            case .unplayed: return progress.position <= 0 && !finished
            case .inProgress: return progress.position > 0 && !finished
            case .finished: return finished
            }
        }
        return filtered.sorted {
            if $0.date != $1.date { return libraryOrder == .newest ? $0.date > $1.date : $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    func selectLibraryItem(_ id: String) { selectedLibraryItemID = id }

    /// Starts production persistence only after the root surface has made its
    /// loading state visible. Fixture modes are already ready at construction.
    func startStoreBootstrap() {
#if canImport(WiltedProducer)
        guard case .loading = startupState else { return }
        beginStoreBootstrap()
#endif
    }

#if canImport(WiltedProducer)
    private func beginStoreBootstrap() {
        guard !fixtureMode, startupTask == nil, startupAttemptCount < Self.maximumStartupAttempts else { return }
        startupAttemptCount += 1
        startupState = .loading(attempt: startupAttemptCount)
        startupTask = Task { [weak self] in
            await self?.performStoreBootstrap()
        }
    }
#endif

    func retryStoreBootstrap() {
#if canImport(WiltedProducer)
        guard case let .failed(failure) = startupState, failure.canRetry else { return }
        beginStoreBootstrap()
#endif
    }

    func presentRetainedV5Store() {
#if canImport(WiltedProducer)
        guard case let .failed(failure) = startupState, let url = failure.retainedV5StoreURL else { return }
        retainedArtifactPresenter(url)
#endif
    }

    /// Deterministic test seam; production does not wait on this task.
    func waitForStoreBootstrap() async {
#if canImport(WiltedProducer)
        await startupTask?.value
#endif
    }

    var syncStatus: WiltedMacSyncStatus {
#if canImport(WiltedProducer)
        syncLifecycle?.status ?? .disabled
#else
        .disabled
#endif
    }

    var syncObservability: WiltedMacObservability {
#if canImport(WiltedProducer)
        syncLifecycle?.observability ?? .unavailable
#else
        .unavailable
#endif
    }

    /// Starts the explicit manual refresh action.
    func refreshSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.startRefresh()
#endif
    }

    /// Starts the explicit manual upload action.
    func uploadPendingSync() {
#if canImport(WiltedProducer)
        Task { [weak self] in
            _ = await self?.queueUnpublishedReadyRevisions()
            self?.syncLifecycle?.startUpload()
        }
#endif
    }

    /// Reconciles durable ready revisions when the producer launches or returns to the
    /// foreground. The task guard makes repeated scene callbacks harmless while the
    /// existing lifecycle coalesces any automatic send requested by the reconciliation.
    func reconcileSyncOnLaunchOrForeground() {
#if canImport(WiltedProducer)
        guard !fixtureMode else { return }
        switch startupState {
        case let .loading(attempt):
            pendingSyncReconciliation = true
            if attempt == 0 {
                startStoreBootstrap()
            }
            return
        case .failed:
            return
        case .ready:
            break
        }
        guard let syncLifecycle,
              syncLifecycle.status.phase != .disabled,
              syncReconciliationTask == nil else { return }
        syncReconciliationTask = Task { [weak self] in
            guard let self else { return }
            let queued = await self.queueUnpublishedReadyRevisions()
            if queued {
                self.syncLifecycle?.startAutomaticUpload()
            }
            self.syncReconciliationTask = nil
        }
#endif
    }

    /// Cancels the current bounded sync action.
    func cancelSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.cancel()
#endif
    }

    func subscribeToPodcastFeed(_ url: URL) {
#if canImport(WiltedProducer)
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            podcastOperationMessage = "Enter a complete HTTPS podcast feed URL."
            return
        }
        startPodcastRefresh(urls: [url], subscribing: true)
#endif
    }

    /// Classifies the Feeds-owned composer input, subscribing direct feeds and
    /// requiring confirmation before following a feed advertised by a page.
    func addPodcastFeedDraft() {
#if canImport(WiltedProducer)
        let trimmed = podcastFeedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            podcastFeedDraftStatus = "Enter a complete HTTPS podcast feed or show-page address."
            return
        }
        guard podcastSubscriptionClassificationTask == nil else { return }
        advertisedFeed = nil
        selectedPodcastFeedID = nil
        isCheckingPodcastSubscription = true
        podcastFeedDraftStatus = Self.podcastCheckInProgressStatus
        podcastSubscriptionCheckGeneration &+= 1
        let generation = podcastSubscriptionCheckGeneration
        podcastSubscriptionClassificationTask = Task { [weak self] in
            guard let self else { return }
            let outcome: PodcastSubscriptionCheckOutcome
            do {
                let kind = try await self.pastedLinkClassifier.classify(url)
                try Task.checkCancellation()
                switch kind {
                case .podcastFeed: outcome = .subscribe(url)
                case .articleAdvertisingFeed(let feedURL): outcome = .confirm(feedURL)
                case .article: outcome = .notAFeed
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .unreachable
            }
            // A cancelled check still resumes, and by then the listener may have
            // started the next one. Only the current generation may write the
            // shared status, or a stale answer clears a live check's progress.
            guard generation == self.podcastSubscriptionCheckGeneration else { return }
            self.isCheckingPodcastSubscription = false
            self.podcastSubscriptionClassificationTask = nil
            self.apply(outcome)
        }
#endif
    }

    /// What one classification of the Feeds composer input concluded.
    private enum PodcastSubscriptionCheckOutcome {
        case subscribe(URL)
        case confirm(URL)
        case notAFeed
        case cancelled
        case unreachable
    }

    private func apply(_ outcome: PodcastSubscriptionCheckOutcome) {
#if canImport(WiltedProducer)
        switch outcome {
        case let .subscribe(url):
            podcastFeedDraftStatus = nil
            subscribeToPodcastFeed(url)
        case let .confirm(feedURL):
            advertisedFeed = feedURL
            podcastFeedDraftStatus = "This page advertises one podcast feed. Confirm before subscribing."
        case .notAFeed:
            podcastFeedDraftStatus = "That page does not advertise a podcast feed."
        case .cancelled:
            podcastFeedDraftStatus = Self.podcastCheckCancelledStatus
        case .unreachable:
            podcastFeedDraftStatus = "Wilted could not reach that address. Check it, or retry when online."
        }
#endif
    }

    func cancelPodcastSubscriptionCheck() {
        guard let task = podcastSubscriptionClassificationTask else { return }
        // The generation moves with the cancellation, so the task being
        // cancelled here cannot write anything after this point.
        podcastSubscriptionCheckGeneration &+= 1
        task.cancel()
        podcastSubscriptionClassificationTask = nil
        isCheckingPodcastSubscription = false
        podcastFeedDraftStatus = Self.podcastCheckCancelledStatus
    }

    /// Follows the feed the last added page advertised.
    func subscribeToAdvertisedFeed() {
        guard let advertisedFeed else { return }
        self.advertisedFeed = nil
        podcastFeedDraft = advertisedFeed.absoluteString
        podcastFeedDraftStatus = nil
        subscribeToPodcastFeed(advertisedFeed)
    }

    /// Moves a feed found by Larder's article classifier to its owning screen.
    ///
    /// The address moves rather than being copied: leaving it in the article box
    /// as well would offer the same paste two homes.
    func handPodcastFeedToSubscriptions(_ url: URL) {
        advertisedFeed = nil
        urlDraft = ""
        podcastFeedDraft = url.absoluteString
        podcastFeedDraftStatus = "Podcast feed detected. Review the address, then subscribe."
        selectedNavigation = .feeds
    }

    func dismissAdvertisedFeed() {
        advertisedFeed = nil
    }

    func refreshPodcastFeeds() {
#if canImport(WiltedProducer)
        guard let store, podcastRefreshTask == nil else { return }
        isRefreshingPodcasts = true
        podcastOperationMessage = "Refreshing subscribed podcasts…"
        podcastRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let subscriptions = try await store.subscriptions().filter(\.enabled)
                var urls: [URL] = []
                for subscription in subscriptions {
                    if let url = try await store.podcastFeed(for: subscription.feedID)?.canonicalURL {
                        urls.append(url)
                    }
                }
                let result = try await self.refreshPodcastURLs(urls, subscribing: false)
                self.lastPodcastRefreshNewEpisodeIDs = result.newEpisodeIDs.map(\.rawValue)
                self.podcastOperationMessage = result.newEpisodeIDs.isEmpty
                    ? "Podcast episodes are up to date."
                    : "Added \(result.newEpisodeIDs.count) new episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
            } catch is CancellationError {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch PodcastFeedClientError.cancelled {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch {
                self.podcastOperationMessage = "Podcasts could not be refreshed. Check your connection and retry."
            }
            self.isRefreshingPodcasts = false
            self.podcastRefreshTask = nil
        }
#endif
    }

    func cancelPodcastRefresh() {
        podcastRefreshTask?.cancel()
        podcastRefreshTask = nil
        isRefreshingPodcasts = false
        podcastOperationMessage = "Podcast refresh cancelled."
    }

    /// Starts one episode's download.
    ///
    /// `alreadyClaimed` is automation saying it holds the store claim already.
    /// Every other caller takes the claim here, because the in-memory task table
    /// below only knows about this process: a claim an earlier launch made, or
    /// one automation took a moment ago, is invisible to it, and the download
    /// coordinator writes its queued record unconditionally. Without the claim
    /// the same episode transfers twice.
    func downloadEpisode(_ episode: WiltedMacEpisode, alreadyClaimed: Bool = false, ignoringExisting: Bool = false) {
#if canImport(WiltedProducer)
        if fixtureMode {
            guard podcastDownloadTasks[episode.id] == nil else { return }
            updateEpisode(episode.id) { $0.downloadState = .queued }
            podcastOperationMessage = "Queued \(episode.title) for download."
            podcastDownloadTasks[episode.id] = Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.updateEpisode(episode.id) { $0.downloadState = .cancelled }
                    self.podcastOperationMessage = "Download cancelled."
                    self.podcastDownloadTasks[episode.id] = nil
                    return
                }
                self.updateEpisode(episode.id) { $0.downloadState = .downloading(received: 3, expected: 6) }
                self.podcastOperationMessage = "Downloading \(episode.title)…"
                await Task.yield()
                guard !Task.isCancelled else {
                    self.updateEpisode(episode.id) { $0.downloadState = .cancelled }
                    self.podcastOperationMessage = "Download cancelled."
                    self.podcastDownloadTasks[episode.id] = nil
                    return
                }
                if self.fixtureDownloadFailuresRemaining > 0 {
                    self.fixtureDownloadFailuresRemaining -= 1
                    self.updateEpisode(episode.id) { $0.downloadState = .failed }
                    self.podcastOperationMessage = "Download failed. Retry when you are online."
                } else {
                    self.updateEpisode(episode.id) { $0.downloadState = .completed }
                    self.podcastOperationMessage = "\(episode.title) is available offline."
                }
                self.podcastDownloadTasks[episode.id] = nil
            }
            return
        }
        guard podcastDownloadTasks[episode.id] == nil,
              let coordinator = podcastDownloadCoordinator,
              let itemID = try? ItemID(rawValue: episode.id) else { return }
        updateEpisode(episode.id) { $0.downloadState = .queued }
        podcastOperationMessage = "Queued \(episode.title) for download."
        podcastDownloadTasks[episode.id] = Task { [weak self] in
            guard let self else { return }
            if !alreadyClaimed {
                let won = await self.claimDownload(itemID)
                guard won else {
                    self.podcastOperationMessage = "\(episode.title) is already downloading."
                    self.updateEpisode(episode.id) { $0.downloadState = .notDownloaded }
                    self.podcastDownloadTasks[episode.id] = nil
                    return
                }
            }
            do {
                _ = try await coordinator.download(episodeID: itemID,
                                                   ignoringExisting: ignoringExisting) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.updateActiveEpisodeDownload(
                            episode.id,
                            received: progress.bytesReceived,
                            expected: progress.expectedByteCount
                        ) == true else { return }
                        self?.podcastOperationMessage = "Downloading \(episode.title)…"
                    }
                }
                guard let store = self.store else { throw CancellationError() }
                self.podcastOperationMessage = "\(episode.title) is available offline."
                self.podcastDownloadTasks[episode.id] = nil
                // Asked for before the library is reloaded, not after. The
                // reload reads the whole library and three downloads landing
                // together each run one, so preparation used to be requested
                // seconds after the transfer it follows -- and until it is
                // requested the row has no state to keep and nothing names it
                // as pending. It reports what it will do straight away, so the
                // reload below has something to preserve.
                self.prepareEpisode(episode)
                // The file has landed and its preparation is under way, so a
                // reload that fails from here leaves stale rows -- it does not
                // mean the download failed, and the catch below would say so.
                // The next reload picks the rows up.
                do {
                    let values = try await self.loadLibrary(from: store)
                    self.articles = values.articles
                    self.applyEpisodes(values.episodes)
                    self.subscriptions = values.subscriptions
                    self.dismissedEpisodes = try await self.loadDismissedEpisodes(from: store)
                } catch {}
                return
            } catch PodcastDownloadCoordinatorError.cancelled {
                self.updateEpisode(episode.id) { $0.downloadState = .cancelled }
                self.podcastOperationMessage = "Download cancelled."
            } catch {
                self.updateEpisode(episode.id) { $0.downloadState = .failed }
                self.podcastOperationMessage = "Download failed. Retry when you are online."
            }
            self.podcastDownloadTasks[episode.id] = nil
        }
#endif
    }

    /// Takes the store claim for a deliberate download, so a transfer already in
    /// flight -- from automation, or from a launch that ended mid-download --
    /// is not started a second time. A settled record does not block: retrying
    /// a failure from the row is exactly what that path is for.
#if canImport(WiltedProducer)
    private func claimDownload(_ episodeID: ItemID) async -> Bool {
        guard let store else { return false }
        return (try? await store.claimPodcastDownload(episodeID: episodeID, scope: .notInFlight)) ?? false
    }
#endif

    /// Removes the advertisements and synchronises the transcript.
    ///
    /// Runs automatically once a download lands, and manually from the row for
    /// an episode that was downloaded before preparation existed or whose last
    /// attempt failed. Every stage is reported as it happens: the speech and
    /// classification passes take minutes, and a silent window is
    /// indistinguishable from a hung one.
    func prepareEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard podcastPreparationTasks[episode.id] == nil else { return }
        if fixtureMode {
            // No worker in fixture mode; the row still has to leave the state
            // it was in, so a UI test can tell a live control from a drawn one.
            updateEpisode(episode.id) { $0.preparationState = .preparing(stage: "Preparing…") }
            podcastPreparationTasks[episode.id] = Task { [weak self] in
                await Task.yield()
                self?.updateEpisode(episode.id) { $0.preparationState = .failed("No preparation worker in fixture mode") }
                self?.podcastPreparationTasks[episode.id] = nil
            }
            return
        }
        guard let pipeline = podcastPreparationPipeline,
              let itemID = try? ItemID(rawValue: episode.id) else { return }
        // Whether this run waits is decided now, so the row can say so now,
        // and so Prep can list it in the order it will run. The place in line
        // is taken here rather than where the run suspends on the gate: those
        // are one main-actor hop apart, and a row saying `Queued` that Prep
        // cannot name is the gap this closes.
        //
        // The gate is asked, and so is this process: a run becomes the gate's
        // business only when its task body reaches `admit()`, one main-actor
        // hop after it was started, so two downloads landing together could
        // both find the gate free and both claim to be preparing. A task
        // already in the table is a run that precedes this one -- this episode
        // cannot be in it, the guard above refused that -- and if that run
        // turns out to be leaving, this one is admitted immediately and the
        // row is corrected below rather than left waiting.
        let queued = preparationGate.isBusy || !podcastPreparationTasks.isEmpty
        updateEpisode(episode.id) {
            $0.preparationState = .preparing(stage: queued ? Self.preparationQueuedStage : Self.preparingStage)
        }
        if queued {
            preparationQueue.enter(WiltedMacWaitingPreparation(
                id: episode.id, title: episode.title, source: episode.feedTitle
            ))
        }
        podcastOperationMessage = queued
            ? "\(episode.title) is queued behind the preparation in flight."
            : "Preparing \(episode.title)…"
        // The row says only that the episode is preparing. Every status the
        // worker emits is journalled by the pipeline, and Prep reads that
        // journal back as the narrative and, on request, the full log.
        podcastPreparationTasks[episode.id] = Task { [weak self] in
            defer {
                self?.podcastPreparationTasks[episode.id] = nil
                // Every way out of this run leaves the line, including the
                // ones that never reached the admission below.
                self?.preparationQueue.leave(episode.id)
            }
            guard let gate = self?.preparationGate else { return }
            do {
                try await gate.admit()
            } catch {
                self?.updateEpisode(episode.id) { $0.preparationState = .notPrepared }
                self?.podcastOperationMessage = "Preparation cancelled."
                return
            }
            defer { gate.release() }
            self?.preparationQueue.leave(episode.id)
            if queued {
                self?.updateEpisode(episode.id) { $0.preparationState = .preparing(stage: Self.preparingStage) }
                self?.podcastOperationMessage = "Preparing \(episode.title)…"
            }
            do {
                let result = try await pipeline.prepare(episodeID: itemID)
                guard let self else { return }
                let summary = result.summary
                self.podcastOperationMessage = "\(episode.title): \(summary)"
                if let store = self.store {
                    let values = try await self.loadLibrary(from: store)
                    self.articles = values.articles
                    self.applyEpisodes(values.episodes)
                    self.subscriptions = values.subscriptions
                }
                // Applied after the reload, not before. The reload derives
                // preparation state from what the library can prove, and how
                // many advertisements a run cut is not stored, so it would
                // otherwise replace this run's summary with a generic one.
                self.updateEpisode(episode.id) { $0.preparationState = .prepared(summary: summary) }
                await self.reloadPreparedPlayback(episode.id, itemID: itemID)
                self.refreshProcessorRuns()
            } catch is CancellationError {
                self?.updateEpisode(episode.id) { $0.preparationState = .notPrepared }
                self?.podcastOperationMessage = "Preparation cancelled."
            } catch {
                // The reason is on Prep, with the log that led to it.
                self?.updateEpisode(episode.id) { $0.preparationState = .failed(Self.preparationFailedLabel) }
                self?.podcastOperationMessage = "\(episode.title): \(Self.preparationFailedLabel)"
                self?.refreshProcessorRuns()
            }
        }
#endif
    }

    /// What a row says when its preparation failed. The cause is on Prep.
    nonisolated static let preparationFailedLabel = "Preparation failed. See \(WiltedScreenCopy.processor)."

    /// What a row says once its preparation owns the single run slot.
    nonisolated static let preparingStage = "Preparing…"

    /// What a row says while it waits for the run ahead of it to finish. The
    /// GPU admits one preparation, so the rest queue instead of failing.
    nonisolated static let preparationQueuedStage = "Queued"

    /// Stops the run Prep is showing. Article runs have their own cancel.
    func cancelProcessorRun(_ run: WiltedMacProcessorRun) {
        podcastPreparationTasks[run.itemID]?.cancel()
    }

    /// Runs a podcast preparation again from its row on Prep. A failed run's
    /// retry lives next to the failure rather than in the Larder, where the
    /// row only says to look here.
    func retryProcessorRun(_ run: WiltedMacProcessorRun) {
        guard run.isPodcast else { return }
        guard let episode = episodes.first(where: { $0.id == run.itemID }) else {
            processorOperationMessage = dismissedEpisodes.contains(where: { $0.id == run.itemID })
                ? "Restore \(run.title) from Podcast feeds before retrying preparation."
                : "\(run.title) is no longer in Larder. Add it again before retrying preparation."
            return
        }
        processorOperationMessage = nil
        prepareEpisode(episode)
    }

    func cancelEpisodePreparation(_ episode: WiltedMacEpisode) {
        podcastPreparationTasks[episode.id]?.cancel()
    }

    /// Stops a run that is still waiting for the slot, from Prep, where the
    /// waiting run is named but its episode row is not in reach. The gate lets
    /// a queued caller leave at the moment it is cancelled rather than when
    /// the run ahead of it finishes, so the row clears now.
    func cancelWaitingPreparation(_ waiting: WiltedMacWaitingPreparation) {
        podcastPreparationTasks[waiting.id]?.cancel()
    }

#if canImport(WiltedProducer)
    /// Re-points the player at an episode that was just prepared.
    ///
    /// Preparation supersedes the revision and deletes the audio it was cut
    /// from, carrying the saved position onto the new timeline. A player still
    /// holding the old revision would keep playing the advertisements and
    /// would fail on its next load, so the episode is selected again, which
    /// resumes from the carried position and picks up the new transcript.
    private func reloadPreparedPlayback(_ episodeID: String, itemID: ItemID) async {
        guard currentPodcastEpisodeID == episodeID, let playback else { return }
        let wasPlaying = playback.liveIsPlaying
        do {
            try await playback.selectPodcastQueueEpisode(itemID, autoplay: wasPlaying)
            refreshPlaybackReadout()
        } catch {
            playbackError = "This episode's saved audio is unavailable."
        }
        await loadEpisodeTranscript(itemID: itemID)
    }
#endif

#if canImport(WiltedProducer)
    /// Turns the worker's own stage vocabulary into something a listener reads.
    nonisolated static func preparationLabel(for progress: PodcastPreparationProgress) -> String {
        switch progress.stage {
        case "pipeline.start": "Preparing…"
        case "transcript.published.fetch": "Fetching the published transcript…"
        case "transcript.published.parse", "transcript.published.accepted",
             "transcript.published.aligned", "transcript.published.unverified":
            "Reading the published transcript…"
        case "transcript.published.unreadable", "transcript.published.unreachable",
             "transcript.published.unparseable": "No usable published transcript. Transcribing…"
        // Named apart from the unusable cases above because this one is not a
        // missing transcript: the feed published a good one for a different
        // rendering of the episode than the download produced.
        case "transcript.published.misaligned":
            "The published transcript does not match this audio. Transcribing…"
        case "transcript.stt.start": "Transcribing the audio…"
        case "transcript.stt.complete": "Transcribed."
        case "transcript.stt.failed": "Transcription unavailable."
        case "transcript.stt.readable.start": "Transcribing again for reading…"
        case "transcript.stt.readable.complete": "Readable transcript ready."
        case "transcript.stt.readable.failed", "transcript.stt.readable.rejected": "Keeping the plain transcript."
        case "transcript.glossary.terms", "transcript.glossary.progress", "transcript.glossary.complete":
            "Correcting names from the show notes…"
        case "transcript.prose.extract", "transcript.prose.accepted": "Reading the episode page…"
        case "transcript.absent": "No transcript available."
        case "transcript.remap": "Resynchronising the transcript…"
        case "ads.model.load": "Loading the advertisement classifier…"
        case "ads.detect.start", "ads.detect.calls", "ads.detect.complete": "Finding advertisements…"
        case "ads.cut.start", "ads.cut.complete": "Removing advertisements…"
        case "ads.cut.refused", "ads.cut.empty": "Advertisements left in place."
        case "audio.publish": "Storing the prepared audio…"
        case "pipeline.complete": "Prepared."
        default: "Preparing…"
        }
    }
#endif

    func cancelEpisodeDownload(_ episode: WiltedMacEpisode) {
        podcastDownloadTasks[episode.id]?.cancel()
    }

    func retryEpisodeDownload(_ episode: WiltedMacEpisode) { downloadEpisode(episode) }

    /// Fetches the episode again and prepares the fresh copy.
    ///
    /// Preparation writes the cut audio over the download, so an episode cut
    /// from a transcript that did not describe its file cannot be redone: the
    /// only copy of the source is the damaged result. This asks the publisher
    /// for the episode again, and the download's own completion starts the
    /// preparation, exactly as a first download does.
    func redownloadEpisode(_ episode: WiltedMacEpisode) {
        downloadEpisode(episode, ignoringExisting: true)
    }

    func waitForPodcastOperations() async {
        await linkClassificationTask?.value
        await podcastSubscriptionClassificationTask?.value
        let refresh = podcastRefreshTask
        let downloads = Array(podcastDownloadTasks.values)
        let restores = Array(podcastRestoreTasks.values)
        await refresh?.value
        for task in downloads { await task.value }
        for task in restores { await task.value }
    }

    /// Turns a feed's episodes on or off in the Larder without unsubscribing.
    func setSubscription(_ subscription: WiltedMacSubscription, enabled: Bool) {
#if canImport(WiltedProducer)
        guard let store, let feedID = try? ItemID(rawValue: subscription.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.save(subscription: PodcastSubscription(
                    feedID: feedID, subscribedAt: Timestamp(subscription.subscribedAt), enabled: enabled
                ))
                let values = try await self.loadLibrary(from: store)
                self.articles = values.articles
                self.applyEpisodes(values.episodes)
                self.subscriptions = values.subscriptions
                self.podcastOperationMessage = enabled
                    ? "\(subscription.title) is showing in Larder again."
                    : "\(subscription.title) is hidden from Larder. Wilted still keeps its episodes."
            } catch {
                self.podcastOperationMessage = "\(subscription.title) could not be updated."
            }
        }
#endif
    }

    /// Unsubscribes and clears every record the feed owned.
    ///
    /// Audio already downloaded stays on disk: an audio revision is identified
    /// by its content, so removing files here could break an episode from
    /// another feed that happens to share them.
    func unsubscribe(_ subscription: WiltedMacSubscription) {
#if canImport(WiltedProducer)
        guard let store, let feedID = try? ItemID(rawValue: subscription.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let removed = try await store.unsubscribeFromPodcast(feedID: feedID)
                let values = try await self.loadLibrary(from: store)
                self.articles = values.articles
                self.applyEpisodes(values.episodes)
                self.subscriptions = values.subscriptions
                self.dismissedEpisodes = try await self.loadDismissedEpisodes(from: store)
                self.podcastOperationMessage =
                    "Unsubscribed from \(subscription.title) and removed \(removed) episode\(removed == 1 ? "" : "s")."
            } catch {
                self.podcastOperationMessage = "\(subscription.title) could not be unsubscribed."
            }
        }
#endif
    }

    /// Removes an episode for good, not just from this view.
    ///
    /// The in-memory hide is the optimistic half: it takes the row off screen
    /// on the next render, before the store round-trip returns. The durable
    /// half is the store's dismissal, which is what stops the next refresh
    /// parsing the same episode out of the same feed and inserting it again.
    /// Without it a removal lasted until the next launch, because this set is
    /// all there was.
    func removeEpisode(_ episode: WiltedMacEpisode) {
        hideEpisode(episode)
        podcastOperationMessage = "Removed \(episode.title). Refreshing will not bring it back."
#if canImport(WiltedProducer)
        Task { [weak self] in
            guard let self else { return }
            if await self.dismissEpisode(episode) == false {
                self.podcastOperationMessage = "\(episode.title) could not be removed."
            }
        }
#endif
    }

    /// The optimistic half of a removal: the row leaves the screen on the next
    /// render, and any work still running for it stops.
    private func hideEpisode(_ episode: WiltedMacEpisode) {
        podcastDownloadTasks[episode.id]?.cancel()
        podcastPreparationTasks[episode.id]?.cancel()
        hiddenEpisodeIDs.insert(episode.id)
        if selectedLibraryItemID == episode.id { selectedLibraryItemID = nil }
    }

#if canImport(WiltedProducer)
    /// The durable half of a removal, awaited rather than fired off so a
    /// caller with something to do afterwards can do it in order.
    ///
    /// Returns whether the dismissal stuck. The optimistic hide is rolled back
    /// here when it did not, but the message stays the caller's to write:
    /// removal by hand and removal on finishing have different things to say.
    private func dismissEpisode(_ episode: WiltedMacEpisode) async -> Bool {
        guard let store, let id = try? ItemID(rawValue: episode.id) else { return false }
        do {
            try await store.dismissPodcastEpisode(id)
            if let playback {
                try? await playback.removePodcastQueueEpisode(id)
                await refreshPodcastQueueState()
            }
            let values = try await loadLibrary(from: store)
            articles = values.articles
            applyEpisodes(values.episodes)
            subscriptions = values.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: store)
            return true
        } catch {
            hiddenEpisodeIDs.remove(episode.id)
            return false
        }
    }
#endif

    /// Restores a removed episode only after a current feed proves the exact identity still exists.
    func restoreEpisode(_ dismissal: WiltedMacDismissedEpisode) {
#if canImport(WiltedProducer)
        guard podcastRestoreTasks[dismissal.id] == nil,
              let store, let episodeID = try? ItemID(rawValue: dismissal.id) else { return }
        podcastOperationMessage = "Checking feeds for \(dismissal.title)…"
        podcastRestoreTasks[dismissal.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.podcastRestoreTasks[dismissal.id] = nil }
            await self.restoreEpisode(dismissal, episodeID: episodeID, store: store)
        }
#endif
    }

#if canImport(WiltedProducer)
    private func restoreEpisode(
        _ dismissal: WiltedMacDismissedEpisode, episodeID: ItemID, store: LocalLibraryStore
    ) async {
        var checkedFeedCount = 0
        var loadedMatch: LoadedPodcastFeed?
        if let rawFeedID = dismissal.feedID, let feedID = try? ItemID(rawValue: rawFeedID) {
            guard let feed = try? await store.podcastFeed(for: feedID) else {
                podcastOperationMessage = "\(dismissal.title) has no known feed to check. It remains in Removed."
                return
            }
            do {
                let loaded = try await podcastFeedClient.load(feed.canonicalURL)
                checkedFeedCount = 1
                if loaded.episodes.contains(where: { $0.itemID == episodeID }) { loadedMatch = loaded }
            } catch {
                podcastOperationMessage = "Could not check \(feed.title). Retry Restore when you are online."
                return
            }
        } else {
            let subscriptions = (try? await store.subscriptions()) ?? []
            guard !subscriptions.isEmpty else {
                podcastOperationMessage = "No subscribed feed can resolve \(dismissal.title). It remains in Removed."
                return
            }
            for subscription in subscriptions {
                guard let feed = try? await store.podcastFeed(for: subscription.feedID) else { continue }
                do {
                    let loaded = try await podcastFeedClient.load(feed.canonicalURL)
                    checkedFeedCount += 1
                    if loaded.episodes.contains(where: { $0.itemID == episodeID }) {
                        loadedMatch = loaded
                        break
                    }
                } catch {
                    continue
                }
            }
        }

        guard let loadedMatch,
              let target = loadedMatch.episodes.first(where: { $0.itemID == episodeID }) else {
            podcastOperationMessage = checkedFeedCount == 0
                ? "No podcast feed could be checked. Retry Restore when you are online."
                : "\(dismissal.title) is no longer published by the feeds checked. It remains in Removed."
            return
        }
        do {
            let result = try await store.restorePodcastEpisode(target, from: loadedMatch.episodes)
            guard result.restored else {
                dismissedEpisodes = try await loadDismissedEpisodes(from: store)
                podcastOperationMessage = "\(dismissal.title) was already restored."
                return
            }
            let values = try await loadLibrary(from: store)
            articles = values.articles
            applyEpisodes(values.episodes)
            subscriptions = values.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: store)
            podcastOperationMessage = "Restored \(dismissal.title) to Larder."
        } catch {
            podcastOperationMessage = "\(dismissal.title) could not be restored. Retry Restore."
        }
    }
#endif

#if canImport(WiltedProducer)
    private func startPodcastRefresh(urls: [URL], subscribing: Bool) {
        guard podcastRefreshTask == nil else { return }
        isRefreshingPodcasts = true
        podcastOperationMessage = subscribing ? "Adding podcast feed…" : "Refreshing subscribed podcasts…"
        podcastRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.refreshPodcastURLs(urls, subscribing: subscribing)
                self.lastPodcastRefreshNewEpisodeIDs = result.newEpisodeIDs.map(\.rawValue)
                if subscribing {
                    self.podcastFeedDraft = ""
                    if let duplicate = result.duplicateSubscription {
                        // Nothing was added, so the answer is the feed already
                        // followed: point at it rather than report a failure.
                        self.selectedPodcastFeedID = duplicate.rawValue
                        self.podcastOperationMessage = "Already following this podcast."
                    } else {
                        self.selectedPodcastFeedID = nil
                        self.podcastOperationMessage = result.newEpisodeIDs.isEmpty
                            ? "Podcast subscription added."
                            : "Podcast subscription added with \(result.newEpisodeIDs.count) episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
                    }
                } else {
                    self.podcastOperationMessage = result.newEpisodeIDs.isEmpty
                        ? "Podcast episodes are up to date."
                        : "Added \(result.newEpisodeIDs.count) new episode\(result.newEpisodeIDs.count == 1 ? "" : "s")."
                }
            } catch is CancellationError {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch PodcastFeedClientError.cancelled {
                self.podcastOperationMessage = "Podcast refresh cancelled."
            } catch {
                self.podcastOperationMessage = "Podcast feed unavailable. Check the address or retry when online."
            }
            self.isRefreshingPodcasts = false
            self.podcastRefreshTask = nil
        }
    }

    /// Loads each feed and stores what the subscription horizon admits.
    ///
    /// The subscription is written before its episodes: the horizon rule reads
    /// it, so a feed subscribed to after its episodes were offered would admit
    /// nothing. Anything the feed published but Wilted did not keep is counted
    /// and reported -- a truncated back catalogue must never read as the whole
    /// feed.
    private struct PodcastRefreshResult {
        var newEpisodeIDs: [ItemID] = []
        var duplicateSubscription: ItemID?
    }

    private func refreshPodcastURLs(_ urls: [URL], subscribing: Bool) async throws -> PodcastRefreshResult {
        guard let store else { throw CancellationError() }
        var withheld = 0
        var result = PodcastRefreshResult()
        for url in urls {
            try Task.checkCancellation()
            let loaded = try await podcastFeedClient.load(url)
            try await store.save(feed: loaded.feed)
            if subscribing {
                let inserted = try await store.subscribeIfNeeded(PodcastSubscription(
                    feedID: loaded.feed.itemID, subscribedAt: Timestamp(Date())
                ))
                if !inserted { result.duplicateSubscription = loaded.feed.itemID }
            }
            let admission = try await store.savePodcastEpisodes(
                loaded.episodes, admission: subscribing ? .backfill : .incremental
            )
            withheld += loaded.droppedEpisodeCount + admission.skipped
            result.newEpisodeIDs.append(contentsOf: admission.newlyAdmitted)
        }
        withheldPodcastEpisodeCount = withheld
        let values = try await loadLibrary(from: store)
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
        dismissedEpisodes = try await loadDismissedEpisodes(from: store)
        return result
    }

#endif

    /// Publishes freshly loaded rows without dropping what only this process
    /// knows.
    ///
    /// `preparationState` is derived from what the library can prove, and a
    /// preparation waiting for the run slot has proved nothing: it has no
    /// journal entry until the worker starts, so the store reports it as not
    /// prepared. Every download that lands reloads the whole library, so one
    /// episode finishing its transfer used to put another episode's `Queued`
    /// row back to offering `Prepare` -- a button that does nothing, because
    /// the run it would start already exists -- while its turn was still
    /// coming. A run this process started keeps the state this process gave it
    /// until it reaches a terminal one of its own.
    private func applyEpisodes(_ loaded: [WiltedMacEpisode]) {
#if canImport(WiltedProducer)
        let running = Set(podcastPreparationTasks.keys)
#else
        let running: Set<String> = []
#endif
        episodes = Self.applyingRunningPreparations(to: loaded, from: episodes, running: running)
    }

    /// Carries a preparation state this process owns onto the loaded row.
    /// Separated from the reload so the rule can be read and tested on its own.
    nonisolated static func applyingRunningPreparations(
        to loaded: [WiltedMacEpisode], from current: [WiltedMacEpisode], running: Set<String>
    ) -> [WiltedMacEpisode] {
        var inFlight: [String: WiltedMacEpisodePreparationState] = [:]
        for episode in current where running.contains(episode.id) {
            guard case .preparing = episode.preparationState else { continue }
            inFlight[episode.id] = episode.preparationState
        }
        guard !inFlight.isEmpty else { return loaded }
        return loaded.map { episode in
            guard let state = inFlight[episode.id] else { return episode }
            var value = episode
            value.preparationState = state
            return value
        }
    }

    private func updateEpisode(_ id: String, transform: (inout WiltedMacEpisode) -> Void) {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
        transform(&episodes[index])
    }

    /// Progress callbacks are delivered through queued MainActor tasks. Once
    /// the store reload publishes a terminal state, an older callback must not
    /// move the row backwards to downloading.
    private func updateActiveEpisodeDownload(_ id: String, received: Int64, expected: Int64?) -> Bool {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return false }
        switch episodes[index].downloadState {
        case .queued, .downloading:
            episodes[index].downloadState = .downloading(received: received, expected: expected)
            return true
        case .notDownloaded, .completed, .failed, .cancelled:
            return false
        }
    }

    /// Quarantines sync after an account-owner change.
    func quarantineSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.quarantineAccount()
#endif
    }

    /// Clears the explicit account quarantine after review.
    func resetSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.resetAfterAccountChange()
#endif
    }

    var currentArticle: WiltedMacArticle? {
        guard let selectedArticleID else { return nil }
        return articles.first(where: { $0.id == selectedArticleID })
    }

    var currentEpisode: WiltedMacEpisode? {
        guard let currentPodcastEpisodeID else { return nil }
        return episodes.first(where: { $0.id == currentPodcastEpisodeID })
    }

    var hasCurrentPlayback: Bool { currentArticle != nil || currentEpisode != nil }

    var canSelectPreviousEpisode: Bool {
        guard isPodcastPlayback, let currentPodcastEpisodeID,
              let index = podcastQueueIDs.firstIndex(of: currentPodcastEpisodeID) else { return false }
        return index > podcastQueueIDs.startIndex
    }

    var canSelectNextEpisode: Bool {
        guard isPodcastPlayback, let currentPodcastEpisodeID,
              let index = podcastQueueIDs.firstIndex(of: currentPodcastEpisodeID) else { return false }
        return podcastQueueIDs.index(after: index) < podcastQueueIDs.endIndex
    }

    var canCancelPreparation: Bool { preparation?.cancellable == true }

    /// The player's one-line status, matching the listener's status channel so
    /// the same condition reads the same way on both platforms. Never color
    /// alone: the tone accompanies this text rather than replacing it.
    var playbackStatusMessage: String {
        if !hasCurrentPlayback { return "Nothing is playing" }
        if let playbackError { return playbackError }
        if isPlaying { return "Playing" }
        if isNowPlaying { return "Paused" }
        return "Ready"
    }

    var playbackStatusTone: WiltedStatusTone {
        if playbackError != nil { return .failure }
        if isPlaying { return .active }
        return .neutral
    }

    /// Elapsed and total, in the listener's wording.
    var playbackProgressLabel: String {
        WiltedDuration.progress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    /// The spoken form of the same readout.
    var playbackProgressSpokenLabel: String {
        WiltedDuration.spokenProgress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    /// Adds whatever was pasted, working out for itself which kind it is.
    ///
    /// Two boxes made the reader classify an address before pasting it, and a
    /// podcast address dropped in the article box produced a parse error rather
    /// than a subscription. The document decides instead: an unmistakable feed
    /// extension short-circuits, anything else is fetched once and sniffed.
    func addPastedLink() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            linkDraftStatus = "Enter a complete HTTPS address."
            return
        }
        advertisedFeed = nil
        linkDraftStatus = nil
        guard !fixtureMode else { addArticle(); return }

#if canImport(WiltedProducer)
        guard linkClassificationTask == nil else { return }
        linkDraftStatus = "Checking that address\u{2026}"
        linkClassificationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.linkClassificationTask = nil }
            do {
                let kind = try await self.pastedLinkClassifier.classify(url)
                guard !Task.isCancelled else { self.linkDraftStatus = nil; return }
                self.linkDraftStatus = nil
                switch kind {
                case .podcastFeed:
                    self.handPodcastFeedToSubscriptions(url)
                case .article:
                    self.addArticle()
                case .articleAdvertisingFeed(let feedURL):
                    self.advertisedFeed = feedURL
                    self.addArticle()
                }
            } catch is CancellationError {
                self.linkDraftStatus = nil
            } catch {
                self.linkDraftStatus = "Wilted could not reach that address. Check it, or retry when online."
            }
        }
#else
        addArticle()
#endif
    }

    func addArticle() {
        guard let url = URL(string: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard let preparedItemID = try? ItemID.derive(from: url) else { return }

        if fixtureMode {
            preparation = WiltedMacPreparation(
                phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
            )
            return
        }

#if canImport(WiltedProducer)
        guard let coordinator else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "The local larder is unavailable.", fraction: nil, cancellable: false
            )
            return
        }
        preparationTask?.cancel()
        preparation = WiltedMacPreparation(
            phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
        )
        preparationTask = Task { [weak self] in
            let run = await coordinator.start(url: url)
            guard let self else { await run.cancel(); return }
            self.preparationRun = run
            for await status in run.statuses {
                guard !Task.isCancelled else { await run.cancel(); return }
                self.update(status)
                if status.terminal { break }
            }
            if self.preparation?.phase == .completed {
                if await self.queuePreparedPublication(itemID: preparedItemID) {
                    self.syncLifecycle?.startAutomaticUpload()
                }
            }
            self.preparationRun = nil
            self.refresh()
        }
#endif
    }

    func cancelPreparation() {
        guard canCancelPreparation else { return }
        preparation = WiltedMacPreparation(
            phase: .cancelling, detail: "The current work will stop without replacing saved audio.",
            fraction: preparation?.fraction, cancellable: false
        )
        if fixtureMode { return }
#if canImport(WiltedProducer)
        let run = preparationRun
        Task { await run?.cancel() }
#endif
    }

    func openNowPlaying(for article: WiltedMacArticle) {
        guard article.isReady else { return }
        beginArticlePlaybackTransition(article)
#if canImport(WiltedProducer)
        guard let playback else { return }
        guard let fixtureRevision else {
            if fixtureMode { return }
            Task { [weak self] in
                guard let self, let store = self.store,
                      let itemID = try? ItemID(rawValue: article.id),
                      let revision = try? await store.readyRevision(for: itemID) else { return }
                do {
                    try await playback.load(revision)
                    self.isPlaying = playback.isPlaying
                    self.refreshPlaybackReadout()
                    await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                } catch { self.playbackError = "Audio could not be loaded." }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.load(fixtureRevision)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                if let itemID = try? ItemID(rawValue: article.id) {
                    await self.loadTranscript(
                        itemID: itemID,
                        revisionID: fixtureRevision.revision.revisionID
                    )
                }
            } catch { self.playbackError = "Audio could not be loaded." }
        }
#endif
    }

    private func beginArticlePlaybackTransition(_ article: WiltedMacArticle) {
        selectedArticleID = article.id
        currentPodcastEpisodeID = nil
        isPodcastPlayback = false
        isNowPlaying = true
        playbackError = nil
        currentTranscript = nil
        playbackPositionSeconds = 0
        playbackDurationSeconds = 0
    }

    func addEpisodeToUpNext(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episode.id) else { return }
        playbackOperationStatus = "Adding \(episode.title) to Up Next…"
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.fixturePodcastInstallTask?.value
                try await playback.addPodcastQueueEpisode(id)
                await self.refreshPodcastQueueState()
                self.playbackOperationStatus = "Added \(episode.title) to Up Next."
            } catch { self.playbackOperationStatus = "Up Next could not be updated." }
        }
#endif
    }

    func playEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episode.id) else { return }
        let wasQueued = podcastQueueIDs.contains(episode.id)
        playbackOperationStatus = "Opening \(episode.title)…"
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.fixturePodcastInstallTask?.value
                try await playback.addPodcastQueueEpisode(id)
                try await playback.selectPodcastQueueEpisode(id, autoplay: true)
                self.selectedArticleID = nil
                self.currentPodcastEpisodeID = episode.id
                self.isPodcastPlayback = true
                self.isNowPlaying = true
                self.currentTranscript = .unavailable
                await self.refreshPodcastQueueState()
                await self.loadEpisodeTranscript(itemID: id)
                self.refreshPlaybackReadout()
                self.playbackError = nil
                self.playbackOperationStatus = nil
            } catch {
                if !wasQueued {
                    try? await playback.removePodcastQueueEpisode(id)
                    await self.refreshPodcastQueueState()
                }
                self.playbackError = "This episode's saved audio is unavailable."
                self.playbackOperationStatus = nil
            }
        }
#endif
    }

    func removeEpisodeFromUpNext(_ episodeID: String) {
#if canImport(WiltedProducer)
        guard let playback, let id = try? ItemID(rawValue: episodeID) else { return }
        playbackOperationStatus = "Updating Up Next…"
        Task { [weak self] in
            try? await playback.removePodcastQueueEpisode(id)
            await self?.refreshPodcastQueueState()
            self?.playbackOperationStatus = nil
        }
#endif
    }

    func moveEpisodeInUpNext(from source: Int, to destination: Int) {
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackOperationStatus = "Reordering Up Next…"
        Task { [weak self] in
            try? await playback.movePodcastQueueEpisode(from: source, to: destination)
            await self?.refreshPodcastQueueState()
            self?.playbackOperationStatus = nil
        }
#endif
    }

    func setPlaybackRate(_ value: Double) {
        playbackRate = Self.clampPlaybackRate(value)
        preferences.set(playbackRate, forKey: Self.playbackRatePreferenceKey)
#if canImport(WiltedProducer)
        playback?.defaultRate = Float(playbackRate)
        playback?.setRate(Float(playbackRate))
        guard isPodcastPlayback, let store, let id = playback?.itemID else { return }
        let selectedRate = playbackRate
        playbackOperationStatus = "Saving playback speed…"
        Task { [weak self] in
            try? await store.save(playbackSpeed: PodcastPlaybackSpeed(
                itemID: id, speed: selectedRate, updatedAt: Timestamp(Date())
            ))
            self?.playbackOperationStatus = nil
        }
#endif
    }

    func setPlaybackVolume(_ value: Double) {
        playbackVolume = min(max(value, 0), 1)
#if canImport(WiltedProducer)
        playback?.setVolume(Float(playbackVolume))
#endif
    }

    func scrub(to value: Double) {
        guard value.isFinite else { return }
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(to: value)
                self.refreshPlaybackReadout()
                // A scrub is exactly the jump the system cannot extrapolate,
                // and a short one is inside the drift tolerance.
                self.publishNowPlaying(force: true)
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#else
        playbackPositionSeconds = min(max(value, 0), max(0, playbackDurationSeconds))
#endif
    }

    /// Republishes elapsed/total from the controller.
    ///
    /// `PlaybackController` advances its own position, but nothing observed it
    /// while audio ran, so the producer's readout would freeze at the loaded
    /// value. The player view drives this on a one-second cadence, matching
    /// the listener's `refreshNowPlayingReadout`.
    func refreshPlaybackReadout() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackDurationSeconds = playback.durationSeconds
        // The live engine read, not the checkpointed one. `positionSeconds`
        // only moves on load, seek, and checkpoint, so polling it left the
        // readout frozen between transport presses.
        playbackPositionSeconds = min(max(0, playback.livePositionSeconds), max(0, playback.durationSeconds))
        isPlaying = playback.liveIsPlaying
        playbackCompleted = playback.completed
        playbackRate = Double(playback.playbackRate)
#endif
        // The one funnel every transport and the player's timer already goes
        // through, so the system readout cannot drift from the on-screen one.
        publishNowPlaying()
    }

#if canImport(WiltedProducer)
    private func loadTranscript(itemID: ItemID, revisionID: RevisionID) async {
        guard let store else { return }
        guard let stored = try? await store.transcript(for: itemID, revisionID: revisionID) else {
            currentTranscript = WiltedMacTranscript(availability: .absent, text: nil)
            return
        }
        let availability: WiltedMacTranscript.Availability = switch stored.availability {
        case .available: .available
        case .stale: .stale
        case .oversized: .oversized
        case .malformed: .malformed
        case .absent: .absent
        }
        let timingSource: String? = switch stored.timing {
        case .published: "synced from the feed"
        case .aligned: "synced"
        case .none: nil
        }
        currentTranscript = WiltedMacTranscript(
            availability: availability, text: stored.text,
            cues: (stored.cues ?? []).enumerated().map { index, cue in
                WiltedMacTranscriptCue(id: index, startSeconds: cue.startSeconds,
                                       endSeconds: cue.endSeconds, text: cue.text)
            },
            timingSource: timingSource
        )
    }
#endif

#if canImport(WiltedProducer)
    /// Loads the transcript for whichever revision of an episode is ready now.
    ///
    /// The revision cannot be remembered from when the episode was downloaded:
    /// preparation cuts the audio, which changes its bytes and therefore its
    /// identity, so the current one has to be read back from the library.
    private func loadEpisodeTranscript(itemID: ItemID) async {
        guard let store, let stored = try? await store.readyRevision(for: itemID) else {
            currentTranscript = .unavailable
            // Spans loaded earlier in the session describe a revision that can
            // no longer be resolved. Leaving them would list cuts under
            // "Transcript unavailable" against audio nothing can vouch for.
            removedSpansByEpisode[itemID.rawValue] = []
            return
        }
        await loadTranscript(itemID: itemID, revisionID: stored.revision.revisionID)
        await loadRemovedSpans(itemID: itemID, revisionID: stored.revision.revisionID)
    }

    /// Reads the cuts from the preparation journal rather than from the
    /// transcript.
    ///
    /// A marker written into the transcript itself would have to be re-based
    /// every time the audio was cut again, and would drift from the numbers
    /// Prep reports for the same run. The journal already holds both clocks.
    private func loadRemovedSpans(itemID: ItemID, revisionID: RevisionID) async {
        guard let store else { return }
        guard let timeline = try? await store.latestPreparationTimeline(
            for: itemID, revisionID: revisionID
        ) else {
            removedSpansByEpisode[itemID.rawValue] = []
            return
        }
        removedSpansByEpisode[itemID.rawValue] = Self.removedSpans(in: timeline)
    }

    /// The removed intervals placed on the prepared clock, in the order a
    /// listener meets them.
    nonisolated static func removedSpans(
        in timeline: PreparationStatus.PreparationTimeline
    ) -> [WiltedMacRemovedSpan] {
        timeline.removed.enumerated().map { index, removed in
            WiltedMacRemovedSpan(
                id: index,
                preparedSeconds: preparedSeam(for: removed, in: timeline),
                originalStartSeconds: removed.originalStartSeconds,
                originalEndSeconds: removed.originalEndSeconds,
                label: removed.label
            )
        }
        .sorted { $0.preparedSeconds < $1.preparedSeconds }
    }
#endif

    // MARK: - System playback integration

    /// What the system widget should show, or nil when nothing is loaded.
    ///
    /// Articles and episodes both appear. An article is spoken audio with a
    /// duration and a position exactly as an episode is, and a listener who
    /// pressed play on one expects the same media key to pause it.
    var currentNowPlayingInfo: WiltedNowPlayingInfo? {
        guard isNowPlaying else { return nil }
        let identity: (id: String, title: String, show: String, artwork: URL?)
        if let episode = currentEpisode, isPodcastPlayback {
            identity = (episode.id, episode.title, episode.feedTitle, episode.artworkURL)
        } else if let article = currentArticle {
            identity = (article.id, article.title, article.source, nil)
        } else {
            return nil
        }
        return WiltedNowPlayingInfo(
            episodeID: identity.id,
            title: identity.title,
            showTitle: identity.show,
            durationSeconds: max(0, playbackDurationSeconds),
            positionSeconds: min(max(0, playbackPositionSeconds), max(0, playbackDurationSeconds)),
            // Zero while paused. The system advances its own clock from this,
            // so reporting the resume speed of a paused episode would make the
            // widget's scrubber walk forward through silence.
            rate: isPlaying ? playbackRate : 0,
            chosenRate: playbackRate,
            isPlaying: isPlaying,
            artworkURL: identity.artwork
        )
    }

    /// Pushes the readout to the system, skipping publications that would say
    /// the same thing. `force` is for the moments the system cannot infer:
    /// a seek, a new episode, a stop.
    func publishNowPlaying(force: Bool = false) {
        guard let nowPlayingSink else { return }
        guard let info = currentNowPlayingInfo else {
            guard lastPublishedNowPlaying != nil else { return }
            lastPublishedNowPlaying = nil
            nowPlayingSink.clear()
            remoteCommandSource?.updateQueueAvailability(hasNext: false, hasPrevious: false)
            return
        }
        guard force || info.differsMateriallyFrom(lastPublishedNowPlaying) else { return }
        lastPublishedNowPlaying = info
        nowPlayingSink.publish(info)
        remoteCommandSource?.updateQueueAvailability(hasNext: canSelectNextEpisode,
                                                     hasPrevious: canSelectPreviousEpisode)
    }

    private func installRemoteCommands() {
        remoteCommandSource?.install { [weak self] command in
            self?.handleRemoteCommand(command)
        }
    }

    /// Applies a media key, headset button, or widget press.
    ///
    /// Every case routes through the same method the on-screen control calls,
    /// so a media key cannot end up with behaviour of its own — including the
    /// durable checkpoint each of those already writes.
    func handleRemoteCommand(_ command: WiltedRemoteCommand) {
        guard hasCurrentPlayback else { return }
        switch command {
        case .play:
            guard !isPlaying else { return }
            togglePlayback()
        case .pause:
            guard isPlaying else { return }
            togglePlayback()
        case .toggle:
            togglePlayback()
        case .skipForward:
            forward()
        case .skipBackward:
            rewind()
        case .nextTrack:
            guard canSelectNextEpisode else { return }
            nextPlayback()
        case .previousTrack:
            guard canSelectPreviousEpisode else { return }
            previousPlayback()
        case let .seek(position):
            scrub(to: position)
        case let .changeRate(rate):
            setPlaybackRate(rate)
        }
    }

    func togglePlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.toggle()
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#else
        isPlaying.toggle()
#endif
    }

    /// Returns to Library without changing playback state.
    ///
    /// The player no longer draws its own back button — the sidebar is
    /// permanent, so a second way back was redundant and the listener has no
    /// equivalent — but menu and keyboard paths still need the operation.
    func returnToLibrary() {
        selectedNavigation = .library
    }

    func rewind() { seek(by: -Self.backwardSkipSeconds) }
    func forward() { seek(by: Self.forwardSkipSeconds) }

    func previousPlayback() { navigatePodcastQueue(previous: true) }
    func nextPlayback() { navigatePodcastQueue(previous: false) }

    /// Starts a new playback session and publishes its durable checkpoint.
    func restartPlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.restart()
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.playbackError = "Playback restart is unavailable." }
        }
#endif
    }

    /// Retires the loaded episode without playing the rest of it.
    ///
    /// The listener who is finished at 91% has no other way to close an
    /// episode out: progress is written from where the audio is, so an
    /// abandoned episode stays at 91% for good and the Larder goes on offering
    /// it. Nothing advances — the press says "I am done with this", not "play
    /// the next thing".
    ///
    /// The library is reloaded rather than patched in memory, because the row
    /// reads its played state from the same durable record the player just
    /// wrote, and the two disagreeing is worse than the reload costs.
    func markCurrentPlaybackCompleted() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.markCompleted()
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
                await self.reloadLibraryRows()
            } catch { self.playbackError = "This episode could not be marked completed." }
        }
#endif
    }

    /// Records a playback fault that a route recovery can plausibly clear, so
    /// the recovery control appears only when it has something to act on.
    func reportAudioRouteFault(_ message: String) {
        playbackError = message
        audioRouteFault = true
    }

    func recoverAudioRoute() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.recoverFromRouteChange()
                self.audioRouteFault = false
                self.playbackError = nil
                self.refreshPlaybackReadout()
            } catch {
                self.playbackError = "Audio route recovery failed."
            }
        }
#else
        audioRouteFault = false
        playbackError = nil
#endif
    }

    func checkpointForQuit() {
        stopAutomationTicker()
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await playback.handlePauseOrQuit()
            await self.queueCurrentPlaybackCheckpoint()
        }
#endif
    }

    /// Deterministic model-test seam for the same checkpoint path used by
    /// transport actions. It never contacts a live service.
    func checkpointCurrentPlaybackForTesting() async {
#if canImport(WiltedProducer)
        try? await playback?.checkpoint()
        await queueCurrentPlaybackCheckpoint()
#endif
    }

    func completePodcastPlaybackForTesting(successfully: Bool = true) {
#if canImport(WiltedProducer)
        (playback?.backend as? WiltedFixturePlaybackBackend)?.finish(successfully: successfully)
#endif
    }

    func waitForPlaybackOperationForTesting() async {
#if canImport(WiltedProducer)
        await playbackOperationTask?.value
#endif
    }

    /// What the audio backend would actually play at, so a test can assert the
    /// silencing above is in force. The backend type is file-private, and the
    /// volume is the property the silencing is about.
    func playbackOutputVolumeForTesting() -> Float? {
#if canImport(WiltedProducer)
        playback?.backend.volume
#else
        nil
#endif
    }

    /// Puts the model in the state a real load leaves behind, so the system
    /// integration can be asserted on without an audio engine.
    ///
    /// The readout properties are `private(set)` because only the engine may
    /// move them, and that is the right rule; this is the one seam that lets a
    /// test stand in for the engine rather than relaxing it.
    func installPlaybackStateForTesting(episode: WiltedMacEpisode? = nil,
                                        article: WiltedMacArticle? = nil,
                                        isPlaying: Bool,
                                        position: TimeInterval,
                                        duration: TimeInterval,
                                        queue: [String] = []) {
        if let episode {
            installEpisodeForTesting(episode)
            currentPodcastEpisodeID = episode.id
            selectedArticleID = nil
            podcastQueueIDs = queue.isEmpty ? [episode.id] : queue
#if canImport(WiltedProducer)
            isPodcastPlayback = true
#endif
        }
        if let article {
            if !articles.contains(where: { $0.id == article.id }) { articles.append(article) }
            selectedArticleID = article.id
            currentPodcastEpisodeID = nil
#if canImport(WiltedProducer)
            isPodcastPlayback = false
#endif
        }
        isNowPlaying = episode != nil || article != nil
        self.isPlaying = isPlaying
        playbackPositionSeconds = position
        playbackDurationSeconds = duration
    }

    func clearPlaybackStateForTesting() {
        isNowPlaying = false
        isPlaying = false
        currentPodcastEpisodeID = nil
        selectedArticleID = nil
        playbackPositionSeconds = 0
        playbackDurationSeconds = 0
    }

    func installEpisodeForTesting(_ episode: WiltedMacEpisode) {
        guard !episodes.contains(where: { $0.id == episode.id }) else { return }
        episodes.append(episode)
    }

    func beginArticlePlaybackTransitionForTesting(_ article: WiltedMacArticle) {
        beginArticlePlaybackTransition(article)
    }

#if canImport(WiltedProducer)
    func applyPodcastPlaybackObservationForTesting(itemID: ItemID?, fault: PlaybackControllerError?) {
        applyPodcastPlaybackObservation(itemID: itemID, fault: fault)
    }
#endif

    /// Deterministic test seam for the natural-completion path.
    ///
    /// Production reaches `handlePodcastPlaybackFinished` only through
    /// `playback?.playbackDidFinishHandler`, which the audio backend fires
    /// from its own completion callback -- not something a test can trigger
    /// without a real, timed audio file. Driving `playback.completed` to
    /// `true` first (for example with `markCurrentPlaybackCompleted()`, the
    /// same checkpoint natural completion writes) and then calling this
    /// reaches the same guard and search logic natural completion does.
    func simulatePodcastPlaybackFinishedForTesting() {
#if canImport(WiltedProducer)
        handlePodcastPlaybackFinished()
#endif
    }

#if canImport(WiltedProducer)
    private func update(_ status: PreparationStatus) {
        let phase: WiltedMacPreparation.Phase
        switch status.stage {
        case .preparing: phase = .preparing
        case .fetching: phase = .preparing
        case .extracting: phase = .extracting
        case .synthesizing: phase = .synthesizing
        case .assembling: phase = .assembling
        case .saving: phase = .saving
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        preparation = WiltedMacPreparation(
            phase: phase, detail: status.detail, fraction: status.fraction, cancellable: status.cancellable
        )
    }

    @discardableResult
    private func queuePreparedPublication(itemID: ItemID, chunkedFile: AudioChunkedFile? = nil) async -> Bool {
        guard let store, let syncLifecycle,
              let article = try? await store.article(for: itemID),
              let stored = try? await store.readyRevision(for: itemID),
              let bytes = try? Data(contentsOf: stored.mediaURL),
              let chunkedFile = chunkedFile ?? (try? AudioChunking.chunk(bytes)) else { return false }
        let revisionResult = await syncLifecycle.queueRevision(stored.revision, chunkedFile: chunkedFile)
        let itemResult = await syncLifecycle.queueItem(article, currentRevisionID: stored.revision.revisionID)
        guard case .success = itemResult, case .success = revisionResult else { return false }
        articlePublicationCount += 1
        return true
    }

    /// Re-queues ready revisions that are durable locally but absent from the outbound queue.
    ///
    /// Publication is otherwise queued only at the instant a preparation completes, so any
    /// enqueue that failed then stays unqueued forever: the revision cannot be re-derived by
    /// re-preparing it either, because the same text and settings derive the same immutable
    /// revision ID and `saveReadyRevision` rejects a second media path for it. Reconciling
    /// from durable local state before an upload is what makes the queue recoverable, and it
    /// matches W-INV-007's rule that local state, not CloudKit, is the source of truth.
    ///
    /// Membership is checked rather than sync status so a partially queued item repairs
    /// itself, and a revision whose media file is gone is skipped instead of failing the
    /// whole upload.
    private func queueUnpublishedReadyRevisions() async -> Bool {
        guard let store, syncLifecycle != nil else { return false }
        guard let articles = try? await store.articles() else { return false }
        let state = try? await store.syncRepositoryState()
        let queued = Set((state?.pendingChanges.map(\.recordID) ?? []) + Array(state?.remoteAcknowledgedRecordIDs ?? []))
        var didQueue = false
        for article in articles where !article.isDeleted {
            guard let stored = try? await store.readyRevision(for: article.itemID),
                  FileManager.default.fileExists(atPath: stored.mediaURL.path),
                  let bytes = try? Data(contentsOf: stored.mediaURL),
                  let chunkedFile = try? AudioChunking.chunk(bytes),
                  let revisionRecordID = try? WiltedRecordID.revision(article.itemID, stored.revision.revisionID) else { continue }
            let chunkRecordIDs = chunkedFile.manifest.chunks.compactMap {
                try? WiltedRecordID.revisionChunk(article.itemID, stored.revision.revisionID, index: $0.index)
            }
            let expected = Set([revisionRecordID] + chunkRecordIDs)
            guard !expected.isSubset(of: queued) else { continue }
            didQueue = await queuePreparedPublication(itemID: article.itemID, chunkedFile: chunkedFile) || didQueue
        }
        let hasSendablePending = (try? await store.syncRepositoryState())?.sendableChanges.isEmpty == false
        return didQueue || hasSendablePending
    }

    private func queueCurrentPlaybackCheckpoint() async {
        guard let store, let syncLifecycle, let playbackItemID = playback?.itemID,
              selectedArticleID == playbackItemID.rawValue,
              articles.contains(where: { $0.id == playbackItemID.rawValue }),
              let playbackRevisionID = playback?.revisionID,
              let state = try? await store.playbackState(for: playbackItemID, revisionID: playbackRevisionID) else { return }
        let sidecar = try? await store.playbackSidecar(for: playbackItemID, revisionID: playbackRevisionID)
        let opaque = sidecar.map {
            WiltedOpaqueSidecar(changeTag: $0.changeTag, encodedSystemFields: $0.encodedSystemFields)
        }
        if case .success = await syncLifecycle.queuePlayback(state, sidecar: opaque) {
            articlePlaybackCheckpointCount += 1
        }
    }

    /// Removes an article from the library.
    ///
    /// Marks the stored article deleted and records a local tombstone, which
    /// is what `refresh()` and the sync repository both already read. The
    /// library had no removal path at all, so anything prepared once —
    /// including a stray fixture row written before fixture mode moved to a
    /// temporary directory — stayed on screen permanently.
    ///
    /// Local only. Publishing the tombstone to CloudKit rides the existing
    /// pending-change path and is not triggered from here.
    func removeArticle(_ article: WiltedMacArticle) {
#if canImport(WiltedProducer)
        guard let store else { return }
        if selectedArticleID == article.id {
            selectedArticleID = nil
            isNowPlaying = false
            currentTranscript = nil
            // Nothing is loaded any more, so the widget has to stop showing it.
            publishNowPlaying(force: true)
        }
        Task { [weak self] in
            guard let self else { return }
            guard let itemID = try? ItemID(rawValue: article.id) else { return }
            guard let stored = try? await store.articles().first(where: { $0.itemID == itemID }) else { return }
            guard let deleted = try? Article(
                itemID: stored.itemID, canonicalURL: stored.canonicalURL, title: stored.title,
                source: stored.source, author: stored.author, publishedTime: stored.publishedTime,
                createdAt: stored.createdAt, isDeleted: true
            ) else { return }
            try? await store.save(article: deleted)
            // Keyed by item, deliberately. `record(tombstone:)` upserts on `id`,
            // and this is the only path in the producer that writes one, so
            // removing the same article twice leaves one row rather than two.
            let tombstone = LocalLibraryTombstone(
                id: itemID.rawValue,
                itemID: itemID,
                requestedAt: Timestamp(Date())
            )
            try? await store.record(tombstone: tombstone)
            self.refresh()
        }
#endif
    }

    /// Fetches and stores the transcript for an already-prepared article.
    ///
    /// Transcript persistence shipped on 2026-08-23; anything prepared before
    /// that has audio and no text, and re-preparing cannot fix it because the
    /// revision ID is derived from the same content and `saveReadyRevision`
    /// refuses to re-point an existing revision. The text is re-extracted from
    /// the canonical URL and saved against the existing revision, so no new
    /// revision, media file, or synthesis run is created.
    func backfillCurrentTranscript() {
#if canImport(WiltedProducer)
        guard !isBackfillingTranscript, let store, let article = currentArticle else { return }
        isBackfillingTranscript = true
        transcriptBackfillStatus = "Fetching article text…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBackfillingTranscript = false }
            guard let itemID = try? ItemID(rawValue: article.id),
                  let revision = try? await store.readyRevision(for: itemID) else {
                self.transcriptBackfillStatus = "This article has no saved audio to attach text to."
                return
            }
            do {
                let extracted = try await NativeArticleExtractor().extract(article.url) { stage, _ in
                    Task { @MainActor [weak self] in
                        self?.transcriptBackfillStatus = "Fetching article text: \(stage.rawValue)"
                    }
                }
                let oversized = extracted.body.utf8.count > Transcript.maximumTextUTF8Bytes
                let transcript = try Transcript(
                    itemID: itemID,
                    revisionID: revision.revision.revisionID,
                    availability: oversized ? .oversized : .available,
                    text: oversized ? nil : extracted.body,
                    updatedAt: Timestamp(Date())
                )
                try await store.save(transcript: transcript)
                await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                self.transcriptBackfillStatus = oversized
                    ? "The article text is too large to store."
                    : nil
            } catch {
                // Named, not swallowed: the reader has to know whether to retry.
                self.transcriptBackfillStatus = Self.backfillFailureMessage(error)
            }
        }
#endif
    }

    /// A sentence a reader can act on, never a raw error dump.
    ///
    /// `ArticleExtractionError` already writes for people, so it passes through.
    /// Transport failures are matched by code rather than rendered: a `URLError`
    /// only has readable `localizedDescription` when URLSession populated it, and
    /// otherwise falls back to `The operation couldn't be completed.
    /// (NSURLErrorDomain error -1009.)`. Everything unmatched collapses to one
    /// generic line, because printing a domain and code into the player is the
    /// same defect as printing `1743` for a duration.
    static func backfillFailureMessage(_ error: Error) -> String {
#if canImport(WiltedProducer)
        if let extraction = error as? ArticleExtractionError, let text = extraction.errorDescription {
            return text
        }
#endif
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Wilted could not reach the article. Check your connection and try again."
            case .timedOut:
                return "The article server did not respond in time. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Wilted could not reach that site."
            default:
                break
            }
        }
        return "Could not fetch the article text. Check the link and try again."
    }

    /// Reloads the preparation run history behind the Processor destination.
    func refreshProcessorRuns() {
#if canImport(WiltedProducer)
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let runs = try? await store.preparationRuns() else { return }
            // Episodes prepare through the same journal as articles, so the
            // history has to be able to name both kinds of item.
            var titles = Dictionary(
                uniqueKeysWithValues: ((try? await store.articles()) ?? [])
                    .map { ($0.itemID.rawValue, ($0.title, $0.source)) }
            )
            let feedTitles = Dictionary(
                uniqueKeysWithValues: ((try? await store.podcastFeeds()) ?? []).map { ($0.itemID, $0.title) }
            )
            for episode in (try? await store.podcastEpisodes()) ?? [] {
                titles[episode.itemID.rawValue] = (episode.title, feedTitles[episode.feedID] ?? "Podcast")
            }
            for dismissal in (try? await store.dismissedPodcastEpisodes()) ?? [] {
                titles[dismissal.episodeID.rawValue] = (
                    dismissal.title ?? "Removed podcast episode",
                    dismissal.feedID.flatMap { feedTitles[$0] } ?? "Removed podcast"
                )
            }
            self.processorRuns = runs.map { run in
                let known = titles[run.itemID.rawValue]
                let outcome: WiltedMacProcessorRun.Outcome = if !run.isTerminal {
                    .running
                } else {
                    switch run.outcome {
                    case .succeeded: .succeeded
                    case .cancelled: .cancelled
                    default: .failed
                    }
                }
                let isPodcast = run.requestID.hasPrefix(Self.podcastRequestPrefix)
                let events = Self.processorEvents(for: run)
                let detail = run.failure?.message ?? run.detail
                let timeline = run.entries.last(where: { $0.status.terminal })?.status.timeline
                return WiltedMacProcessorRun(
                    id: run.requestID,
                    itemID: run.itemID.rawValue,
                    isPodcast: isPodcast,
                    // A run that failed before extraction never learned a
                    // title, so the item identity is all there is to name it.
                    title: known?.0 ?? "Unknown item",
                    source: known?.1 ?? run.itemID.rawValue,
                    stage: run.stage.rawValue,
                    detail: detail,
                    narrative: Self.processorNarrative(isPodcast: isPodcast, outcome: outcome, detail: detail,
                                                       events: events),
                    fraction: run.fraction,
                    outcome: outcome,
                    updatedAt: run.updatedAt.date,
                    events: events,
                    timeline: timeline
                )
            }
        }
#endif
    }

    static let podcastRequestPrefix = "podcast-prepare|"

    /// The legacy terminal detail, from builds that journalled only that the
    /// run had finished.
    nonisolated static let legacyPreparedDetail = "Prepared."

    /// What a finished run recorded it did, so "Synced transcript" alone never
    /// stands in for "were the advertisements removed?" after a relaunch.
    ///
    /// Current builds journal the outcome summary as the terminal row. Older
    /// ones wrote "Prepared.", but their `pipeline.complete` row still counted
    /// the advertisements, and zero there is the honest answer for an episode
    /// the build that never loaded the detector marked prepared.
    nonisolated static func recordedSummary(of run: PreparationRunSummary?) -> String? {
        guard let run, run.isTerminal, run.outcome == .succeeded else { return nil }
        if run.detail != legacyPreparedDetail, !run.detail.isEmpty { return run.detail }
        let completion = run.entries.last { $0.id.hasSuffix("|pipeline.complete") }?.status.detail ?? ""
        guard let match = completion.firstMatch(of: #/^(\d+) advertisements?/#),
              let count = Int(match.1) else { return nil }
        let ads = switch count {
        case 0: "no ads found"
        case 1: "1 ad removed"
        default: "\(count) ads removed"
        }
        return "\(PodcastPreparationResult.readyLabel) · \(ads) · \(PodcastPreparationResult.transcriptStep(.aligned))"
    }

    /// Where a cut lands in the prepared audio: the end of the last kept
    /// interval before it, carried onto the output clock. Zero when the cut
    /// starts the episode, because nothing was kept ahead of it.
    nonisolated static func preparedSeam(
        for removed: PreparationStatus.PreparationTimeline.RemovedInterval,
        in timeline: PreparationStatus.PreparationTimeline
    ) -> TimeInterval {
        timeline.kept.last(where: { $0.originalEndSeconds <= removed.originalStartSeconds })
            .map { $0.outputStartSeconds + ($0.originalEndSeconds - $0.originalStartSeconds) } ?? 0
    }

    /// A Prep row's concise evidence of one cut: the prepared-file seam, the
    /// original span, its duration, and the worker's normalized label.
    nonisolated static func removedSpanLine(
        _ removed: PreparationStatus.PreparationTimeline.RemovedInterval,
        in timeline: PreparationStatus.PreparationTimeline
    ) -> String {
        let seam = preparedSeam(for: removed, in: timeline)
        return "\(WiltedDuration.clock(seam)) in prepared · original \(WiltedDuration.clock(removed.originalStartSeconds))–\(WiltedDuration.clock(removed.originalEndSeconds)) · \(WiltedDuration.clock(removed.originalEndSeconds - removed.originalStartSeconds)) \(removed.label)"
    }

#if canImport(WiltedProducer)
    /// The journal keys each status as `requestID|stage#ordinal`, and the stage it
    /// stores is the coarse one every pipeline shares, so the worker's own
    /// stage name survives only in the key.
    nonisolated static func processorEvents(for run: PreparationRunSummary) -> [WiltedMacProcessorEvent] {
        run.entries.map { entry in
            let prefix = run.requestID + "|"
            let storedStage = entry.id.hasPrefix(prefix) ? String(entry.id.dropFirst(prefix.count)) : entry.status.stage.rawValue
            let stage = storedStage.split(separator: "#").first.map(String.init) ?? storedStage
            return WiltedMacProcessorEvent(
                id: entry.id, at: entry.status.emittedAt.date, stage: stage,
                detail: entry.status.detail, fraction: entry.status.fraction
            )
        }
    }

    /// A running podcast run is narrated from its latest worker stage; a
    /// finished one, and every article run, from what the journal recorded.
    nonisolated static func processorNarrative(
        isPodcast: Bool, outcome: WiltedMacProcessorRun.Outcome, detail: String, events: [WiltedMacProcessorEvent]
    ) -> String {
        guard isPodcast, outcome == .running, let latest = events.last(where: { !$0.stage.hasPrefix("log.") }) else {
            return detail
        }
        return preparationLabel(for: PodcastPreparationProgress(stage: latest.stage, detail: latest.detail))
    }
#endif

#if canImport(WiltedProducer)
    private func performStoreBootstrap() async {
        let retainedPathsBeforeAttempt = await Task.detached { [libraryURL] in
            Set(Self.retainedV5StoreURLs(for: libraryURL).map(\.path))
        }.value
        do {
            let configuredStore = try await storeBootstrap(libraryURL)
            configureStoreDependencies(configuredStore)
            // The account-review gate is durable state, so restore it before
            // the ready surface can expose sync controls.
            syncLifecycle?.restoreAccountQuarantine()
            let library = try await loadLibrary(from: configuredStore)
            articles = library.articles
            episodes = library.episodes
            subscriptions = library.subscriptions
            dismissedEpisodes = try await loadDismissedEpisodes(from: configuredStore)
            await restorePodcastPlayback()
            startupState = .ready
            if pendingSyncReconciliation {
                pendingSyncReconciliation = false
                reconcileSyncOnLaunchOrForeground()
            }
            // After the library is in memory, not in a parallel task: automation
            // resolves a claimed episode ID against `episodes`.
            startAutomationOnLaunch()
            startAutomationTicker()
            startPlaybackCheckpointTicker()
        } catch {
            configureStoreDependencies(nil)
            let retainedURL = await Task.detached { [libraryURL, retainedPathsBeforeAttempt] in
                Self.retainedV5StoreURLs(for: libraryURL).first {
                    !retainedPathsBeforeAttempt.contains($0.path)
                }
            }.value
            startupState = .failed(WiltedMacStartupFailure(
                message: "Wilted could not open your larder. The existing library was left in place.",
                detail: String(describing: error),
                retainedV5StoreURL: retainedURL,
                canRetry: startupAttemptCount < Self.maximumStartupAttempts
            ))
        }
        startupTask = nil
    }

    private func configureStoreDependencies(_ configuredStore: LocalLibraryStore?) {
        store = configuredStore
        coordinator = configuredStore.map {
            PreparationCoordinator(store: $0, mediaDirectory: mediaDirectory)
        }
        playback = configuredStore.map {
            PlaybackController(
                store: $0,
                backend: Self.playbackBackend(fixtureMode: fixtureMode),
                deviceID: "mac"
            )
        }
        playback?.defaultRate = Float(playbackRate)
        playback?.podcastStateHandler = { [weak self] itemID, fault in
            self?.applyPodcastPlaybackObservation(itemID: itemID, fault: fault)
        }
        // An episode that ends with nothing behind it stops the audio without
        // changing which item is loaded. The on-screen readout would catch up
        // on its next tick, but the system widget has no tick of its own, so
        // without this it would sit there claiming to be playing. For a
        // podcast episode this is also the only signal that the Producer's
        // own Up Next queue had nothing to advance into, which is where
        // continuing across the Larder picks up.
        playback?.playbackDidFinishHandler = { [weak self] in
            self?.handlePodcastPlaybackFinished()
        }
        podcastDownloadCoordinator = configuredStore.map {
            PodcastDownloadCoordinator(store: $0, libraryDirectory: mediaDirectory)
        }
        podcastPreparationPipeline = fixtureMode ? nil : configuredStore.map {
            PodcastPreparationPipeline(
                store: $0,
                workDirectory: mediaDirectory.appendingPathComponent("preparation", isDirectory: true),
                removeAds: removesAdvertisements
            )
        }
        var selectedSyncFactory = syncTransportFactory
#if WILTED_CLOUDKIT_LIVE
        if !fixtureMode, selectedSyncFactory == nil, let configuredStore {
            let liveConfiguration = WiltedMacLiveSyncConfiguration(
                database: CKContainer(identifier: "iCloud.com.zerodelta.wilted").privateCloudDatabase,
                assetRootURL: mediaDirectory,
                store: configuredStore,
                assetResolver: assetResolver
            )
            selectedSyncFactory = makeWiltedMacLiveSyncTransportFactory(configuration: liveConfiguration)
        }
#endif
        syncLifecycle = configuredStore.map {
            WiltedMacSyncLifecycle(
                store: $0,
                transportFactory: fixtureMode ? nil : selectedSyncFactory,
                assetResolver: assetResolver
            )
        }
    }

    private func restorePodcastPlayback() async {
        guard let playback else { return }
        playbackOperationStatus = "Restoring Up Next…"
        await playback.restorePodcastQueue()
        await refreshPodcastQueueState()
        if let itemID = playback.itemID,
           episodes.contains(where: { $0.id == itemID.rawValue }) {
            currentPodcastEpisodeID = itemID.rawValue
            selectedArticleID = nil
            isPodcastPlayback = true
            isNowPlaying = true
            refreshPlaybackReadout()
            await loadEpisodeTranscript(itemID: itemID)
        }
        playbackOperationStatus = nil
    }

    private func refreshPodcastQueueState() async {
        guard let store, let state = try? await store.podcastQueueState() else { return }
        podcastQueueIDs = state.episodeIDs.map(\.rawValue)
        if isPodcastPlayback {
            let loadedEpisodeID = playback?.itemID?.rawValue
            let activeEpisodeID = loadedEpisodeID.flatMap { id in
                episodes.contains(where: { $0.id == id }) ? id : nil
            }
            currentPodcastEpisodeID = state.currentEpisodeID?.rawValue ?? activeEpisodeID
        }
    }

    private func applyPodcastPlaybackObservation(itemID: ItemID?, fault: PlaybackControllerError?) {
        let movedToAnotherEpisode = itemID != nil && currentPodcastEpisodeID != itemID?.rawValue
        currentPodcastEpisodeID = itemID?.rawValue
        if itemID != nil {
            selectedArticleID = nil
            isPodcastPlayback = true
            isNowPlaying = true
        }
        playbackError = switch fault {
        case .podcastMediaUnavailable?: "This episode's saved audio is unavailable."
        case .podcastMediaUnreadable?: "This episode's saved audio could not be opened."
        case .some: "Podcast playback could not continue."
        case nil: nil
        }
        playbackOperationStatus = nil
        refreshPlaybackReadout()
        // Continuous playback advances the queue without going through
        // `playEpisode`, so the previous episode's transcript would otherwise
        // stay on screen against the new audio.
        if movedToAnotherEpisode, let itemID {
            currentTranscript = .unavailable
            Task { [weak self] in
                guard let self else { return }
                await self.loadEpisodeTranscript(itemID: itemID)
                // The episode just left behind may be the one that finished
                // and pushed the queue into this one; its Played badge is
                // otherwise stale until something else happens to reload it.
                await self.reloadLibraryRows()
            }
        }
    }

    /// Handles a podcast episode running out with nothing queued behind it.
    ///
    /// `PlaybackController` already advances on its own when the Up Next
    /// queue has another entry — that case surfaces through
    /// `applyPodcastPlaybackObservation` instead and never reaches here. Up
    /// Next is a manually curated list though: pressing Play on a single
    /// episode queues only that one, so the ordinary case of a listen
    /// finishing with nothing queued after it is the common one, not the
    /// exception. This is that case: look at the Larder in the order it is
    /// shown and start the next episode that is both downloaded and
    /// successfully prepared, rather than trading one stall for another with
    /// no one watching.
    ///
    /// The episode that just finished is then removed, the same removal the
    /// Skip button performs: a listened episode is done with, and leaving it
    /// in the Larder means the owner clears by hand what playing it to the
    /// end already said.
    private func handlePodcastPlaybackFinished() {
        refreshPlaybackReadout()
        guard isPodcastPlayback, let finishedID = currentPodcastEpisodeID,
              playback?.completed == true, !canSelectNextEpisode else { return }
        Task { [weak self] in
            guard let self else { return }
            // The completed record was already written by the controller
            // before this handler fired; reload so the finished row's Played
            // badge (and any other row that changed underneath it) is
            // current before searching past it.
            await self.reloadLibraryRows()
            let finished = self.episodes.first { $0.id == finishedID }
            // The successor is chosen before the finished episode goes,
            // because the search walks the ordered rows past the finished one
            // and there is nothing to walk past once it has been taken out.
            let next = self.nextReadyEpisode(after: finishedID)
            var note: String?
            if let finished {
                self.hideEpisode(finished)
                note = await self.dismissEpisode(finished)
                    ? "Removed \(finished.title)."
                    : "\(finished.title) could not be removed."
            }
            guard let next else {
                self.podcastOperationMessage = [note, "No other downloaded, prepared episode is ready to play next."]
                    .compactMap { $0 }.joined(separator: " ")
                return
            }
            self.podcastOperationMessage = note
            self.playEpisode(next)
        }
    }

    /// The next episode after `finishedID`, in the same order the Larder
    /// shows them, whose audio is downloaded and whose preparation finished
    /// successfully.
    ///
    /// Already-played rows are skipped so a shorter episode already listened
    /// to does not loop back in; optimistically-hidden rows are skipped for
    /// the same reason `libraryItems` skips them, because a removal the
    /// store has not yet confirmed should not be handed back to the player.
    private func nextReadyEpisode(after finishedID: String) -> WiltedMacEpisode? {
        let ordered = episodes
            .filter { !hiddenEpisodeIDs.contains($0.id) }
            .sorted {
                if $0.releasedAt != $1.releasedAt {
                    return libraryOrder == .newest ? $0.releasedAt > $1.releasedAt : $0.releasedAt < $1.releasedAt
                }
                return $0.id < $1.id
            }
        guard let index = ordered.firstIndex(where: { $0.id == finishedID }) else { return nil }
        return ordered[ordered.index(after: index)...]
            .first { $0.downloadState == .completed && $0.preparationState.isPrepared && !$0.isPlayed }
    }

    /// Re-reads the rows the Library draws from the store.
    ///
    /// Failure is silent on purpose: the rows on screen are the ones the last
    /// successful read produced, and replacing them with nothing because a
    /// refresh failed would take the library away over a transient error.
    private func reloadLibraryRows() async {
        guard let store, let values = try? await loadLibrary(from: store) else { return }
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
    }

    private func loadLibrary(from store: LocalLibraryStore) async throws
        -> (articles: [WiltedMacArticle], episodes: [WiltedMacEpisode], subscriptions: [WiltedMacSubscription]) {
        var articleValues: [WiltedMacArticle] = []
        for article in try await store.articles() where !article.isDeleted {
            let revision = try await store.readyRevision(for: article.itemID)
            articleValues.append(WiltedMacArticle(
                id: article.itemID.rawValue, title: article.title, source: article.source,
                url: article.canonicalURL, isReady: revision != nil,
                durationSeconds: revision?.revision.durationSeconds, createdAt: article.createdAt.date
            ))
        }
        let feeds = Dictionary(uniqueKeysWithValues: try await store.podcastFeeds().map { ($0.itemID, $0) })
        let allSubscriptions = try await store.subscriptions()
        let subscribed = Set(allSubscriptions.filter(\.enabled).map(\.feedID))
        var episodeCounts: [ItemID: Int] = [:]
        for episode in try await store.podcastEpisodes() { episodeCounts[episode.feedID, default: 0] += 1 }
        let subscriptionValues = allSubscriptions.compactMap { subscription -> WiltedMacSubscription? in
            guard let feed = feeds[subscription.feedID] else { return nil }
            return WiltedMacSubscription(
                id: subscription.feedID.rawValue, title: feed.title, feedURL: feed.canonicalURL,
                episodeCount: episodeCounts[subscription.feedID] ?? 0,
                subscribedAt: subscription.subscribedAt.date, enabled: subscription.enabled
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let downloads = Dictionary(uniqueKeysWithValues: try await store.downloads().map { ($0.episodeID, $0) })
        var episodeValues: [WiltedMacEpisode] = []
        let runs = Dictionary(
            uniqueKeysWithValues: ((try? await store.preparationRuns()) ?? [])
                .filter { $0.requestID.hasPrefix(Self.podcastRequestPrefix) }
                .map { ($0.itemID, $0) }
        )
        for episode in try await store.podcastEpisodes() where subscribed.contains(episode.feedID) {
            let revision = try await store.readyRevision(for: episode.itemID)
            let playbackState: PlaybackState?
            if let revision {
                playbackState = try await store.playbackState(
                    for: episode.itemID, revisionID: revision.revision.revisionID
                )
            } else {
                playbackState = nil
            }
            let transcript: Transcript?
            if let revision {
                transcript = try? await store.transcript(for: episode.itemID,
                                                         revisionID: revision.revision.revisionID)
            } else {
                transcript = nil
            }
            let downloadState: WiltedMacEpisodeDownloadState
            switch downloads[episode.itemID]?.status {
            case .queued: downloadState = .queued
            case .downloading:
                let value = downloads[episode.itemID]!
                downloadState = .downloading(received: value.bytesReceived, expected: value.expectedByteCount)
            case .completed: downloadState = .completed
            case .failed: downloadState = .failed
            case .cancelled: downloadState = .cancelled
            case nil: downloadState = .notDownloaded
            }
            let feedTitle = feeds[episode.feedID]?.title ?? "Podcast"
            episodeValues.append(WiltedMacEpisode(
                id: episode.itemID.rawValue, title: episode.title, feedTitle: feedTitle,
                summary: Self.episodeSummary(notes: episode.notes, fallback: episode.author ?? feedTitle),
                notes: episode.notes, artworkURL: episode.artworkURL ?? feeds[episode.feedID]?.artworkURL,
                releasedAt: (episode.publishedTime ?? episode.createdAt).date,
                durationSeconds: revision?.revision.durationSeconds ?? episode.durationSeconds,
                playbackSeconds: playbackState?.positionSeconds ?? 0,
                isPlayed: playbackState?.completed ?? false, downloadState: downloadState,
                preparationState: Self.preparationState(run: runs[episode.itemID], transcript: transcript)
            ))
        }
        return (articleValues, episodeValues, subscriptionValues)
    }

    private func loadDismissedEpisodes(from store: LocalLibraryStore) async throws -> [WiltedMacDismissedEpisode] {
        let feeds = Dictionary(uniqueKeysWithValues: try await store.podcastFeeds().map { ($0.itemID, $0.title) })
        let preparedItemIDs = Set(try await store.preparationRuns().map(\.itemID))
        return try await store.dismissedPodcastEpisodes().map { dismissal in
            WiltedMacDismissedEpisode(
                id: dismissal.episodeID.rawValue,
                feedID: dismissal.feedID?.rawValue,
                title: dismissal.title ?? "Removed podcast episode",
                feedTitle: dismissal.feedID.flatMap { feeds[$0] },
                dismissedAt: dismissal.dismissedAt.date,
                hasPreparationHistory: preparedItemIDs.contains(dismissal.episodeID)
            )
        }
    }

    static let fixtureEpisodeNotes = """
    A walk through the machines that keep the field office quiet.

    Guest: Ada Ferris (https://example.com/ada)
    Sponsor: Quiet Co, code WILTED at https://example.com/quiet
    """

    /// The row's one-liner. The notes' first paragraph says what the episode
    /// is about; the author or show name, the old summary, only says who made it.
    nonisolated static func episodeSummary(notes: String?, fallback: String) -> String {
        let opening = notes?
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
        return String((opening ?? fallback).prefix(180))
    }

    /// What the library already knows about an episode's preparation.
    ///
    /// The stored transcript is the evidence that survives a relaunch: it says
    /// whether the words are synchronised with the audio. The journal supplies
    /// the rest -- a failure worth showing, or a run this process did not start.
    nonisolated static func preparationState(
        run: PreparationRunSummary?, transcript: Transcript?
    ) -> WiltedMacEpisodePreparationState {
        if let run, !run.isTerminal { return .preparing(stage: "Preparing…") }
        // Without a journal the transcript is the only evidence, and it says
        // nothing about advertisements, so that step is not claimed.
        let ready = PodcastPreparationResult.readyLabel
        switch transcript?.timing {
        case .published:
            return .prepared(summary: recordedSummary(of: run)
                             ?? "\(ready) · \(PodcastPreparationResult.transcriptStep(.published))")
        case .aligned:
            return .prepared(summary: recordedSummary(of: run)
                             ?? "\(ready) · \(PodcastPreparationResult.transcriptStep(.aligned))")
        case nil, .some(.none):
            if let run, run.isTerminal, run.outcome == .failed {
                return .failed(preparationFailedLabel)
            }
            if transcript?.availability == .available {
                return .prepared(summary: "\(ready) · \(PodcastPreparationResult.transcriptStep(.none))")
            }
            return .notPrepared
        }
    }

    private nonisolated static func startupFailure(canRetry: Bool) -> WiltedMacStartupFailure {
        WiltedMacStartupFailure(
            message: "Wilted could not open your larder. The existing library was left in place.",
            detail: nil,
            retainedV5StoreURL: nil,
            canRetry: canRetry
        )
    }

    private nonisolated static func retainedV5StoreURLs(for libraryURL: URL) -> [URL] {
        let manager = FileManager.default
        let directory = libraryURL.deletingLastPathComponent()
        let prefix = "\(libraryURL.lastPathComponent).v5-"
        let candidates = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { retainedDirectory -> (URL, Date)? in
                let retainedStore = retainedDirectory.appendingPathComponent(libraryURL.lastPathComponent)
                guard manager.fileExists(atPath: retainedStore.path) else { return nil }
                let values = try? retainedDirectory.resourceValues(forKeys: [.contentModificationDateKey])
                let date = values?.contentModificationDate ?? .distantPast
                return (retainedStore, date)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.path < $1.0.path
            }
            .map(\.0)
    }
#endif

    private func refresh() {
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let values = try? await self.loadLibrary(from: store) else { return }
            self.articles = values.articles
            self.applyEpisodes(values.episodes)
            self.subscriptions = values.subscriptions
            self.dismissedEpisodes = (try? await self.loadDismissedEpisodes(from: store)) ?? self.dismissedEpisodes
        }
    }

    private func installFixture(ready: Bool, preparing: Bool = false, podcasts: Bool = false) {
        if preparing {
            let url = URL(string: "https://example.test/wilted-preparing-fixture")!
            guard let itemID = try? ItemID.derive(from: url) else { return }
            articles = [WiltedMacArticle(
                id: itemID.rawValue, title: "Preparing article", source: "Example source",
                url: url, isReady: false, durationSeconds: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
            return
        }
        guard ready, let store else { return }
        let url = URL(string: "https://example.test/wilted-fixture")!
        guard let itemID = try? ItemID.derive(from: url),
              let article = try? Article(
                itemID: itemID, canonicalURL: url, title: "Fixture article", source: "Example source",
                createdAt: Timestamp(Date())
              ),
              let revisionID = try? RevisionID(rawValue: "fixture-revision"),
              let revision = try? AudioRevision(
                itemID: itemID, revisionID: revisionID, durationSeconds: 120, byteCount: 1,
                contentHash: "sha256:\(String(repeating: "0", count: 64))", mediaType: "audio/mp4",
                createdAt: Timestamp(Date()), schemaVersion: 1
              ) else { return }
        let mediaURL = URL(fileURLWithPath: "/tmp/wilted-fixture.m4a")
        fixtureRevision = StoredAudioRevision(revision: revision, mediaURL: mediaURL)
        let fixtureTranscript = try? Transcript(
            itemID: itemID,
            revisionID: revisionID,
            availability: .available,
            text: "This fixture transcript proves saved article text stays readable while listening.",
            updatedAt: Timestamp(Date())
        )
        articles = [WiltedMacArticle(
            id: itemID.rawValue, title: article.title, source: article.source,
            url: article.canonicalURL, isReady: true, durationSeconds: revision.durationSeconds,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        if podcasts { installPodcastFixture(in: store) }
        Task {
            try? await store.save(article: article)
            if let fixtureTranscript {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: fixtureTranscript)
            } else {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL)
            }
        }
    }

    /// The fixture's prepared episode reads the way a real one does after a
    /// relaunch: the journal's terminal summary, not just "synced".
    static let fixturePreparedSummary = "Ready · 5 ads removed (7:22) · transcript synced"

    private func installPodcastFixture(in store: LocalLibraryStore) {
        let feedURL = URL(string: "https://fixtures.example.test/field-notes.xml")!
        let enclosureURL = URL(string: "https://fixtures.example.test/media/quiet-machines.mp3")!
        guard let feedID = try? ItemID.derivePodcastFeed(from: feedURL),
              let episodeID = try? ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "fixture-episode-001", enclosureURL: enclosureURL
              ),
              let feed = try? PodcastFeed(
                itemID: feedID, canonicalURL: feedURL, title: "Field Notes",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
              ),
              let episode = try? PodcastEpisode(
                itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "fixture-episode-001",
                title: "Quiet Machines", author: "Field Notes desk",
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_699_827_200)),
                enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", durationSeconds: 1_482,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
              ) else { return }
        episodes = [WiltedMacEpisode(
            id: episodeID.rawValue, title: episode.title, feedTitle: feed.title,
            summary: Self.episodeSummary(notes: Self.fixtureEpisodeNotes, fallback: "Field Notes desk"),
            notes: Self.fixtureEpisodeNotes, artworkURL: nil, releasedAt: episode.createdAt.date,
            durationSeconds: episode.durationSeconds, playbackSeconds: 0,
            downloadState: fixtureDownloadFailuresRemaining > 0 ? .notDownloaded : .completed,
            preparationState: fixtureEpisodeIsPrepared ? .prepared(summary: Self.fixturePreparedSummary) : .notPrepared
        )]
        // The Feeds card reads `subscriptions`, which only the store-backed load
        // path populates. Fixture mode assigns the library directly, so it has
        // to supply the same rows -- including a feed the listener has hidden,
        // so the card's hidden-from-Larder state is covered by evidence rather
        // than assumed. The hidden feed is written to the store too, so a
        // reload during a test agrees with what was drawn.
        let hiddenFeedURL = URL(string: "https://fixtures.example.test/quiet-season.xml")!
        let hiddenFeed = try? PodcastFeed(
            itemID: ItemID.derivePodcastFeed(from: hiddenFeedURL), canonicalURL: hiddenFeedURL,
            title: "Quiet Season", createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_740_800))
        )
        subscriptions = [
            WiltedMacSubscription(
                id: feedID.rawValue, title: feed.title, feedURL: feedURL, episodeCount: 1,
                subscribedAt: Date(timeIntervalSince1970: 1_699_827_200), enabled: true
            ),
        ] + (hiddenFeed.map { hidden in
            [WiltedMacSubscription(
                id: hidden.itemID.rawValue, title: hidden.title, feedURL: hiddenFeedURL, episodeCount: 0,
                subscribedAt: Date(timeIntervalSince1970: 1_699_740_800), enabled: false
            )]
        } ?? [])
        let mediaURL = mediaDirectory.appendingPathComponent("fixture-podcast.mp3")
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: mediaURL.path, contents: Data([0]))
        let revision = try? AudioRevision(
            itemID: episodeID, revisionID: RevisionID(rawValue: "fixture-podcast-revision"),
            durationSeconds: 1_482, byteCount: 1,
            contentHash: "sha256:" + String(repeating: "9", count: 64), mediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200)), schemaVersion: 1
        )
        fixturePodcastInstallTask = Task {
            try? await store.save(feed: feed)
            try? await store.save(episode: episode)
            try? await store.save(subscription: PodcastSubscription(
                feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
            ))
            if let hiddenFeed {
                try? await store.save(feed: hiddenFeed)
                try? await store.save(subscription: PodcastSubscription(
                    feedID: hiddenFeed.itemID,
                    subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_699_740_800)), enabled: false
                ))
            }
            if let revision { try? await store.saveReadyRevision(revision, mediaURL: mediaURL) }
            // A prepared fixture episode has a history for Prep to read, in
            // the worker's own vocabulary, so the detailed log is exercised
            // through the same journal the real pipeline writes.
            if fixtureEpisodeIsPrepared {
                let requestID = Self.podcastRequestPrefix + episodeID.rawValue
                let started = Date(timeIntervalSince1970: 1_699_830_000)
                let journalled: [(String, PreparationStage, String, Double?)] = [
                    ("pipeline.start", .preparing, episode.title, nil),
                    ("transcript.stt.start", .extracting, "transcript.stt.start", nil),
                    ("ads.detect.calls", .assembling, "50 requests, 0 failed", nil),
                    ("ads.detect.span.1", .assembling, "0:01:20–0:02:10 · host read · 91%", nil),
                    ("ads.cut.complete", .assembling, "442.12 s removed", 0.9),
                ]
                for (offset, (stage, coarse, detail, fraction)) in journalled.enumerated() {
                    guard let status = try? PreparationStatus(
                        stage: coarse, detail: detail, fraction: fraction, cancellable: true,
                        emittedAt: Timestamp(started.addingTimeInterval(Double(offset) * 60))
                    ) else { continue }
                    try? await store.record(preparation: PreparationJournalEntry(
                        id: requestID + "|" + stage, itemID: episodeID, requestID: requestID, status: status
                    ))
                }
                if let terminal = try? PreparationTerminalResult(outcome: .succeeded, revisionID: revision?.revisionID),
                   let status = try? PreparationStatus(
                    stage: .completed, detail: Self.fixturePreparedSummary, cancellable: false, terminalResult: terminal,
                    emittedAt: Timestamp(started.addingTimeInterval(300))
                   ) {
                    try? await store.record(preparation: PreparationJournalEntry(
                        id: requestID + "|terminal", itemID: episodeID, requestID: requestID, status: status
                    ))
                }
            }
        }
    }

    /// Jumps playback to a transcript line the listener picked.
    func seekToTranscriptCue(_ cue: WiltedMacTranscriptCue) {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(to: cue.startSeconds)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#endif
    }

    /// The transcript line the audio is currently in, if the transcript is
    /// synchronised with it.
    /// What preparation cut out of the episode now playing.
    ///
    /// Empty for an article, which is synthesized from text and has nothing to
    /// cut, and for an episode played from an unprepared revision.
    var currentRemovedSpans: [WiltedMacRemovedSpan] {
        guard let currentPodcastEpisodeID else { return [] }
        return removedSpansByEpisode[currentPodcastEpisodeID] ?? []
    }

    var activeTranscriptCueID: Int? {
        currentTranscript?.cueIndex(at: playbackPositionSeconds)
    }

    private func seek(by seconds: TimeInterval) {
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(by: seconds)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
    }

    private func navigatePodcastQueue(previous: Bool) {
#if canImport(WiltedProducer)
        guard let playback, isPodcastPlayback else { return }
        playbackOperationStatus = previous ? "Opening previous episode…" : "Opening next episode…"
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selected = try await (previous
                    ? playback.selectPreviousPodcastQueueEpisode()
                    : playback.selectNextPodcastQueueEpisode())
                if selected {
                    await self.refreshPodcastQueueState()
                    self.refreshPlaybackReadout()
                    self.playbackError = nil
                }
                self.playbackOperationStatus = nil
            } catch {
                self.playbackOperationStatus = nil
                self.playbackError = previous
                    ? "The previous episode is unavailable."
                    : "The next episode is unavailable."
            }
        }
#endif
    }

    private static func stateDirectory(fixtureMode: Bool) -> URL {
        if fixtureMode {
            let temporaryDirectory = FileManager.default.temporaryDirectory
            // XCUITest terminates the fixture host it drives by design, so this
            // process's own previous wilted-ui-fixture-<pid> directory (from a
            // prior launch that never got to run any cleanup, trapped or
            // otherwise) is still sitting in $TMPDIR. Shell callers get this
            // from scripts/lib/temp-sweep.sh; this is its Swift equivalent,
            // scoped only to the family this function itself creates. The 24h
            // cutoff mirrors that library's and is the same safety argument: a
            // directory nothing has touched in a day belongs to a run that is
            // not coming back, and a fixture launch that is still running is at
            // most minutes old.
            sweepStaleFixtureDirectories(in: temporaryDirectory)
            return temporaryDirectory
                .appendingPathComponent(
                    "wilted-ui-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
                )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Wilted", isDirectory: true)
    }

    /// Removes abandoned `wilted-ui-fixture-*` directories under `root` older
    /// than 24 hours. Never throws and never fails the caller: this is
    /// housekeeping in front of a fixture launch, not a precondition for one.
    private static func sweepStaleFixtureDirectories(in root: URL) {
        let maxAge: TimeInterval = 24 * 60 * 60
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            // Re-validated here, in the loop that deletes, not only by relying
            // on this being the only prefix `stateDirectory` ever mints.
            guard entry.lastPathComponent.hasPrefix("wilted-ui-fixture-") else { continue }
            guard let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate), modified < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
#endif
}

#if canImport(WiltedProducer)
@MainActor
private final class WiltedFixturePlaybackBackend: PlaybackBackend {
    var duration: TimeInterval = 120
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var rate: Float = 1
    var volume: Float = 1
    private(set) var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    func load(url: URL) throws {
        loadedGeneration += 1
        isPlaying = false
        duration = url.lastPathComponent.contains("podcast") ? 1_482 : 120
    }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func finish(successfully: Bool) {
        isPlaying = false
        completionHandler?(loadedGeneration, successfully)
    }
}

/// The real audio backend with its output pinned to silence.
///
/// A test that plays an episode plays it out of the machine's speakers: a tone
/// during a gate run with nothing on screen to say where it came from. The
/// scripted fixture backend above is not a substitute, because it invents its
/// duration from the file name and the tests that play do so to assert on real
/// durations and on completion firing off the audio clock. So the real backend
/// does the work and only its output is taken away.
///
/// The mute is applied twice on purpose. `AVAudioPlayerBackend.load` copies its
/// own stored volume onto each new player, so the inner backend has to start at
/// zero; and the model pushes the owner's saved volume through
/// `PlaybackController.setVolume` on every load, so the setter here is answered
/// rather than obeyed.
@MainActor
private final class WiltedSilentPlaybackBackend: PlaybackBackend {
    private let inner = AVAudioPlayerBackend()

    init() { inner.volume = 0 }

    var duration: TimeInterval { inner.duration }
    var currentTime: TimeInterval {
        get { inner.currentTime }
        set { inner.currentTime = newValue }
    }
    var isPlaying: Bool { inner.isPlaying }
    var rate: Float {
        get { inner.rate }
        set { inner.rate = newValue }
    }
    var volume: Float {
        get { inner.volume }
        set { _ = newValue }
    }
    var loadedGeneration: UInt64 { inner.loadedGeneration }
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)? {
        get { inner.completionHandler }
        set { inner.completionHandler = newValue }
    }

    func load(url: URL) throws { try inner.load(url: url) }
    @discardableResult func play() -> Bool { inner.play() }
    func pause() { inner.pause() }
    func stop() { inner.stop() }
}
#endif
