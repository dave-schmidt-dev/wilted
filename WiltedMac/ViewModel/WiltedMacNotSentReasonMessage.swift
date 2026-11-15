import Foundation
import WiltedProducer

/// The four forced-reason sentences, reusing ``RemoteLabellingNotSent.sentence``.
extension RemoteLabellingNotSentReason {
    /// The plain words for a show the policy never sends for ad finding whatever
    /// the owner chooses; nil for a reason the owner's own switches decide.
    var forcedNotSentMessage: String? {
        guard let notSent = RemoteLabellingNotSent(self) else { return nil }
        switch self {
        case .unknownFeedURL, .credentialedURL, .tokenLikeFeedURL, .privateTitle:
            return notSent.sentence
        default:
            return nil
        }
    }
}
