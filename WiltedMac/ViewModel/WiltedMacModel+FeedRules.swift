import Foundation
import WiltedDomain
import WiltedProducer

/// Counted progress for a rules evaluation: episodes done, and the total.
typealias FeedRulesProgress = @MainActor @Sendable (_ done: Int, _ total: Int) -> Void

/// Everything Undo needs to put one Apply back.
struct FeedRulesUndo: Sendable, Equatable {
    let feedID: String
    /// Each changed episode's decision record before Apply; `nil` was undecided.
    let prior: [ItemID: EpisodeDecisionRecord?]
    /// The record Apply wrote, so Undo never overwrites a later decision.
    let applied: [ItemID: EpisodeDecisionRecord]
    let priorQueue: PodcastQueueState
    let postQueue: PodcastQueueState
    /// Keeps whose download and preparation Apply issued.
    var issued: Set<ItemID> = []
    /// Episodes Apply skipped that were holding a preparation request.
    var withdrawn: Set<ItemID> = []
    /// Episodes a rule Skip retired, which Undo returns to the feed.
    var retired: Set<ItemID> = []
}

struct FeedRulesApplyResult: Sendable, Equatable {
    let counts: FeedRulesCounts
    /// Nil when nothing needed to change.
    let undo: FeedRulesUndo?
}

extension WiltedMacModel {
    // MARK: Snapshot

    /// Reads one feed's decisions, queue, policy and episodes into plain values.
    ///
    /// Every stored episode is read, so a rule can be tried against a feed
    /// whose episodes are mostly decided. Retired and finished ones are
    /// history: the preview shows their verdict and Apply never changes them.
    /// Dismissed episodes are not in `episodes` (their separate rows carry no
    /// notes to match), so they are not here either.
    func feedRulesInput(feedID rawFeedID: String, rules: EpisodeMatchRules) async throws -> FeedRulesInput {
        guard let store, let feedID = try? ItemID(rawValue: rawFeedID) else { throw CancellationError() }
        let policy = try await store.feedAutomationPolicy(for: feedID)
            .resolved(using: EpisodeAdmissionService.globalDefaults(automationSettings))
        let records = try await store.decisions(forFeed: feedID)
        let queue = try await store.podcastQueueState()
        let stored = episodes.filter { $0.feedID == rawFeedID && $0.removalKind != .dismissed }
        // Finished episodes are not candidates for refresh, so they are history here too.
        let isHistory = { (episode: WiltedMacEpisode) in episode.removalKind != nil || episode.isPlayed }
        let live = stored.filter { !isHistory($0) }
        let playing = Set([currentPodcastEpisodeID, queue.currentEpisodeID?.rawValue].compactMap { $0 })
        return FeedRulesInput(
            rules: rules, policy: policy,
            episodes: stored.map {
                FeedRulesEpisode(
                    id: $0.id, title: $0.title, notes: $0.notes ?? "", releasedAt: $0.releasedAt,
                    isStarted: playing.contains($0.id) || hasStartedEpisode($0), isHistory: isHistory($0),
                    hasDownloadedAudio: $0.downloadState == .completed || $0.preparationState.isPrepared
                )
            },
            records: Dictionary(records.map { ($0.episodeID.rawValue, $0) }, uniquingKeysWith: { first, _ in first }),
            keptIDs: Set(queue.episodeIDs.map(\.rawValue)).intersection(live.map(\.id))
        )
    }

    // MARK: Evaluate

