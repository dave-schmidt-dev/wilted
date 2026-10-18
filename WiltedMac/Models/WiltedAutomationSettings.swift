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

    /// The one listener-facing value used by Settings for each bounded choice.
    var settingsControlLabel: String {
        switch self {
        case .manual: "Manual"
        case .onLaunch: "On launch"
        case .whileOpen(everyHours: 6): "Every 6 hours while open"
        case .whileOpen(everyHours: 12): "Every 12 hours while open"
        case .whileOpen(everyHours: 24): "Every 24 hours while open"
        case .whileOpen: ""
        }
    }

    static func fromSettingsControlLabel(_ label: String) -> Self? {
        switch label {
        case "Manual": .manual
        case "On launch": .onLaunch
        case "Every 6 hours while open": .whileOpen(everyHours: 6)
        case "Every 12 hours while open": .whileOpen(everyHours: 12)
        case "Every 24 hours while open": .whileOpen(everyHours: 24)
        default: nil
        }
    }
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

    var settingsControlLabel: String {
        switch self {
        case .manual: "Manual"
        case .newestOnePerEnabledFeed: "Newest 1 per feed"
        case .newestThreePerEnabledFeed: "Newest 3 per feed"
        case .allNewlyAdmittedUpToTwenty: "All newly admitted, up to 20"
        }
    }

    static func fromSettingsControlLabel(_ label: String) -> Self? {
        switch label {
        case "Manual": .manual
        case "Newest 1 per feed": .newestOnePerEnabledFeed
        case "Newest 3 per feed": .newestThreePerEnabledFeed
        case "All newly admitted, up to 20": .allNewlyAdmittedUpToTwenty
        default: nil
        }
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

    var settingsControlLabel: String {
        switch self {
        case .immediate: "Immediately"
        case .manual: "Manual"
        case .offPeak: "Off-peak"
        }
    }

    static func fromSettingsControlLabel(_ label: String, window: WiltedAutomationOffPeakWindow) -> Self? {
        switch label {
        case "Immediately": .immediate
        case "Manual": .manual
        case "Off-peak": .offPeak(window)
        default: nil
        }
    }
}

/// The transcript source order selected for future podcast preparation.
enum WiltedAutomationTranscriptPolicy: String, Equatable, Sendable, Codable {
    case bestAvailable
    case alwaysTranscribe
    case noLocalSTT

    var settingsControlLabel: String {
        switch self {
        case .bestAvailable: "Best available"
        case .alwaysTranscribe: "Always transcribe"
        case .noLocalSTT: "No local speech-to-text"
        }
    }

    static func fromSettingsControlLabel(_ label: String) -> Self? {
        switch label {
        case "Best available": .bestAvailable
        case "Always transcribe": .alwaysTranscribe
        case "No local speech-to-text": .noLocalSTT
        default: nil
        }
    }
}

extension WiltedAutomationStatus {
    /// Idle and terminal results do not advertise a Stop action: only a pass
    /// that can still be interrupted belongs in Settings' live-status row.
    var isCancellable: Bool {
        switch self {
        case .refreshing, .downloading, .retrying: true
        case .idle, .failed, .cancelled, .finished: false
        }
    }

    var settingsStatusText: String {
        switch self {
        case let .refreshing(feedsRemaining):
            "Refreshing \(feedsRemaining) feed\(feedsRemaining == 1 ? "" : "s")"
        case let .downloading(episode, remaining):
            "Downloading \(episode)\(remaining > 0 ? " (\(remaining) remaining)" : "")"
        case let .retrying(afterSeconds, attempt):
            "Retrying in \(Int(afterSeconds.rounded())) seconds (attempt \(attempt))"
        case .idle: "Idle"
        case let .failed(message): "Failed: \(message)"
        case .cancelled: "Stopped"
        case let .finished(refreshed, downloaded, failed):
            Self.finishedStatusText(refreshed: refreshed, downloaded: downloaded, failed: failed)
        }
    }

