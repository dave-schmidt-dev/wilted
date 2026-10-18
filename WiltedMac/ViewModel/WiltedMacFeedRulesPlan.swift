import Foundation
import WiltedDomain
import WiltedProducer

// MARK: - Input

/// What the rules plan needs to know about one of the feed's episodes.
struct FeedRulesEpisode: Sendable, Equatable {
    let id: String
    let title: String
    let notes: String
    let releasedAt: Date
    /// Factual source metadata for list presentation. `releasedAt` remains the
    /// legacy intake-order fallback; it is never presented as publication.
    var presentation: WiltedMacEpisodePresentation? = nil
    var artworkURL: URL? = nil
    var isReport = false
    /// Playing now or part-heard. A started episode is never changed.
    let isStarted: Bool
    /// Retired or finished. Its verdict is shown, but it is never changed.
    var isHistory = false
    /// Its downloaded or prepared audio is on disk, which a Skip deletes.
    var hasDownloadedAudio = false
}

/// A value snapshot of one feed's rules, episodes, decisions and Larder, so the
/// evaluation can run off the main actor.
struct FeedRulesInput: Sendable {
    var rules: EpisodeMatchRules
    var policy: EffectiveFeedAutomationPolicy
    var episodes: [FeedRulesEpisode]
    var records: [String: EpisodeDecisionRecord]
    /// The feed's episodes currently in the Larder queue.
    var keptIDs: Set<String>
}

// MARK: - Result

/// What Apply would do to one episode, or why it would leave it alone.
enum FeedRulesOutcome: Sendable, Equatable {
    /// Undecided, becomes Keep.
    case keep
    /// Undecided, becomes Skip, which retires it. A live episode already
    /// holding an automatic Skip that never retired it (written before rule
    /// Skips retired episodes) is retired the same way.
    case skip
    /// An automatic Keep becomes Skip.
    case keepToSkip
    /// An automatic Skip becomes Keep.
    case skipToKeep
    /// Already as the rules would leave it, or no rule applies.
    case unchanged
    /// The listener decided; rules never touch it.
    case protectedManual
    /// Playing or part-heard; rules never touch it.
    case heldStarted
    /// Would be kept, but the feed is at its kept limit.
    case waiting
    /// A rule could not finish in time, so the episode stays as it is.
    case unfinished
    /// Auto keep is Off for this feed, so only a Skip rule decides.
    case inactive
    /// Retired or finished: the verdict shows what the rules say, and Apply
    /// never changes it.
    case history

    var isChange: Bool {
        switch self {
        case .keep, .skip, .keepToSkip, .skipToKeep: true
        default: false
        }
    }
}

/// The episode's decision before Apply, for the preview.
enum FeedRulesCurrent: Sendable, Equatable {
    case undecided
    case decided(EpisodeDecision, EpisodeDecisionSource)
}

/// One preview row: the rule engine's verdict and what Apply would do about it.
struct FeedRulesPreviewRow: Identifiable, Sendable, Equatable {
    let episodeID: String
    let title: String
    let result: EpisodeMatchResult
    /// The 1-based position of the matching rule in the ordered list.
    let ruleNumber: Int?
    let current: FeedRulesCurrent
    let isKept: Bool
    let outcome: FeedRulesOutcome
    /// Apply would skip it and delete its downloaded audio, as a manual Skip does.
    let deletesDownloadedAudio: Bool
    /// Where the deciding rule matched, prepared off the main actor with the
    /// plan so the preview never runs a pattern. Nil when there is nothing to
    /// draw; `make` fills it, and its default keeps callers that predate it.
    var highlight: WiltedMacRuleMatchHighlight? = nil
    var presentation: WiltedMacEpisodePresentation? = nil
    var artworkURL: URL? = nil
    var isReport = false

    var id: String { episodeID }
}

