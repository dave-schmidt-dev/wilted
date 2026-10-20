import Foundation

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// The podcast feeds whose preparation also removes the show's own promotion:
/// its sponsor roll call, ad-free or Patreon pitches, events and webinars.
///
/// The detector keeps a show's self-promotion as programme unless its feed is
/// listed here. Held in the Mac app's preferences rather than the library, so
/// the option needs no library schema change. Stored as a sorted array of feed
/// IDs; the key is removed once no feed has the option on.
struct WiltedMacSelfPromotionPreference {
    static let preferenceKey = "wilted.feeds.removeSelfPromotion"

    let preferences: UserDefaults

    /// The opted-in feed IDs, sorted, without blanks or repeats.
    var feedIDs: [String] {
        let stored = preferences.stringArray(forKey: Self.preferenceKey) ?? []
        return Set(stored.filter { !$0.isEmpty }).sorted()
    }

    /// Whether the feed has the option on. An episode with no feed never does.
    func isEnabled(feedID: String?) -> Bool {
        guard let feedID, !feedID.isEmpty else { return false }
        return feedIDs.contains(feedID)
    }

    /// Turns the option on or off for one feed, leaving every other feed's choice as it was.
    func set(feedID: String, enabled: Bool) {
        guard !feedID.isEmpty else { return }
        var ids = Set(feedIDs)
        if enabled { ids.insert(feedID) } else { ids.remove(feedID) }
        if ids.isEmpty {
            preferences.removeObject(forKey: Self.preferenceKey)
        } else {
            preferences.set(ids.sorted(), forKey: Self.preferenceKey)
        }
    }
}

#if canImport(WiltedProducer)
extension WiltedMacModel {
    /// Maps the settings visible when a job is admitted into the worker's
    /// immutable request shape.
    static func preparationPolicySnapshot(
        from settings: WiltedAutomationSettings, removeSelfPromotion: Bool = false
    ) -> PodcastPreparationPolicySnapshot {
        let transcriptPolicy: PodcastTranscriptPolicy
        switch settings.transcriptPolicy {
        case .bestAvailable: transcriptPolicy = .bestAvailable
        case .alwaysTranscribe: transcriptPolicy = .alwaysTranscribe
        case .noLocalSTT: transcriptPolicy = .noLocalSTT
        }
        return PodcastPreparationPolicySnapshot(
            transcriptPolicy: transcriptPolicy,
            removeAds: settings.removeAds,
            removeSelfPromotion: removeSelfPromotion
        )
    }

    /// The same mapping, with the feed's own-promotion choice read from `preferences`.
    static func preparationPolicySnapshot(
        from settings: WiltedAutomationSettings, feedID: String?, preferences: UserDefaults
    ) -> PodcastPreparationPolicySnapshot {
        preparationPolicySnapshot(
            from: settings,
            removeSelfPromotion: WiltedMacSelfPromotionPreference(preferences: preferences).isEnabled(feedID: feedID)
        )
    }

    /// The snapshot an episode is admitted with: today's settings and its feed's choice.
    func preparationPolicySnapshot(for episode: WiltedMacEpisode) -> PodcastPreparationPolicySnapshot {
        Self.preparationPolicySnapshot(from: automationSettings, feedID: episode.feedID, preferences: preferences)
    }
}
#endif
