import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

/// Computes the durable admission request shared by refresh and Feeds actions.
/// It deliberately returns data rather than starting work: the caller commits
/// the decision, queue entry, and tickets together through `admitEpisode`.
struct EpisodeAdmissionService {
    struct Candidate: Equatable, Sendable {
        let id: String
        let title: String
        let notes: String?
        let releasedAt: Date
    }

    struct Admission: Equatable, Sendable {
        let episodeID: String
        let decision: EpisodeDecision
        let source: EpisodeDecisionSource
        let ruleID: UUID?
        let workTicketKinds: [WorkTicketKind]
    }

    static func plan(
        candidates: [Candidate],
        keptEpisodeIDs: Set<String>,
        manualDecisions: [String: FeedManualDecision],
        rules: EpisodeMatchRules,
        policy: EffectiveFeedAutomationPolicy
    ) -> [Admission] {
        guard policy.autoKeep else { return [] }

        var ruleAdmissions: [Admission] = []
        var plannerCandidates: [FeedAdmissionCandidate] = []
        for candidate in candidates where manualDecisions[candidate.id] == nil {
            let match = try? rules.evaluate(.init(
                id: candidate.id, title: candidate.title, notes: candidate.notes ?? ""
            ))
            switch match {
            case let .keep(ruleID):
                ruleAdmissions.append(keepAdmission(candidate.id, source: .rule, ruleID: ruleID, policy: policy))
            case let .skip(ruleID):
                ruleAdmissions.append(.init(episodeID: candidate.id, decision: .skip, source: .rule,
                                            ruleID: ruleID, workTicketKinds: []))
            case .noMatch:
                plannerCandidates.append(.init(id: candidate.id, releaseDate: candidate.releasedAt))
            case .timedOut, .none:
                // A rule that could not finish must not hand the episode to
                // the planner; it stays undecided until a later pass.
                continue
            }
        }

        let alreadyClaimed = Set(ruleAdmissions.map(\.episodeID))
        let planned = FeedAdmissionPlanner.plan(
            candidates: plannerCandidates.filter { !alreadyClaimed.contains($0.id) },
            keptEpisodeIDs: keptEpisodeIDs, playingEpisodeID: nil, partHeardEpisodeIDs: [],
            manualDecisions: manualDecisions, policy: policy
        ).compactMap { decision -> Admission? in
            guard decision.outcome == .keepNow else { return nil }
            return keepAdmission(decision.candidate.id, source: .policy, ruleID: nil, policy: policy)
        }
        // FIFO release order is the request order: the oldest episode takes the
        // first place in the download and preparation lines.
        let releasedAt = Dictionary(candidates.map { ($0.id, $0.releasedAt) }, uniquingKeysWith: { first, _ in first })
        return (ruleAdmissions + planned).sorted { lhs, rhs in
            let (left, right) = (releasedAt[lhs.episodeID] ?? .distantFuture, releasedAt[rhs.episodeID] ?? .distantFuture)
            return left == right ? lhs.episodeID < rhs.episodeID : left < right
        }
    }

    static func shouldDownloadAfterManualKeep(
        feedPolicy: FeedAutomationPolicy, globalDownloadEverything: Bool
    ) -> Bool {
        feedPolicy.resolved(using: .init(autoDownload: globalDownloadEverything)).autoDownload
    }

    /// Only an explicit per-feed Off stops automatic preparation after a
    /// download; Use global leaves the processing policy in charge.
    static func suppressesAutomaticPreparation(_ feedPolicy: FeedAutomationPolicy) -> Bool {
        feedPolicy.autoPrepare == .off
    }

    /// Global values behind every Use global feed override. Auto keep has no
    /// global switch, so automatic refresh gains authority only on feeds set
    /// to On. Manual processing is the global Auto prepare Off.
    static func globalDefaults(_ settings: WiltedAutomationSettings) -> FeedAutomationGlobalDefaults {
        let prepares: Bool
        switch settings.processingPolicy {
        case .manual: prepares = settings.prepareEverythingDownloaded
        case .immediate, .offPeak: prepares = true
        }
        return .init(autoKeep: false, autoDownload: settings.downloadEverythingOnMenu, autoPrepare: prepares)
    }

