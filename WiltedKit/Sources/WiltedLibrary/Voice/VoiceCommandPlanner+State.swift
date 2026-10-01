import Foundation

/// Commands about the player's own state rather than which episode plays: time left, speed and the
/// sleep timer. Same rules as the rest of the planner: pure, one short sentence each.
extension VoiceCommandPlanner {
    /// Longest sleep timer a spoken request may set.
    public static let maxSleepMinutes = 12 * 60

    static func planTimeLeft(snapshot: VoiceSnapshot) -> VoicePlan {
        guard let playing = snapshot.nowPlaying else {
            return VoicePlan(action: .none, dialog: "Nothing is playing.")
        }
        guard playing.duration > 0 else {
            return VoicePlan(action: .none, dialog: "I can't tell how long is left.")
        }
        let remaining = max(0, playing.duration - playing.position)
        if remaining < 1 {
            return VoicePlan(action: .none, dialog: "\(playing.episode.title) has finished.")
        }
        // What the listener will actually sit through, so it follows the speed.
        let wall = remaining / (playing.rate > 0 ? playing.rate : 1)
        return VoicePlan(action: .none, dialog: "\(spokenLeft(seconds: wall)) left.")
    }

    static func planSetSpeed(_ rate: Double, snapshot: VoiceSnapshot) -> VoicePlan {
        guard PlaybackSpeeds.contains(rate) else {
            return VoicePlan(action: .none, dialog: "That speed isn't available.")
        }
        let spoken = rate == 1 ? "normal" : "\(speedText(rate)) times"
        let line = snapshot.nowPlaying == nil ? "Default speed set to \(spoken)." : "Speed set to \(spoken)."
        return VoicePlan(action: .setSpeed(rate), dialog: line)
    }

    static func planSleepTimer(_ request: VoiceSleepTimer, snapshot: VoiceSnapshot) -> VoicePlan {
        switch request {
        case .off:
            return VoicePlan(action: .cancelSleepTimer, dialog: "Sleep timer is off.")
        case .endOfEpisode:
            guard let playing = snapshot.nowPlaying else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }
            if playing.duration > 0, playing.duration - playing.position < 1 {
                return VoicePlan(action: .none, dialog: "\(playing.episode.title) has finished.")
            }
            return VoicePlan(action: .stopAfterEpisode, dialog: "Sleep timer set for the end of this episode.")
        case .minutes(let minutes):
            guard (1...maxSleepMinutes).contains(minutes) else {
                return VoicePlan(action: .none, dialog: "Pick a sleep timer between 1 minute and 12 hours.")
            }
            guard snapshot.nowPlaying != nil else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }
            return VoicePlan(
                action: .startSleepTimer(minutes: minutes),
                dialog: "Sleep timer set for \(spokenDuration(minutes: minutes)).")
        }
    }

    /// "About 12 minutes", "About 1 hour 5 minutes", "Less than a minute".
    static func spokenLeft(seconds: TimeInterval) -> String {
        if seconds < 30 { return "Less than a minute" }
        return "About \(spokenDuration(minutes: max(1, Int((seconds / 60).rounded()))))"
    }

    static func spokenDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        let minuteText = rest == 1 ? "1 minute" : "\(rest) minutes"
        switch (hours, rest) {
        case (0, _): return minuteText
        case (_, 0): return hourText
        default: return "\(hourText) \(minuteText)"
        }
    }

    /// 1.5 and 0.75, never 1.50 or 2.0.
    static func speedText(_ rate: Double) -> String {
        let text = String(format: "%.2f", rate)
        return text.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }
}
