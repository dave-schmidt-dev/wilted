import Foundation
import WiltedDomain

/// What the listener said about ad removal at one moment of a prepared episode.
///
/// Presses are the cheap way to grow the ad corpus: each one becomes a reviewed label
/// (`must-cut`, `must-keep`) once the owner accepts it in the Mac's inbox.
public enum AdFeedbackKind: String, Codable, Sendable, CaseIterable {
    /// An advertisement is playing that preparation did not remove.
    case adHere
    /// The cut just heard removed an advertisement, and only that.
    case goodCut
    /// The cut just heard removed programme the listener wanted.
    case notAnAd

    /// The words on the button, the inbox and the acknowledgement.
    public var title: String {
        switch self {
        case .adHere: "Ad here"
        case .goodCut: "Good cut"
        case .notAnAd: "Not an ad"
        }
    }

    /// SF Symbol shown beside `title` on both players.
    public var systemImage: String {
        switch self {
        case .adHere: "megaphone"
        case .goodCut: "checkmark.circle"
        case .notAnAd: "arrow.uturn.backward.circle"
        }
    }

    /// True for the two actions that judge a cut rather than the audio now playing.
    public var judgesCut: Bool { self != .adHere }
}

/// When a press counts as being about a cut: from `beforeSeam` seconds before the place the cut
/// lands in the prepared audio to `afterSeam` seconds after it. The Mac's and the phone's buttons
/// and the Mac's nearest-cut lookup all use this one window.
public enum AdFeedbackWindow {
    public static let beforeSeam: TimeInterval = 5
    public static let afterSeam: TimeInterval = 30

    public static func contains(seam: TimeInterval, position: TimeInterval) -> Bool {
        position >= seam - beforeSeam && position <= seam + afterSeam
    }
}

/// One removed span placed on both clocks: where it lands in the prepared audio (`preparedSeconds`)
/// and what it removed from the original (`originalStartSeconds..<originalEndSeconds`).
public struct AdCut: Codable, Equatable, Sendable {
    public let preparedSeconds: Double
    public let originalStartSeconds: Double
    public let originalEndSeconds: Double
    /// The worker's normalized name for what it removed (`ad_break`, `sponsor_read`, ...).
    public let label: String

    public init(preparedSeconds: Double, originalStartSeconds: Double, originalEndSeconds: Double, label: String) {
        self.preparedSeconds = preparedSeconds
        self.originalStartSeconds = originalStartSeconds
        self.originalEndSeconds = originalEndSeconds
        self.label = label
    }

    var isValid: Bool {
        preparedSeconds.isFinite && preparedSeconds >= 0 && originalStartSeconds.isFinite && originalEndSeconds.isFinite
            && originalStartSeconds >= 0 && originalEndSeconds > originalStartSeconds && !label.isEmpty
    }

    /// The cut whose seam is nearest `position` inside `AdFeedbackWindow`, or nil when none is.
    public static func nearest(to position: Double, in cuts: [AdCut]) -> AdCut? {
        guard position.isFinite else { return nil }
        return cuts
            .filter { AdFeedbackWindow.contains(seam: $0.preparedSeconds, position: position) }
            .min { abs($0.preparedSeconds - position) < abs($1.preparedSeconds - position) }
    }
}

/// A prepared-audio position carried back onto the original episode.
public struct AdFeedbackOriginalPosition: Equatable, Sendable {
    public let seconds: Double
    /// True when the position lay past the last kept audio and was pinned to its end.
    public let clamped: Bool
}

extension PreparationStatus.PreparationTimeline {
    /// Where `removed` lands in the prepared audio: the end of the last kept interval before it,
    /// carried onto the output clock. Zero when the cut starts the episode.
    public func preparedSeam(for removed: RemovedInterval) -> Double {
        kept.last(where: { $0.originalEndSeconds <= removed.originalStartSeconds })
            .map { $0.outputStartSeconds + ($0.originalEndSeconds - $0.originalStartSeconds) } ?? 0
    }

    /// Every removed span with its seam, in the order a listener meets them.
    public var adCuts: [AdCut] {
        removed.map {
            AdCut(preparedSeconds: preparedSeam(for: $0), originalStartSeconds: $0.originalStartSeconds,
                  originalEndSeconds: $0.originalEndSeconds, label: $0.label)
        }
        .sorted { $0.preparedSeconds < $1.preparedSeconds }
    }

    /// The original-episode time of a prepared-audio position, by inverting `kept`.
    ///
    /// Only `kept` is used: trimmed silence leaves gaps between kept intervals that no removed
    /// interval names, so subtracting removed durations would drift. Intervals are half-open, so a
    /// position exactly on a seam maps to the start of the audio after the cut. A position past the
    /// last kept audio is pinned to its end and flagged. Nil when nothing was kept.
    public func originalPosition(forPrepared seconds: Double) -> AdFeedbackOriginalPosition? {
        guard seconds.isFinite, let first = kept.first, let last = kept.last else { return nil }
        let position = max(0, seconds)
        for interval in kept {
            let length = interval.originalEndSeconds - interval.originalStartSeconds
            if position >= interval.outputStartSeconds, position < interval.outputStartSeconds + length {
                return AdFeedbackOriginalPosition(
                    seconds: interval.originalStartSeconds + (position - interval.outputStartSeconds), clamped: false)
            }
        }
        if position < first.outputStartSeconds {
            return AdFeedbackOriginalPosition(seconds: first.originalStartSeconds, clamped: true)
        }
        return AdFeedbackOriginalPosition(seconds: last.originalEndSeconds, clamped: true)
    }
}
