import Foundation
import WiltedDomain
import WiltedProducer

extension WiltedMacFeedPolicyBoard {
    /// Where the policy sends this feed's transcripts right now: the owner's ad labeller
    /// preferences, the injected key presence, and the feed's own title and address.
    func adRoute(for feedID: String) -> RemoteLabellingRoute {
        let context = RemoteLabellingContext(
            preferences: AdLabellerPreferences(preferences: model.preferences),
            hasKey: hasProviderKey(),
            counter: LabellerRequestCounter(preferences: model.preferences)
        )
        return RemoteLabellingPolicy.route(for: adRouteInput(for: feedID), context: context)
    }

    /// Why this feed is never sent for ad finding, whatever the switches say.
    func forcedNotSentAdReason(for feedID: String) -> RemoteLabellingNotSentReason? {
        RemoteLabellingPolicy.forcedNotSentReason(for: adRouteInput(for: feedID))
    }

    private func adRouteInput(for feedID: String) -> RemoteLabellingInput {
        let subscription = model.subscriptions.first { $0.id == feedID }
        return RemoteLabellingInput(
            feedID: feedID, feedURL: subscription?.feedURL,
            feedTitle: subscription?.publisherTitle ?? subscription?.title ?? "",
            customTitle: subscription?.title, audioURL: nil, removeAds: model.automationSettings.removeAds
        )
    }

    /// The feed's choices resolved against the same global defaults admission uses.
    func resolved(for feedID: String) -> EffectiveFeedAutomationPolicy {
        policy(for: feedID).resolved(using: model.automationSettings.feedAutomationDefaults)
    }

    func summary(for feedID: String) -> [WiltedFeedAutomationSummary.Row] {
        WiltedFeedAutomationSummary.rows(resolved(for: feedID))
    }

    // MARK: Waiting for space

    /// Episodes the admission planner holds back because the feed is full,
    /// oldest first. Empty unless the feed resolves to Auto keep with a limit.
    func waitingEpisodes(forFeed feedID: String) -> [WiltedMacEpisode] {
        guard isLoaded(feedID) else { return [] }
        let policy = resolved(for: feedID)
        guard policy.autoKeep, policy.keptLimit != nil else { return [] }
        let live = model.episodes.filter { $0.feedID == feedID && $0.removalKind == nil }
        let kept = Set(model.podcastQueueIDs).intersection(live.map(\.id))
        let feedRules = rules(for: feedID)
        let candidates = model.feedsEpisodes.filter { episode in
            guard episode.feedID == feedID, episode.removalKind == nil, !episode.isPlayed else { return false }
            // A rule decides its own episodes; only the rest reach the planner.
            guard case .noMatch? = try? feedRules.evaluate(
                .init(id: episode.id, title: episode.title, notes: episode.notes ?? "")
            ) else { return false }
            return true
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return FeedAdmissionPlanner.plan(
            candidates: candidates.map { .init(id: $0.id, releaseDate: $0.releasedAt) },
            keptEpisodeIDs: kept, playingEpisodeID: nil, partHeardEpisodeIDs: [],
            manualDecisions: [:], policy: policy
        ).filter { $0.outcome == .wait }.compactMap { byID[$0.candidate.id] }
    }

    /// The IDs waiting for space across every loaded feed.
    var waitingEpisodeIDs: Set<String> {
        Set(policies.keys.flatMap { waitingEpisodes(forFeed: $0).map(\.id) })
    }

    /// How many of the feed's episodes are kept in Larder right now.
    func keptCount(forFeed feedID: String) -> Int {
        let queued = Set(model.podcastQueueIDs)
        return model.episodes.filter { $0.feedID == feedID && $0.removalKind == nil && queued.contains($0.id) }.count
    }
}

