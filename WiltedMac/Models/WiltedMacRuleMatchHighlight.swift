import Foundation
import WiltedProducer

/// Where the rule that already decided an episode matched, prepared with the
/// rules plan off the main actor. The preview only draws these ranges; it never
/// runs a pattern itself.
///
/// Ranges are offsets into their own text's characters, not UTF-16 units, so a
/// match around an accented letter, a combining mark, or an emoji keeps its
/// boundaries on both platforms. A zero-length match is never a range: there is
/// nothing to draw, so it is dropped and the row falls back to plain text.
struct WiltedMacRuleMatchHighlight: Sendable, Equatable {
    /// One piece of text and the matched ranges worth drawing in it, ascending.
    struct TextMatch: Sendable, Equatable {
        /// The text as shown, bounded when it came from the notes.
        let text: String
        /// Matched character ranges into `text`.
        let ranges: [Range<Int>]
    }

    /// The rule that decided the episode.
    let ruleID: UUID
    /// The field that rule searched.
    let field: EpisodeMatchField
    /// The title and its matched ranges, when the title matched.
    let title: TextMatch?
    /// A bounded notes excerpt with its matched ranges, when the notes matched
    /// and the title alone cannot show it.
    let notes: TextMatch?
}

// MARK: - Evaluation

extension WiltedMacRuleMatchHighlight {
    /// The most matched ranges drawn per text.
    static let maximumRanges = 8
    /// The most characters a notes excerpt shows.
    static let maximumSnippetLength = 180
    /// How much of the excerpt's length precedes its first match.
    static let snippetContextBefore = 40

    /// Match details for the rule that decided an episode, or nil when there is
    /// nothing worth drawing: no decisive rule, a stale or disabled rule id, an
    /// unusable pattern, or a recomputation that ran past the deadline.
    ///
    /// The recomputation mirrors `EpisodeMatchRules.evaluate` exactly -- the
    /// same case-insensitive compile, the same pattern and notes caps, the same
    /// short deadline with `.reportProgress` cancellation -- and never changes
    /// the decision it was handed. A timeout here draws nothing; the verdict
    /// the plan already made stands.
    static func make(
        result: EpisodeMatchResult,
        title: String,
        notes: String,
        rules: EpisodeMatchRules,
        timeout: TimeInterval = EpisodeMatchRules.defaultEvaluationTimeout,
        clock: @escaping EpisodeMatchRules.Clock = { ProcessInfo.processInfo.systemUptime }
    ) -> WiltedMacRuleMatchHighlight? {
        let ruleID: UUID
        switch result {
        case let .keep(id), let .skip(id): ruleID = id
        case .noMatch, .timedOut: return nil
        }
        guard let rule = rules.rules.first(where: { $0.id == ruleID }), rule.isEnabled,
              rule.includePattern.count <= EpisodeMatchRules.maximumPatternLength,
              let expression = try? NSRegularExpression(pattern: rule.includePattern, options: [.caseInsensitive])
        else { return nil }

        let deadline = clock() + max(0, timeout)
        let cappedNotes = String(notes.prefix(EpisodeMatchRules.maximumNotesLength))
        var titleRanges: [Range<Int>] = []
        var notesRanges: [Range<Int>] = []
        if rule.field != .notes {
            guard let ranges = matchRanges(in: title, expression: expression, deadline: deadline, clock: clock)
            else { return nil }
            titleRanges = ranges
        }
        if rule.field != .title {
            guard let ranges = matchRanges(in: cappedNotes, expression: expression, deadline: deadline, clock: clock)
            else { return nil }
            notesRanges = ranges
        }

        let titleMatch: TextMatch? = titleRanges.isEmpty ? nil : TextMatch(text: title, ranges: titleRanges)
        var notesMatch: TextMatch?
        if !notesRanges.isEmpty, rule.field == .notes || titleRanges.isEmpty {
            notesMatch = snippet(in: cappedNotes, ranges: notesRanges)
        }
        guard titleMatch != nil || notesMatch != nil else { return nil }
        return WiltedMacRuleMatchHighlight(ruleID: rule.id, field: rule.field, title: titleMatch, notes: notesMatch)
    }

    /// Every non-empty match in `text`, bounded to `maximumRanges` and stopped
    /// by the deadline. Returns nil when the deadline passed, so a pathological
    /// pattern draws nothing rather than blocking the plan.
    private static func matchRanges(
        in text: String,
        expression: NSRegularExpression,
        deadline: TimeInterval,
        clock: EpisodeMatchRules.Clock
    ) -> [Range<Int>]? {
        guard clock() <= deadline else { return nil }
        var ranges: [Range<Int>] = []
        var timedOut = false
        expression.enumerateMatches(
            in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)
        ) { result, _, stop in
            if clock() > deadline {
                timedOut = true
                stop.pointee = true
            } else if let result, result.range.length > 0,
                      let range = Range(result.range, in: text), !range.isEmpty {
                ranges.append(characterRange(range, in: text))
                if ranges.count >= maximumRanges { stop.pointee = true }
            }
        }
        if timedOut || clock() > deadline { return nil }
        return ranges
    }

    /// The matched range as character offsets, which stay right across UTF-16
    /// surrogate pairs and combining sequences.
    private static func characterRange(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return lower..<upper
    }

    /// A bounded excerpt around the first match, with an ellipsis marking each
    /// truncated end and the ranges shifted onto the excerpt.
    private static func snippet(in text: String, ranges: [Range<Int>]) -> TextMatch {
        let length = text.count
        guard length > maximumSnippetLength else {
            return TextMatch(text: text, ranges: Array(ranges.prefix(maximumRanges)))
        }
        let anchor = ranges.first?.lowerBound ?? 0
        var start = max(0, anchor - snippetContextBefore)
        let end = min(length, start + maximumSnippetLength)
        if end == length { start = max(0, end - maximumSnippetLength) }
        let prefix = start > 0 ? "…" : ""
        let suffix = end < length ? "…" : ""
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: end - start)
        let excerpt = prefix + String(text[lower..<upper]) + suffix
        let shift = prefix.count - start
        let marked = ranges.compactMap { range -> Range<Int>? in
            let clippedLower = max(range.lowerBound, start) + shift
            let clippedUpper = min(range.upperBound, end) + shift
            guard clippedLower >= 0, clippedLower < clippedUpper, clippedUpper <= excerpt.count else { return nil }
            return clippedLower..<clippedUpper
        }
        return TextMatch(text: excerpt, ranges: Array(marked.prefix(maximumRanges)))
    }
}
