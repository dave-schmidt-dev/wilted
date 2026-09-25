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
    /// Who is speaking, when the publisher's transcript said so.
    var speaker: String?
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
