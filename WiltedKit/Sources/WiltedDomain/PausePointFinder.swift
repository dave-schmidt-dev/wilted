import Foundation

/// Finds where a spoken interruption can start without cutting speech: the next gap between
/// transcript cues.
public enum PausePointFinder {
    /// The shortest silence between cues that counts as a pause.
    public static let minimumGap: Double = 0.7

    /// The media position to interrupt at, never later than `now + waitLimit`.
    ///
    /// A gap starts at the running maximum cue end (cues may overlap, so a short cue inside a
    /// long one is not a gap) and must last `minimumGap` before the next cue starts. The silence
    /// after the last cue counts, and a gap already under way at `now` is usable from `now`.
    /// Without timed cues there is nothing to measure against, so the answer is the wait limit.
    public static func next(after now: Double, cues: [TranscriptCue]?, timing: TranscriptTiming,
                            waitLimit: Double) -> Double {
        let limit = now + (waitLimit.isFinite ? max(0, waitLimit) : 0)
        guard now.isFinite, timing != .none, let cues, !cues.isEmpty else { return limit }
        var coveredUntil = 0.0
        for cue in cues {
            let gapStart = max(coveredUntil, now)
            if gapStart > limit { break }
            if cue.startSeconds - gapStart >= minimumGap { return gapStart }
            coveredUntil = max(coveredUntil, cue.endSeconds)
        }
        return min(max(coveredUntil, now), limit)
    }
}
