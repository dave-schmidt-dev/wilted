import CryptoKit
import Foundation
import WiltedDomain

public enum PodcastPreparationError: Error, Equatable, LocalizedError, Sendable {
    case episodeNotDownloaded
    case workerUnavailable(String)
    case workerFailed(code: String, message: String)
    case workerTimedOut
    case malformedWorkerResponse(String)
    case preparedAudioUnreadable
    case readyAudioChanged
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .episodeNotDownloaded: "Download the episode before preparing it."
        case .workerUnavailable(let detail):
            Self.formatDescription(
                prefix: "Wilted could not start the preparation pipeline",
                fallback: "Wilted could not start the preparation pipeline.",
                detail: detail
            )
        case .workerFailed(_, let message): "Preparation failed: \(message)"
        case .workerTimedOut: "Preparation took too long and was stopped."
        case .malformedWorkerResponse(let detail):
            Self.formatDescription(
                prefix: "The preparation pipeline returned an unreadable result",
                fallback: "The preparation pipeline returned an unreadable result.",
                detail: detail
            )
        case .preparedAudioUnreadable: "The prepared audio could not be read back."
        case .readyAudioChanged: "The episode's audio changed while it was being prepared again."
        case .cancelled: "Preparation was cancelled."
        }
    }

    private static func formatDescription(prefix: String, fallback: String, detail: String) -> String {
        let collapsed = detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback }
        let bounded: String
        if collapsed.count > 300 {
            bounded = String(collapsed.prefix(299)) + "…"
        } else {
            bounded = collapsed
        }
        return "\(prefix): \(bounded)."
    }
}

/// One advertisement the pipeline found, in the downloaded audio's own clock.
///
/// Kept for the report rather than for playback: once the audio is cut these
/// spans no longer exist in the file, and their value is telling the owner what
/// was removed and how confident the classifier was.
public struct PodcastAdSegment: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let label: String
    public let confidence: Double
    /// Paid advertising, house promotion, or credits -- what was removed, not
    /// which detector rule found it. A merged span reports the strongest kind
    /// present, so a paid read absorbed into a house promotion stays paid.
    ///
    /// The worker labels a span and names its kind separately, and the two do
    /// not agree: `effective_ad_spans` attributes a merged span the *first*
    /// overlapping nomination's label while taking the union of their kinds.
    /// Deriving the kind from the label here would put the first-label
    /// attribution back.
    public let kind: String

    /// What the worker reports for a span no nomination overlapped, and what
    /// a journal written before kinds existed decodes as. Both are unknown
    /// removals, and the conservative reading of an unknown removal is paid.
    public static let defaultKind = "paid advertising"
    public static let houseKind = "house promotion"
    public static let creditsKind = "credits"

    /// The taxonomy the worker publishes, strongest first. Ordering is the
    /// display order too: a summary that led with credits would bury the
    /// removal a listener actually cares about.
    public static let recognisedKinds = [defaultKind, houseKind, creditsKind]

    public init(
        startSeconds: Double, endSeconds: Double, label: String, confidence: Double,
        kind: String = PodcastAdSegment.defaultKind
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.label = label
        self.confidence = confidence
        self.kind = kind
    }

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

