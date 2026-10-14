import Foundation

/// Whether a playlist is a hand-ordered list or the result of rules.
public enum PlaylistKind: String, Sendable, Equatable, CaseIterable {
    case manual
    case automatic
}

/// A Larder entry's listening progress, as rules see it.
public enum PlaylistPlayedState: String, Sendable, Equatable, CaseIterable {
    case unplayed
    case inProgress
    case played
}

/// The fields an automatic playlist rule can test.
public enum PlaylistRuleField: String, Sendable, Equatable, CaseIterable, Codable {
    case feed
    case played
    case length
    case published
    case kind
    case ready
    case expression
}

/// How a rule compares its field with its value.
public enum PlaylistComparator: String, Sendable, Equatable, CaseIterable, Codable {
    case `is`
    case isNot
    case shorterThan
    case longerThan
    case withinDays
    case before
    case after
    case expression
}

/// Why a rule was refused.
public struct PlaylistRuleError: Error, Equatable, Sendable {
    public let reason: String

    public init(reason: String) { self.reason = reason }
}

/// The facts of one Larder entry that rules read. The caller builds these from
/// library entries and listening state; evaluation does no I/O.
public struct PlaylistCandidate: Sendable, Equatable {
    public let entryID: String
    /// The entry's feed (its source ID), when it has one.
    public let feedID: String?
    /// The entry's library kind, such as `podcast.episode`, `article` or `audiobook`.
    public let kind: String
    public let durationSeconds: Double?
    public let publishedAt: Date
    public let playedState: PlaylistPlayedState
    /// Whether the entry's media is ready to play now. A candidate built without
    /// saying reads as not ready.
    public let isReady: Bool

    public init(entryID: String, feedID: String?, kind: String, durationSeconds: Double?,
                publishedAt: Date, playedState: PlaylistPlayedState, isReady: Bool = false) {
        self.entryID = entryID; self.feedID = feedID; self.kind = kind
        self.durationSeconds = durationSeconds; self.publishedAt = publishedAt
        self.playedState = playedState; self.isReady = isReady
    }
}

/// One automatic-playlist rule: `field comparator value`.
///
/// Values are strings so they round-trip through the store unchanged:
/// - feed, kind: `is` or `isNot` a feed ID or kind string.
/// - played: `is` or `isNot` one of `unplayed`, `inProgress`, `played`.
/// - ready: `is` or `isNot` `true` or `false`.
/// - length: `shorterThan` or `longerThan` a number of minutes.
/// - published: `withinDays` a whole number of days before now, or `before` or
///   `after` an ISO 8601 date.
/// - expression: built with `PlaylistRule.expression(...)`; its value is the
///   versioned JSON payload and its comparator is the dedicated `.expression`.
public struct PlaylistRule: Sendable, Equatable {
    public let field: PlaylistRuleField
    public let comparator: PlaylistComparator
    public let value: String
    let expressionProgram: PlaylistExpressionProgram?

    /// Creates a rule, refusing a comparator or value the field cannot use.
    public init(field: PlaylistRuleField, comparator: PlaylistComparator, value: String) throws {
        guard field != .expression, comparator != .expression else {
            throw PlaylistRuleError(reason: "use PlaylistRule.expression to build an expression rule")
        }
        let allowed: Set<PlaylistComparator>
        switch field {
        case .feed, .kind, .played, .ready: allowed = [.is, .isNot]
        case .length: allowed = [.shorterThan, .longerThan]
        case .published: allowed = [.withinDays, .before, .after]
        case .expression: allowed = [.expression]
        }
        guard allowed.contains(comparator) else {
            throw PlaylistRuleError(reason: "\(comparator.rawValue) does not apply to \(field.rawValue)")
        }
        let valid: Bool
        switch field {
        case .feed, .kind: valid = !value.isEmpty
        case .played: valid = PlaylistPlayedState(rawValue: value) != nil
        case .ready: valid = value == "true" || value == "false"
        case .length: valid = Double(value).map { $0.isFinite && $0 >= 0 } ?? false
        case .published:
            valid = comparator == .withinDays
                ? Int(value).map { $0 >= 0 } ?? false
                : Self.parseDate(value) != nil
        case .expression: valid = false
        }
        guard valid else { throw PlaylistRuleError(reason: "invalid value for \(field.rawValue)") }
        self.init(field: field, comparator: comparator, value: value, expressionProgram: nil)
    }

