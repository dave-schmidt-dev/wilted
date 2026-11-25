import Foundation
import Observation

enum WiltedMacHeadlineToastPreference {
    static let key = "wilted.mac.headline-toast.duration-seconds"
    static let defaultDuration = 15
    static let durationRange = 5...60
    static let durationStep = 5

    static func duration(from preferences: UserDefaults) -> Int {
        guard preferences.object(forKey: key) != nil else { return defaultDuration }
        return min(max(preferences.integer(forKey: key), durationRange.lowerBound), durationRange.upperBound)
    }
}

@MainActor
@Observable
final class WiltedMacHeadlineToastPreferenceState {
    private let preferences: UserDefaults
    private(set) var durationSeconds: Int

    init(preferences: UserDefaults) {
        self.preferences = preferences
        durationSeconds = WiltedMacHeadlineToastPreference.duration(from: preferences)
    }

    func setDuration(_ seconds: Int) {
        let range = WiltedMacHeadlineToastPreference.durationRange
        durationSeconds = min(max(seconds, range.lowerBound), range.upperBound)
        preferences.set(durationSeconds, forKey: WiltedMacHeadlineToastPreference.key)
    }
}

extension WiltedMacModel {
    var headlineToastDurationSeconds: Int {
        get { headlineToastPreferenceState.durationSeconds }
        set { headlineToastPreferenceState.setDuration(newValue) }
    }
}
