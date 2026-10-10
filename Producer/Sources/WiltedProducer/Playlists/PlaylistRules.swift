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
public enum PlaylistRuleField: String, Sendable, Equatable, CaseIterable {
    case feed
    case played
    case length
    case published
    case kind
}

/// How a rule compares its field with its value.
public enum PlaylistComparator: String, Sendable, Equatable, CaseIterable {
    case `is`
    case isNot
    case shorterThan
    case longerThan
    case withinDays
    case before
    case after
}

/// Why a rule was refused.
public struct PlaylistRuleError: Error, Equatable, Sendable {
    public let reason: String
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

    public init(entryID: String, feedID: String?, kind: String, durationSeconds: Double?,
                publishedAt: Date, playedState: PlaylistPlayedState) {
        self.entryID = entryID; self.feedID = feedID; self.kind = kind
        self.durationSeconds = durationSeconds; self.publishedAt = publishedAt
        self.playedState = playedState
    }
}

/// One automatic-playlist rule: `field comparator value`.
///
/// Values are strings so they round-trip through the store unchanged:
/// - feed, kind: `is` or `isNot` a feed ID or kind string.
/// - played: `is` or `isNot` one of `unplayed`, `inProgress`, `played`.
/// - length: `shorterThan` or `longerThan` a number of minutes.
/// - published: `withinDays` a whole number of days before now, or `before` or
///   `after` an ISO 8601 date.
public struct PlaylistRule: Sendable, Equatable {
    public let field: PlaylistRuleField
    public let comparator: PlaylistComparator
    public let value: String

    /// Creates a rule, refusing a comparator or value the field cannot use.
    public init(field: PlaylistRuleField, comparator: PlaylistComparator, value: String) throws {
        let allowed: Set<PlaylistComparator>
        switch field {
        case .feed, .kind, .played: allowed = [.is, .isNot]
        case .length: allowed = [.shorterThan, .longerThan]
        case .published: allowed = [.withinDays, .before, .after]
        }
        guard allowed.contains(comparator) else {
            throw PlaylistRuleError(reason: "\(comparator.rawValue) does not apply to \(field.rawValue)")
        }
        let valid: Bool
        switch field {
        case .feed, .kind: valid = !value.isEmpty
        case .played: valid = PlaylistPlayedState(rawValue: value) != nil
        case .length: valid = Double(value).map { $0.isFinite && $0 >= 0 } ?? false
        case .published:
            valid = comparator == .withinDays
                ? Int(value).map { $0 >= 0 } ?? false
                : Self.parseDate(value) != nil
        }
        guard valid else { throw PlaylistRuleError(reason: "invalid value for \(field.rawValue)") }
        self.field = field; self.comparator = comparator; self.value = value
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    /// Formats a date the way `before` and `after` values are stored.
    public static func dateValue(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Whether `candidate` satisfies this rule at `now`. A candidate missing the
    /// field (no feed, no duration) does not satisfy a rule that needs it,
    /// except `isNot`, which a missing feed satisfies.
    func matches(_ candidate: PlaylistCandidate, now: Date) -> Bool {
        switch field {
        case .feed:
            return (candidate.feedID == value) == (comparator == .is)
        case .kind:
            return (candidate.kind == value) == (comparator == .is)
        case .played:
            return (candidate.playedState.rawValue == value) == (comparator == .is)
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
        }
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
}
