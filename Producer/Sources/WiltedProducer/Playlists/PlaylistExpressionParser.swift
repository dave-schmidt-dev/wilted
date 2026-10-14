import Foundation

/// A parsed boolean expression over numbered leaf rules. `reference(n)` asks the
/// leaf evaluator about rule number `n`; NOT binds tighter than AND, and AND
/// tighter than OR.
public indirect enum PlaylistExpressionNode: Sendable, Equatable {
    case reference(Int)
    case not(PlaylistExpressionNode)
    case and(PlaylistExpressionNode, PlaylistExpressionNode)
    case or(PlaylistExpressionNode, PlaylistExpressionNode)

    /// Evaluates the tree, with `leaf` answering each rule reference.
    public func evaluate(_ leaf: (Int) -> Bool) -> Bool {
        switch self {
        case .reference(let number): return leaf(number)
        case .not(let child): return !child.evaluate(leaf)
        case .and(let left, let right): return left.evaluate(leaf) && right.evaluate(leaf)
        case .or(let left, let right): return left.evaluate(leaf) || right.evaluate(leaf)
        }
    }
}

/// The pure parser for numbered-rule expressions: positive integer references
/// combined with case-insensitive AND, OR and NOT and parentheses. It refuses
/// unknown references, malformed syntax, missing operands or operators, and
/// expressions over the byte, node or nesting ceilings. Every ceiling is
/// checked iteratively before the recursive descent, so hostile input cannot
/// exhaust the stack.
public enum PlaylistExpressionParser {
    /// The largest formula accepted, in UTF-8 bytes.
    public static let maximumExpressionBytes = 4_096
    /// The largest encoded payload accepted, in bytes.
    public static let maximumPayloadBytes = 65_536
    /// The largest number of expression nodes and references accepted.
    public static let maximumNodes = 256
    /// The deepest parentheses and NOT nesting accepted, combined.
    public static let maximumNesting = 8

    /// Parses `expression` without checking which rules it references.
    public static func parse(_ expression: String) throws -> PlaylistExpressionNode {
        try parse(expression, declaredNumbers: nil)
    }

    /// Parses `expression`, refusing any reference outside `ruleNumbers`.
    public static func parse(_ expression: String, ruleNumbers: Set<Int>) throws -> PlaylistExpressionNode {
        try parse(expression, declaredNumbers: ruleNumbers)
    }

    /// The rule numbers `node` references, in no particular order.
    public static func references(in node: PlaylistExpressionNode) -> Set<Int> {
        switch node {
        case .reference(let number): return [number]
        case .not(let child): return references(in: child)
        case .and(let left, let right), .or(let left, let right):
            return references(in: left).union(references(in: right))
        }
    }