/// Facts for ranking one row. Notes remain available for selected rows, while
/// match highlighting is only built after the display cap is applied.
struct FeedRulesPlanCandidate: Sendable, Equatable {
    let id: String
    let title: String
    let notesForHighlight: String?
    let presentation: WiltedMacEpisodePresentation?
    let artworkURL: URL?
    let isReport: Bool
    let result: EpisodeMatchResult
    let ruleNumber: Int?
    let current: FeedRulesCurrent
    let isKept: Bool
    let outcome: FeedRulesOutcome
    let deletesDownloadedAudio: Bool

    func previewRow(using rules: EpisodeMatchRules) -> FeedRulesPreviewRow {
        FeedRulesPreviewRow(
            episodeID: id,
            title: title,
            result: result,
            ruleNumber: ruleNumber,
            current: current,
            isKept: isKept,
            outcome: outcome,
            deletesDownloadedAudio: deletesDownloadedAudio,
            highlight: WiltedMacRuleMatchHighlight.make(
                result: result, title: title, notes: notesForHighlight ?? "", rules: rules),
            presentation: presentation,
            artworkURL: artworkURL,
            isReport: isReport
        )
    }
}

/// A decision Apply will write. `expected` is the record the plan was built
/// against, so a decision made meanwhile is never overwritten.
struct FeedRulesAdmission: Sendable, Equatable {
    let episodeID: String
    let decision: EpisodeDecision
    let source: EpisodeDecisionSource
    let ruleID: UUID?
    let expected: EpisodeDecisionRecord?
}

/// Separate counts for each kind of change, and for what is left alone.
struct FeedRulesCounts: Sendable, Equatable {
    var keeps = 0
    var skips = 0
    var keepToSkip = 0
    var skipToKeep = 0
    var protectedManual = 0
    var heldStarted = 0
    var waiting = 0

    /// Changes to undecided episodes.
    var undecidedChanges: Int { keeps + skips }
    /// Changes to episodes that hold an automatic decision.
    var automaticChanges: Int { keepToSkip + skipToKeep }
    var totalChanges: Int { undecidedChanges + automaticChanges }
}

struct FeedRulesPlan: Sendable, Equatable {
    /// The default preview rows in their established newest-first intake order.
    var rows: [FeedRulesPreviewRow]
    /// Lightweight facts for every candidate before the display cap.
    var candidates: [FeedRulesPlanCandidate]
    /// The rules snapshot used to build highlights for newly selected rows.
    var rules: EpisodeMatchRules
    /// Every change Apply makes, including episodes the preview does not show.
    var admissions: [FeedRulesAdmission]
    /// Every episode's outcome counted, including those the preview does not show.
    var counts: FeedRulesCounts
    /// How many episodes Apply would skip whose downloaded audio is on disk,
    /// including those the preview does not show.
    var audioDeletions: Int

    /// At most this many rule matches are shown.
    static let shownMatchLimit = 25
    /// Fewer matches than this are padded with the newest non-matching episodes.
    static let shownRowMinimum = 10

    /// The rows shown for a selected presentation order. Custom keeps the
    /// established newest-first order; calculated sorts rank every candidate
    /// before applying the 25-match/10-row cap.
    func presentationRows(
        sort: WiltedMacLarderSort,
        direction: WiltedMacLarderSortDirection
    ) -> [FeedRulesPreviewRow] {
        guard sort.canonical != .custom else { return rows }
        let keyed = candidates.map { candidate in
            let presentation = candidate.presentation ?? WiltedMacEpisodePresentation(
                title: candidate.title, showTitle: nil, publishedAt: nil,
                sourceDurationSeconds: nil, playableDurationSeconds: nil)
            return (
                candidate: candidate,
                key: WiltedMacEpisodeListOrder.key(for: presentation, id: candidate.id)
            )
        }
        let ranked = WiltedMacEpisodeListOrder.ordered(
            keyed, key: { $0.key },
            sort: sort,
            direction: direction
        ).map { $0.candidate }
        return Self.selectedCandidates(from: ranked).map { $0.previewRow(using: rules) }
    }

