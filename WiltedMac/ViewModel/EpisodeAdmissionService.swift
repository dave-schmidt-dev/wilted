import Foundation
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

private let episodeAdmissionLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "EpisodeAdmission")

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
        var automaticKeptLimit: Int? = nil
    }

    /// Plans one feed's admissions. Rules run whatever the feed's Auto keep:
    /// a Skip rule always claims its match. With Auto keep Off nothing is
    /// kept automatically, so Keep rules and the policy planner leave their
    /// episodes undecided.
    static func plan(
        candidates: [Candidate],
        keptEpisodeIDs: Set<String>,
        manualDecisions: [String: FeedManualDecision],
        rules: EpisodeMatchRules,
        policy: EffectiveFeedAutomationPolicy,
        reservedCapacity: Int = 0
    ) -> [Admission] {
        var ruleAdmissions: [Admission] = []
        var plannerCandidates: [FeedAdmissionCandidate] = []
        for candidate in candidates where manualDecisions[candidate.id] == nil {
            let match = try? rules.evaluate(.init(
                id: candidate.id, title: candidate.title, notes: candidate.notes ?? ""
            ))
            switch match {
            case let .keep(ruleID):
                guard policy.autoKeep else { continue }
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
        var remaining = policy.keptLimit.map { max(0, $0 - keptEpisodeIDs.count - max(0, reservedCapacity)) } ?? Int.max
        return (ruleAdmissions + planned).sorted { lhs, rhs in
            let (left, right) = (releasedAt[lhs.episodeID] ?? .distantFuture, releasedAt[rhs.episodeID] ?? .distantFuture)
            return left == right ? lhs.episodeID < rhs.episodeID : left < right
        }.filter { admission in
            guard admission.decision == .keep else { return true }
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
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
    /// Auto keep is Off globally until Settings turns it on, so automatic
    /// refresh gains authority only on feeds set to On. Manual processing is
    /// the global Auto prepare Off.
    static func globalDefaults(_ settings: WiltedAutomationSettings) -> FeedAutomationGlobalDefaults {
        let prepares: Bool
        switch settings.processingPolicy {
        case .manual: prepares = settings.prepareEverythingDownloaded
        case .immediate, .offPeak: prepares = true
        }
        return .init(
            autoKeep: settings.autoKeepNewEpisodes, autoDownload: settings.downloadEverythingOnLarder,
            autoPrepare: prepares, keptLimit: settings.keptLimitPerFeed
        )
    }

    private static func keepAdmission(
        _ id: String, source: EpisodeDecisionSource, ruleID: UUID?, policy: EffectiveFeedAutomationPolicy
    ) -> Admission {
        .init(episodeID: id, decision: .keep, source: source, ruleID: ruleID,
              workTicketKinds: keepWorkTicketKinds(for: policy), automaticKeptLimit: policy.keptLimit)
    }

    /// The work an automatic Keep issues under this policy. Preparation follows
    /// a download, so Auto prepare alone issues nothing.
    static func keepWorkTicketKinds(for policy: EffectiveFeedAutomationPolicy) -> [WorkTicketKind] {
        guard policy.autoDownload else { return [] }
        return policy.autoPrepare ? [.podcastDownload, .podcastPreparation] : [.podcastDownload]
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
        var values = try await loadLibrary(from: store)
        let admitted = try await admitAutomatically(
            feedID: loaded.feed.itemID, feedEpisodes: Array(values.episodes),
            newlySaved: Set(saved.newlyAdmitted.map(\.rawValue)), store: store
        )
        // A rule Skip retired episodes after that read; read again so the Feed shows them gone.
        if !admitted.ruleSkipped.isEmpty { values = try await loadLibrary(from: store) }
        articles = values.articles
        applyEpisodes(values.episodes)
        subscriptions = values.subscriptions
        dismissedEpisodes = try await loadDismissedEpisodes(from: store)
        await refreshPodcastQueueState()
        return admitted.downloads
    }

    /// What one automatic admission pass committed.
    struct AutomaticAdmissionOutcome {
        /// Episode IDs whose download claim the pass took.
        var downloads: [String] = []
        /// Episodes a Skip rule retired. Library rows read before the pass
        /// still show them live.
        var ruleSkipped: [String] = []
    }

    /// Plans and commits automatic admissions for one feed. Candidates are the
    /// feed's new episodes, plus, when Auto keep is On and the feed has a kept
    /// limit, undecided episodes waiting for a slot. With Auto keep Off only
    /// Skip rules act, and only on `newlySaved`; callers releasing slots pass
    /// none, so that case reads nothing. A rule Skip on a `newlySaved` episode
    /// retires it and records its rule in one write. A rule Skip on an older
    /// waiting episode writes nothing: a skip record alone would leave it in
    /// the Feed, so it stays undecided until the rules sheet's Apply retires
    /// it. Every other admission goes through `commitAdmission`, which records
    /// the decision. `feedEpisodes` may hold other feeds' rows: only this
    /// feed's are considered, so one feed's rules never touch another's.
    func admitAutomatically(
        feedID: ItemID, feedEpisodes: [WiltedMacEpisode], newlySaved: Set<String>, store: LocalLibraryStore
    ) async throws -> AutomaticAdmissionOutcome {
        // An overdue receipt remains reserved until this durable seal succeeds.
        _ = try await store.sealExpiredManualCompletions(at: manualCompletionNow())
        await scheduleManualCompletionExpiry(store: store)
        let reserved = try await store.manualCompletionCapacityReservations(at: manualCompletionNow())[feedID, default: 0]
        let policy = try await store.feedAutomationPolicy(for: feedID)
            .resolved(using: EpisodeAdmissionService.globalDefaults(automationSettings))
        guard policy.autoKeep || !newlySaved.isEmpty else { return .init() }
        let rules = try await store.episodeMatchRules(for: feedID)
        guard policy.autoKeep || !rules.rules.isEmpty else { return .init() }

        let decisions = try await store.decisions(forFeed: feedID)
        let decided = Set(decisions.map(\.episodeID.rawValue))
        let manual = Dictionary(uniqueKeysWithValues: decisions.filter { $0.source == .manual }.map {
            ($0.episodeID.rawValue, $0.decision == .keep ? FeedManualDecision.keep : .skip)
        })
        let live = feedEpisodes.filter { $0.removalKind == nil && $0.feedID == feedID.rawValue }
        let queued = Set(try await store.podcastQueueState().episodeIDs.map(\.rawValue))
        let keptDecisions = Set(decisions.filter { $0.decision == .keep }.map(\.episodeID.rawValue))
        let keptRaw = queued.union(keptDecisions).intersection(live.map(\.id))
        let kept = Set(try await store.logicalEpisodeRepresentatives(keptRaw.compactMap { try? ItemID(rawValue: $0) }).map(\.rawValue))
        var plannedGroups = Set<String>()
        let candidates = live.filter {
            !decided.contains($0.id) && !queued.contains($0.id) && !$0.isPlayed
                && (newlySaved.contains($0.id) || (policy.autoKeep && policy.keptLimit != nil))
                && !kept.contains(logicalRepresentativeID($0.id))
                && plannedGroups.insert(logicalRepresentativeID($0.id)).inserted
        }.map {
            EpisodeAdmissionService.Candidate(id: $0.id, title: $0.title, notes: $0.notes, releasedAt: $0.releasedAt)
        }
        let admissions = EpisodeAdmissionService.plan(
            candidates: candidates, keptEpisodeIDs: kept, manualDecisions: manual, rules: rules, policy: policy, reservedCapacity: reserved
        )
        var outcome = AutomaticAdmissionOutcome()
        for admission in admissions {
            guard let id = try? ItemID(rawValue: admission.episodeID) else { continue }
            if admission.decision == .skip {
                // Only an episode this refresh found is retired: an older one
                // may be a restore whose manual Keep failed to save, so it is
                // left undecided. The store also refuses any episode with a
                // manual decision.
                guard let ruleID = admission.ruleID, newlySaved.contains(admission.episodeID),
                      try await store.retireEpisodeBySkipRule(id, ruleID: ruleID, at: Timestamp(Date())) else { continue }
                // Withdrawing writes a cancelled ticket even when none existed,
                // so only an episode actually waiting in the line is withdrawn.
                if preparationRequestSequences[admission.episodeID] != nil {
                    withdrawPreparationRequest(for: admission.episodeID)
                }
                outcome.ruleSkipped.append(admission.episodeID)
            } else if try await commitAdmission(admission, as: id, decidedAt: Timestamp(Date()), store: store) {
                outcome.downloads.append(admission.episodeID)
            }
        }
        return outcome
    }

    /// What the admission after a manual refresh committed.
    struct ManualRefreshAdmission {
        var downloads: [String] = []
        /// Episodes a Skip rule retired. When any did, the caller's library
        /// read is stale and must be taken again, and they are not reported
        /// as added: the listener would look for them and find nothing.
        var ruleSkipped: [String] = []
    }

    /// Admits the episodes a manual refresh found, feed by feed, as automatic
    /// refresh does. `rows` is the library read taken after the refresh saved
    /// its episodes. A feed whose admission fails is logged and its new
    /// episodes stay undecided; the other feeds and the refresh itself go on.
    func admitAfterManualRefresh(
        _ newEpisodes: [ItemID: [ItemID]], rows: [WiltedMacEpisode], store: LocalLibraryStore
    ) async throws -> ManualRefreshAdmission {
        var result = ManualRefreshAdmission()
        for (feedID, ids) in newEpisodes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try Task.checkCancellation()
            do {
                let admitted = try await admitAutomatically(
                    feedID: feedID, feedEpisodes: rows, newlySaved: Set(ids.map(\.rawValue)), store: store
                )
                result.downloads += admitted.downloads
                result.ruleSkipped += admitted.ruleSkipped
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let reason = error.localizedDescription
                episodeAdmissionLog.error(
                    "Manual-refresh admission failed for \(feedID.rawValue, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }
        return result
    }

    /// Commits one admission: decision, queue entry and tickets in one write,
    /// then adopts the preparation request and takes the download claim.
    /// Returns true when this call took the download claim.
    func commitAdmission(
        _ admission: EpisodeAdmissionService.Admission, as id: ItemID, decidedAt: Timestamp, store: LocalLibraryStore
    ) async throws -> Bool {
        let tickets: [WorkTicket]
        do { tickets = try await store.admitEpisode(.init(
            episodeID: id, decision: admission.decision, source: admission.source,
            ruleID: admission.ruleID, decidedAt: decidedAt
        ), enqueue: admission.decision == .keep, workTicketKinds: admission.workTicketKinds,
            requestedAt: Timestamp(manualCompletionNow()), automaticKeptLimit: admission.automaticKeptLimit)
        } catch is AutomaticEpisodeAdmissionError { return false }
        for ticket in tickets where ticket.kind == .podcastPreparation {
            adoptAdmittedPreparation(sequence: ticket.requestSequence, for: admission.episodeID)
        }
        return admission.workTicketKinds.contains(.podcastDownload)
            ? try await store.claimPodcastDownload(episodeID: id) : false
    }

    /// Starts the transfers whose claims `commitAdmission` took.
    func startClaimedDownloads(_ ids: [String]) {
        for id in ids {
            if let episode = episodes.first(where: { $0.id == id }) { downloadEpisode(episode, alreadyClaimed: true) }
        }
    }

    /// Fills the slots a Skip or retirement freed: re-plans each affected feed
    /// and starts the downloads its policy authorizes.
    func releaseWaitingEpisodes(feedIDs: Set<String>) async {
        guard let store, !isClosingTemporaryState else { return }
        var started: [String] = []
        for rawFeedID in feedIDs.sorted() {
            // No episode is new here, so a rule Skip writes nothing.
            guard let feedID = try? ItemID(rawValue: rawFeedID),
                  let admitted = try? await admitAutomatically(
                    feedID: feedID, feedEpisodes: episodes.filter { $0.feedID == rawFeedID },
                    newlySaved: [], store: store
                  ) else { continue }
            started += admitted.downloads
        }
        await refreshPodcastQueueState()
        startClaimedDownloads(started)
    }

    /// Releases the waiting episodes a retirement or removal just freed a slot
    /// for. The library rows are re-read first because admission counts the
    /// kept episodes from them, and the retired or dismissed one must no
    /// longer count. Call it only after the store write has committed. A
    /// closing model admits nothing, so it skips the reload too.
    func releaseWaitingEpisodesAfterRetirement(of episode: WiltedMacEpisode) async {
        guard let feedID = episode.feedID, !isClosingTemporaryState else { return }
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
    func commitManualKeep(_ captured: [WiltedMacEpisode], store: LocalLibraryStore, at: Timestamp = Timestamp(Date())) async throws -> ManualKeepOutcome {
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
            let download = !wasKept && Self.larderGroup(for: episode) == .available
                && EpisodeAdmissionService.shouldDownloadAfterManualKeep(
                    feedPolicy: feedPolicy, globalDownloadEverything: automationSettings.downloadEverythingOnLarder
                )
            do {
                try await store.admitEpisode(.init(
                    episodeID: id, decision: .keep, source: .manual, decidedAt: at
                ), workTicketKinds: download ? [.podcastDownload] : [])
            } catch AutomaticEpisodeAdmissionError.supersededManualDecision {
                outcome.unresolved.insert(episode.id)
                continue
            }
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
