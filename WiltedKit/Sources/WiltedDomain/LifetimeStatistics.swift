import Foundation

/// Device-local lifetime counters. These values are never synchronized or
/// reconstructed from mutable library rows.
public struct LifetimeStatistics: Equatable, Sendable {
    public var audioProcessedSeconds: Double
    public var speechGeneratedSeconds: Double
    public var confirmedAdTimeRemovedSeconds: Double
    public var fasterPlaybackTimeSavedSeconds: Double

    public init(
        audioProcessedSeconds: Double = 0,
        speechGeneratedSeconds: Double = 0,
        confirmedAdTimeRemovedSeconds: Double = 0,
        fasterPlaybackTimeSavedSeconds: Double = 0
    ) {
        self.audioProcessedSeconds = audioProcessedSeconds
        self.speechGeneratedSeconds = speechGeneratedSeconds
        self.confirmedAdTimeRemovedSeconds = confirmedAdTimeRemovedSeconds
        self.fasterPlaybackTimeSavedSeconds = fasterPlaybackTimeSavedSeconds
    }
}

/// The only four quantities admitted to the append-only local event ledger.
public enum LifetimeStatisticKind: String, CaseIterable, Codable, Sendable {
    case audioProcessed
    case speechGenerated
    case confirmedAdTimeRemoved
    case fasterPlaybackTimeSaved
}

/// One validated contribution to the device-local append-only ledger.
public struct LifetimeStatisticContribution: Equatable, Sendable {
    public let id: String
    public let kind: LifetimeStatisticKind
    public let seconds: Double

    public init(id: String, kind: LifetimeStatisticKind, seconds: Double) {
        self.id = id
        self.kind = kind
        self.seconds = seconds
    }
}

/// Stable event identifiers shared by producers and regression tests.
public enum LifetimeStatisticEventID {
    public static func articleSpeech(revisionID: RevisionID) -> String {
        "article-speech|\(revisionID.rawValue)"
    }

    public static func podcastAudioProcessed(sourceRevisionID: RevisionID) -> String {
        "podcast-audio-processed|\(sourceRevisionID.rawValue)"
    }

    public static func podcastAdRemoved(revisionID: RevisionID) -> String {
        "podcast-ad-removed|\(revisionID.rawValue)"
    }
}
