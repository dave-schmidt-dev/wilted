import Foundation
import WiltedProducer

/// The podcast feeds the owner has marked as already ad-free: preparation leaves
/// their audio uncut.
///
/// Held in the Mac app's preferences rather than the library, so the option needs
/// no library schema change. Stored as a sorted array of feed IDs; the key is
/// removed once no feed has the option on.
struct WiltedMacAdFreeFeedPreference {
    static let preferenceKey = AdLabellerPreferences.adFreeFeedsKey

    let preferences: UserDefaults

    /// The opted-in feed IDs, sorted, without blanks or repeats.
    var feedIDs: [String] {
        let stored = preferences.stringArray(forKey: Self.preferenceKey) ?? []
        return Set(stored.filter { !$0.isEmpty }).sorted()
    }

    /// Whether the feed is marked ad-free. An episode with no feed never is.
    func isAdFree(feedID: String?) -> Bool {
        guard let feedID, !feedID.isEmpty else { return false }
        return feedIDs.contains(feedID)
    }

    /// Turns the option on or off for one feed, leaving every other feed's choice as it was.
    func set(feedID: String, adFree: Bool) {
        guard !feedID.isEmpty else { return }
        var ids = Set(feedIDs)
        if adFree { ids.insert(feedID) } else { ids.remove(feedID) }
        if ids.isEmpty {
            preferences.removeObject(forKey: Self.preferenceKey)
        } else {
            preferences.set(ids.sorted(), forKey: Self.preferenceKey)
        }
    }
}
