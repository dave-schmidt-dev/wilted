import Foundation
import WiltedDomain
import WiltedProducer

// MARK: - Input

/// What the rules plan needs to know about one live, unfinished episode.
struct FeedRulesEpisode: Sendable, Equatable {
    let id: String
    let title: String
    let notes: String
    let releasedAt: Date
    /// Playing now or part-heard. A started episode is never changed.
    let isStarted: Bool
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
    /// Undecided, becomes Skip.
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
    /// Auto keep is Off for this feed, so rules decide nothing.
    case inactive

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

    var id: String { episodeID }
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
    var rows: [FeedRulesPreviewRow]
    var admissions: [FeedRulesAdmission]

    var counts: FeedRulesCounts {
        var counts = FeedRulesCounts()
        for row in rows {
            switch row.outcome {
            case .keep: counts.keeps += 1
            case .skip: counts.skips += 1
            case .keepToSkip: counts.keepToSkip += 1
            case .skipToKeep: counts.skipToKeep += 1
            case .protectedManual: counts.protectedManual += 1
            case .heldStarted: counts.heldStarted += 1
            case .waiting: counts.waiting += 1
            case .unchanged, .unfinished, .inactive: break
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
    /// Only undecided episodes and episodes holding a rule or policy decision
    /// can change. A listener's decision, and any playing or part-heard
    /// episode, is left exactly as it is. Rule Keeps follow the same contract
    /// as refresh, which does not hold them to the kept limit, but they do use
    /// up places; the rest are kept in release order by `FeedAdmissionPlanner`,
    /// which never removes an episode.
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
            if record?.source == .manual { outcomes[episode.id] = .protectedManual; continue }
            if !autoKeep { outcomes[episode.id] = .inactive; continue }
            if episode.isStarted { outcomes[episode.id] = .heldStarted; continue }
            let isKept = kept.contains(episode.id)
            switch result {
            case .timedOut:
                outcomes[episode.id] = .unfinished
            case let .skip(ruleID):
                if record?.decision == .skip {
                    outcomes[episode.id] = .unchanged
                } else {
                    outcomes[episode.id] = record == nil ? .skip : .keepToSkip
                    admissions.append(.init(episodeID: episode.id, decision: .skip, source: .rule,
                                            ruleID: ruleID, expected: record))
                    kept.remove(episode.id)
                }
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
        let planned = FeedAdmissionPlanner.plan(
            candidates: undecidedForPolicy, keptEpisodeIDs: kept, playingEpisodeID: nil,
            partHeardEpisodeIDs: [], manualDecisions: [:], policy: input.policy
        )
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

        let order = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = ordered.map { episode in
            let record = input.records[episode.id]
            let result = results[episode.id] ?? .noMatch
            return FeedRulesPreviewRow(
                episodeID: episode.id, title: episode.title, result: result,
                ruleNumber: ruleNumber(of: result, in: input.rules),
                current: record.map { .decided($0.decision, $0.source) } ?? .undecided,
                isKept: input.keptIDs.contains(episode.id), outcome: outcomes[episode.id] ?? .unchanged
            )
        }
        return FeedRulesPlan(rows: rows, admissions: admissions.sorted { (order[$0.episodeID] ?? 0) < (order[$1.episodeID] ?? 0) })
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
