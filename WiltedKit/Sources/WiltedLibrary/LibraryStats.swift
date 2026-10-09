import Foundation
import WiltedDomain

/// The Mac's lifetime statistics as published to other devices. The Mac is the only writer
/// (W-INV-005): a phone reads this record and never derives or accumulates statistics itself.
///
/// The four seconds fields mirror `LifetimeStatistics`. The optional fields are reserved for
/// later metrics; a writer that has no value leaves them nil, and a reader that predates a
/// field ignores it, so adding one never breaks an older client.
public struct LibraryStats: Codable, Equatable, Sendable {
    public var audioProcessedSeconds: Double
    public var speechGeneratedSeconds: Double
    public var confirmedAdTimeRemovedSeconds: Double
    public var fasterPlaybackTimeSavedSeconds: Double
    public var minutesPlayed: Double?
    public var gigabytesDownloaded: Double?
    public var minutesSkipped: Double?
    /// When the Mac last published these values.
    public var updatedAt: Date?
    /// Names of the intent actions this Mac applies (for example `subscribe`, `addArticle`). Nil
    /// from a Mac that predates the field, so a phone sends only what it sees listed.
    public var supportedIntentActions: [String]?

    public init(
        audioProcessedSeconds: Double = 0,
        speechGeneratedSeconds: Double = 0,
        confirmedAdTimeRemovedSeconds: Double = 0,
        fasterPlaybackTimeSavedSeconds: Double = 0,
        minutesPlayed: Double? = nil,
        gigabytesDownloaded: Double? = nil,
        minutesSkipped: Double? = nil,
        updatedAt: Date? = nil,
        supportedIntentActions: [String]? = nil
    ) {
        self.audioProcessedSeconds = audioProcessedSeconds
        self.speechGeneratedSeconds = speechGeneratedSeconds
        self.confirmedAdTimeRemovedSeconds = confirmedAdTimeRemovedSeconds
        self.fasterPlaybackTimeSavedSeconds = fasterPlaybackTimeSavedSeconds
        self.minutesPlayed = minutesPlayed
        self.gigabytesDownloaded = gigabytesDownloaded
        self.minutesSkipped = minutesSkipped
        self.updatedAt = updatedAt
        self.supportedIntentActions = supportedIntentActions
    }

    /// Maps the Mac's four lifetime counters onto the wire value. Negative or non-finite
    /// inputs (never produced by the ledger) are clamped to zero rather than published.
    public init(_ lifetime: LifetimeStatistics, updatedAt: Date? = nil) {
        func clean(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        self.init(
            audioProcessedSeconds: clean(lifetime.audioProcessedSeconds),
            speechGeneratedSeconds: clean(lifetime.speechGeneratedSeconds),
            confirmedAdTimeRemovedSeconds: clean(lifetime.confirmedAdTimeRemovedSeconds),
            fasterPlaybackTimeSavedSeconds: clean(lifetime.fasterPlaybackTimeSavedSeconds),
            updatedAt: updatedAt
        )
    }

    /// True when every metric matches `other`, ignoring `updatedAt`. A publisher uses this to
    /// send only real changes, so a restamp alone never writes a record.
    public func hasSameMetrics(as other: LibraryStats) -> Bool {
        var lhs = self, rhs = other
        lhs.updatedAt = nil
        rhs.updatedAt = nil
        return lhs == rhs
    }
}
