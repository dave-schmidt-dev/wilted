import Foundation
import WiltedProducer

/// One editable rule row. Values stay strings, as the store keeps them; `makeRule` is the only
/// place that validates, so an invalid draft is explained instead of silently dropped.
struct WiltedMacPlaylistRuleDraft: Identifiable, Equatable {
    let id = UUID()
    /// The stable positive number the match expression references. Numbers stay put across edits
    /// and deletions, so a formula keeps meaning exactly what it said.
    var number = 0
    var field: PlaylistRuleField = .played
    var comparator: PlaylistComparator = .is
    var value = PlaylistPlayedState.unplayed.rawValue

    init() {}
    init(_ rule: PlaylistRule) { field = rule.field; comparator = rule.comparator; value = rule.value }
    init(number: Int, _ rule: PlaylistRule) {
        self.init(rule)
        self.number = number
    }

    static func comparators(for field: PlaylistRuleField) -> [PlaylistComparator] {
        switch field {
        case .feed, .kind, .played, .ready: [.is, .isNot]
        case .length: [.shorterThan, .longerThan]
        case .published: [.withinDays, .before, .after]
        case .expression: [.expression]
        }
    }

    /// Switching field resets the comparator and value to ones the new field accepts.
    mutating func setField(_ new: PlaylistRuleField, firstFeedID: String?) {
        field = new
        comparator = Self.comparators(for: new)[0]
        switch new {
        case .feed: value = firstFeedID ?? ""
        case .kind: value = "podcast.episode"
        case .played: value = PlaylistPlayedState.unplayed.rawValue
        case .ready: value = "true"
        case .length: value = "30"
        case .published: value = "7"
        case .expression: value = ""
        }
    }

    mutating func setComparator(_ new: PlaylistComparator) {
        comparator = new
        guard field == .published else { return }
        value = new == .withinDays ? "7" : PlaylistRule.dateValue(Date())
    }

    func makeRule() throws -> PlaylistRule {
        try PlaylistRule(field: field, comparator: comparator, value: value)
    }

    static func name(_ field: PlaylistRuleField) -> String {
        switch field {
        case .feed: "Feed"
        case .played: "Played"
        case .length: "Length"
        case .published: "Published"
        case .kind: "Kind"
        case .ready: "Ready"
        case .expression: "Expression"
        }
    }

    static func name(_ comparator: PlaylistComparator) -> String {
        switch comparator {
        case .is: "is"
        case .isNot: "is not"
        case .shorterThan: "is shorter than"
        case .longerThan: "is longer than"
        case .withinDays: "is within the last"
        case .before: "is before"
        case .after: "is after"
        case .expression: "matches expression"
        }
    }
}

/// The rule editor's pure model: stable numbered leaves, the formula exactly as written, and the
/// all-of or any-of preset that generated it. A legacy flat list loads as numbered leaves with the
/// formula its saved mode implies; Save turns it into one versioned expression rule without
/// changing what matched. The formula follows added leaves only while it is still the generated
/// ALL/ANY one; after the reader edits it, only they change it, and declared leaves it stops
/// using are named instead of rewritten away.
struct WiltedMacPlaylistRulesEditor: Equatable {
    enum Validated: Equatable {
        /// No leaves and no formula: a valid editor that matches nothing.
        case empty
        case expression(PlaylistRule)
    }

    private(set) var leaves: [WiltedMacPlaylistRuleDraft] = []
    private(set) var expression = ""
    private(set) var matchAll = true
    /// Whether the formula still mirrors ALL/ANY of the declared leaves.
    private(set) var formulaIsGenerated = true
    /// The next fresh number a new leaf takes. It only grows, so a deleted number is never handed
    /// to a later leaf while a formula might still reference it.
    private(set) var nextRuleNumber = 1

    init(playlist: Playlist, storedRules: [PlaylistRule]) {
        matchAll = playlist.matchAll
        if storedRules.count == 1, let rule = storedRules.first, rule.isExpression,
           let payload = rule.expressionPayload {
            leaves = payload.numberedRules.map { WiltedMacPlaylistRuleDraft(number: $0.number, $0.rule) }
            expression = payload.expressionString
            formulaIsGenerated = payload.expressionString == Self.generatedFormula(for: leaves, matchAll: matchAll)
        } else if !storedRules.isEmpty {
            leaves = storedRules.enumerated().map { WiltedMacPlaylistRuleDraft(number: $0.offset + 1, $0.element) }
            expression = Self.generatedFormula(for: leaves, matchAll: matchAll)
            formulaIsGenerated = true
        }
        nextRuleNumber = (leaves.map(\.number).max() ?? 0) + 1
    }

