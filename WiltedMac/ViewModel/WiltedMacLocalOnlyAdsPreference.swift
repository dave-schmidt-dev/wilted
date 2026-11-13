import Foundation
import WiltedProducer

/// The podcast feeds whose transcripts stay on this Mac rather than going to the
/// online ad labeller: the per-feed "Find ads on this Mac only" choice.
///
/// Kept in the owner's ad labeller preferences, so the choice lives in one place
/// beside the global switch and the confirmed feeds, and the policy reads the same
/// set this switch writes.
extension RemoteLabellingLocalReason {
    /// The plain words for a show the policy keeps on this Mac whatever the owner
    /// chooses; nil for a reason the owner's own switches decide.
    var forcedLocalMessage: String? {
        switch self {
        case .unknownFeedURL:
            "This show's address is not known, so its transcripts always stay on this Mac."
        case .credentialedURL:
            "This show's address carries sign-in details, so its transcripts always stay on this Mac."
        case .tokenLikeFeedURL:
            "This show's address carries a private token, so its transcripts always stay on this Mac."
        case .privateTitle:
            "This show's title sounds private, so its transcripts always stay on this Mac."
        case .switchOff, .noKey, .notConfirmed, .adRemovalOff, .ownerLocalOnly, .dailyCapReached:
            nil
        }
    }
}

struct WiltedMacLocalOnlyAdsPreference {
    let preferences: UserDefaults

    private var labeller: AdLabellerPreferences { AdLabellerPreferences(preferences: preferences) }

    /// The opted-out feed IDs, sorted, without blanks or repeats.
    var feedIDs: [String] { labeller.localOnlyFeedIDs }

    /// Whether the feed's transcripts stay on this Mac. An episode with no feed never does.
    func isLocalOnly(feedID: String?) -> Bool {
        guard let feedID, !feedID.isEmpty else { return false }
        return labeller.isLocalOnly(feedID: feedID)
    }

    /// Turns the choice on or off for one feed, leaving every other feed's choice as it
    /// was. The key is removed once no feed is local-only.
    func set(feedID: String, localOnly: Bool) {
        labeller.setLocalOnly(feedID: feedID, localOnly)
    }
}
