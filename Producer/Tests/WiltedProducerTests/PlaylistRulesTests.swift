import XCTest
@testable import WiltedProducer

final class PlaylistRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func day(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func candidate(
        _ id: String, feed: String? = "feed-a", kind: String = "podcast.episode",
        minutes: Double? = 30, daysAgo: Double = 1, played: PlaylistPlayedState = .unplayed,
        ready: Bool = false
    ) -> PlaylistCandidate {
        PlaylistCandidate(entryID: id, feedID: feed, kind: kind, durationSeconds: minutes.map { $0 * 60 },
                          publishedAt: day(daysAgo), playedState: played, isReady: ready)
    }

    private func rule(_ field: PlaylistRuleField, _ comparator: PlaylistComparator, _ value: String) throws -> PlaylistRule {
        try PlaylistRule(field: field, comparator: comparator, value: value)
    }

    private func leaf(_ number: Int, _ field: PlaylistRuleField, _ comparator: PlaylistComparator,
                      _ value: String) throws -> PlaylistNumberedRule {
        try PlaylistNumberedRule(number: number, rule: rule(field, comparator, value))
    }

    private func expression(_ formula: String, _ numbered: [PlaylistNumberedRule]) throws -> PlaylistRule {
        try PlaylistRule.expression(numberedRules: numbered, expressionString: formula)
    }

    private func ids(_ rules: [PlaylistRule], all: Bool, _ candidates: [PlaylistCandidate]) -> [String] {
        PlaylistRules.evaluate(rules, matchAll: all, candidates: candidates, now: now).map(\.entryID)
    }

    /// Two matching and one non-matching rule on distinct candidates make all-of
    /// and any-of differ for every field.
    private func assertField(_ hit: PlaylistRule, hitting: PlaylistCandidate, missing: PlaylistCandidate,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let always = try rule(.kind, .isNot, "never-a-kind")
        XCTAssertEqual(ids([hit], all: true, [hitting, missing]), [hitting.entryID], file: file, line: line)
        XCTAssertEqual(ids([hit], all: false, [hitting, missing]), [hitting.entryID], file: file, line: line)
        XCTAssertEqual(ids([hit, always], all: true, [hitting, missing]), [hitting.entryID], file: file, line: line)
        XCTAssertEqual(ids([hit, always], all: false, [hitting, missing]), [hitting.entryID, missing.entryID],
                       file: file, line: line)
    }

    func testFeedRuleWithAllOfAndAnyOf() throws {
        try assertField(rule(.feed, .is, "feed-a"), hitting: candidate("in"), missing: candidate("out", feed: "feed-b"))
        XCTAssertEqual(ids([try rule(.feed, .isNot, "feed-a")], all: true, [candidate("a"), candidate("b", feed: nil)]), ["b"])
    }

    func testPlayedRuleWithAllOfAndAnyOf() throws {
        for state in PlaylistPlayedState.allCases {
            let other = PlaylistPlayedState.allCases.first { $0 != state }!
            try assertField(rule(.played, .is, state.rawValue), hitting: candidate("in", played: state),
                            missing: candidate("out", played: other))
        }
        XCTAssertEqual(ids([try rule(.played, .isNot, "played")], all: true,
                           [candidate("a", played: .played), candidate("b", played: .inProgress)]), ["b"])
    }

    func testLengthRuleWithAllOfAndAnyOf() throws {
        try assertField(rule(.length, .shorterThan, "20"), hitting: candidate("in", minutes: 10), missing: candidate("out", minutes: 40))
        try assertField(rule(.length, .longerThan, "20"), hitting: candidate("in", minutes: 40), missing: candidate("out", minutes: 10))
        XCTAssertEqual(ids([try rule(.length, .longerThan, "20")], all: true, [candidate("none", minutes: nil)]), [],
                       "an entry with no length never matches a length rule")
        XCTAssertEqual(ids([try rule(.length, .shorterThan, "20")], all: true, [candidate("edge", minutes: 20)]), [])
    }

    func testPublishedRuleWithAllOfAndAnyOf() throws {
        try assertField(rule(.published, .withinDays, "7"), hitting: candidate("in", daysAgo: 2), missing: candidate("out", daysAgo: 30))
        let cutoff = PlaylistRule.dateValue(day(10))
        try assertField(rule(.published, .before, cutoff), hitting: candidate("in", daysAgo: 20), missing: candidate("out", daysAgo: 2))
        try assertField(rule(.published, .after, cutoff), hitting: candidate("in", daysAgo: 2), missing: candidate("out", daysAgo: 20))
        XCTAssertEqual(ids([try rule(.published, .withinDays, "7")], all: true, [candidate("future", daysAgo: -1)]), [])
    }

    func testKindRuleWithAllOfAndAnyOf() throws {
        try assertField(rule(.kind, .is, "audiobook"), hitting: candidate("in", kind: "audiobook"), missing: candidate("out", kind: "article"))
    }

    func testReadyRuleWithAllOfAndAnyOf() throws {
        try assertField(rule(.ready, .is, "true"), hitting: candidate("in", ready: true), missing: candidate("out"))
        try assertField(rule(.ready, .is, "false"), hitting: candidate("in"), missing: candidate("out", ready: true))
        XCTAssertEqual(ids([try rule(.ready, .isNot, "true")], all: true,
                           [candidate("a", ready: true), candidate("b")]), ["b"])
        XCTAssertEqual(ids([try rule(.ready, .is, "false")], all: true, [candidate("missing")]), ["missing"],
                       "a candidate built without saying is not ready")
    }

    func testMixedRulesAndEmptyList() throws {
        let rules = [try rule(.kind, .is, "article"), try rule(.length, .shorterThan, "15")]
        let pool = [candidate("both", kind: "article", minutes: 5), candidate("kindOnly", kind: "article", minutes: 60),
                    candidate("lengthOnly", minutes: 5), candidate("neither", minutes: 60)]
        XCTAssertEqual(ids(rules, all: true, pool), ["both"])
        XCTAssertEqual(ids(rules, all: false, pool), ["both", "kindOnly", "lengthOnly"])
        XCTAssertEqual(ids([], all: true, pool), [])
        XCTAssertEqual(ids([], all: false, pool), [])
    }

    func testInvalidRulesAreRefused() {
        XCTAssertThrowsError(try PlaylistRule(field: .length, comparator: .is, value: "5"))
        XCTAssertThrowsError(try PlaylistRule(field: .length, comparator: .shorterThan, value: "soon"))
        XCTAssertThrowsError(try PlaylistRule(field: .played, comparator: .is, value: "half"))
        XCTAssertThrowsError(try PlaylistRule(field: .published, comparator: .withinDays, value: "-1"))
        XCTAssertThrowsError(try PlaylistRule(field: .published, comparator: .before, value: "yesterday"))
        XCTAssertThrowsError(try PlaylistRule(field: .feed, comparator: .is, value: ""))
    }

    func testInvalidReadyBooleanIsRefused() {
        XCTAssertThrowsError(try PlaylistRule(field: .ready, comparator: .is, value: "yes"))
        XCTAssertThrowsError(try PlaylistRule(field: .ready, comparator: .is, value: "TRUE"))
        XCTAssertThrowsError(try PlaylistRule(field: .ready, comparator: .is, value: ""))
        XCTAssertThrowsError(try PlaylistRule(field: .ready, comparator: .shorterThan, value: "true"))
    }

    // MARK: - Expressions

    func testExpressionFiveFeedsOrUnplayedAndReady() throws {
        var numbered = try (1...5).map { try leaf($0, .feed, .is, "feed-\($0)") }
        numbered.append(try leaf(6, .played, .is, PlaylistPlayedState.unplayed.rawValue))
        numbered.append(try leaf(7, .ready, .is, "true"))
        let match = try expression("1 OR 2 OR 3 OR 4 OR 5 OR (6 AND 7)", numbered)
        let pool = [candidate("feed1", feed: "feed-1"), candidate("feed3", feed: "feed-3", ready: true),
                    candidate("otherUnplayedReady", feed: "other", ready: true),
                    candidate("otherPlayedReady", feed: "other", played: .played, ready: true),
                    candidate("otherUnplayedNotReady", feed: "other")]
        XCTAssertEqual(ids([match], all: true, pool), ["feed1", "feed3", "otherUnplayedReady"])
        XCTAssertEqual(match.usedNumbers, Set(1...7))
        XCTAssertEqual(match.numberedRules.map(\.number), Array(1...7))
    }

    func testExpressionNotBindsTighterThanAnd() throws {
        let numbered = [try leaf(1, .feed, .is, "feed-a"), try leaf(2, .ready, .is, "true")]
        let formula = try expression("NOT 1 AND 2", numbered)
        let pool = [candidate("aReady", feed: "feed-a", ready: true),
                    candidate("bReady", feed: "feed-b", ready: true),
                    candidate("bNotReady", feed: "feed-b")]
        XCTAssertEqual(ids([formula], all: true, pool), ["bReady"])
    }

    func testExpressionAndBindsTighterThanOr() throws {
        let numbered = [try leaf(1, .feed, .is, "feed-a"), try leaf(2, .feed, .is, "feed-b"),
                        try leaf(3, .ready, .is, "true")]
        let formula = try expression("1 OR 2 AND 3", numbered)
        let pool = [candidate("a", feed: "feed-a"), candidate("bReady", feed: "feed-b", ready: true),
                    candidate("bNotReady", feed: "feed-b")]
        XCTAssertEqual(ids([formula], all: true, pool), ["a", "bReady"])
    }

    func testExpressionParenthesesGroup() throws {
        let numbered = [try leaf(1, .feed, .is, "feed-a"), try leaf(2, .feed, .is, "feed-b"),
                        try leaf(3, .ready, .is, "true")]
        let formula = try expression("(1 OR 2) AND 3", numbered)
        let pool = [candidate("aReady", feed: "feed-a", ready: true),
                    candidate("aNotReady", feed: "feed-a"),
                    candidate("bReady", feed: "feed-b", ready: true)]
        XCTAssertEqual(ids([formula], all: true, pool), ["aReady", "bReady"])
    }

    func testExpressionSparseNumbersKeepUnusedLeaves() throws {
        let numbered = [try leaf(3, .feed, .is, "feed-a"),
                        try leaf(7, .played, .is, PlaylistPlayedState.unplayed.rawValue),
                        try leaf(9, .ready, .is, "true")]
        let formula = try expression("3 OR (7 AND NOT 9)", numbered)
        XCTAssertEqual(formula.numberedRules.map(\.number), [3, 7, 9])
        XCTAssertEqual(formula.usedNumbers, [3, 7, 9])
        let unused = try expression("3 OR 7", numbered)
        XCTAssertEqual(unused.numberedRules.map(\.number), [3, 7, 9], "unused leaves are kept")
        XCTAssertEqual(unused.usedNumbers, [3, 7])
        XCTAssertEqual(unused.usedRuleNumbers, [3, 7])
        let unusedPayload = try XCTUnwrap(unused.expressionPayload)
        XCTAssertEqual(unusedPayload.usedNumbers, [3, 7])
    }

    func testExpressionPayloadRoundTripsThroughCodable() throws {
        let numbered = [try leaf(1, .feed, .is, "feed-a"), try leaf(2, .ready, .is, "false")]
        let formula = "1 and not 2"
        let rule = try expression(formula, numbered)
        let payload = try XCTUnwrap(rule.expressionPayload)
        XCTAssertEqual(payload.version, PlaylistExpressionPayload.currentVersion)
        XCTAssertEqual(payload.expressionString, formula, "the formula is kept as written")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(PlaylistExpressionPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.numberedRules.map(\.number), [1, 2])
    }

    func testExpressionRuleRebuildsFromStoredValue() throws {
        let numbered = [try leaf(4, .feed, .is, "feed-a"), try leaf(8, .ready, .is, "true")]
        let original = try expression("4 AND 8", numbered)
        let rebuilt = try PlaylistRule.expression(storedValue: original.value)
        XCTAssertEqual(rebuilt, original)
        XCTAssertEqual(rebuilt.expressionString, "4 AND 8")
        XCTAssertEqual(rebuilt.usedNumbers, [4, 8])
        XCTAssertEqual(rebuilt.field, .expression)
        XCTAssertEqual(rebuilt.comparator, .expression)
        XCTAssertTrue(rebuilt.isExpression)
    }

    func testExpressionUnknownReferencesAreRefused() throws {
        let numbered = [try leaf(1, .feed, .is, "feed-a")]
        XCTAssertThrowsError(try expression("1 OR 4", numbered))
        XCTAssertThrowsError(try expression("NOT 2", numbered))
    }

    func testExpressionSyntaxErrorsAreRefused() throws {
        let numbered = [try leaf(1, .feed, .is, "feed-a"), try leaf(2, .ready, .is, "true")]
        let malformed = ["", "1 AND", "AND 2", "1 2", "NOT", "(1", "1)", "()", "1 AND OR 2",
                         "1 OR OR 2", "1 XOR 2", "1 $ 2", "-1", "1 + 2", "1 AND (2"]
        for formula in malformed {
            XCTAssertThrowsError(try expression(formula, numbered), "formula \(formula)")
        }
    }

    func testExpressionDuplicateNumbersAndNestedExpressionsAreRefused() throws {
        let leafOne = try leaf(1, .feed, .is, "feed-a")
        XCTAssertThrowsError(try expression("1", [leafOne, leafOne]), "duplicate rule number")
        XCTAssertThrowsError(try PlaylistNumberedRule(number: 0, rule: rule(.feed, .is, "feed-a")))
        XCTAssertThrowsError(try PlaylistNumberedRule(number: -3, rule: rule(.feed, .is, "feed-a")))
        let inner = try expression("1", [leafOne])
        XCTAssertThrowsError(try PlaylistNumberedRule(number: 2, rule: inner), "no nested expressions")
        XCTAssertThrowsError(try PlaylistRule(field: .expression, comparator: .expression, value: inner.value))
    }

    func testExpressionLimitsAreEnforced() throws {
        let leafOne = try leaf(1, .feed, .is, "feed-a")
        XCTAssertThrowsError(try expression(String(repeating: " ", count: 4_100) + "1", [leafOne]),
                             "expression byte ceiling")
        let manyReferences = Array(repeating: "1", count: 257).joined(separator: " OR ")
        XCTAssertThrowsError(try expression(manyReferences, [leafOne]), "node ceiling")
        let deepParentheses = String(repeating: "(", count: 9) + "1" + String(repeating: ")", count: 9)
        XCTAssertThrowsError(try expression(deepParentheses, [leafOne]), "nesting ceiling")
        let deepNegation = String(repeating: "NOT ", count: 9) + "1"
        XCTAssertThrowsError(try expression(deepNegation, [leafOne]), "NOT nesting ceiling")
        let hostile = String(repeating: "(", count: 2_000) + "1" + String(repeating: ")", count: 2_000)
        XCTAssertThrowsError(try expression(hostile, [leafOne]), "hostile depth is refused before parsing")
        let wideLeaves = try (1...256).map { try leaf($0, .feed, .is, "feed-\($0)") }
        XCTAssertThrowsError(try expression("1", wideLeaves + [try leaf(257, .feed, .is, "feed-257")]),
                             "leaf ceiling")
        let fatLeaves = try (1...250).map { number in
            try leaf(number, .feed, .is, String(repeating: "f", count: 300) + "\(number)")
        }
        XCTAssertThrowsError(try expression("1", fatLeaves), "payload byte ceiling")
    }

    func testExpressionUnsupportedVersionAndMalformedPayloadsAreRefused() throws {
        let leafOne = try leaf(1, .feed, .is, "feed-a")
        let rule = try expression("1", [leafOne])
        let versionTwo = rule.value.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        XCTAssertThrowsError(try PlaylistRule.expression(storedValue: versionTwo), "unsupported version")
        XCTAssertThrowsError(try PlaylistRule.expression(storedValue: "not json"))
        XCTAssertThrowsError(try PlaylistRule.expression(storedValue: "{\"version\":1}"))
        let hostile = Data("{\"version\":99,\"numberedRules\":[],\"expressionString\":\"\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PlaylistExpressionPayload.self, from: hostile))
    }

    func testExpressionParserIsCaseInsensitiveButKeepsFormula() throws {
        let numbered = [try leaf(1, .ready, .is, "true"), try leaf(2, .feed, .is, "feed-a")]
        let formula = "1 aNd NoT 2"
        let rule = try expression(formula, numbered)
        XCTAssertEqual(rule.expressionString, formula)
        XCTAssertTrue(rule.matches(candidate("readyB", feed: "feed-b", ready: true), now: now))
        XCTAssertFalse(rule.matches(candidate("readyA", feed: "feed-a", ready: true), now: now))
    }

    func testExpressionParserBuildsAndEvaluatesTree() throws {
        let node = try PlaylistExpressionParser.parse("1 OR (2 AND NOT 3)", ruleNumbers: [1, 2, 3])
        XCTAssertEqual(PlaylistExpressionParser.references(in: node), [1, 2, 3])
        XCTAssertTrue(node.evaluate { $0 == 1 })
        XCTAssertTrue(node.evaluate { $0 == 2 })
        XCTAssertFalse(node.evaluate { $0 == 3 })
    }

    func testFlatAllAnyAndEmptySemanticsWithExpressionRules() throws {
        let numbered = [try leaf(1, .ready, .is, "true")]
        let ready = try expression("1", numbered)
        let always = try rule(.kind, .isNot, "never-a-kind")
        let pool = [candidate("ready", ready: true), candidate("notReady")]
        XCTAssertEqual(ids([ready], all: true, pool), ["ready"])
        XCTAssertEqual(ids([ready], all: false, pool), ["ready"])
        XCTAssertEqual(ids([ready, always], all: true, pool), ["ready"])
        XCTAssertEqual(ids([ready, always], all: false, pool), ["ready", "notReady"])
        XCTAssertEqual(ids([], all: true, pool), [])
        XCTAssertEqual(ids([], all: false, pool), [])
    }

    func testCompileHelperMatchesFactory() throws {
        let numbered = [try leaf(1, .ready, .is, "true")]
        let compiled = try PlaylistRules.compile(numberedRules: numbered, expression: "1")
        let direct = try PlaylistRule.expression(numberedRules: numbered, expressionString: "1")
        XCTAssertEqual(compiled, direct)
    }
}