/// One span of the original audio that survived the cut, and where it landed.
///
/// Carried back from the worker so a listener's saved position can move onto
/// the prepared file rather than being discarded with the revision it belonged
/// to. Estimating from total removed time would be wrong: what matters is how
/// much was removed *before* the position, not in total.
public struct PodcastKeepInterval: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let outputStartSeconds: Double

    /// Where `seconds` on the original clock lands on the cut clock, or nil if
    /// it fell inside a removed advertisement. A position inside a shortened
    /// pause in `silence` moves to where the audio resumes after it.
    static func map(_ seconds: Double, through intervals: [PodcastKeepInterval],
                    silence: [Range<Double>] = []) -> Double? {
        guard !intervals.isEmpty else { return nil }
        for interval in intervals where seconds >= interval.startSeconds && seconds < interval.endSeconds {
            return interval.outputStartSeconds + (seconds - interval.startSeconds)
        }
        // Past the end of the last surviving span: the listener had finished
        // everything that remains, so the end of the file is the honest answer.
        if let last = intervals.last, seconds >= last.endSeconds {
            return last.outputStartSeconds + (last.endSeconds - last.startSeconds)
        }
        if silence.contains(where: { $0.contains(seconds) }),
           let next = intervals.first(where: { $0.startSeconds >= seconds }) {
            return next.outputStartSeconds
        }
        return nil
    }

    /// Where `seconds` on the cut file's clock was on the original's clock: the
    /// inverse of `map`.
    ///
    /// The cut file is the kept spans laid end to end, so every position in it
    /// lies inside exactly one span and the answer is exact. Past the end of
    /// the last span is the end of the original's last kept audio, and a
    /// position before zero is the start of the first.
    static func unmap(_ seconds: Double, through intervals: [PodcastKeepInterval]) -> Double? {
        guard let first = intervals.first, let last = intervals.last else { return nil }
        if seconds <= first.outputStartSeconds { return first.startSeconds }
        for interval in intervals {
            let length = interval.endSeconds - interval.startSeconds
            if seconds >= interval.outputStartSeconds, seconds < interval.outputStartSeconds + length {
                return interval.startSeconds + (seconds - interval.outputStartSeconds)
            }
        }
        // Only reachable past the end, or in the rounding gap between two
        // spans: the next span's start is where the audio resumes.
        if let next = intervals.first(where: { $0.outputStartSeconds >= seconds }) { return next.startSeconds }
        return last.endSeconds
    }

    /// `map`, except that a position inside a removed span lands where the
    /// programme resumes instead of being dropped. Preparing an episode again
    /// moves a listener who was inside what the new cut removes to the next
    /// audio they will hear, rather than losing their place.
    static func mapSnapping(_ seconds: Double, through intervals: [PodcastKeepInterval],
                            silence: [Range<Double>] = []) -> Double? {
        if let mapped = map(seconds, through: intervals, silence: silence) { return mapped }
        return intervals.first(where: { $0.startSeconds >= seconds })?.outputStartSeconds
    }
}

extension PodcastKeepInterval {
    /// A persisted timeline's kept span, in the shape `map` and `unmap` read.
    /// An extension, so the struct keeps its memberwise initializer.
    init(_ kept: PreparationStatus.PreparationTimeline.KeptInterval) {
        self.init(startSeconds: kept.originalStartSeconds, endSeconds: kept.originalEndSeconds,
                  outputStartSeconds: kept.outputStartSeconds)
    }
}

public struct PodcastPreparationProgress: Equatable, Sendable {
    public let stage: String
    public let detail: String
    public let fraction: Double?
    public let evidence: PreparationEvidence?
    public let requestID: UUID?

    public init(stage: String, detail: String = "", fraction: Double? = nil,
                evidence: PreparationEvidence? = nil, requestID: UUID? = nil) {
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
        self.evidence = evidence
        self.requestID = requestID
    }
}

extension PodcastPreparationProgress {
    /// Where this stage belongs in the journal the Processor page reads.
    ///
    /// The worker's vocabulary is its own -- it names transcript tiers and
    /// ffmpeg passes -- but the durable record has one shape for every kind of
    /// preparation, so a reader does not need to know which pipeline ran.
    var journalStage: PreparationStage {
        let parts = stage.split(separator: ".").map(String.init)
        switch (parts.first ?? stage, parts.count > 1 ? parts[1] : "") {
        case ("transcript", "published"): return .fetching
        case ("transcript", _): return .extracting
        case ("ads", _): return .assembling
        case ("audio", _): return .saving
        default: return .preparing
        }
    }
}

public struct PodcastPreparationResult: Sendable {
    public let revision: AudioRevision
    public let mediaURL: URL
    public let transcript: Transcript
    public let adSegments: [PodcastAdSegment]
    public let removedSeconds: Double
    public let adRemovalOutcome: String
    public var warning: String? = nil
    public var audioWasCut: Bool { removedSeconds > 0 }

