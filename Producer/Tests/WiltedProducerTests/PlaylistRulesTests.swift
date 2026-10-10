import XCTest
@testable import WiltedProducer

final class PlaylistRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func day(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func candidate(
        _ id: String, feed: String? = "feed-a", kind: String = "podcast.episode",
        minutes: Double? = 30, daysAgo: Double = 1, played: PlaylistPlayedState = .unplayed
    ) -> PlaylistCandidate {
        PlaylistCandidate(entryID: id, feedID: feed, kind: kind, durationSeconds: minutes.map { $0 * 60 },
                          publishedAt: day(daysAgo), playedState: played)
    }

    private func rule(_ field: PlaylistRuleField, _ comparator: PlaylistComparator, _ value: String) throws -> PlaylistRule {
        try PlaylistRule(field: field, comparator: comparator, value: value)
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
}
