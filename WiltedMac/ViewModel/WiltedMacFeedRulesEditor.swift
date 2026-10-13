import Foundation
import Observation
import WiltedProducer

/// One feed's rules draft, preview and Apply state. It lives on the policy
/// board, so the draft and the last preview survive closing the popover.
/// Rules are saved as soon as every rule is valid; a rule with an error keeps
/// its text on screen and nothing is stored until it is fixed. Each valid edit
/// previews again once editing pauses; only Apply writes episodes.
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
    /// The latest preview, Apply or Undo, for a caller that waits for it.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// A preview waiting for editing to pause, or running. An edit replaces it.
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// An Apply or Undo. No edit cancels it; a preview waits for it.
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    /// Advanced whenever a preview is replaced, so the replaced one's plan,
    /// progress and cancellation never reach the screen.
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var isPreviewRunning = false
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
        cancelPreview()
        guard !hasProblems else { return }
        board.replaceRules(rules, for: feedID)
        if board.isLoaded(feedID) { startPreview(after: Self.livePreviewDelay) }
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

    /// How long a preview waits after the last edit.
    static let livePreviewDelay: Duration = .milliseconds(300)

    var canRun: Bool { board.isLoaded(feedID) && !hasProblems && !isBusy }
    var canApply: Bool { canRun && (plan?.counts.totalChanges ?? 0) > 0 }

    /// Previews now, in place of one waiting for editing to pause.
    func preview() { guard canRun else { return }; startPreview(after: nil) }

    func apply() {
        guard canApply else { return }
        cancelPreview()
        isBusy = true
        message = nil
        progress = (0, 0)
        let (feedID, rules, hook) = (feedID, rules, stepHookForTesting)
        let model = board.model
        let work = model.runFeedRulesTask { [weak self] in
            defer { self?.finish() }
            let report: FeedRulesProgress = { done, total in self?.progress = (done, total) }
            do {
                let result = try await model.applyFeedRules(feedID: feedID, rules: rules, progress: report, stepHook: hook)
                self?.plan = nil
                self?.undo = result.undo
                self?.message = result.undo == nil
                    ? "Nothing needed to change."
                    : "Applied \(result.counts.totalChanges) change\(result.counts.totalChanges == 1 ? "" : "s")."
            } catch is CancellationError {
                self?.message = "Cancelled. Nothing was changed."
            } catch {
                self?.message = "Could not check the rules. Nothing was changed."
            }
        }
        commitTask = work
        task = work
    }

    /// Stops an evaluation in progress. Nothing has been written until it ends.
    func cancel() {
        previewTask?.cancel()
        commitTask?.cancel()
    }

    func undoLastApply() {
        guard let undo, !isBusy else { return }
        isBusy = true
        message = nil
        let model = board.model
        let work = model.runFeedRulesTask { [weak self] in
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
        commitTask = work
        task = work
    }

    /// Replaces any waiting or running preview with one that starts after
    /// `delay`, or at once. A delayed preview also waits for an Apply or Undo
    /// in progress. The model is captured now: the board may be gone by then.
    private func startPreview(after delay: Duration?) {
        cancelPreview()
        let generation = previewGeneration
        let model = board.model
        // An edit already cleared the message; a delayed preview keeps a newer one.
        if delay == nil { message = nil; beginPreview() }
        let preview = Task { [weak self] in
            if let delay {
                do { try await Task.sleep(for: delay) } catch { return }
                await self?.commitTask?.value
            }
            await self?.runPreview(generation: generation, model: model)
        }
        previewTask = preview
        task = preview
    }

    private func beginPreview() {
        isPreviewRunning = true
        isBusy = true
        progress = (0, 0)
    }

    /// Evaluates in the writer ledger model close drains. Cancelling the
    /// preview task cancels the evaluation.
    private func runPreview(generation: Int, model: WiltedMacModel) async {
        guard previewGeneration == generation else { return }
        if !isPreviewRunning { beginPreview() }
        let (feedID, rules, hook) = (feedID, rules, stepHookForTesting)
        let work = model.runFeedRulesTask { [weak self] in
            let report: FeedRulesProgress = { done, total in
                if self?.previewGeneration == generation { self?.progress = (done, total) }
            }
            do {
                let plan = try await model.previewFeedRules(feedID: feedID, rules: rules, progress: report, stepHook: hook)
                if self?.previewGeneration == generation { self?.plan = plan }
            } catch {
                guard self?.previewGeneration == generation else { return }
                self?.message = error is CancellationError
                    ? "Cancelled. Nothing was changed." : "Could not check the rules. Nothing was changed."
            }
        }
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard previewGeneration == generation else { return }
        isPreviewRunning = false
        finish()
    }

    /// Cancels a waiting or running preview without a word: it is out of date.
    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewGeneration &+= 1
        if isPreviewRunning {
            isPreviewRunning = false
            finish()
        }
    }

    private func finish() {
        isBusy = false
        progress = nil
    }
}
