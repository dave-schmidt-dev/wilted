import Foundation
import Observation
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
    /// Kept episodes Apply skipped that were holding a preparation request.
    var withdrawn: Set<ItemID> = []
}

struct FeedRulesApplyResult: Sendable, Equatable {
    let counts: FeedRulesCounts
    /// Nil when nothing needed to change.
    let undo: FeedRulesUndo?
}

extension WiltedMacModel {
    // MARK: Snapshot

    /// Reads one feed's decisions, queue, policy and episodes into plain values.
    func feedRulesInput(feedID rawFeedID: String, rules: EpisodeMatchRules) async throws -> FeedRulesInput {
        guard let store, let feedID = try? ItemID(rawValue: rawFeedID) else { throw CancellationError() }
        let policy = try await store.feedAutomationPolicy(for: feedID)
            .resolved(using: EpisodeAdmissionService.globalDefaults(automationSettings))
        let records = try await store.decisions(forFeed: feedID)
        let queue = try await store.podcastQueueState()
        // Finished episodes are not candidates for refresh, so they are not here either.
        let live = episodes.filter { $0.feedID == rawFeedID && $0.removalKind == nil && !$0.isPlayed }
        let playing = Set([currentPodcastEpisodeID, queue.currentEpisodeID?.rawValue].compactMap { $0 })
        return FeedRulesInput(
            rules: rules, policy: policy,
            episodes: live.map {
                FeedRulesEpisode(
                    id: $0.id, title: $0.title, notes: $0.notes ?? "", releasedAt: $0.releasedAt,
                    isStarted: playing.contains($0.id) || hasStartedEpisode($0)
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
    /// episodes holding a rule or policy decision. Evaluation is the
    /// cancellable part; once it finishes, the commit runs to the end.
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
        for admission in admissions where admission.decision == .skip && priorQueue.episodeIDs.map(\.rawValue).contains(admission.episodeID) {
            let id = try ItemID(rawValue: admission.episodeID)
            if await holdsPreparationRequest(for: id, store: store) { withdrawn.insert(id) }
        }
        var claimed: [String] = []
        var issued: Set<ItemID> = []
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
                let keeps = admission.decision == .keep
                let request = EpisodeAdmissionService.Admission(
                    episodeID: admission.episodeID, decision: admission.decision, source: admission.source,
                    ruleID: admission.ruleID, workTicketKinds: keeps ? kinds : []
                )
                if try await commitAdmission(request, as: id, decidedAt: decidedAt, store: store) { claimed.append(admission.episodeID) }
                if keeps, !kinds.isEmpty { issued.insert(id) }
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
            // A half-applied pass is worse than none: put everything back.
            try? await store.restoreEpisodeDecisions(prior, queue: priorQueue)
            for id in issued { await withdrawUnstartedKeepWork(for: id, store: store) }
            await refreshPodcastQueueState()
            throw error
        }
        let postQueue = try await store.podcastQueueState()
        await refreshPodcastQueueState()
        // A kept episode that is now skipped gives up its place in the preparation line.
        for (id, record) in applied where record.decision == .skip && priorQueue.episodeIDs.contains(id) {
            withdrawPreparationRequest(for: id.rawValue)
        }
        startClaimedDownloads(claimed)
        return FeedRulesApplyResult(
            counts: plan.counts,
            undo: FeedRulesUndo(
                feedID: rawFeedID, prior: prior, applied: applied, priorQueue: priorQueue, postQueue: postQueue,
                issued: issued, withdrawn: withdrawn
            )
        )
    }

    // MARK: Undo

    /// Restores the decision records and the queue as they were before Apply.
    /// An episode the listener has decided about since is left as they left it.
    /// Returns how many episodes were restored.
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
        try await store.restoreEpisodeDecisions(restore, queue: queue)
        await refreshPodcastQueueState()
        // Work Apply asked for goes with the Keep; a request Apply withdrew comes back with it.
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

// MARK: - Editor state

/// One feed's rules draft, preview and Apply state. It lives on the policy
/// board, so the draft and the last preview survive closing the popover.
/// Rules are saved as soon as every rule is valid; a rule with an error keeps
/// its text on screen and nothing is stored until it is fixed.
@MainActor @Observable
final class WiltedMacFeedRulesEditor {
    struct Draft: Identifiable, Equatable {
        let id: UUID
        var field: EpisodeMatchField
        var include: String
        var exclude: String
        var action: EpisodeMatchAction
        var isEnabled: Bool

        init(_ rule: EpisodeMatchRule) {
            id = rule.id; field = rule.field; include = rule.includePattern
            exclude = rule.excludePattern ?? ""; action = rule.action; isEnabled = rule.isEnabled
        }
    }

    struct Problems: Equatable {
        var include: String?
        var exclude: String?
        var isEmpty: Bool { include == nil && exclude == nil }
    }

    private unowned let board: WiltedMacFeedPolicyBoard
    let feedID: String
    private(set) var drafts: [Draft] = []
    private(set) var plan: FeedRulesPlan?
    private(set) var progress: (done: Int, total: Int)?
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var undo: FeedRulesUndo?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    private var hasLoaded = false
    /// Test seam: runs after each episode's evaluation, off the main actor.
    @ObservationIgnored var stepHookForTesting: (@Sendable (Int) async -> Void)?

    init(board: WiltedMacFeedPolicyBoard, feedID: String) {
        self.board = board
        self.feedID = feedID
    }

    /// Takes the saved rules once the board has loaded them; later calls keep the draft.
    func loadIfNeeded() {
        guard !hasLoaded, board.isLoaded(feedID) else { return }
        hasLoaded = true
        drafts = board.rules(for: feedID).rules.map(Draft.init)
    }

    /// The number of rules, from the draft once it is loaded.
    var ruleCount: Int { hasLoaded ? drafts.count : board.rules(for: feedID).rules.count }

    // MARK: Editing

    var rules: EpisodeMatchRules {
        EpisodeMatchRules(rules: drafts.map {
            EpisodeMatchRule(
                id: $0.id, field: $0.field, includePattern: $0.include,
                excludePattern: $0.exclude.isEmpty ? nil : $0.exclude, action: $0.action, isEnabled: $0.isEnabled
            )
        })
    }

    func problems(for draft: Draft) -> Problems {
        Problems(
            include: draft.include.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Enter the text or pattern to match." : message(forPattern: draft.include),
            exclude: draft.exclude.isEmpty ? nil : message(forPattern: draft.exclude)
        )
    }

    var hasProblems: Bool { drafts.contains { !problems(for: $0).isEmpty } }

    @discardableResult
    func addRule() -> UUID {
        let rule = EpisodeMatchRule(field: .title, includePattern: "", action: .keep)
        drafts.append(Draft(rule))
        edited()
        return rule.id
    }

    func update(_ id: UUID, _ change: (inout Draft) -> Void) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        var draft = drafts[index]
        change(&draft)
        guard draft != drafts[index] else { return }
        drafts[index] = draft
        edited()
    }

    func delete(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        edited()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = drafts.firstIndex(where: { $0.id == id }),
              drafts.indices.contains(index + offset) else { return }
        drafts.swapAt(index, index + offset)
        edited()
    }

    private func edited() {
        plan = nil
        message = nil
        if !hasProblems { board.replaceRules(rules, for: feedID) }
    }

    private func message(forPattern pattern: String) -> String? {
        do {
            try EpisodeMatchRules(rules: [.init(field: .title, includePattern: pattern, action: .keep)]).validate()
            return nil
        } catch EpisodeMatchRuleError.patternTooLong(_, let maximum) {
            return "Use at most \(maximum) characters."
        } catch {
            return "This is not a valid pattern. Check brackets and escapes."
        }
    }

    // MARK: Preview, Apply, Undo

    var canRun: Bool { board.isLoaded(feedID) && !hasProblems && !isBusy }
    var canApply: Bool { canRun && (plan?.counts.totalChanges ?? 0) > 0 }

    func preview() { run(applying: false) }
    func apply() { guard canApply else { return }; run(applying: true) }

    /// Stops an evaluation in progress. Nothing has been written until it ends.
    func cancel() { task?.cancel() }

    func undoLastApply() {
        guard let undo, !isBusy else { return }
        isBusy = true
        message = nil
        let model = board.model
        task = model.runFeedRulesTask { [weak self] in
            defer { self?.finish() }
            do {
                let restored = try await model.undoFeedRules(undo)
                self?.undo = nil
                self?.plan = nil
                self?.message = "Undone. \(restored) episode\(restored == 1 ? "" : "s") restored."
            } catch {
                self?.message = "Could not undo. Nothing was changed."
            }
        }
    }

    private func run(applying: Bool) {
        guard canRun else { return }
        isBusy = true
        message = nil
        progress = (0, 0)
        let (feedID, rules, hook) = (feedID, rules, stepHookForTesting)
        let model = board.model
        task = model.runFeedRulesTask { [weak self] in
            defer { self?.finish() }
            let report: FeedRulesProgress = { done, total in self?.progress = (done, total) }
            do {
                if applying {
                    let result = try await model.applyFeedRules(feedID: feedID, rules: rules, progress: report, stepHook: hook)
                    self?.plan = nil
                    self?.undo = result.undo
                    self?.message = result.undo == nil
                        ? "Nothing needed to change."
                        : "Applied \(result.counts.totalChanges) change\(result.counts.totalChanges == 1 ? "" : "s")."
                } else {
                    self?.plan = try await model.previewFeedRules(feedID: feedID, rules: rules, progress: report, stepHook: hook)
                }
            } catch is CancellationError {
                self?.message = "Cancelled. Nothing was changed."
            } catch {
                self?.message = "Could not check the rules. Nothing was changed."
            }
        }
    }

    private func finish() {
        isBusy = false
        progress = nil
    }
}
