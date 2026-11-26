import Foundation
import Observation

enum WiltedMacHeadlineToastPreference {
    static let key = "wilted.mac.headline-toast.duration-seconds"
    static let tickerEnabledKey = "wilted.mac.headline-ticker.enabled"
    static let defaultDuration = 15
    static let durationRange = 5...60
    static let durationStep = 5

    static func duration(from preferences: UserDefaults) -> Int {
        guard preferences.object(forKey: key) != nil else { return defaultDuration }
        return min(max(preferences.integer(forKey: key), durationRange.lowerBound), durationRange.upperBound)
    }

    static func tickerEnabled(from preferences: UserDefaults) -> Bool {
        preferences.bool(forKey: tickerEnabledKey)
    }
}

@MainActor
@Observable
final class WiltedMacHeadlineToastPreferenceState {
    private let preferences: UserDefaults
    private(set) var durationSeconds: Int
    private(set) var tickerEnabled: Bool

    init(preferences: UserDefaults) {
        self.preferences = preferences
        durationSeconds = WiltedMacHeadlineToastPreference.duration(from: preferences)
        tickerEnabled = WiltedMacHeadlineToastPreference.tickerEnabled(from: preferences)
    }

    func setDuration(_ seconds: Int) {
        let range = WiltedMacHeadlineToastPreference.durationRange
        durationSeconds = min(max(seconds, range.lowerBound), range.upperBound)
        preferences.set(durationSeconds, forKey: WiltedMacHeadlineToastPreference.key)
    }

    func setTickerEnabled(_ enabled: Bool) {
        tickerEnabled = enabled
        preferences.set(enabled, forKey: WiltedMacHeadlineToastPreference.tickerEnabledKey)
    }
}

extension WiltedMacModel {
    var headlineToastDurationSeconds: Int {
        get { headlineToastPreferenceState.durationSeconds }
        set { headlineToastPreferenceState.setDuration(newValue) }
    }

    var headlineTickerEnabled: Bool {
        get { headlineToastPreferenceState.tickerEnabled }
        set { headlineToastPreferenceState.setTickerEnabled(newValue) }
    }
}