    /// What the run did, for the row: "Ready · 5 ads removed (7:22) ·
    /// transcript synced". Leads with the completion state and then names
    /// each step's result, so a reader can see the run finished and where
    /// it fell short ("transcript not synced") without knowing the
    /// pipeline. Journalled as the run's terminal detail so the answer
    /// outlives the process that knew it.
    public var summary: String {
        Self.summary(advertisements: adSegments.count, secondsRemoved: removedSeconds, timing: transcript.timing,
                     adRemovalOutcome: adRemovalOutcome, warning: warning)
    }

    public static let readyLabel = "Ready"

    public static func summary(advertisements: Int, secondsRemoved: Double, timing: TranscriptTiming,
                               adRemovalOutcome: String? = nil, warning: String? = nil) -> String {
        var parts: [String] = [readyLabel]
        if adRemovalOutcome == "disabled" {
            parts.append("ad removal disabled")
        } else if adRemovalOutcome == "uncertain" {
            parts.append(warning ?? "original audio includes ads; ad removal could not be verified")
        } else if advertisements > 0, secondsRemoved > 0 {
            let removed = clock(secondsRemoved)
            parts.append(advertisements == 1 ? "1 ad removed (\(removed))" : "\(advertisements) ads removed (\(removed))")
        } else {
            parts.append("no ads found")
        }
        parts.append(transcriptStep(timing))
        return parts.joined(separator: " · ")
    }

    public static func transcriptStep(_ timing: TranscriptTiming) -> String {
        switch timing {
        case .published: "transcript synced from the feed"
        case .aligned: "transcript synced"
        case .none: "transcript not synced"
        }
    }

    /// `h:mm:ss` at an hour or more, `m:ss` below it.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// The seam between the coordinator and the Python process.
///
/// Exists so the gate can exercise every decision this file makes without a
/// virtualenv, a four-gigabyte language model, or a GPU. The real runner is the
/// only part that needs any of those.
public protocol PodcastPipelineRunning: Sendable {
    func run(
        request: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data

    func codeRevision() async -> String?
}

extension PodcastPipelineRunning {
    public func codeRevision() async -> String? {
        nil
    }
}

public enum PodcastTranscriptPolicy: String, Codable, Equatable, Sendable {
    case bestAvailable
    case alwaysTranscribe
    case noLocalSTT
}

/// The processing choices captured when one preparation job is admitted.
///
/// Passing this value into `prepare` keeps a queued job independent of later
/// preference changes. The default is the pipeline's legacy behavior.
public struct PodcastPreparationPolicySnapshot: Codable, Equatable, Sendable {
    public let transcriptPolicy: PodcastTranscriptPolicy
    public let removeAds: Bool
    /// Whether the show's own promotion (its sponsor roll call, ad-free or
    /// Patreon pitches, events and webinars) is cut as well. Off by default:
    /// the detector otherwise keeps self-promotion as programme.
    public let removeSelfPromotion: Bool

    public static let defaultValue = PodcastPreparationPolicySnapshot(
        transcriptPolicy: .bestAvailable,
        removeAds: true
    )

    public init(
        transcriptPolicy: PodcastTranscriptPolicy,
        removeAds: Bool,
        removeSelfPromotion: Bool = false
    ) {
        self.transcriptPolicy = transcriptPolicy
        self.removeAds = removeAds
        self.removeSelfPromotion = removeSelfPromotion
    }

    private enum CodingKeys: String, CodingKey {
        case transcriptPolicy, removeAds, removeSelfPromotion
    }

    /// Snapshots stored before the option existed carry no key and read as off.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptPolicy = try container.decode(PodcastTranscriptPolicy.self, forKey: .transcriptPolicy)
        removeAds = try container.decode(Bool.self, forKey: .removeAds)
        removeSelfPromotion = try container.decodeIfPresent(Bool.self, forKey: .removeSelfPromotion) ?? false
    }

    /// The key is written only when on, so every snapshot without the option
    /// encodes to the same bytes it did before the option existed.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptPolicy, forKey: .transcriptPolicy)
        try container.encode(removeAds, forKey: .removeAds)
        if removeSelfPromotion { try container.encode(true, forKey: .removeSelfPromotion) }
    }
}
