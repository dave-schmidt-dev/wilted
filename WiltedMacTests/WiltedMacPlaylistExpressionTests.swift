import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
extension WiltedMacPlaylistTests {
    private func automaticPlaylist(matchAll: Bool = true) -> Playlist {
        Playlist(id: "test-playlist", name: "Test", kind: .automatic, matchAll: matchAll, sortIndex: 0)
    }

    func testAnInvalidRuleDraftIsRefusedNotDropped() throws {
        var draft = WiltedMacPlaylistRuleDraft()
        draft.setField(.length, firstFeedID: nil)
        draft.value = "soon"
        XCTAssertThrowsError(try draft.makeRule())
        draft.value = "45"
        XCTAssertEqual(try draft.makeRule().value, "45")
    }

    func testTheEditorLoadsLegacyFlatRulesAsNumberedLeavesWithTheModesFormula() throws {
        let rules = [
            try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue),
            try PlaylistRule(field: .length, comparator: .shorterThan, value: "30"),
        ]
        let all = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(matchAll: true), storedRules: rules)
        XCTAssertEqual(all.leaves.map(\.number), [1, 2])
        XCTAssertEqual(all.expression, "1 AND 2")
        XCTAssertTrue(all.formulaIsGenerated)
        XCTAssertNil(all.validationProblem)
        let any = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(matchAll: false), storedRules: rules)
        XCTAssertEqual(any.expression, "1 OR 2")
        XCTAssertNil(any.validationProblem)
    }

    func testAddingARuleCopiesTheLastLeafWithTheNextStableNumber() throws {
        var editor = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(), storedRules: [
            try PlaylistRule(field: .length, comparator: .longerThan, value: "45"),
        ])
        editor.addRule()
        editor.addRule()
        XCTAssertEqual(editor.leaves.map(\.number), [1, 2, 3])
        XCTAssertEqual(editor.leaves[1].field, .length)
        XCTAssertEqual(editor.leaves[1].comparator, .longerThan)
        XCTAssertEqual(editor.leaves[1].value, "45", "the copy keeps the last leaf's safe value")
        XCTAssertEqual(editor.expression, "1 AND 2 AND 3")
    }

    func testDeletingARuleFromAnEditedFormulaLeavesAGapAndFlagsTheReference() throws {
        var editor = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(), storedRules: [
            try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue),
            try PlaylistRule(field: .length, comparator: .shorterThan, value: "30"),
            try PlaylistRule(field: .kind, comparator: .is, value: "podcast.episode"),
        ])
        editor.editExpression("(1 OR 2) AND 3")
        editor.removeRule(number: 2)
        XCTAssertEqual(editor.leaves.map(\.number), [1, 3], "numbers are never renumbered")
        XCTAssertEqual(editor.expression, "(1 OR 2) AND 3", "the reader's formula is never rewritten")
        XCTAssertEqual(editor.unknownRuleNumbers, [2])
        XCTAssertNotNil(editor.validationProblem, "the unknown reference disables Save")
        XCTAssertFalse(editor.formulaIsGenerated)
    }

    func testANewRuleNeverReusesADeletedNumberAFormulaStillNames() throws {
        let leaves = [
            try PlaylistNumberedRule(
                number: 1, field: .played, comparator: .is,
                value: PlaylistPlayedState.unplayed.rawValue),
            try PlaylistNumberedRule(number: 4, field: .kind, comparator: .is, value: "article"),
            try PlaylistNumberedRule(number: 5, field: .length, comparator: .shorterThan, value: "30"),
        ]
        let stored = try PlaylistRule.expression(numberedRules: leaves, expressionString: "1 OR 5")
        var editor = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(), storedRules: [stored])
        XCTAssertEqual(editor.expression, "1 OR 5")
        editor.removeRule(number: 5)
        editor.addRule()
        XCTAssertEqual(editor.leaves.map(\.number), [1, 4, 6], "the deleted 5 is never handed out again")
        XCTAssertEqual(editor.expression, "1 OR 5", "the formula still names the leaf the reader deleted")
        XCTAssertNotNil(editor.validationProblem)
    }

    func testAnEditedFormulaIsKeptWhenRulesAreAddedAndUnusedLeavesAreNamed() throws {
        var editor = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(), storedRules: [
            try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue),
        ])
        editor.editExpression("1")
        editor.addRule()
        XCTAssertEqual(editor.expression, "1")
        XCTAssertEqual(editor.unusedRuleNumbers, [2])
        editor.applyPreset(matchAll: false)
        XCTAssertEqual(editor.expression, "1 OR 2", "the preset is only a shortcut that rewrites the formula")
        XCTAssertTrue(editor.formulaIsGenerated)
    }

    func testAMalformedFormulaNamesItsProblemAndNotAndParenthesesParse() throws {
        var editor = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(), storedRules: [
            try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue),
        ])
        editor.editExpression("1 AND")
        XCTAssertNotNil(editor.validationProblem, "a missing operand disables Save")
        XCTAssertEqual(editor.expression, "1 AND", "the typed formula stays")
        editor.editExpression("NOT (1)")
        XCTAssertNil(editor.validationProblem, "NOT and parentheses are part of the language")
        guard case let .expression(rule) = try editor.validated() else { return XCTFail("expected a rule") }
        XCTAssertEqual(rule.expressionString, "NOT (1)")
    }

    func testTheEditorOffersReadyAndNeverTheInternalExpressionField() throws {
        let editor = WiltedMacPlaylistRulesEditor(playlist: automaticPlaylist(), storedRules: [])
        XCTAssertEqual(editor.fieldChoices, [.feed, .played, .length, .published, .kind, .ready])
        XCTAssertFalse(editor.fieldChoices.contains(.expression))
        var draft = WiltedMacPlaylistRuleDraft()
        draft.setField(.ready, firstFeedID: nil)
        XCTAssertEqual(draft.comparator, .is)
        XCTAssertEqual(draft.value, "true")
        XCTAssertEqual(try draft.makeRule().field, .ready)
    }

    func testTheCompiledEditorRuleSavesAsAVersionedExpressionPayload() async throws {
        let f = try await fixture("expression-save", count: 3)
        let model = f.model
        let store = try XCTUnwrap(model.store)
        let playlist = try await created(model, .automatic, "Expression")
        var editor = WiltedMacPlaylistRulesEditor(
            playlist: try XCTUnwrap(model.playlist(playlist.id)), storedRules: [])
        editor.addRule()
        editor.addRule()
        editor.editExpression("1 OR 2")
        guard case let .expression(rule) = try editor.validated() else { return XCTFail("expected a rule") }
        let saved = await model.savePlaylistRules(playlist.id, rules: [rule], matchAll: true)
        XCTAssertTrue(saved)
        let stored = try await store.playlistRules(playlistID: playlist.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].isExpression)
        XCTAssertEqual(stored[0].expressionString, "1 OR 2")
        XCTAssertEqual(stored[0].numberedRules.map(\.number), [1, 2])
    }

    func testTheLivePreviewUsesTheSameEvaluationAndReadinessAsThePage() async throws {
        let f = try await fixture("preview-ready", count: 3)
        let model = f.model
        let playlist = try await created(model, .automatic, "Ready")
        let ready = try PlaylistRule(field: .ready, comparator: .is, value: "true")
        _ = await model.savePlaylistRules(playlist.id, rules: [ready], matchAll: true)
        let saved = try XCTUnwrap(model.playlist(playlist.id))
        XCTAssertEqual(model.playlistItems(saved).count, 3, "the fixture's entries are ready")
        let preview = await model.playlistRulePreview(for: model.playlists.rules[playlist.id] ?? [], matchAll: true)
        XCTAssertEqual(preview.matchCount, 3)
        XCTAssertEqual(Set(preview.entries.map(\.id)), Set(model.playlistItems(saved).map(\.id)))
        XCTAssertTrue(preview.entries.allSatisfy { !$0.title.isEmpty })
        let signature = model.playlistPreviewFingerprint
        model.episodes[0].playbackSeconds = 10
        XCTAssertNotEqual(model.playlistPreviewFingerprint, signature,
                          "played-state changes refresh even when entry IDs and readiness stay fixed")
        let unplayed = try PlaylistRule(field: .played, comparator: .is, value: "unplayed")
        let changed = await model.playlistRulePreview(for: [unplayed], matchAll: true)
        XCTAssertEqual(changed.matchCount, 2)
        let item = WiltedMacLibraryItem.episode(model.episodes[0])
        XCTAssertFalse(WiltedMacModel.playlistCandidate(item).isReady, "the compatibility default reads as not ready")
        XCTAssertTrue(WiltedMacModel.playlistCandidate(item, ready: true).isReady)
        let url = try XCTUnwrap(URL(string: "https://example.test/preview-title"))
        func article(_ title: String) -> WiltedMacArticle {
            .init(id: "preview-title", title: title, source: "Fixture", url: url, isReady: false, durationSeconds: 120)
        }
        model.articles = [article("Before refresh")]
        let candidateFacts = model.playlistCandidates()
        let titleSignature = model.playlistPreviewFingerprint
        model.articles = [article("After refresh")]
        XCTAssertEqual(model.playlistCandidates(), candidateFacts, "only the displayed title changed")
        XCTAssertNotEqual(model.playlistPreviewFingerprint, titleSignature, "same-ID title refresh invalidates the preview")
        let articles = try PlaylistRule(field: .kind, comparator: .is, value: "article")
        let refreshed = await model.playlistRulePreview(for: [articles], matchAll: true)
        XCTAssertEqual(refreshed.entries.map(\.title), ["After refresh"])
    }

    func testTheRuleEditorKeepsItsStableIdentifiersAndAccessibilityLabels() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacPlaylistRulesSheet.swift")
        for identifier in [
            "wilted-playlist-rules-sheet", "wilted-playlist-rules-add", "wilted-playlist-rules-save",
            "wilted-playlist-rules-error", "wilted-playlist-rules-match", "wilted-playlist-rule-expression",
            "wilted-playlist-rule-preview", "wilted-playlist-rule-preview-count",
            "wilted-playlist-rule-preview-empty", "wilted-playlist-preview",
        ] {
            XCTAssertTrue(source.contains(identifier), "missing \(identifier)")
        }
        XCTAssertTrue(source.contains("\"Rule \\(number) field\""))
        XCTAssertTrue(source.contains("\"Rule \\(number) comparison\""))
        XCTAssertTrue(source.contains("\"Rule \\(number) value\""))
    }
}