    private static func selectedCandidates(from ordered: [FeedRulesPlanCandidate]) -> [FeedRulesPlanCandidate] {
        func isMatch(_ candidate: FeedRulesPlanCandidate) -> Bool {
            switch candidate.result {
            case .keep, .skip: true
            case .noMatch, .timedOut: false
            }
        }
        let matches = ordered.filter(isMatch)
        var selected = Set(matches.prefix(shownMatchLimit).map(\.id))
        if selected.count < shownRowMinimum {
            let padding = ordered.filter { !isMatch($0) }
                .prefix(max(0, shownRowMinimum - selected.count))
            selected.formUnion(padding.map(\.id))
        }
        return ordered.filter { selected.contains($0.id) }
    }

    fileprivate static func counts(of outcomes: some Sequence<FeedRulesOutcome>) -> FeedRulesCounts {
        var counts = FeedRulesCounts()
        for outcome in outcomes {
            switch outcome {
            case .keep: counts.keeps += 1
            case .skip: counts.skips += 1
            case .keepToSkip: counts.keepToSkip += 1
            case .skipToKeep: counts.skipToKeep += 1
            case .protectedManual: counts.protectedManual += 1
            case .heldStarted: counts.heldStarted += 1
            case .waiting: counts.waiting += 1
            case .unchanged, .unfinished, .inactive, .history: break
            }
        }
        return counts
    }
}

// MARK: - Evaluation