    private static func keepAdmission(
        _ id: String, source: EpisodeDecisionSource, ruleID: UUID?, policy: EffectiveFeedAutomationPolicy
    ) -> Admission {
        var tickets: [WorkTicketKind] = []
        if policy.autoDownload {
            tickets.append(.podcastDownload)
            if policy.autoPrepare { tickets.append(.podcastPreparation) }
        }
        return .init(episodeID: id, decision: .keep, source: source, ruleID: ruleID,
                     workTicketKinds: tickets)
    }
}

/// The committing half: loads a feed's durable state, asks the pure service
/// what to admit, and commits each admission through `admitEpisode`.
extension WiltedMacModel {
    /// Refreshes one feed and admits only episodes its feed policy authorizes.
    /// The per-feed `limit` of the retired automatic-download policy is not
    /// consulted: Auto download on the feed now decides what is claimed.
    func automaticRefresh(_ url: URL, claimingNewest limit: Int) async throws -> [String] {
        guard let store else { throw CancellationError() }
        let loaded = try await podcastFeedClient.load(url)
        try await store.save(feed: loaded.feed)
        let saved = try await store.savePodcastEpisodes(loaded.episodes, admission: .incremental)
        let values = try await loadLibrary(from: store)
        let downloads = try await admitAutomatically(
            feedID: loaded.feed.itemID, feedEpisodes: Array(values.episodes),
            newlySaved: Set(saved.newlyAdmitted.map(\.rawValue)), store: store
        )
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
        dismissedEpisodes = try await loadDismissedEpisodes(from: store)
        await refreshPodcastQueueState()
        return downloads
    }

    /// Plans and commits automatic admissions for one feed. Candidates are the
    /// feed's new episodes, plus, when the feed has a kept limit, undecided
    /// episodes waiting for a slot. Returns the episode IDs whose download
    /// claim this call took.
    func admitAutomatically(
        feedID: ItemID, feedEpisodes: [WiltedMacEpisode], newlySaved: Set<String>, store: LocalLibraryStore
    ) async throws -> [String] {
        let policy = try await store.feedAutomationPolicy(for: feedID)
            .resolved(using: EpisodeAdmissionService.globalDefaults(automationSettings))
        guard policy.autoKeep else { return [] }

        let decisions = try await store.decisions(forFeed: feedID)
        let decided = Set(decisions.map(\.episodeID.rawValue))
        let manual = Dictionary(uniqueKeysWithValues: decisions.filter { $0.source == .manual }.map {
            ($0.episodeID.rawValue, $0.decision == .keep ? FeedManualDecision.keep : .skip)
        })
        let live = feedEpisodes.filter { $0.removalKind == nil }
        let queued = Set(try await store.podcastQueueState().episodeIDs.map(\.rawValue))
        let kept = queued.intersection(live.map(\.id))
        let candidates = live.filter {
            !decided.contains($0.id) && !queued.contains($0.id) && !$0.isPlayed
                && (newlySaved.contains($0.id) || policy.keptLimit != nil)
        }.map {
            EpisodeAdmissionService.Candidate(id: $0.id, title: $0.title, notes: $0.notes, releasedAt: $0.releasedAt)
        }
        let admissions = EpisodeAdmissionService.plan(
            candidates: candidates, keptEpisodeIDs: kept, manualDecisions: manual,
            rules: try await store.episodeMatchRules(for: feedID), policy: policy
        )
        var downloads: [String] = []
        for admission in admissions {
            guard let id = try? ItemID(rawValue: admission.episodeID) else { continue }
            let tickets = try await store.admitEpisode(.init(
                episodeID: id, decision: admission.decision, source: admission.source,
                ruleID: admission.ruleID, decidedAt: Timestamp(Date())
            ), enqueue: admission.decision == .keep, workTicketKinds: admission.workTicketKinds)
            for ticket in tickets where ticket.kind == .podcastPreparation {
                adoptAdmittedPreparation(sequence: ticket.requestSequence, for: admission.episodeID)
            }
            if admission.workTicketKinds.contains(.podcastDownload),
               try await store.claimPodcastDownload(episodeID: id) {
                downloads.append(admission.episodeID)
            }
        }
        return downloads
    }