    private static func finishedStatusText(refreshed: Int, downloaded: Int, failed: Int) -> String {
        if failed == 0 { return "Finished: \(refreshed) refreshed, \(downloaded) downloaded" }
        if refreshed + downloaded == 0 { return "Could not finish: \(failed) failed. Will try again." }
        return "Finished: \(refreshed) refreshed, \(downloaded) downloaded, \(failed) failed"
    }
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
        autoAddPreparedToLarder: true,
        downloadEverythingOnLarder: false,
        prepareEverythingDownloaded: false,
        initialEpisodeMetadataCount: 5,
        autoKeepNewEpisodes: false,
        keptLimitPerFeed: nil
    )

    let version: Int
    let refreshPolicy: WiltedAutomationRefreshPolicy
    let downloadPolicy: WiltedAutomationDownloadPolicy
    let processingPolicy: WiltedAutomationProcessingPolicy
    let transcriptPolicy: WiltedAutomationTranscriptPolicy
    let removeAds: Bool

    /// Whether an episode that finishes preparing joins the Larder on its own.
    /// Defaulted rather than required at every call site: a listener who
    /// prepares an episode almost always means to listen to it, and the
    /// existing tests describe automation policies, not queueing.
    let autoAddPreparedToLarder: Bool

    /// Whether everything on the Larder is fetched as soon as it waits. Off by
    /// default: downloads cost disk and bandwidth, so this is a deliberate
    /// override of the one-step-at-a-time row action, not a default policy.
    let downloadEverythingOnLarder: Bool

    /// Whether everything downloaded on the Larder starts preparing on its own.
    /// Off by default for the same reason: preparation spends model time.
    let prepareEverythingDownloaded: Bool

    /// Initial subscription metadata only; it never admits audio, downloads, or Keeps.
    let initialEpisodeMetadataCount: Int

    /// The global Auto keep that every feed set to Use global inherits. Off by
    /// default, so refresh gains no authority until the listener grants it.
    let autoKeepNewEpisodes: Bool

    /// The global kept limit for feeds set to Use global: a positive count, or
    /// nil for no limit.
    let keptLimitPerFeed: Int?

    // MARK: Reports (B6.4). Absent keys decode to these defaults, so a file saved
    // before Reports existed keeps every other preference and interruptions stay off.
    // Change them through `updatingReports`, which clamps and validates.

    /// Whether the Mac may pause playback at a pause point to read a bulletin. Off until chosen.
    private(set) var interruptionsEnabled = false
    private(set) var alertsEnabled = true
    private(set) var headlinesEnabled = true
    /// How long a waiting bulletin may wait for a pause point before it is dropped.
    private(set) var waitLimitSeconds = 60
    private(set) var headlineMinimumGapMinutes = 30
    private(set) var reportEnabled = false
    private(set) var reportTime = WiltedAutomationLocalTime(hour: 7, minute: 0)!
    /// Raw typed position; read through `typedCoordinates`, which rounds and validates.
    private(set) var typedLatitude: Double?
    private(set) var typedLongitude: Double?
    /// Contact sent to the National Weather Service in the User-Agent; empty until entered.
    private(set) var nwsContact = ""

    static let waitLimitRange = 10...300
    static let headlineGapRange = 5...240
    static let nwsContactLimit = 200

    init(refreshPolicy: WiltedAutomationRefreshPolicy, downloadPolicy: WiltedAutomationDownloadPolicy,
         processingPolicy: WiltedAutomationProcessingPolicy, transcriptPolicy: WiltedAutomationTranscriptPolicy,
         removeAds: Bool, autoAddPreparedToLarder: Bool = true,
         downloadEverythingOnLarder: Bool = false, prepareEverythingDownloaded: Bool = false,
         initialEpisodeMetadataCount: Int = 5, autoKeepNewEpisodes: Bool = false,
         keptLimitPerFeed: Int? = nil) {
        version = Self.currentVersion
        self.refreshPolicy = refreshPolicy
        self.downloadPolicy = downloadPolicy
        self.processingPolicy = processingPolicy
        self.transcriptPolicy = transcriptPolicy
        self.removeAds = removeAds
        self.autoAddPreparedToLarder = autoAddPreparedToLarder
        self.downloadEverythingOnLarder = downloadEverythingOnLarder
        self.prepareEverythingDownloaded = prepareEverythingDownloaded
        self.initialEpisodeMetadataCount = Self.validInitialEpisodeMetadataCount(initialEpisodeMetadataCount) ?? 5
        self.autoKeepNewEpisodes = autoKeepNewEpisodes
        self.keptLimitPerFeed = keptLimitPerFeed.flatMap { $0 > 0 ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case version, refreshPolicy, downloadPolicy, processingPolicy, transcriptPolicy, removeAds
        // Stored settings keep the keys they were written under; only the Swift names moved.
        case autoAddPreparedToLarder = "autoAddPreparedToMenu"
        case downloadEverythingOnLarder = "downloadEverythingOnMenu"
        case prepareEverythingDownloaded
        case initialEpisodeMetadataCount
        case autoKeepNewEpisodes
        case keptLimitPerFeed
        case legacyReadableTranscriptPass = "readableTranscriptPass"
        case interruptionsEnabled, alertsEnabled, headlinesEnabled, waitLimitSeconds, headlineMinimumGapMinutes
        case reportEnabled, reportTime, typedLatitude, typedLongitude, nwsContact
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
        // Absent in settings saved before the Larder learned to fill itself.
        // Decoded permissively rather than behind a version bump, because
        // refusing to read an otherwise valid file would reset every other
        // preference to answer a question the file simply predates.
        autoAddPreparedToLarder = try container.decodeIfPresent(Bool.self, forKey: .autoAddPreparedToLarder) ?? true
        // Absent in settings saved before the Larder overrides existed. Off is
        // the answer the file would give if it were written today, and a
        // missing key is not evidence the reader ever asked for either.
        downloadEverythingOnLarder =
            try container.decodeIfPresent(Bool.self, forKey: .downloadEverythingOnLarder) ?? false
        prepareEverythingDownloaded =
            try container.decodeIfPresent(Bool.self, forKey: .prepareEverythingDownloaded) ?? false
        initialEpisodeMetadataCount = Self.validInitialEpisodeMetadataCount(
            try container.decodeIfPresent(Int.self, forKey: .initialEpisodeMetadataCount) ?? 5
        ) ?? 5
        // Absent in settings saved before feeds gained global Auto keep and a
        // kept limit: off and unlimited, which is what those installs did.
        autoKeepNewEpisodes = try container.decodeIfPresent(Bool.self, forKey: .autoKeepNewEpisodes) ?? false
        keptLimitPerFeed = (try container.decodeIfPresent(Int.self, forKey: .keptLimitPerFeed))
            .flatMap { $0 > 0 ? $0 : nil }
        interruptionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .interruptionsEnabled) ?? false
        alertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true
        headlinesEnabled = try container.decodeIfPresent(Bool.self, forKey: .headlinesEnabled) ?? true
        waitLimitSeconds = Self.clamped(
            try container.decodeIfPresent(Int.self, forKey: .waitLimitSeconds), Self.waitLimitRange, default: 60)
        headlineMinimumGapMinutes = Self.clamped(
            try container.decodeIfPresent(Int.self, forKey: .headlineMinimumGapMinutes), Self.headlineGapRange, default: 30)
        reportEnabled = try container.decodeIfPresent(Bool.self, forKey: .reportEnabled) ?? false
        // A malformed time falls back to 07:00 rather than refusing the whole file.
        reportTime = (try? container.decodeIfPresent(WiltedAutomationLocalTime.self, forKey: .reportTime))
            ?? WiltedAutomationLocalTime(hour: 7, minute: 0)!
        let latitude = try container.decodeIfPresent(Double.self, forKey: .typedLatitude)
        let longitude = try container.decodeIfPresent(Double.self, forKey: .typedLongitude)
        let typed = latitude.flatMap { lat in longitude.flatMap { WiltedCoordinates(latitude: lat, longitude: $0) } }
        typedLatitude = typed?.latitude
        typedLongitude = typed?.longitude
        nwsContact = Self.cleanedContact(try container.decodeIfPresent(String.self, forKey: .nwsContact) ?? "")
        // Settings saved before the single-pass pipeline included this no-op
        // preference. Deliberately accept and discard it on migration.
        _ = try? container.decode(Bool.self, forKey: .legacyReadableTranscriptPass)
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
        try container.encode(autoAddPreparedToLarder, forKey: .autoAddPreparedToLarder)
        try container.encode(downloadEverythingOnLarder, forKey: .downloadEverythingOnLarder)
        try container.encode(prepareEverythingDownloaded, forKey: .prepareEverythingDownloaded)
        try container.encode(initialEpisodeMetadataCount, forKey: .initialEpisodeMetadataCount)
        try container.encode(autoKeepNewEpisodes, forKey: .autoKeepNewEpisodes)
        try container.encodeIfPresent(keptLimitPerFeed, forKey: .keptLimitPerFeed)
        try container.encode(interruptionsEnabled, forKey: .interruptionsEnabled)
        try container.encode(alertsEnabled, forKey: .alertsEnabled)
        try container.encode(headlinesEnabled, forKey: .headlinesEnabled)
        try container.encode(waitLimitSeconds, forKey: .waitLimitSeconds)
        try container.encode(headlineMinimumGapMinutes, forKey: .headlineMinimumGapMinutes)
        try container.encode(reportEnabled, forKey: .reportEnabled)
        try container.encode(reportTime, forKey: .reportTime)
        try container.encodeIfPresent(typedLatitude, forKey: .typedLatitude)
        try container.encodeIfPresent(typedLongitude, forKey: .typedLongitude)
        try container.encode(nwsContact, forKey: .nwsContact)
    }

    /// The typed position, rounded to 2 decimals; nil unless both halves are present and in range.
    var typedCoordinates: WiltedCoordinates? {
        guard let typedLatitude, let typedLongitude else { return nil }
        return WiltedCoordinates(latitude: typedLatitude, longitude: typedLongitude)
    }

    /// These settings with the Reports fields changed by `change`; everything else is kept.
    /// Out-of-range numbers are clamped, an invalid typed pair is cleared and the contact is trimmed.
    func updatingReports(_ change: (_ reports: inout ReportsFields) -> Void) -> Self {
        var fields = ReportsFields(self)
        change(&fields)
        var copy = self
        copy.interruptionsEnabled = fields.interruptionsEnabled
        copy.alertsEnabled = fields.alertsEnabled
        copy.headlinesEnabled = fields.headlinesEnabled
        copy.waitLimitSeconds = Self.clamped(fields.waitLimitSeconds, Self.waitLimitRange, default: 60)
        copy.headlineMinimumGapMinutes = Self.clamped(fields.headlineMinimumGapMinutes, Self.headlineGapRange, default: 30)
        copy.reportEnabled = fields.reportEnabled
        copy.reportTime = fields.reportTime
        let typed = fields.typedLatitude.flatMap { lat in
            fields.typedLongitude.flatMap { WiltedCoordinates(latitude: lat, longitude: $0) }
        }
        copy.typedLatitude = typed?.latitude
        copy.typedLongitude = typed?.longitude
        copy.nwsContact = Self.cleanedContact(fields.nwsContact)
        return copy
    }

    /// The editable Reports values, for `updatingReports`.
    struct ReportsFields {
        var interruptionsEnabled: Bool
        var alertsEnabled: Bool
        var headlinesEnabled: Bool
        var waitLimitSeconds: Int
        var headlineMinimumGapMinutes: Int
        var reportEnabled: Bool
        var reportTime: WiltedAutomationLocalTime
        var typedLatitude: Double?
        var typedLongitude: Double?
        var nwsContact: String

        init(_ settings: WiltedAutomationSettings) {
            interruptionsEnabled = settings.interruptionsEnabled
            alertsEnabled = settings.alertsEnabled
            headlinesEnabled = settings.headlinesEnabled
            waitLimitSeconds = settings.waitLimitSeconds
            headlineMinimumGapMinutes = settings.headlineMinimumGapMinutes
            reportEnabled = settings.reportEnabled
            reportTime = settings.reportTime
            typedLatitude = settings.typedLatitude
            typedLongitude = settings.typedLongitude
            nwsContact = settings.nwsContact
        }
    }

    /// These settings with the Reports fields of `other`; used where a rebuild goes through `init`.
    func carryingReports(of other: Self) -> Self {
        updatingReports { $0 = ReportsFields(other) }
    }

    private static func clamped(_ value: Int?, _ range: ClosedRange<Int>, default fallback: Int) -> Int {
        guard let value else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func cleanedContact(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nwsContactLimit))
    }

    /// These settings with the global Auto keep replaced; everything else is kept.
    func settingAutoKeepNewEpisodes(_ value: Bool) -> Self {
        Self(
            refreshPolicy: refreshPolicy, downloadPolicy: downloadPolicy, processingPolicy: processingPolicy,
            transcriptPolicy: transcriptPolicy, removeAds: removeAds, autoAddPreparedToLarder: autoAddPreparedToLarder,
            downloadEverythingOnLarder: downloadEverythingOnLarder, prepareEverythingDownloaded: prepareEverythingDownloaded,
            initialEpisodeMetadataCount: initialEpisodeMetadataCount, autoKeepNewEpisodes: value,
            keptLimitPerFeed: keptLimitPerFeed
        ).carryingReports(of: self)
    }

    /// These settings with the global kept limit replaced (nil is No limit); everything else is kept.
    func settingKeptLimitPerFeed(_ limit: Int?) -> Self {
        Self(
            refreshPolicy: refreshPolicy, downloadPolicy: downloadPolicy, processingPolicy: processingPolicy,
            transcriptPolicy: transcriptPolicy, removeAds: removeAds, autoAddPreparedToLarder: autoAddPreparedToLarder,
            downloadEverythingOnLarder: downloadEverythingOnLarder, prepareEverythingDownloaded: prepareEverythingDownloaded,
            initialEpisodeMetadataCount: initialEpisodeMetadataCount, autoKeepNewEpisodes: autoKeepNewEpisodes,
            keptLimitPerFeed: limit
        ).carryingReports(of: self)
    }

    static func validInitialEpisodeMetadataCount(_ value: Int) -> Int? { (1...100).contains(value) ? value : nil }

    var isValid: Bool {
        version == Self.currentVersion && refreshPolicy.isValid
            && Self.validInitialEpisodeMetadataCount(initialEpisodeMetadataCount) != nil
    }

    /// True when the two saved preferences cannot both be honoured. Ad removal
    /// is timed from an aligned local pass and never from a publisher's cues,
    /// so with local speech-to-text forbidden the worker refuses every
    /// preparation before it spends any model time. Computed rather than
    /// stored: a configuration saved before removal required the aligned pass
    /// is a legitimate file, and re-versioning the format to record a fact
    /// derivable from it would refuse to decode it for nothing.
    var transcriptPolicyBlocksAdRemoval: Bool {
        removeAds && transcriptPolicy == .noLocalSTT
    }

    /// Says what the pair does and how to leave it, in that order, because the
    /// reader is looking at both controls and either one resolves it.
    static let transcriptPolicyBlocksAdRemovalExplanation =
        "Removing ads needs a local transcript timed to this audio, so no episode will prepare "
        + "while the transcript source is No local speech-to-text. Turn off Remove ads, or choose "
        + "another transcript source."
}