    /// The fields a leaf can test; the editor's own expression field is not one of them.
    var fieldChoices: [PlaylistRuleField] { PlaylistRuleField.allCases.filter { $0 != .expression } }

    static func generatedFormula(for leaves: [WiltedMacPlaylistRuleDraft], matchAll: Bool) -> String {
        leaves.map { String($0.number) }.joined(separator: matchAll ? " AND " : " OR ")
    }

    /// Adds a leaf with a fresh number, copying the last leaf's field, comparison and value; a
    /// number a deleted leaf held is never handed out again in this session.
    mutating func addRule() {
        var draft = WiltedMacPlaylistRuleDraft()
        draft.number = nextRuleNumber
        nextRuleNumber += 1
        if let last = leaves.last {
            draft.field = last.field
            draft.comparator = last.comparator
            draft.value = last.value
        } else {
            draft.setField(.played, firstFeedID: nil)
        }
        leaves.append(draft)
        regenerateFormulaIfGenerated()
    }

    /// Removes one leaf and leaves its number as a gap; a formula that referenced it now flags an
    /// unknown reference rather than being silently rebound.
    mutating func removeRule(number: Int) {
        leaves.removeAll { $0.number == number }
        regenerateFormulaIfGenerated()
    }

    /// Replaces one leaf's draft, for the row bindings.
    mutating func updateLeaf(_ id: UUID, _ change: (inout WiltedMacPlaylistRuleDraft) -> Void) {
        guard let index = leaves.firstIndex(where: { $0.id == id }) else { return }
        change(&leaves[index])
    }

    /// The ALL/ANY preset: a shortcut that rewrites the formula and re-arms generated following.
    mutating func applyPreset(matchAll: Bool) {
        self.matchAll = matchAll
        expression = Self.generatedFormula(for: leaves, matchAll: matchAll)
        formulaIsGenerated = true
    }

    /// The reader typed in the expression field: keep their text from here on.
    mutating func editExpression(_ newValue: String) {
        expression = newValue
        formulaIsGenerated = false
    }

    /// References the formula makes to numbers no leaf declares.
    var unknownRuleNumbers: [Int] {
        guard let node = try? PlaylistExpressionParser.parse(expression) else { return [] }
        return PlaylistExpressionParser.references(in: node)
            .subtracting(leaves.map(\.number))
            .sorted()
    }

    /// Declared leaves the formula does not reference.
    var unusedRuleNumbers: [Int] {
        guard let node = try? PlaylistExpressionParser.parse(expression) else { return [] }
        let used = PlaylistExpressionParser.references(in: node)
        return leaves.map(\.number).filter { !used.contains($0) }
    }

    /// The leaves as validated numbered rules, each failure naming its rule number.
    func numberedRules() throws -> [PlaylistNumberedRule] {
        try leaves.map { draft in
            do { return try PlaylistNumberedRule(number: draft.number, rule: draft.makeRule()) }
            catch let error as PlaylistRuleError {
                throw PlaylistRuleError(reason: "rule \(draft.number): \(error.reason)")
            }
        }
    }

    /// What Save writes: nothing for an empty editor, otherwise the one compiled expression rule.
    func validated() throws -> Validated {
        let numbered = try numberedRules()
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if numbered.isEmpty && trimmed.isEmpty { return .empty }
        _ = try PlaylistExpressionParser.parse(expression, ruleNumbers: Set(numbered.map(\.number)))
        guard !numbered.isEmpty else { return .empty }
        return .expression(try PlaylistRule.expression(numberedRules: numbered, expressionString: expression))
    }

    /// The concise reason Save is unavailable, or nil.
    var validationProblem: String? {
        do {
            _ = try validated()
            return nil
        } catch let error as PlaylistRuleError {
            return error.reason
        } catch {
            return "The expression is not valid."
        }
    }

    /// Everything a re-preview depends on.
    var previewSignature: String {
        let leafText = leaves.map { "\($0.number):\($0.field.rawValue):\($0.comparator.rawValue):\($0.value)" }
        return (leafText + [expression]).joined(separator: "|")
    }

    private mutating func regenerateFormulaIfGenerated() {
        guard formulaIsGenerated else { return }
        expression = Self.generatedFormula(for: leaves, matchAll: matchAll)
    }
}