    private init(field: PlaylistRuleField, comparator: PlaylistComparator, value: String,
                 expressionProgram: PlaylistExpressionProgram?) {
        self.field = field; self.comparator = comparator; self.value = value
        self.expressionProgram = expressionProgram
    }

    public static func == (lhs: PlaylistRule, rhs: PlaylistRule) -> Bool {
        lhs.field == rhs.field && lhs.comparator == rhs.comparator && lhs.value == rhs.value
    }

    /// Compiles an expression rule from numbered leaf rules and a formula.
    public static func expression(numberedRules: [PlaylistNumberedRule],
                                  expressionString: String) throws -> PlaylistRule {
        let payload = try PlaylistExpressionPayload(numberedRules: numberedRules, expressionString: expressionString)
        return try compiledExpression(payload: payload)
    }

    /// Compiles an expression rule; `expression` is the formula as written.
    public static func expression(numberedRules: [PlaylistNumberedRule],
                                  expression: String) throws -> PlaylistRule {
        try Self.expression(numberedRules: numberedRules, expressionString: expression)
    }

    /// Compiles an expression rule; `expression` is the formula as written.
    public static func expression(_ numberedRules: [PlaylistNumberedRule],
                                  expression: String) throws -> PlaylistRule {
        try Self.expression(numberedRules: numberedRules, expressionString: expression)
    }

    /// Compiles an expression rule from already-built leaves and a formula.
    public static func expression(rules: [PlaylistNumberedRule],
                                  expression: String) throws -> PlaylistRule {
        try Self.expression(numberedRules: rules, expressionString: expression)
    }

    /// Compiles an expression rule from an already-validated payload.
    public static func expression(payload: PlaylistExpressionPayload) throws -> PlaylistRule {
        try compiledExpression(payload: payload)
    }

    /// Rebuilds an expression rule from the JSON string the store keeps in the
    /// rule's value, refusing oversized, malformed or unsupported payloads.
    public static func expression(storedValue: String) throws -> PlaylistRule {
        guard storedValue.utf8.count <= PlaylistExpressionParser.maximumPayloadBytes else {
            throw PlaylistRuleError(reason: "expression payload is larger than \(PlaylistExpressionParser.maximumPayloadBytes) bytes")
        }
        guard let data = storedValue.data(using: .utf8) else {
            throw PlaylistRuleError(reason: "expression payload is not valid UTF-8")
        }
        try PlaylistExpressionParser.checkPayloadNesting(data)
        let payload: PlaylistExpressionPayload
        do {
            payload = try JSONDecoder().decode(PlaylistExpressionPayload.self, from: data)
        } catch let error as PlaylistRuleError {
            throw error
        } catch {
            throw PlaylistRuleError(reason: "expression payload is not valid JSON")
        }
        return try compiledExpression(payload: payload)
    }

