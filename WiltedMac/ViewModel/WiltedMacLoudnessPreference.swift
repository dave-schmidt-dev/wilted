import Foundation

enum WiltedMacLoudnessOverride: String, CaseIterable {
    case inherit
    case on
    case off

    var label: String {
        switch self {
        case .inherit: "Same as default"
        case .on: "On for this show"
        case .off: "Off for this show"
        }
    }
}

/// Mac-local per-show overrides for the global voice-leveling choice.
struct WiltedMacLoudnessPreference {
    static let preferenceKey = "wilted.feeds.evenOutVoiceLoudness"
    static let offPreferenceKey = "wilted.feeds.evenOutVoiceLoudnessOff"
    let preferences: UserDefaults

    var feedIDs: [String] {
        Set((preferences.stringArray(forKey: Self.preferenceKey) ?? []).filter { !$0.isEmpty }).sorted()
    }

    var offFeedIDs: [String] {
        Set((preferences.stringArray(forKey: Self.offPreferenceKey) ?? []).filter { !$0.isEmpty }).sorted()
    }

    func override(feedID: String?) -> WiltedMacLoudnessOverride {
        guard let feedID, !feedID.isEmpty else { return .inherit }
        if feedIDs.contains(feedID) { return .on }
        if offFeedIDs.contains(feedID) { return .off }
        return .inherit
    }

    func isEnabled(feedID: String?, globalDefault: Bool) -> Bool {
        switch override(feedID: feedID) {
        case .inherit: globalDefault
        case .on: true
        case .off: false
        }
    }

    func set(feedID: String, enabled: Bool) {
        set(feedID: feedID, override: enabled ? .on : .off)
    }

    func set(feedID: String, override: WiltedMacLoudnessOverride) {
        guard !feedID.isEmpty else { return }
        var on = Set(feedIDs)
        var off = Set(offFeedIDs)
        on.remove(feedID)
        off.remove(feedID)
        switch override {
        case .inherit: break
        case .on: on.insert(feedID)
        case .off: off.insert(feedID)
        }
        if on.isEmpty { preferences.removeObject(forKey: Self.preferenceKey) }
        else { preferences.set(on.sorted(), forKey: Self.preferenceKey) }
        if off.isEmpty { preferences.removeObject(forKey: Self.offPreferenceKey) }
        else { preferences.set(off.sorted(), forKey: Self.offPreferenceKey) }
    }
}