#if canImport(WiltedProducer)
extension WiltedAutomationSettings {
    /// The global values every feed set to Use global inherits. It is the one
    /// definition admission resolves against, so Settings, the per-feed
    /// summary and the episodes admitted can never disagree.
    var feedAutomationDefaults: FeedAutomationGlobalDefaults {
        EpisodeAdmissionService.globalDefaults(self)
    }
}

/// The listener-facing words for a resolved feed policy. The per-feed summary
/// and the Settings defaults both read their rows from here.
enum WiltedFeedAutomationSummary {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    static func rows(_ policy: EffectiveFeedAutomationPolicy) -> [Row] {
        [
            Row(label: "Auto keep", value: onOff(policy.autoKeep)),
            Row(label: "Auto download", value: onOff(policy.autoDownload)),
            Row(label: "Auto prepare", value: onOff(policy.autoPrepare)),
            Row(label: "Kept limit", value: limitText(policy.keptLimit)),
        ]
    }

    /// What a feed set to Use global resolves to under these settings.
    static func globalRows(_ settings: WiltedAutomationSettings) -> [Row] {
        rows(FeedAutomationPolicy().resolved(using: settings.feedAutomationDefaults))
    }

    static func limitText(_ limit: Int?) -> String {
        guard let limit else { return "No limit" }
        return limit == 1 ? "1 episode" : "\(limit) episodes"
    }

    private static func onOff(_ value: Bool) -> String { value ? "On" : "Off" }
}
#endif