    private static func compiledExpression(payload: PlaylistExpressionPayload) throws -> PlaylistRule {
        let program = try PlaylistExpressionProgram(payload: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= PlaylistExpressionParser.maximumPayloadBytes else {
            throw PlaylistRuleError(reason: "expression payload is larger than \(PlaylistExpressionParser.maximumPayloadBytes) bytes")
        }
        return PlaylistRule(field: .expression, comparator: .expression,
                            value: String(decoding: data, as: UTF8.self), expressionProgram: program)
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    /// Formats a date the way `before` and `after` values are stored.
    public static func dateValue(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Whether this rule is the expression kind.
    public var isExpression: Bool { field == .expression && comparator == .expression }

    /// The validated versioned payload of an expression rule.
    public var expressionPayload: PlaylistExpressionPayload? { expressionProgram?.payload }

    /// The numbered leaves of an expression rule, in declared order.
    public var numberedRules: [PlaylistNumberedRule] { expressionProgram?.payload.numberedRules ?? [] }

    /// The formula exactly as written, for an expression rule.
    public var expressionString: String? { expressionProgram?.payload.expressionString }

    /// The numbers an expression rule's formula references; declared leaves it
    /// does not use are absent.
    public var usedNumbers: Set<Int> { expressionProgram?.usedNumbers ?? [] }

    /// `usedNumbers` sorted, for display.
    public var usedRuleNumbers: [Int] { usedNumbers.sorted() }

    /// Alternate spelling for `numberedRules`.
    public var expressionRules: [PlaylistNumberedRule] { numberedRules }

    /// Alternate spelling for `expressionString`.
    public var expressionFormula: String? { expressionString }

    /// Alternate spelling for `expressionPayload`.
    public var expressionData: PlaylistExpressionPayload? { expressionPayload }

    /// Whether `candidate` satisfies this rule at `now`. A candidate missing the
    /// field (no feed, no duration) does not satisfy a rule that needs it,
    /// except `isNot`, which a missing feed satisfies.
    public func matches(_ candidate: PlaylistCandidate, now: Date) -> Bool {
        switch field {
        case .feed:
            return (candidate.feedID == value) == (comparator == .is)
        case .kind:
            return (candidate.kind == value) == (comparator == .is)
        case .played:
            return (candidate.playedState.rawValue == value) == (comparator == .is)
        case .ready:
            return (candidate.isReady == (value == "true")) == (comparator == .is)
        case .length:
            guard let seconds = candidate.durationSeconds, let minutes = Double(value) else { return false }
            return comparator == .shorterThan ? seconds < minutes * 60 : seconds > minutes * 60
        case .published:
            switch comparator {
            case .withinDays:
                guard let days = Int(value) else { return false }
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                return candidate.publishedAt >= cutoff && candidate.publishedAt <= now
            case .before: return Self.parseDate(value).map { candidate.publishedAt < $0 } ?? false
            case .after: return Self.parseDate(value).map { candidate.publishedAt > $0 } ?? false
            default: return false
            }
        case .expression:
            guard let expressionProgram else { return false }
            return expressionProgram.matches(candidate, now: now)
        }
    }
}

extension PlaylistRule: Codable {
    private enum CodingKeys: String, CodingKey { case field, comparator, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let field = try container.decode(PlaylistRuleField.self, forKey: .field)
        let comparator = try container.decode(PlaylistComparator.self, forKey: .comparator)
        let value = try container.decode(String.self, forKey: .value)
        try self.init(field: field, comparator: comparator, value: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encode(comparator, forKey: .comparator)
        try container.encode(value, forKey: .value)
    }
}

/// Pure evaluation of automatic-playlist rules over Larder entries.
public enum PlaylistRules {
    /// The candidates that satisfy `rules`, in their input order. Linear in
    /// `candidates` for a fixed rule list. With `matchAll` every rule must hold
    /// (all-of); otherwise any one suffices (any-of). An empty rule list
    /// matches nothing, so a new automatic playlist starts empty.
    public static func evaluate(
        _ rules: [PlaylistRule], matchAll: Bool, candidates: [PlaylistCandidate], now: Date
    ) -> [PlaylistCandidate] {
        guard !rules.isEmpty else { return [] }
        return candidates.filter { candidate in
            matchAll
                ? rules.allSatisfy { $0.matches(candidate, now: now) }
                : rules.contains { $0.matches(candidate, now: now) }
        }
    }

    /// Compiles numbered leaves and a formula into one expression rule, the
    /// entry point for editors that keep the two parts separately.
    public static func compile(numberedRules: [PlaylistNumberedRule],
                               expression: String) throws -> PlaylistRule {
        try PlaylistRule.expression(numberedRules: numberedRules, expressionString: expression)
    }
}
