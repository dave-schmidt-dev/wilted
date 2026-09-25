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
        case let .finished(refreshed, downloaded):
            "Finished: \(refreshed) refreshed, \(downloaded) downloaded"
        }
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
        autoAddPreparedToMenu: true,
        downloadEverythingOnMenu: false,
        prepareEverythingDownloaded: false
    )

    let version: Int
    let refreshPolicy: WiltedAutomationRefreshPolicy
    let downloadPolicy: WiltedAutomationDownloadPolicy
    let processingPolicy: WiltedAutomationProcessingPolicy
    let transcriptPolicy: WiltedAutomationTranscriptPolicy
    let removeAds: Bool

    /// Whether an episode that finishes preparing joins the Menu on its own.
    /// Defaulted rather than required at every call site: a listener who
    /// prepares an episode almost always means to listen to it, and the
    /// existing tests describe automation policies, not queueing.
    let autoAddPreparedToMenu: Bool

    /// Whether everything on the Menu is fetched as soon as it waits. Off by
    /// default: downloads cost disk and bandwidth, so this is a deliberate
    /// override of the one-step-at-a-time row action, not a default policy.
    let downloadEverythingOnMenu: Bool

    /// Whether everything downloaded on the Menu starts preparing on its own.
    /// Off by default for the same reason: preparation spends model time.
    let prepareEverythingDownloaded: Bool

    init(refreshPolicy: WiltedAutomationRefreshPolicy, downloadPolicy: WiltedAutomationDownloadPolicy,
         processingPolicy: WiltedAutomationProcessingPolicy, transcriptPolicy: WiltedAutomationTranscriptPolicy,
         removeAds: Bool, autoAddPreparedToMenu: Bool = true,
         downloadEverythingOnMenu: Bool = false, prepareEverythingDownloaded: Bool = false) {
        version = Self.currentVersion
        self.refreshPolicy = refreshPolicy
        self.downloadPolicy = downloadPolicy
        self.processingPolicy = processingPolicy
        self.transcriptPolicy = transcriptPolicy
        self.removeAds = removeAds
        self.autoAddPreparedToMenu = autoAddPreparedToMenu
        self.downloadEverythingOnMenu = downloadEverythingOnMenu
        self.prepareEverythingDownloaded = prepareEverythingDownloaded
    }

    private enum CodingKeys: String, CodingKey {
        case version, refreshPolicy, downloadPolicy, processingPolicy, transcriptPolicy, removeAds
        case autoAddPreparedToMenu
        case downloadEverythingOnMenu
        case prepareEverythingDownloaded
        case legacyReadableTranscriptPass = "readableTranscriptPass"
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
        // Absent in settings saved before the Menu learned to fill itself.
        // Decoded permissively rather than behind a version bump, because
        // refusing to read an otherwise valid file would reset every other
        // preference to answer a question the file simply predates.
        autoAddPreparedToMenu = try container.decodeIfPresent(Bool.self, forKey: .autoAddPreparedToMenu) ?? true
        // Absent in settings saved before the Menu overrides existed. Off is
        // the answer the file would give if it were written today, and a
        // missing key is not evidence the reader ever asked for either.
        downloadEverythingOnMenu =
            try container.decodeIfPresent(Bool.self, forKey: .downloadEverythingOnMenu) ?? false
        prepareEverythingDownloaded =
            try container.decodeIfPresent(Bool.self, forKey: .prepareEverythingDownloaded) ?? false
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
        try container.encode(autoAddPreparedToMenu, forKey: .autoAddPreparedToMenu)
        try container.encode(downloadEverythingOnMenu, forKey: .downloadEverythingOnMenu)
        try container.encode(prepareEverythingDownloaded, forKey: .prepareEverythingDownloaded)
    }

    var isValid: Bool { version == Self.currentVersion && refreshPolicy.isValid }

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