    /// Fills the slots a Skip or retirement freed: re-plans each affected feed
    /// and starts the downloads its policy authorizes.
    func releaseWaitingEpisodes(feedIDs: Set<String>) async {
        guard let store, !isClosingTemporaryState else { return }
        var started: [String] = []
        for rawFeedID in feedIDs.sorted() {
            guard let feedID = try? ItemID(rawValue: rawFeedID),
                  let claimed = try? await admitAutomatically(
                    feedID: feedID, feedEpisodes: episodes.filter { $0.feedID == rawFeedID },
                    newlySaved: [], store: store
                  ) else { continue }
            started += claimed
        }
        await refreshPodcastQueueState()
        for id in started {
            if let episode = episodes.first(where: { $0.id == id }) { downloadEpisode(episode, alreadyClaimed: true) }
        }
    }

    /// Releases the waiting episodes a retirement or removal just freed a slot
    /// for. The library rows are re-read first because admission counts the
    /// kept episodes from them, and the retired or dismissed one must no
    /// longer count. Call it only after the store write has committed.
    func releaseWaitingEpisodesAfterRetirement(of episode: WiltedMacEpisode) async {
        guard let feedID = episode.feedID else { return }
        await reloadLibraryRows()
        await releaseWaitingEpisodes(feedIDs: [feedID])
    }

    struct ManualKeepOutcome {
        var changed: Set<String> = []
        var accepted: Set<String> = []
        var unresolved: Set<String> = []
        var downloads: [WiltedMacEpisode] = []
        /// The durable queue read right after the last admission.
        var queueIDs: [String] = []
    }

    /// Commits a manual Keep: the queue entry, a manual decision record, and a
    /// download ticket only when the feed's Auto download (or, on Use global,
    /// the global override) asks for the download and the episode needs one.
    func commitManualKeep(_ captured: [WiltedMacEpisode], store: LocalLibraryStore) async throws -> ManualKeepOutcome {
        var outcome = ManualKeepOutcome()
        for episode in captured {
            guard episode.removalKind == nil, let id = try? ItemID(rawValue: episode.id),
                  try await store.podcastEpisode(for: id) != nil else {
                outcome.unresolved.insert(episode.id)
                continue
            }
            let wasKept = podcastQueueIDs.contains(episode.id)
            var feedPolicy = FeedAutomationPolicy()
            if let rawFeedID = episode.feedID, let feedID = try? ItemID(rawValue: rawFeedID) {
                feedPolicy = try await store.feedAutomationPolicy(for: feedID)
            }
            let download = !wasKept && Self.menuGroup(for: episode) == .available
                && EpisodeAdmissionService.shouldDownloadAfterManualKeep(
                    feedPolicy: feedPolicy, globalDownloadEverything: automationSettings.downloadEverythingOnMenu
                )
            try await store.admitEpisode(.init(
                episodeID: id, decision: .keep, source: .manual, decidedAt: Timestamp(Date())
            ), workTicketKinds: download ? [.podcastDownload] : [])
            outcome.accepted.insert(episode.id)
            if !wasKept { outcome.changed.insert(episode.id) }
            if download { outcome.downloads.append(episode) }
        }
        outcome.queueIDs = try await store.podcastQueueState().episodeIDs.map(\.rawValue)
        return outcome
    }

    /// Records the listener's manual Skip or Restore for episodes the store
    /// accepted. Unresolved IDs get no record.
    func recordManualDecisions(
        _ decision: EpisodeDecision, for accepted: Set<String>, at decidedAt: Timestamp, store: LocalLibraryStore
    ) async throws {
        for raw in accepted.sorted() {
            guard let id = try? ItemID(rawValue: raw) else { continue }
            try await store.save(episodeDecision: .init(
                episodeID: id, decision: decision, source: .manual, decidedAt: decidedAt
            ))
        }
    }
}
#endif
