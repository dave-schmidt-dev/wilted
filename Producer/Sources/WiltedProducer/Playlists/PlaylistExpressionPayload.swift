import Foundation

/// One numbered leaf rule of an expression: a stable positive number plus a
/// validated flat rule. Numbers need not be contiguous, and a formula need not
/// use every declared leaf.
public struct PlaylistNumberedRule: Sendable, Equatable, Codable {
    public let number: Int
    public let rule: PlaylistRule

    /// Creates a numbered leaf, refusing a non-positive number and a nested
    /// expression (`rule` is itself validated by `PlaylistRule`).
    public init(number: Int, rule: PlaylistRule) throws {
        guard number > 0 else { throw PlaylistRuleError(reason: "rule number must be positive") }
        guard rule.field != .expression, rule.comparator != .expression else {
            throw PlaylistRuleError(reason: "an expression cannot use another expression as a leaf")
        }
        self.number = number
        self.rule = rule
    }

    /// Creates a numbered leaf from a validated rule triple.
    public init(number: Int, field: PlaylistRuleField, comparator: PlaylistComparator,
                value: String) throws {
        try self.init(number: number, rule: PlaylistRule(field: field, comparator: comparator, value: value))
    }

    /// Creates a numbered leaf from a validated rule.
    public init(_ number: Int, _ rule: PlaylistRule) throws {
        try self.init(number: number, rule: rule)
    }

    public var field: PlaylistRuleField { rule.field }
    public var comparator: PlaylistComparator { rule.comparator }
    public var value: String { rule.value }

    /// Alternate spelling for `rule`.
    public var playlistRule: PlaylistRule { rule }
}

extension PlaylistRuleField {
    /// Alternate spelling for the expression kind.
    public static var formula: PlaylistRuleField { .expression }
}

extension PlaylistComparator {
    /// Alternate spelling for the dedicated expression comparator.
    public static var matchesExpression: PlaylistComparator { .expression }
}

/// Alternate spelling for callers that read the number first.
public typealias NumberedPlaylistRule = PlaylistNumberedRule

/// The versioned, Codable payload an expression rule stores in its value
/// string: the ordered numbered leaves exactly as declared and the formula
/// exactly as written. Decoding refuses an unsupported version before reading
/// anything else.
public struct PlaylistExpressionPayload: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public let version: Int
    public let numberedRules: [PlaylistNumberedRule]
    public let expressionString: String

    public init(version: Int = PlaylistExpressionPayload.currentVersion,
                numberedRules: [PlaylistNumberedRule],
                expressionString: String) throws {
        guard version == Self.currentVersion else {
            throw PlaylistRuleError(reason: "unsupported expression version \(version)")
        }
        try Self.validate(numberedRules: numberedRules, expressionString: expressionString)
        self.version = version
        self.numberedRules = numberedRules
        self.expressionString = expressionString
    }

    /// The numbers this payload's formula references; declared leaves it does
    /// not use are absent.
    public var usedNumbers: Set<Int> {
        guard let node = try? PlaylistExpressionParser.parse(
            expressionString, ruleNumbers: Set(numberedRules.map(\.number))) else { return [] }
        return PlaylistExpressionParser.references(in: node)
    }

    static func validate(numberedRules: [PlaylistNumberedRule], expressionString: String) throws {
        guard expressionString.utf8.count <= PlaylistExpressionParser.maximumExpressionBytes else {
            throw PlaylistRuleError(reason: "expression is longer than \(PlaylistExpressionParser.maximumExpressionBytes) UTF-8 bytes")
        }
        guard numberedRules.count <= PlaylistExpressionParser.maximumNodes else {
            throw PlaylistRuleError(reason: "expression declares more than \(PlaylistExpressionParser.maximumNodes) leaves")
        }
        var numbers = Set<Int>()
        for numbered in numberedRules {
            guard numbered.number > 0 else { throw PlaylistRuleError(reason: "rule number must be positive") }
            guard numbers.insert(numbered.number).inserted else {
                throw PlaylistRuleError(reason: "duplicate rule number \(numbered.number)")
            }
            guard numbered.rule.field != .expression, numbered.rule.comparator != .expression else {
                throw PlaylistRuleError(reason: "an expression cannot use another expression as a leaf")
            }
        }
        _ = try PlaylistExpressionParser.parse(expressionString, ruleNumbers: numbers)
    }

    private enum CodingKeys: String, CodingKey { case version, numberedRules, expressionString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw PlaylistRuleError(reason: "unsupported expression version \(version)")
        }
        let numberedRules = try container.decode([PlaylistNumberedRule].self, forKey: .numberedRules)
        let expressionString = try container.decode(String.self, forKey: .expressionString)
        try self.init(version: version, numberedRules: numberedRules, expressionString: expressionString)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(numberedRules, forKey: .numberedRules)
        try container.encode(expressionString, forKey: .expressionString)
    }
}

/// The precomputed evaluation plan of an expression rule: the parsed tree, its
/// numbered leaves and the payload it came from. It is built once when the rule
/// is created, so evaluating a candidate never decodes or parses again.
final class PlaylistExpressionProgram: @unchecked Sendable {
    let payload: PlaylistExpressionPayload
    let node: PlaylistExpressionNode
    private let leaves: [Int: PlaylistRule]

    init(payload: PlaylistExpressionPayload) throws {
        node = try PlaylistExpressionParser.parse(payload.expressionString,
                                                  ruleNumbers: Set(payload.numberedRules.map(\.number)))
        self.payload = payload
        var leaves: [Int: PlaylistRule] = [:]
        for numbered in payload.numberedRules { leaves[numbered.number] = numbered.rule }
        self.leaves = leaves
    }

    var usedNumbers: Set<Int> { PlaylistExpressionParser.references(in: node) }

    func matches(_ candidate: PlaylistCandidate, now: Date) -> Bool {
        node.evaluate { leaves[$0]?.matches(candidate, now: now) ?? false }
    }
}
