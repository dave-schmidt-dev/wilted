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

// MARK: - Measured lifetime totals (store V14)

/// The base unit a measured lifetime quantity is stored in. Integer base
/// units keep every sum exact; display units are derived, never stored.
public enum LifetimeMeasureUnit: String, Codable, Sendable {
    case milliseconds
    case bytes
}

/// The measured quantities admitted to the typed V14 ledger. Each kind has
/// exactly one unit, so a time value can never be summed into a byte total.
public enum LifetimeMeasureKind: String, CaseIterable, Codable, Sendable {
    /// Elapsed active listening time, including replayed audio.
    case playedTime
    /// Network bytes actually received, including partial and retried transfers.
    case receivedBytes
    /// Positive program time passed over by an explicit manual seek or Next.
    case manuallySkippedTime

    public var unit: LifetimeMeasureUnit {
        switch self {
        case .playedTime, .manuallySkippedTime: .milliseconds
        case .receivedBytes: .bytes
        }
    }
}

/// One validated, unit-typed quantity. Construct it only through the typed
/// factories, which reject a unit that does not match the kind and any
/// non-finite or negative value.
public struct LifetimeMeasureAmount: Equatable, Hashable, Sendable {
    public let kind: LifetimeMeasureKind
    /// Milliseconds for time kinds, bytes for byte kinds.
    public let baseUnits: Int64

    /// A time amount, rounded to the nearest millisecond.
    public static func time(_ kind: LifetimeMeasureKind, seconds: Double) -> LifetimeMeasureAmount? {
        guard kind.unit == .milliseconds, seconds.isFinite, seconds >= 0 else { return nil }
        let milliseconds = (seconds * 1_000).rounded()
        guard milliseconds < Double(Int64.max) else { return nil }
        return LifetimeMeasureAmount(kind: kind, baseUnits: Int64(milliseconds))
    }

    /// A byte amount.
    public static func bytes(_ kind: LifetimeMeasureKind, count: Int64) -> LifetimeMeasureAmount? {
        guard kind.unit == .bytes, count >= 0 else { return nil }
        return LifetimeMeasureAmount(kind: kind, baseUnits: count)
    }

    /// Rehydrates a stored amount. Returns nil for a negative value.
    public static func stored(_ kind: LifetimeMeasureKind, baseUnits: Int64) -> LifetimeMeasureAmount? {
        guard baseUnits >= 0 else { return nil }
        return LifetimeMeasureAmount(kind: kind, baseUnits: baseUnits)
    }

    private init(kind: LifetimeMeasureKind, baseUnits: Int64) {
        self.kind = kind
        self.baseUnits = baseUnits
    }

    /// Seconds for a time kind; nil for a byte kind.
    public var seconds: Double? { kind.unit == .milliseconds ? Double(baseUnits) / 1_000 : nil }
    /// Bytes for a byte kind; nil for a time kind.
    public var byteCount: Int64? { kind.unit == .bytes ? baseUnits : nil }
}

/// Exact totals of the typed ledger, in base units.
public struct LifetimeMeasuredTotals: Equatable, Sendable {
    public var playedMilliseconds: Int64
    public var receivedBytes: Int64
    public var manuallySkippedMilliseconds: Int64

    public init(playedMilliseconds: Int64 = 0, receivedBytes: Int64 = 0, manuallySkippedMilliseconds: Int64 = 0) {
        self.playedMilliseconds = playedMilliseconds
        self.receivedBytes = receivedBytes
        self.manuallySkippedMilliseconds = manuallySkippedMilliseconds
    }

    public subscript(kind: LifetimeMeasureKind) -> Int64 {
        get {
            switch kind {
            case .playedTime: playedMilliseconds
            case .receivedBytes: receivedBytes
            case .manuallySkippedTime: manuallySkippedMilliseconds
            }
        }
        set {
            switch kind {
            case .playedTime: playedMilliseconds = newValue
            case .receivedBytes: receivedBytes = newValue
            case .manuallySkippedTime: manuallySkippedMilliseconds = newValue
            }
        }
    }

    /// Adds without overflow; a total saturates at `Int64.max` instead of trapping.
    public mutating func add(_ amount: LifetimeMeasureAmount) {
        let (sum, overflow) = self[amount.kind].addingReportingOverflow(amount.baseUnits)
        self[amount.kind] = overflow ? .max : sum
    }

    public var playedMinutes: Double { Double(playedMilliseconds) / 60_000 }
    public var manuallySkippedMinutes: Double { Double(manuallySkippedMilliseconds) / 60_000 }
    /// Decimal gigabytes (10^9 bytes).
    public var receivedDecimalGigabytes: Double { Double(receivedBytes) / 1_000_000_000 }
}

/// The durable lifetime summary: the four legacy totals plus the measured
/// totals, read in O(1) from one summary row.
public struct LifetimeStatisticsSummary: Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Totals are current and may be displayed.
        case ready
        /// The summary must be rebuilt from the ledgers before its totals are
        /// trusted (for example, right after the V14 migration). Totals are zero.
        case rebuildRequired
    }

    public var state: State
    public var legacy: LifetimeStatistics
    public var measured: LifetimeMeasuredTotals
    /// When this store began measuring the typed quantities. History before
    /// this instant was never measured and is never reconstructed.
    public var trackingStartedAt: Date?
    public var updatedAt: Date?

    public init(state: State, legacy: LifetimeStatistics = LifetimeStatistics(),
                measured: LifetimeMeasuredTotals = LifetimeMeasuredTotals(),
                trackingStartedAt: Date? = nil, updatedAt: Date? = nil) {
        self.state = state
        self.legacy = legacy
        self.measured = measured
        self.trackingStartedAt = trackingStartedAt
        self.updatedAt = updatedAt
    }
}

extension LifetimeStatistics {
    /// Adds one legacy contribution with the ledger's validation: a
    /// non-finite or negative value, or a sum that stops being finite, is ignored.
    public mutating func add(_ kind: LifetimeStatisticKind, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        switch kind {
        case .audioProcessed:
            let value = audioProcessedSeconds + seconds
            if value.isFinite { audioProcessedSeconds = value }
        case .speechGenerated:
            let value = speechGeneratedSeconds + seconds
            if value.isFinite { speechGeneratedSeconds = value }
        case .confirmedAdTimeRemoved:
            let value = confirmedAdTimeRemovedSeconds + seconds
            if value.isFinite { confirmedAdTimeRemovedSeconds = value }
        case .fasterPlaybackTimeSaved:
            let value = fasterPlaybackTimeSavedSeconds + seconds
            if value.isFinite { fasterPlaybackTimeSavedSeconds = value }
        }
    }
}
