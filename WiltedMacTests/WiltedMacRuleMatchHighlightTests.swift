import Foundation
import SwiftUI
import XCTest
import WiltedProducer
@testable import WiltedMac

/// The highlight data the rules plan prepares for the preview: the decisive
/// rule only, case-insensitive ICU matching with the same caps and deadline as
/// evaluation, Unicode-safe character ranges, and a bounded notes fallback so
/// a notes-only match is never invisible. Pure values; no view and no main
/// actor.
final class WiltedMacRuleMatchHighlightTests: XCTestCase {
    // MARK: The owner's case

    func testLowerCasePatternHighlightsMMAInsideTheJRETitle() throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "mma", action: .skip)
        let rules = EpisodeMatchRules(rules: [rule])
        let title = "JRE MMA Show #186 with Sean Sharaf"
        let decision = try rules.evaluate(EpisodeMatchEpisode(id: "jre", title: title, notes: ""))
        XCTAssertEqual(decision, .skip(ruleID: rule.id), "matching is case insensitive")

        let highlight = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: decision, title: title, notes: "", rules: rules))
        XCTAssertEqual(highlight.ruleID, rule.id)
        XCTAssertEqual(highlight.field, .title)
        XCTAssertEqual(highlight.title, WiltedMacRuleMatchHighlight.TextMatch(text: title, ranges: [4..<7]))
        XCTAssertEqual(markedSubstrings(try XCTUnwrap(highlight.title)), ["MMA"])
        XCTAssertNil(highlight.notes)
    }

    // MARK: Patterns

    func testAlternationHighlightsEveryAlternativeItFinds() throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "MMA|boxing", action: .keep)
        let rules = EpisodeMatchRules(rules: [rule])
        let title = "MMA and boxing tonight"

        let highlight = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: .keep(ruleID: rule.id), title: title, notes: "", rules: rules))
        XCTAssertEqual(highlight.title?.ranges, [0..<3, 8..<14])
        XCTAssertEqual(markedSubstrings(try XCTUnwrap(highlight.title)), ["MMA", "boxing"])
    }

    func testMoreMatchesThanTheCapAreBounded() throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "mma", action: .keep)
        let rules = EpisodeMatchRules(rules: [rule])
        let title = Array(repeating: "MMA", count: 12).joined(separator: " ")

        let highlight = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: .keep(ruleID: rule.id), title: title, notes: "", rules: rules))
        XCTAssertEqual(highlight.title?.ranges.count, WiltedMacRuleMatchHighlight.maximumRanges)
    }

    func testAnOverLongPatternIsNeverRecomputed() {
        let overLong = EpisodeMatchRule(
            field: .title,
            includePattern: String(repeating: "a", count: EpisodeMatchRules.maximumPatternLength + 1),
            action: .keep
        )
        XCTAssertNil(WiltedMacRuleMatchHighlight.make(
            result: .keep(ruleID: overLong.id), title: String(repeating: "a", count: 600), notes: "",
            rules: EpisodeMatchRules(rules: [overLong])))
    }

    func testZeroLengthMatchesDrawNothingInsteadOfCrashing() throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "x*", action: .keep)
        let rules = EpisodeMatchRules(rules: [rule])
        let title = "JRE MMA Show #186 with Sean Sharaf"
        let decision = try rules.evaluate(EpisodeMatchEpisode(id: "jre", title: title, notes: ""))
        XCTAssertEqual(decision, .keep(ruleID: rule.id), "a zero-length match still decides")

        XCTAssertNil(
            WiltedMacRuleMatchHighlight.make(result: decision, title: title, notes: "", rules: rules),
            "there is nothing to draw, so the row falls back to plain text")
    }

    // MARK: Unicode boundaries

    func testCharacterRangesSurviveComposedDecomposedAndEmojiTitles() throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "MMA", action: .keep)
        let rules = EpisodeMatchRules(rules: [rule])
        // The decomposed é is two UTF-16 units but one character; the emoji is
        // two UTF-16 units ahead of the match.
        for (title, expected) in [("Café MMA", 5..<8), ("Cafe\u{301} MMA", 5..<8), ("🎧 MMA", 2..<5)] {
            let highlight = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
                result: .keep(ruleID: rule.id), title: title, notes: "", rules: rules), title)
            XCTAssertEqual(highlight.title?.ranges, [expected], title)
            XCTAssertEqual(markedSubstrings(try XCTUnwrap(highlight.title)), ["MMA"], title)
        }
    }

    // MARK: What decides

    func testAnExcludedRuleIsNeverTheHighlightedOne() throws {
        let excluded = EpisodeMatchRule(
            field: .title, includePattern: "MMA", excludePattern: "Sharaf", action: .skip)
        let show = EpisodeMatchRule(field: .title, includePattern: "Show", action: .keep)
        let rules = EpisodeMatchRules(rules: [excluded, show])
        let title = "JRE MMA Show #186 with Sean Sharaf"
        let decision = try rules.evaluate(EpisodeMatchEpisode(id: "jre", title: title, notes: ""))
        XCTAssertEqual(decision, .keep(ruleID: show.id), "the exclude vetoes the first rule")

        let highlight = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: decision, title: title, notes: "", rules: rules))
        XCTAssertEqual(highlight.ruleID, show.id)
        XCTAssertEqual(highlight.title?.ranges, [8..<12])
        XCTAssertEqual(markedSubstrings(try XCTUnwrap(highlight.title)), ["Show"])
    }

    func testNoMatchAndStaleOrDisabledRuleIDsDrawNothing() {
        let live = EpisodeMatchRule(field: .title, includePattern: "MMA", action: .skip)
        let disabled = EpisodeMatchRule(field: .title, includePattern: "MMA", action: .keep, isEnabled: false)
        let rules = EpisodeMatchRules(rules: [live, disabled])
        let title = "JRE MMA Show #186 with Sean Sharaf"
        for result: EpisodeMatchResult in [
            .noMatch, .skip(ruleID: UUID()), .keep(ruleID: disabled.id), .timedOut(.timedOut(ruleID: live.id)),
        ] {
            XCTAssertNil(
                WiltedMacRuleMatchHighlight.make(result: result, title: title, notes: "", rules: rules), "\(result)")
        }
    }

    // MARK: Notes

    func testANotesOnlyMatchCarriesABoundedSnippetAroundItsHighlight() throws {
        let rule = EpisodeMatchRule(field: .notes, includePattern: "sponsor", action: .skip)
        let rules = EpisodeMatchRules(rules: [rule])
        let title = "JRE MMA Show #186 with Sean Sharaf"
        let notes = String(repeating: "context ", count: 40)
            + "This Sponsor message is long." + String(repeating: " tail", count: 40)
        let decision = try rules.evaluate(EpisodeMatchEpisode(id: "jre", title: title, notes: notes))
        XCTAssertEqual(decision, .skip(ruleID: rule.id))

        let highlight = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: decision, title: title, notes: notes, rules: rules))
        XCTAssertNil(highlight.title, "the title does not carry the match")
        let snippet = try XCTUnwrap(highlight.notes)
        XCTAssertLessThanOrEqual(snippet.text.count, WiltedMacRuleMatchHighlight.maximumSnippetLength + 2)
        XCTAssertTrue(snippet.text.hasPrefix("…"), snippet.text)
        XCTAssertTrue(snippet.text.hasSuffix("…"), snippet.text)
        XCTAssertEqual(snippet.ranges.count, 1)
        XCTAssertEqual(markedSubstrings(snippet), ["Sponsor"])
    }

    func testABothFieldsRuleFallsBackToNotesOnlyWhenTheTitleDidNotMatch() throws {
        let rule = EpisodeMatchRule(field: .both, includePattern: "sponsor", action: .keep)
        let rules = EpisodeMatchRules(rules: [rule])
        let inNotes = "Episode 12"
        let inTitle = "Sponsor Q&A"

        let notesMatch = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: .keep(ruleID: rule.id), title: inNotes, notes: "Our sponsor today", rules: rules))
        XCTAssertNil(notesMatch.title)
        XCTAssertEqual(markedSubstrings(try XCTUnwrap(notesMatch.notes)).map { $0.lowercased() }, ["sponsor"])

        let titleMatch = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: .keep(ruleID: rule.id), title: inTitle, notes: "Our sponsor today", rules: rules))
        XCTAssertEqual(titleMatch.title?.ranges, [0..<7])
        XCTAssertNil(titleMatch.notes, "the drawn title already shows the match")
    }

    func testANotesMatchBeyondTheCapIsNotDrawn() {
        let rule = EpisodeMatchRule(field: .notes, includePattern: "needle", action: .keep)
        let notes = String(repeating: "a", count: EpisodeMatchRules.maximumNotesLength) + "needle"
        XCTAssertNil(WiltedMacRuleMatchHighlight.make(
            result: .keep(ruleID: rule.id), title: "Title", notes: notes,
            rules: EpisodeMatchRules(rules: [rule])))
    }

    // MARK: Timeout

    func testATimedOutRecomputationDrawsNothingAndLeavesTheDecisionAlone() throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "MMA", action: .skip)
        let rules = EpisodeMatchRules(rules: [rule])
        let title = "JRE MMA Show #186 with Sean Sharaf"
        let episode = EpisodeMatchEpisode(id: "jre", title: title, notes: "")
        let decision = try rules.evaluate(episode)
        XCTAssertEqual(decision, .skip(ruleID: rule.id))

        let clock = AdvancingClock()
        XCTAssertNil(WiltedMacRuleMatchHighlight.make(
            result: decision, title: title, notes: "", rules: rules, timeout: 0.05, clock: { clock.now() }))
        XCTAssertGreaterThanOrEqual(clock.calls, 2, "the deadline check stops the recomputation")
        XCTAssertEqual(try rules.evaluate(episode), decision, "no highlight work changes the verdict")
    }

    // MARK: The plan and the row

    func testThePlanAttachesTheDecisiveRulesHighlightToItsRow() async throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "mma", action: .skip)
        let episode = FeedRulesEpisode(
            id: "jre", title: "JRE MMA Show #186 with Sean Sharaf", notes: "",
            releasedAt: Date(timeIntervalSince1970: 0), isStarted: false)
        let input = FeedRulesInput(
            rules: EpisodeMatchRules(rules: [rule]),
            policy: EffectiveFeedAutomationPolicy(
                autoKeep: true, autoDownload: false, autoPrepare: false, keptLimit: nil),
            episodes: [episode], records: [:], keptIDs: [])
        let plan = try await FeedRulesPlan.make(input)
        let row = try XCTUnwrap(plan.rows.first)
        XCTAssertEqual(row.result, .skip(ruleID: rule.id))
        XCTAssertEqual(row.highlight?.title?.ranges, [4..<7])
        XCTAssertEqual(row.highlight?.ruleID, rule.id)
    }

    func testThePreviewRowsMemberwiseInitKeepsItsOldCallShape() {
        let row = FeedRulesPreviewRow(
            episodeID: "episode", title: "Plain title", result: .noMatch, ruleNumber: nil, current: .undecided,
            isKept: false, outcome: .unchanged, deletesDownloadedAudio: false)
        XCTAssertNil(row.highlight, "the default keeps every existing test init compiling")
    }

    // MARK: Drawing

    func testTheHighlightedTitleIsBoldAndBackedNotColorOnly() throws {
        let rule = EpisodeMatchRule(field: .title, includePattern: "mma", action: .skip)
        let title = "JRE MMA Show #186 with Sean Sharaf"
        let highlight = try XCTUnwrap(WiltedMacRuleMatchHighlight.make(
            result: .skip(ruleID: rule.id), title: title, notes: "",
            rules: EpisodeMatchRules(rules: [rule])))
        let match = try XCTUnwrap(highlight.title)
        let attributed = match.attributed(scheme: .light)
        XCTAssertEqual(String(attributed.characters), title)

        let emphasized = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(emphasized.count, 1)
        let run = try XCTUnwrap(emphasized.first)
        XCTAssertEqual(String(attributed[run.range].characters), "MMA")
        XCTAssertNotNil(run.backgroundColor, "the theme backs the match, so color alone is not the signal")
        XCTAssertNotNil(run.foregroundColor)
    }

    // MARK: Helpers

    private func markedSubstrings(_ match: WiltedMacRuleMatchHighlight.TextMatch) -> [String] {
        match.ranges.compactMap { range in
            guard range.lowerBound >= 0, range.lowerBound < range.upperBound,
                  range.upperBound <= match.text.count else { return nil }
            let lower = match.text.index(match.text.startIndex, offsetBy: range.lowerBound)
            let upper = match.text.index(match.text.startIndex, offsetBy: range.upperBound)
            return String(match.text[lower..<upper])
        }
    }
}

/// A clock that steps past the first deadline: the plan reads it once for the
/// deadline, and the match loop sees the second value already expired.
private final class AdvancingClock: @unchecked Sendable {
    private var value: TimeInterval = 0
    private(set) var calls = 0

    func now() -> TimeInterval {
        calls += 1
        value += 1
        return value
    }
}
