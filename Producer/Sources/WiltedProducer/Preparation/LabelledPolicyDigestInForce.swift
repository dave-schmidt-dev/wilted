import Foundation

/// The labelled policy digest a fresh preparation would store under the owner's
/// current ad-finding settings, and whether a recorded digest is stale against it.
public enum LabelledPolicyDigestInForce {
    /// The digest a fresh labelled cut would store, or `nil` when the run would
    /// not enter the labelled path: ad removal off or an ad-free feed, or any
    /// not-sent reason (a private show, labeller off, no key or not confirmed).
    /// A run that was not sent records the plain digest, so once its show is sent
    /// this digest differs and Prepare Again is offered.
    ///
    /// The daily request cap is ignored (`dailyCapReached` is evaluated as false)
    /// so reaching the cap never changes which episodes are stale.
    public static func digest(
        policy: PodcastPreparationPolicySnapshot,
        input: RemoteLabellingInput,
        preferences: AdLabellerPreferences,
        hasKey: Bool
    ) -> String? {
        let context = RemoteLabellingContext(
            switchOn: preferences.isEnabled,
            hasKey: hasKey,
            confirmedFeedIDs: Set(preferences.confirmedFeedIDs),
            adFreeFeedIDs: Set(preferences.adFreeFeedIDs),
            dailyCapReached: false
        )
        guard case .labelled = PodcastPreparationPipeline.labellingGate(input: input, context: context)
        else { return nil }
        return PodcastPreparationPipeline.policyDigest(
            policy, labelled: PodcastPreparationPipeline.labelledRunProvenance(preferences: preferences))
    }

    /// Whether prepared audio is stale because a digest is in force and differs
    /// from a non-empty recorded digest. An empty recorded digest (backfilled
    /// rows) or a nil digest in force (not labelled) is never stale by digest.
    public static func isStale(recordedDigest: String?, digestInForce: String?) -> Bool {
        guard let digestInForce, !digestInForce.isEmpty else { return false }
        guard let recordedDigest, !recordedDigest.isEmpty else { return false }
        return recordedDigest != digestInForce
    }
}