    /// Evaluates the rules against the feed's episodes off the main actor,
    /// reporting counted progress. Cancelling the caller cancels the work, and
    /// nothing is written either way.
    func previewFeedRules(
        feedID: String, rules: EpisodeMatchRules, progress: @escaping FeedRulesProgress,
        stepHook: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> FeedRulesPlan {
        let input = try await feedRulesInput(feedID: feedID, rules: rules)
        return try await Self.evaluateFeedRules(input) { done, total in
            await progress(done, total)
            await stepHook?(done)
        }
    }

    nonisolated private static func evaluateFeedRules(
        _ input: FeedRulesInput, step: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> FeedRulesPlan {
        let work = Task.detached(priority: .userInitiated) { try await FeedRulesPlan.make(input, step: step) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    // MARK: Apply

    /// Re-evaluates the feed and commits the changes: undecided episodes and
    /// episodes holding a rule or policy decision. A rule Skip retires the
    /// episode, deleting its downloaded audio as a manual Skip does. Evaluation
    /// is the cancellable part; once it finishes, the commit runs to the end.
    func applyFeedRules(
        feedID: String, rules: EpisodeMatchRules, progress: @escaping FeedRulesProgress,
        stepHook: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> FeedRulesApplyResult {
        let plan = try await previewFeedRules(feedID: feedID, rules: rules, progress: progress, stepHook: stepHook)
        try Task.checkCancellation()
        return try await commitFeedRules(plan, feedID: feedID)
    }

    private func commitFeedRules(_ plan: FeedRulesPlan, feedID rawFeedID: String) async throws -> FeedRulesApplyResult {
        guard let store, !isClosingTemporaryState, let feedID = try? ItemID(rawValue: rawFeedID) else {
            throw CancellationError()
        }
        // Read again: anything the listener decided or started since the
        // evaluation began is left alone.
        let current = Dictionary(
            try await store.decisions(forFeed: feedID).map { ($0.episodeID.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let startedNow = Set(episodes.filter { hasStartedEpisode($0) }.map(\.id))
        let admissions = plan.admissions.filter {
            current[$0.episodeID] == $0.expected && !startedNow.contains($0.episodeID)
        }
        guard !admissions.isEmpty else { return FeedRulesApplyResult(counts: plan.counts, undo: nil) }

        let priorQueue = try await store.podcastQueueState()
        let decidedAt = Timestamp(Date())
        // A Keep here is an automatic Keep: it asks for what the feed's policy calls for.
        let kinds = EpisodeAdmissionService.keepWorkTicketKinds(
            for: try await store.feedAutomationPolicy(for: feedID)
                .resolved(using: EpisodeAdmissionService.globalDefaults(automationSettings))
        )
        var withdrawn: Set<ItemID> = []
        for admission in admissions where admission.decision == .skip {
            let id = try ItemID(rawValue: admission.episodeID)
            if await holdsPreparationRequest(for: id, store: store) { withdrawn.insert(id) }
        }
        var claimed: [String] = []
        var issued: Set<ItemID> = []
        var retired: Set<ItemID> = []
        var prior: [ItemID: EpisodeDecisionRecord?] = [:]
        var applied: [ItemID: EpisodeDecisionRecord] = [:]
        do {
            for admission in admissions {
                let id = try ItemID(rawValue: admission.episodeID)
                prior[id] = admission.expected
                let record = EpisodeDecisionRecord(
                    episodeID: id, decision: admission.decision, source: admission.source,
                    ruleID: admission.ruleID, decidedAt: decidedAt
                )
                if admission.decision == .skip {
                    // One save retires it with its rule's skip record. The plan
                    // skips only by rule; false means it was removed or decided
                    // by the listener since the read above, so it is left alone.
                    guard let ruleID = admission.ruleID,
                          try await store.retireEpisodeBySkipRule(id, ruleID: ruleID, at: decidedAt) else {
                        prior.removeValue(forKey: id)
                        continue
                    }
                    retired.insert(id)
                } else {
                    let request = EpisodeAdmissionService.Admission(
                        episodeID: admission.episodeID, decision: admission.decision, source: admission.source,
                        ruleID: admission.ruleID, workTicketKinds: kinds
                    )
                    if try await commitAdmission(request, as: id, decidedAt: decidedAt, store: store) { claimed.append(admission.episodeID) }
                    if !kinds.isEmpty { issued.insert(id) }
                }
                applied[id] = record
            }
            let skipped = Set(applied.filter { $0.value.decision == .skip }.keys)
            let queue = try await store.podcastQueueState()
            if !skipped.isDisjoint(with: queue.episodeIDs) {
                let remaining = queue.episodeIDs.filter { !skipped.contains($0) }
                try await store.replacePodcastQueue(try PodcastQueueState(
                    episodeIDs: remaining, currentEpisodeID: queue.currentEpisodeID.flatMap { remaining.contains($0) ? $0 : nil }
                ))
            }
        } catch {
            // A half-applied pass is worse than none: put everything back,
            // each retirement in the same save as its decision. Should that
            // fail, every retired episode still carries its rule's skip.
            try? await store.restoreEpisodeDecisions(prior, queue: priorQueue, unretiring: retired)
            for id in issued { await withdrawUnstartedKeepWork(for: id, store: store) }
            if !retired.isEmpty { await reloadLibraryRows() }
            await refreshPodcastQueueState()
            throw error
        }
        let postQueue = try await store.podcastQueueState()
        // The Feed, Larder and the next preview read the retirements from `episodes`.
        if !retired.isEmpty { await reloadLibraryRows() }
        await refreshPodcastQueueState()
        // A skipped episode that was kept, or held a request, gives up its place in the preparation line.
        for (id, record) in applied
        where record.decision == .skip && (priorQueue.episodeIDs.contains(id) || withdrawn.contains(id)) {
            withdrawPreparationRequest(for: id.rawValue)
        }
        startClaimedDownloads(claimed)
        return FeedRulesApplyResult(
            counts: plan.counts,
            undo: FeedRulesUndo(
                feedID: rawFeedID, prior: prior, applied: applied, priorQueue: priorQueue, postQueue: postQueue,
                issued: issued, withdrawn: withdrawn, retired: retired
            )
        )
    }

    // MARK: Undo

    /// Restores the decision records and the queue as they were before Apply,
    /// and returns the episodes a rule Skip retired to the feed in the same
    /// save; the audio that Skip deleted is not restored. An episode the
    /// listener has decided about since is left as they left it. Returns how
    /// many episodes were restored.
    @discardableResult
    func undoFeedRules(_ undo: FeedRulesUndo) async throws -> Int {
        guard let store, !isClosingTemporaryState else { throw CancellationError() }
        var restore: [ItemID: EpisodeDecisionRecord?] = [:]
        for (id, written) in undo.applied {
            if try await store.episodeDecision(for: id) == written { restore[id] = undo.prior[id] ?? nil }
        }
        let current = try await store.podcastQueueState()
        let queue: PodcastQueueState
        if current == undo.postQueue {
            queue = undo.priorQueue
        } else {
            // The queue moved on: undo only this Apply's own additions and removals.
            let priorIDs = undo.priorQueue.episodeIDs
            let added = Set(undo.postQueue.episodeIDs).subtracting(priorIDs).intersection(restore.keys)
            var ids = current.episodeIDs.filter { !added.contains($0) }
            for (index, id) in priorIDs.enumerated()
            where restore.keys.contains(id) && !undo.postQueue.episodeIDs.contains(id) && !ids.contains(id) {
                ids.insert(id, at: min(index, ids.count))
            }
            queue = try PodcastQueueState(
                episodeIDs: ids, currentEpisodeID: current.currentEpisodeID.flatMap { ids.contains($0) ? $0 : nil }
            )
        }
        let unretiring = undo.retired.intersection(restore.keys)
        try await store.restoreEpisodeDecisions(restore, queue: queue, unretiring: unretiring)
        if !unretiring.isEmpty { await reloadLibraryRows() }
        await refreshPodcastQueueState()
        // Work Apply asked for goes with the Keep; a request Apply withdrew
        // comes back with it, for a retired Keep as for any other.
        for id in restore.keys where undo.issued.contains(id) { await withdrawUnstartedKeepWork(for: id, store: store) }
        for id in restore.keys where undo.withdrawn.contains(id) && restore[id]??.decision == .keep {
            registerPreparationRequest(for: id.rawValue)
        }
        return restore.count
    }

    // MARK: Writer ledger

    /// Runs rules work in the same finite-writer ledger that model close drains.
    @discardableResult
    func runFeedRulesTask(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.subscriptionWriteTasks[token] = nil }
            guard let self, !self.isClosingTemporaryState else { return }
            await body()
        }
        subscriptionWriteTasks[token] = task
        return task
    }
}