    /// Refuses a stored payload whose JSON nests deeper than the expression
    /// ceiling, iteratively and before any decoder can recurse through it.
    static func checkPayloadNesting(_ data: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                depth += 1
                guard depth <= maximumNesting else {
                    throw PlaylistRuleError(reason: "expression payload nests deeper than \(maximumNesting)")
                }
            case 0x7D, 0x5D:
                depth -= 1
            default:
                break
            }
        }
    }

    private static func parse(_ expression: String, declaredNumbers: Set<Int>?) throws -> PlaylistExpressionNode {
        guard expression.utf8.count <= maximumExpressionBytes else {
            throw PlaylistRuleError(reason: "expression is longer than \(maximumExpressionBytes) UTF-8 bytes")
        }
        let tokens = try tokenize(expression)
        try checkLimits(tokens)
        var parser = TokenParser(tokens: tokens)
        let node = try parser.parseExpression(depth: 0)
        guard parser.isAtEnd else {
            throw PlaylistRuleError(reason: "expression is missing an operator or has an extra operand")
        }
        if let declaredNumbers {
            let unknown = references(in: node).subtracting(declaredNumbers)
            guard unknown.isEmpty else {
                throw PlaylistRuleError(reason: "expression references unknown rule numbers \(unknown.sorted())")
            }
        }
        return node
    }

    private enum Token: Equatable {
        case reference(Int)
        case and
        case or
        case not
        case leftParenthesis
        case rightParenthesis

        var isNode: Bool {
            switch self {
            case .reference, .and, .or, .not: return true
            case .leftParenthesis, .rightParenthesis: return false
            }
        }
    }

    private static func tokenize(_ expression: String) throws -> [Token] {
        var tokens: [Token] = []
        let scalars = expression.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index = scalars.index(after: index)
            } else if scalar == "(" {
                tokens.append(.leftParenthesis)
                index = scalars.index(after: index)
            } else if scalar == ")" {
                tokens.append(.rightParenthesis)
                index = scalars.index(after: index)
            } else if scalar.value >= 48, scalar.value <= 57 {
                var number = 0
                while index < scalars.endIndex, scalars[index].value >= 48, scalars[index].value <= 57 {
                    let digit = Int(scalars[index].value) - 48
                    guard number <= (Int.max - digit) / 10 else {
                        throw PlaylistRuleError(reason: "expression rule number is too large")
                    }
                    number = number * 10 + digit
                    index = scalars.index(after: index)
                }
                tokens.append(.reference(number))
            } else if CharacterSet.letters.contains(scalar) {
                var word = ""
                while index < scalars.endIndex, CharacterSet.letters.contains(scalars[index]) {
                    word.unicodeScalars.append(scalars[index])
                    index = scalars.index(after: index)
                }
                switch word.uppercased() {
                case "AND": tokens.append(.and)
                case "OR": tokens.append(.or)
                case "NOT": tokens.append(.not)
                default: throw PlaylistRuleError(reason: "unknown operator \(word)")
                }
            } else {
                throw PlaylistRuleError(reason: "unexpected character \(scalar) in expression")
            }
        }
        guard !tokens.isEmpty else { throw PlaylistRuleError(reason: "expression is empty") }
        return tokens
    }

    private static func checkLimits(_ tokens: [Token]) throws {
        let nodes = tokens.reduce(0) { $0 + ($1.isNode ? 1 : 0) }
        guard nodes <= maximumNodes else {
            throw PlaylistRuleError(reason: "expression has more than \(maximumNodes) nodes")
        }
        var parentheses = 0
        var negations = 0
        var deepest = 0
        for token in tokens {
            switch token {
            case .leftParenthesis:
                parentheses += 1
                deepest = max(deepest, parentheses + negations)
            case .rightParenthesis:
                parentheses -= 1
                guard parentheses >= 0 else {
                    throw PlaylistRuleError(reason: "expression has unbalanced parentheses")
                }
                negations = 0
            case .not:
                negations += 1
                deepest = max(deepest, parentheses + negations)
            case .reference, .and, .or:
                negations = 0
            }
        }
        guard parentheses == 0 else {
            throw PlaylistRuleError(reason: "expression has unbalanced parentheses")
        }
        guard deepest <= maximumNesting else {
            throw PlaylistRuleError(reason: "expression nests deeper than \(maximumNesting)")
        }
    }

    private struct TokenParser {
        let tokens: [Token]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }

        mutating func parseExpression(depth: Int) throws -> PlaylistExpressionNode {
            guard depth <= PlaylistExpressionParser.maximumNesting else {
                throw PlaylistRuleError(reason: "expression nests deeper than \(PlaylistExpressionParser.maximumNesting)")
            }
            var left = try parseAnd(depth: depth)
            while peek() == Token.or {
                position += 1
                let right = try parseAnd(depth: depth)
                left = .or(left, right)
            }
            return left
        }

        private mutating func parseAnd(depth: Int) throws -> PlaylistExpressionNode {
            var left = try parseNot(depth: depth)
            while peek() == Token.and {
                position += 1
                let right = try parseNot(depth: depth)
                left = .and(left, right)
            }
            return left
        }

        private mutating func parseNot(depth: Int) throws -> PlaylistExpressionNode {
            guard peek() == Token.not else { return try parsePrimary(depth: depth) }
            position += 1
            return .not(try parseNot(depth: depth + 1))
        }

        private mutating func parsePrimary(depth: Int) throws -> PlaylistExpressionNode {
            switch peek() {
            case .reference(let number):
                position += 1
                return .reference(number)
            case .leftParenthesis:
                position += 1
                let inner = try parseExpression(depth: depth + 1)
                guard peek() == Token.rightParenthesis else {
                    throw PlaylistRuleError(reason: "expression is missing a closing parenthesis")
                }
                position += 1
                return inner
            default:
                throw PlaylistRuleError(reason: "expression is missing an operand")
            }
        }

        private func peek() -> Token? {
            position < tokens.count ? tokens[position] : nil
        }
    }
}
