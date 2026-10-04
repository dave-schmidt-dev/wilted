import Foundation

/// The part of an episode a matching rule searches.
public enum EpisodeMatchField: String, Codable, CaseIterable, Sendable {
    case title
    case notes
    case both
}

/// The decision made when a rule matches an episode.
public enum EpisodeMatchAction: String, Codable, CaseIterable, Sendable {
    case keep
    case skip
}

/// One ordered, per-show episode matching rule.
public struct EpisodeMatchRule: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var field: EpisodeMatchField
    public var includePattern: String
    public var excludePattern: String?
    public var action: EpisodeMatchAction
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        field: EpisodeMatchField,
        includePattern: String,
        excludePattern: String? = nil,
        action: EpisodeMatchAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.field = field
        self.includePattern = includePattern
        self.excludePattern = excludePattern
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// The episode data needed to evaluate per-show rules.
public struct EpisodeMatchEpisode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var notes: String

    public init(id: String, title: String, notes: String) {
        self.id = id
        self.title = title
        self.notes = notes
    }
}

/// A validation or evaluation error tied to one matching rule.
public enum EpisodeMatchRuleError: Error, Codable, Equatable, LocalizedError, Sendable {
    case patternTooLong(ruleID: UUID, maximumLength: Int)
    case invalidPattern(ruleID: UUID, problem: String)
    case timedOut(ruleID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .patternTooLong(ruleID, maximumLength):
            "Rule \(ruleID.uuidString) has a pattern longer than \(maximumLength) characters."
        case let .invalidPattern(ruleID, problem):
            "Rule \(ruleID.uuidString) has an invalid regular expression: \(problem)"
        case let .timedOut(ruleID):
            "Rule \(ruleID.uuidString) took too long to evaluate."
        }
    }
}

/// The outcome of evaluating the ordered rules for one episode.
public enum EpisodeMatchResult: Codable, Equatable, Sendable {
    case keep(ruleID: UUID)
    case skip(ruleID: UUID)
    case noMatch
    case timedOut(EpisodeMatchRuleError)
}

/// An episode and its rule-preview result.
public struct EpisodeMatchPreview: Identifiable, Codable, Equatable, Sendable {
    public let episodeID: String
    public let result: EpisodeMatchResult

    public var id: String { episodeID }

    public init(episodeID: String, result: EpisodeMatchResult) {
        self.episodeID = episodeID
        self.result = result
    }
}

/// Ordered per-show rules that decide whether an episode should be kept or skipped.
public struct EpisodeMatchRules: Codable, Equatable, Sendable {
    /// Patterns are capped to bound storage and compilation work at save time.
    public static let maximumPatternLength = 512
    /// Notes are capped before matching so unusually large feed descriptions cannot dominate evaluation.
    public static let maximumNotesLength = 16 * 1_024
    /// Each episode receives this much matching time by default.
    public static let defaultEvaluationTimeout: TimeInterval = 0.05

    public typealias Clock = @Sendable () -> TimeInterval

    public var rules: [EpisodeMatchRule]

    public init(rules: [EpisodeMatchRule] = []) {
        self.rules = rules
    }

    /// Rejects invalid or unbounded patterns before a rule set is saved.
    public func validate() throws {
        for rule in rules {
            try validate(pattern: rule.includePattern, ruleID: rule.id)
            if let excludePattern = rule.excludePattern {
                try validate(pattern: excludePattern, ruleID: rule.id)
            }
        }
    }

    /// Evaluates an episode until the first enabled rule matches, or the deadline passes.
    public func evaluate(
        _ episode: EpisodeMatchEpisode,
        timeout: TimeInterval = defaultEvaluationTimeout,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime }
    ) throws -> EpisodeMatchResult {
        let deadline = clock() + max(0, timeout)
        let notes = String(episode.notes.prefix(Self.maximumNotesLength))

        for rule in rules where rule.isEnabled {
            let include = try expression(for: rule.includePattern, ruleID: rule.id)
            let includeResult = evaluate(include, in: texts(for: rule.field, title: episode.title, notes: notes), deadline: deadline, clock: clock)
            if includeResult.timedOut {
                return .timedOut(.timedOut(ruleID: rule.id))
            }
            guard includeResult.matched else { continue }

            if let excludePattern = rule.excludePattern {
                let exclude = try expression(for: excludePattern, ruleID: rule.id)
                let excludeResult = evaluate(exclude, in: texts(for: rule.field, title: episode.title, notes: notes), deadline: deadline, clock: clock)
                if excludeResult.timedOut {
                    return .timedOut(.timedOut(ruleID: rule.id))
                }
                guard !excludeResult.matched else { continue }
            }

            switch rule.action {
            case .keep: return .keep(ruleID: rule.id)
            case .skip: return .skip(ruleID: rule.id)
            }
        }
        return .noMatch
    }

    /// Evaluates the same rule set for every supplied episode.
    public func preview(
        _ episodes: [EpisodeMatchEpisode],
        timeout: TimeInterval = defaultEvaluationTimeout,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime }
    ) throws -> [EpisodeMatchPreview] {
        try episodes.map { episode in
            EpisodeMatchPreview(episodeID: episode.id, result: try evaluate(episode, timeout: timeout, clock: clock))
        }
    }

    private func validate(pattern: String, ruleID: UUID) throws {
        guard pattern.count <= Self.maximumPatternLength else {
            throw EpisodeMatchRuleError.patternTooLong(ruleID: ruleID, maximumLength: Self.maximumPatternLength)
        }
        _ = try expression(for: pattern, ruleID: ruleID)
    }

    private func expression(for pattern: String, ruleID: UUID) throws -> NSRegularExpression {
        guard pattern.count <= Self.maximumPatternLength else {
            throw EpisodeMatchRuleError.patternTooLong(ruleID: ruleID, maximumLength: Self.maximumPatternLength)
        }
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw EpisodeMatchRuleError.invalidPattern(ruleID: ruleID, problem: error.localizedDescription)
        }
    }

    private func texts(for field: EpisodeMatchField, title: String, notes: String) -> [String] {
        switch field {
        case .title: [title]
        case .notes: [notes]
        case .both: [title, notes]
        }
    }

    private func evaluate(
        _ expression: NSRegularExpression,
        in texts: [String],
        deadline: TimeInterval,
        clock: Clock
    ) -> (matched: Bool, timedOut: Bool) {
        for text in texts {
            var matched = false
            var timedOut = clock() > deadline
            guard !timedOut else { return (false, true) }

            expression.enumerateMatches(
                in: text,
                options: [.reportProgress],
                range: NSRange(text.startIndex..., in: text)
            ) { result, _, stop in
                if clock() > deadline {
                    timedOut = true
                    stop.pointee = true
                } else if result != nil {
                    matched = true
                    stop.pointee = true
                }
            }

            if timedOut || (!matched && clock() > deadline) {
                return (false, true)
            }
            if matched { return (true, false) }
        }
        return (false, false)
    }
}