extension FeedRulesPlan {
    /// Evaluates every episode against the ordered rules, then decides what
    /// Apply would change. It writes nothing. `step` runs after each episode
    /// with the count done and the total; the plan checks for cancellation
    /// there, so a cancelled evaluation returns no plan at all.
    ///
    /// Every episode is evaluated, but only undecided episodes and episodes
    /// holding a rule or policy decision can change. A retired or finished
    /// episode, a listener's decision, and any playing or part-heard episode
    /// is left exactly as it is. Rule Keeps follow the same contract as
    /// refresh, which does not hold them to the kept limit, but they do use up
    /// places; the rest are kept in release order by `FeedAdmissionPlanner`,
    /// which never removes an episode. With Auto keep Off, the only automatic
    /// authority to Keep, a Skip rule still skips; Keep rules and the policy
    /// decide nothing.
    static func make(
        _ input: FeedRulesInput,
        step: @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in }
    ) async throws -> FeedRulesPlan {
        let ordered = input.episodes.sorted {
            $0.releasedAt == $1.releasedAt ? $0.id < $1.id : $0.releasedAt < $1.releasedAt
        }
        var results: [String: EpisodeMatchResult] = [:]
        for (offset, episode) in ordered.enumerated() {
            try Task.checkCancellation()
            results[episode.id] = try input.rules.evaluate(
                .init(id: episode.id, title: episode.title, notes: episode.notes)
            )
            await step(offset + 1, ordered.count)
            try Task.checkCancellation()
        }

        var outcomes: [String: FeedRulesOutcome] = [:]
        var admissions: [FeedRulesAdmission] = []
        var kept = input.keptIDs
        var undecidedForPolicy: [FeedAdmissionCandidate] = []
        let autoKeep = input.policy.autoKeep

        for episode in ordered {
            let record = input.records[episode.id]
            let result = results[episode.id] ?? .noMatch
            if episode.isHistory { outcomes[episode.id] = .history; continue }
            if record?.source == .manual { outcomes[episode.id] = .protectedManual; continue }
            if episode.isStarted { outcomes[episode.id] = .heldStarted; continue }
            let isKept = kept.contains(episode.id)
            switch result {
            case .timedOut:
                outcomes[episode.id] = .unfinished
            case let .skip(ruleID):
                // A live episode holding a Skip was recorded without being
                // retired, so Apply retires it and replaces that record.
                outcomes[episode.id] = record?.decision == .keep ? .keepToSkip : .skip
                admissions.append(.init(episodeID: episode.id, decision: .skip, source: .rule,
                                        ruleID: ruleID, expected: record))
                kept.remove(episode.id)
            case .keep where !autoKeep, .noMatch where !autoKeep:
                outcomes[episode.id] = .inactive
            case let .keep(ruleID):
                if isKept, record == nil || record?.decision == .keep {
                    outcomes[episode.id] = .unchanged
                } else {
                    outcomes[episode.id] = record?.decision == .skip ? .skipToKeep : .keep
                    admissions.append(.init(episodeID: episode.id, decision: .keep, source: .rule,
                                            ruleID: ruleID, expected: record))
                    kept.insert(episode.id)
                }
            case .noMatch:
                if record == nil, !isKept {
                    undecidedForPolicy.append(.init(id: episode.id, releaseDate: episode.releasedAt))
                } else {
                    outcomes[episode.id] = .unchanged
                }
            }
        }

        // What no rule decided goes to the shared planner, which honours the
        // kept limit using the places the rules above have already taken.
        let planned = autoKeep ? FeedAdmissionPlanner.plan(
            candidates: undecidedForPolicy, keptEpisodeIDs: kept, playingEpisodeID: nil,
            partHeardEpisodeIDs: [], manualDecisions: [:], policy: input.policy
        ) : []
        for decision in planned {
            let id = decision.candidate.id
            switch decision.outcome {
            case .keepNow:
                outcomes[id] = .keep
                admissions.append(.init(episodeID: id, decision: .keep, source: .policy, ruleID: nil, expected: nil))
            case .wait:
                outcomes[id] = .waiting
            case .leaveUndecided:
                outcomes[id] = .unchanged
            }
        }

        // A Skip deletes downloaded audio, as a manual Skip does.
        func deletesAudio(_ episode: FeedRulesEpisode) -> Bool {
            let outcome = outcomes[episode.id] ?? .unchanged
            return episode.hasDownloadedAudio && (outcome == .skip || outcome == .keepToSkip)
        }
        let order = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedCandidates = Array(ordered.reversed()).map { episode in
            let record = input.records[episode.id]
            let result = results[episode.id] ?? .noMatch
            let notesForHighlight: String?
            switch result {
            case let .keep(ruleID), let .skip(ruleID):
                let field = input.rules.rules.first(where: { $0.id == ruleID })?.field
                notesForHighlight = field == .title ? nil : episode.notes
            case .noMatch, .timedOut:
                notesForHighlight = nil
            }
            return FeedRulesPlanCandidate(
                id: episode.id,
                title: episode.title,
                notesForHighlight: notesForHighlight,
                presentation: episode.presentation,
                artworkURL: episode.artworkURL,
                isReport: episode.isReport,
                result: result,
                ruleNumber: ruleNumber(of: result, in: input.rules),
                current: record.map { .decided($0.decision, $0.source) } ?? .undecided,
                isKept: input.keptIDs.contains(episode.id),
                outcome: outcomes[episode.id] ?? .unchanged,
                deletesDownloadedAudio: deletesAudio(episode)
            )
        }
        let rows = Self.selectedCandidates(from: orderedCandidates).map {
            $0.previewRow(using: input.rules)
        }
        return FeedRulesPlan(
            rows: rows, candidates: orderedCandidates, rules: input.rules,
            admissions: admissions.sorted { (order[$0.episodeID] ?? 0) < (order[$1.episodeID] ?? 0) },
            counts: counts(of: ordered.map { outcomes[$0.id] ?? .unchanged }),
            audioDeletions: ordered.filter(deletesAudio).count
        )
    }

    private static func ruleNumber(of result: EpisodeMatchResult, in rules: EpisodeMatchRules) -> Int? {
        let id: UUID
        switch result {
        case let .keep(ruleID), let .skip(ruleID): id = ruleID
        case let .timedOut(error):
            switch error {
            case let .timedOut(ruleID), let .invalidPattern(ruleID, _), let .patternTooLong(ruleID, _): id = ruleID
            }
        case .noMatch: return nil
        }
        return rules.rules.firstIndex { $0.id == id }.map { $0 + 1 }
    }
}
