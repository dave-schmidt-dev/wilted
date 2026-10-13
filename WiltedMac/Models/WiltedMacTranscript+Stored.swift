import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

extension WiltedMacTranscript {
    init(stored: Transcript) {
        let availability: Availability = switch stored.availability {
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
        self.init(
            availability: availability,
            text: stored.text,
            cues: (stored.cues ?? []).enumerated().map { index, cue in
                WiltedMacTranscriptCue(
                    id: index,
                    startSeconds: cue.startSeconds,
                    endSeconds: cue.endSeconds,
                    text: cue.text,
                    speaker: cue.speaker
                )
            },
            timingSource: timingSource
        )
    }
}
#endif