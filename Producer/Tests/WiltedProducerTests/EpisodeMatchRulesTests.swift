import XCTest
@testable import WiltedProducer

final class EpisodeMatchRulesTests: XCTestCase {
    func testOwnerExampleRulesPreviewExpectedEpisodes() throws {
        let mmaRule = EpisodeMatchRule(field: .title, includePattern: "Fight Companion|MMA Show", action: .skip)
        let headlinesRule = EpisodeMatchRule(field: .title, includePattern: "The Headlines", action: .keep)
        let techCrunchRule = EpisodeMatchRule(field: .both, includePattern: "TechCrunch", action: .keep)
        let rules = EpisodeMatchRules(rules: [mmaRule, headlinesRule, techCrunchRule])

        XCTAssertEqual(
            try rules.preview([
                EpisodeMatchEpisode(id: "rogan", title: "Fight Companion - UFC 310", notes: "Friends discuss the card."),
                EpisodeMatchEpisode(id: "nyt", title: "The Headlines: Markets and the Election", notes: "A daily news briefing."),
                EpisodeMatchEpisode(id: "tech", title: "Equity", notes: "TechCrunch reports on early-stage startups."),
            ]).map(\.result),
            [.skip(ruleID: mmaRule.id), .keep(ruleID: headlinesRule.id), .keep(ruleID: techCrunchRule.id)]
        )
    }

    func testValidationRejectsInvalidAndOverLengthPatterns() {
        let invalid = EpisodeMatchRule(field: .title, includePattern: "[", action: .keep)
        XCTAssertThrowsError(try EpisodeMatchRules(rules: [invalid]).validate()) { error in
            guard case let .invalidPattern(ruleID, problem) = error as? EpisodeMatchRuleError else {
                return XCTFail("Expected an invalid-pattern error, got \(error)")
            }
            XCTAssertEqual(ruleID, invalid.id)
            XCTAssertFalse(problem.isEmpty)
        }

        let tooLong = EpisodeMatchRule(
            field: .title,
            includePattern: String(repeating: "a", count: EpisodeMatchRules.maximumPatternLength + 1),
            action: .keep
        )
        XCTAssertThrowsError(try EpisodeMatchRules(rules: [tooLong]).validate()) { error in
            XCTAssertEqual(error as? EpisodeMatchRuleError, .patternTooLong(ruleID: tooLong.id, maximumLength: EpisodeMatchRules.maximumPatternLength))
        }
    }

    func testNotesAreTruncatedBeforeMatching() throws {
        let rule = EpisodeMatchRule(field: .notes, includePattern: "needle", action: .keep)
        let notes = String(repeating: "a", count: EpisodeMatchRules.maximumNotesLength) + "needle"
        XCTAssertEqual(
            try EpisodeMatchRules(rules: [rule]).evaluate(EpisodeMatchEpisode(id: "episode", title: "Title", notes: notes)),
            .noMatch
        )
    }

    func testTimedOutRuleDoesNotFallThroughToLaterRule() throws {
        let slowRule = EpisodeMatchRule(field: .title, includePattern: "(a+)+$", action: .keep)
        let laterRule = EpisodeMatchRule(field: .title, includePattern: "b$", action: .skip)
        let rules = EpisodeMatchRules(rules: [slowRule, laterRule])
        let episode = EpisodeMatchEpisode(id: "episode", title: String(repeating: "a", count: 800) + "b", notes: "")

        let started = Date()
        let result = try rules.evaluate(episode, timeout: 0.01)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(result, .timedOut(.timedOut(ruleID: slowRule.id)))
    }

    func testExcludeFieldsAndFirstMatchOrder() throws {
        let disabled = EpisodeMatchRule(field: .title, includePattern: "daily", action: .skip, isEnabled: false)
        let excluded = EpisodeMatchRule(field: .title, includePattern: "news", excludePattern: "sports", action: .keep)
        let notesOnly = EpisodeMatchRule(field: .notes, includePattern: "member bonus", action: .skip)
        let first = EpisodeMatchRule(field: .both, includePattern: "daily", action: .keep)
        let second = EpisodeMatchRule(field: .title, includePattern: "daily", action: .skip)
        let rules = EpisodeMatchRules(rules: [disabled, excluded, notesOnly, first, second])

        XCTAssertEqual(
            try rules.evaluate(EpisodeMatchEpisode(id: "excluded", title: "News and sports", notes: "")),
            .noMatch
        )
        XCTAssertEqual(
            try rules.evaluate(EpisodeMatchEpisode(id: "notes", title: "Regular show", notes: "Member Bonus: aftershow")),
            .skip(ruleID: notesOnly.id)
        )
        XCTAssertEqual(
            try rules.evaluate(EpisodeMatchEpisode(id: "ordered", title: "Daily briefing", notes: "")),
            .keep(ruleID: first.id)
        )
    }
}
