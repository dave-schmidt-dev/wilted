import Foundation
import WiltedLibrary

/// The follow-along rules for the transcript view, kept pure so they do not depend on SwiftUI.
enum LibraryTranscriptFollow {
    /// How long auto-scroll stays off after the reader last touched the list.
    static let autoScrollPause: TimeInterval = 4

    /// Index of the cue covering `seconds`: the last one whose start has passed, the same rule as
    /// `LibraryTranscript.cue(at:)`. Nil before the first cue, for no position, or for a
    /// non-finite one.
    static func currentIndex(in cues: [LibraryTranscriptCue], at seconds: Double?) -> Int? {
        guard let seconds, seconds.isFinite else { return nil }
        var low = 0, high = cues.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= seconds { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// Whether a cue change may scroll the list: never while a finger is dragging, and not until
    /// `pause` seconds after the last touch.
    static func shouldAutoScroll(
        isDragging: Bool, lastTouch: Date?, now: Date, pause: TimeInterval = autoScrollPause
    ) -> Bool {
        guard !isDragging else { return false }
        guard let lastTouch else { return true }
        return now.timeIntervalSince(lastTouch) >= pause
    }

    /// The position to seek to for a tapped cue, only when this transcript's entry is playing.
    static func seekTarget(for cue: LibraryTranscriptCue, isPlayingItem: Bool) -> Double? {
        isPlayingItem ? cue.start : nil
    }

    /// "12:03" or "1:02:03" label for a cue's start.
    static func timecode(_ seconds: Double) -> String { LibraryClockFormat.duration(seconds) }
}
