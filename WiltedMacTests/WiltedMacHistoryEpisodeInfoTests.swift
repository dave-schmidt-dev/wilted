import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// B7d T5: the episode info popover (notes and transcript) on the two Mac
/// surfaces whose rows hold only the stored identity: History, which Off the
/// list and feed details share, and the rules preview. Both resolve the
/// episode through the model as the popover opens, and both keep the visible
/// states the popover already states elsewhere.
@MainActor
final class WiltedMacHistoryEpisodeInfoTests: XCTestCase {
    func testHistoryTitleOpensInfoForPlayedSkippedAndRuleSkippedRows() async throws {
        let fixture = try await makeHistoryFixture()
        for (name, status) in [
            ("finished", WiltedMacFeedHistoryStatus.played),
            ("passed", .skipped),
            ("rule", .skippedByRule),
        ] {
            let record = try XCTUnwrap(fixture.records[name], name)
            XCTAssertEqual(record.status, status, name)

            // The row's own click resolves its facts and notes by identity.
            let source = fixture.model.episodeInfoSource(id: record.id, showTitle: record.feedTitle)
            let load = await source.loadInfo()
            guard case .loaded(let info) = load else { return XCTFail("\(name): \(load)") }
            XCTAssertEqual(info.id, record.id, name)
            XCTAssertEqual(info.title, "Episode \(name)", name)
            XCTAssertEqual(info.presentation.showTitle, "History show", name)
            XCTAssertEqual(info.notes, "Show notes for \(name)", name)

            // The title is the button that opens it: it still draws the name.
            let drawn = try WiltedMacHeadless.recognizedText(
                WiltedMacFeedHistoryTitle(model: fixture.model, record: record),
                size: CGSize(width: 420, height: 80)
            ).joined(separator: " ")
            XCTAssertTrue(drawn.contains("Episode \(name)"), drawn)
        }

        // Retirement keeps a saved transcript, so a played row still reads it;
        // a row with nothing retained says so without an error.
        let playedTranscript = await fixture.model.savedTranscript(forEpisodeID: fixture.ids["finished"]!.rawValue)
        guard case .loaded(let transcript) = playedTranscript else {
            return XCTFail("finished: \(playedTranscript)")
        }
        XCTAssertEqual(transcript.text, "Transcript for the played episode")
        XCTAssertTrue(transcript.isReadable)
        let skippedTranscript = await fixture.model.savedTranscript(forEpisodeID: fixture.ids["passed"]!.rawValue)
        XCTAssertEqual(skippedTranscript, WiltedMacEpisodeTranscriptLoad.none)
        let ruleTranscript = await fixture.model.savedTranscript(forEpisodeID: fixture.ids["rule"]!.rawValue)
        XCTAssertEqual(ruleTranscript, WiltedMacEpisodeTranscriptLoad.none)

        // The page itself draws every row through the title button.
        let page = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedHistoryView(model: fixture.model, feedID: fixture.feedID.rawValue, loader: fixture.loader),
            size: CGSize(width: 900, height: 800)
        ).joined(separator: " ")
        for name in ["finished", "passed", "rule"] {
            XCTAssertTrue(page.contains("Episode \(name)"), page)
        }

        let history = try WiltedMacHeadless.viewSource("WiltedMacFeedHistoryView.swift")
        XCTAssertTrue(history.contains("WiltedMacFeedHistoryTitle(model: model, record: record)"))
        XCTAssertFalse(history.contains("Text(record.presentation.title)"),
                       "the plain title was replaced, not duplicated")
        let title = try WiltedMacHeadless.viewSource("WiltedMacFeedHistoryTitle.swift")
        XCTAssertTrue(title.contains("@State private var isPresented = false"), "the open state is per row")
        XCTAssertTrue(title.contains("prefix: \"wilted-feed-history\""))
        XCTAssertTrue(title.contains("model.episodeInfoSource(id: record.id, showTitle: record.feedTitle)"))
        XCTAssertTrue(title.contains("WiltedMacEpisodeInfoPopoverContent("))
    }

    func testRulesPreviewRowKeepsItsIdentifierAndExposesTheTitleButton() async throws {
        let fixture = try await makeRulesFixture()
        let plan = try await fixture.previewed()
        let row = try XCTUnwrap(plan.rows.first { $0.title == "Fight Companion - March 1" })

        // The editor's factory hands the row's popover the board's model and
        // the show title the plan row cannot carry itself.
        let load = await fixture.editor.episodeInfoSource(forRowID: row.episodeID).loadInfo()
        guard case .loaded(let info) = load else { return XCTFail("\(load)") }
        XCTAssertEqual(info.id, row.episodeID)
        XCTAssertEqual(info.title, row.title)
        XCTAssertEqual(info.notes, "Fight notes")
        XCTAssertEqual(info.presentation.showTitle, "Fight Feed")

        // The row still draws its title inside the preview it belongs to.
        let drawn = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedRulesPreview(editor: fixture.editor, subscription: fixture.subscription),
            size: CGSize(width: 760, height: 700)
        ).joined(separator: " ")
        XCTAssertTrue(drawn.contains("Fight Companion - March 1"), drawn)

        // The row keeps its identity, and the title is a real button now: a
        // combined row would hide it from assistive technology.
        let preview = try WiltedMacHeadless.viewSource("WiltedMacFeedRulesPreviewView.swift")
        XCTAssertTrue(preview.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(preview.contains(".accessibilityLabel(\"\\(row.title): \\(row.verdict) · \\(row.outcome.explanation)\")"))
        XCTAssertTrue(preview.contains("\"wilted-feed-rules-row-\\(row.episodeID)\""))
        XCTAssertFalse(preview.contains(".accessibilityElement(children: .combine)"),
                       "combining would hide the title button")
        XCTAssertTrue(preview.contains("WiltedMacEpisodeNotesTitle("))
        XCTAssertTrue(preview.contains("prefix: \"wilted-feed-rules\""))
        XCTAssertTrue(preview.contains("titleLineLimit: 2"), "the rules row keeps its two-line title")
        XCTAssertTrue(preview.contains("editor.episodeInfoSource(forRowID: row.episodeID)"))

        let editor = try String(
            contentsOf: WiltedMacHeadless.sourceRoot()
                .appendingPathComponent("WiltedMac/ViewModel/WiltedMacFeedRulesEditor.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(editor.contains("func episodeInfoSource(forRowID rowID: String)"))
        XCTAssertTrue(editor.contains("board.model"), "the popover reads through the board's model")
    }

    func testHistoryPopoverStatesLoadNotFoundError() async throws {
        let fixture = try await makeHistoryFixture()
        let passed = try XCTUnwrap(fixture.records["passed"])

        // Loaded: the facts and notes the popover draws.
        let loaded = await fixture.model.episodeInfoSource(id: passed.id, showTitle: passed.feedTitle).loadInfo()
        guard case .loaded(let info) = loaded else { return XCTFail("\(loaded)") }
        XCTAssertEqual(info.title, passed.presentation.title)
        XCTAssertEqual(info.notes, "Show notes for passed")

        // A row gone from the library is not an error.
        let gone = await fixture.model.episodeInfo(id: "item-gone-from-history", showTitle: nil)
        XCTAssertEqual(gone, .notFound)

        // A read that cannot be made fails, for facts and for the transcript.
        let invalid = String(repeating: "x", count: 129)
        let invalidInfo = await fixture.model.episodeInfo(id: invalid, showTitle: nil)
        XCTAssertEqual(invalidInfo, .failed)
        let invalidTranscript = await fixture.model.savedTranscript(forEpisodeID: invalid)
        XCTAssertEqual(invalidTranscript, .failed)

        // Without a library both reads fail rather than claiming nothing was saved.
        let empty = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let emptyInfo = await empty.episodeInfo(id: "item-nowhere", showTitle: nil)
        XCTAssertEqual(emptyInfo, .failed)
        let emptyTranscript = await empty.savedTranscript(forEpisodeID: "item-nowhere")
        XCTAssertEqual(emptyTranscript, .failed)

        // A row with no transcript record is the neutral state, not an error.
        let none = await fixture.model.savedTranscript(forEpisodeID: passed.id)
        XCTAssertEqual(none, WiltedMacEpisodeTranscriptLoad.none)

        // The popover's transcript half draws each state with its own copy.
        let loading = try transcriptText(nil)
        XCTAssertTrue(loading.contains("Loading transcript"), loading)
        let noneText = try transcriptText(WiltedMacEpisodeTranscriptLoad.none)
        XCTAssertTrue(noneText.contains("No transcript was saved for this episode"), noneText)
        let failed = try transcriptText(.failed)
        XCTAssertTrue(failed.contains("Could not read the saved transcript"), failed)
        XCTAssertTrue(failed.contains("Retry"), failed)
        let saved = try transcriptText(.loaded(WiltedMacTranscript(
            availability: .available, text: "Saved transcript text", cues: [], timingSource: nil
        )))
        XCTAssertTrue(saved.contains("Saved transcript text"), saved)
    }

    private func transcriptText(_ load: WiltedMacEpisodeTranscriptLoad?) throws -> String {
        try WiltedMacHeadless.recognizedText(
            WiltedMacEpisodeTranscriptSection(
                id: "row", prefix: "wilted-feed-history", load: load, retry: {}
            ),
            size: CGSize(width: 420, height: 160)
        ).joined(separator: " ")
    }

    // MARK: Fixtures

    /// History rows over one feed: a completed episode that kept its saved
    /// transcript, a hand skip, and a feed rule's skip.
    private func makeHistoryFixture() async throws -> HistoryFixture {
        let directory = wiltedTemporaryDirectory("history-episode-info")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedURL = URL(string: "https://feeds.example.test/history-info.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let at = Timestamp(Date(timeIntervalSince1970: 1_900_000_000))
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "History show", createdAt: at
        ))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: at))
        let names = ["finished", "passed", "rule"]
        let episodes = try names.map { name -> PodcastEpisode in
            let enclosure = URL(string: "https://cdn.example.test/history-\(name).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: name, enclosureURL: enclosure),
                feedID: feedID, feedURL: feedURL, rssGUID: name, title: "Episode \(name)",
                publishedTime: at, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
                durationSeconds: 1_800, notes: "Show notes for \(name)", createdAt: at
            )
        }
        let byName = Dictionary(uniqueKeysWithValues: zip(names, episodes))
        try await store.savePodcastEpisodes(episodes, admission: .backfill)

        let finished = try XCTUnwrap(byName["finished"]).itemID
        try await store.save(transcript: try Transcript(
            itemID: finished, revisionID: try RevisionID(rawValue: "revision-finished"),
            availability: .available, text: "Transcript for the played episode", updatedAt: at
        ))
        _ = try await store.completeAndRetireEpisode(listening: PodcastListeningState(
            episodeID: finished, completedAt: at, lastRevisionID: nil, updatedAt: at
        ), at: at)
        _ = try await store.retireEpisode(try XCTUnwrap(byName["passed"]).itemID, at: at)
        let rule = try XCTUnwrap(byName["rule"]).itemID
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: rule, decision: .skip, source: .rule, ruleID: UUID(), decidedAt: at
        ))
        _ = try await store.retireEpisode(rule, at: at)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let loader = WiltedMacFeedHistoryLoader(fetch: { request in
            try await store.historyPage(
                feedID: request.feedID.map { try ItemID(rawValue: $0) }, search: request.search,
                status: request.status, offset: request.offset, limit: request.limit
            )
        })
        await loader.start(feedID: feedID.rawValue)
        let ids = byName.mapValues(\.itemID)
        let nameByID = Dictionary(uniqueKeysWithValues: ids.map { ($1.rawValue, $0) })
        let records = Dictionary(uniqueKeysWithValues: loader.rows.compactMap { row in
            nameByID[row.episodeID.rawValue].map {
                ($0, WiltedMacFeedHistoryRecord(row: row, feedTitle: "History show"))
            }
        })
        return HistoryFixture(
            store: store, model: model, feedID: feedID, ids: ids, loader: loader, records: records
        )
    }

    /// A feed whose one episode a match rule keeps, ready to preview.
    private func makeRulesFixture() async throws -> RulesFixture {
        let directory = wiltedTemporaryDirectory("history-episode-info-rules")
        let feedURL = URL(string: "https://feeds.example.test/history-info-rules.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let at = Timestamp(Date(timeIntervalSince1970: 1_900_000_000))
        let enclosure = URL(string: "https://cdn.example.test/history-info-rules-1.mp3")!
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "fight", enclosureURL: enclosure)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Fight Feed", createdAt: at
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: at))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "fight",
                    title: "Fight Companion - March 1", publishedTime: at, enclosureURL: enclosure,
                    enclosureMediaType: "audio/mpeg", notes: "Fight notes", createdAt: at
                ))
                try await store.save(
                    feedAutomationPolicy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off),
                    for: feedID
                )
                try await store.replaceEpisodeMatchRules(
                    EpisodeMatchRules(rules: [.init(field: .title, includePattern: "Fight Companion", action: .keep)]),
                    for: feedID
                )
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        let editor = board.rulesEditor(for: feedID.rawValue)
        editor.loadIfNeeded()
        let subscription = try XCTUnwrap(model.subscriptions.first { $0.id == feedID.rawValue })
        return RulesFixture(model: model, board: board, editor: editor, subscription: subscription)
    }
}

private struct HistoryFixture {
    let store: LocalLibraryStore
    let model: WiltedMacModel
    let feedID: ItemID
    let ids: [String: ItemID]
    let loader: WiltedMacFeedHistoryLoader
    let records: [String: WiltedMacFeedHistoryRecord]
}

@MainActor
private struct RulesFixture {
    let model: WiltedMacModel
    let board: WiltedMacFeedPolicyBoard
    let editor: WiltedMacFeedRulesEditor
    let subscription: WiltedMacSubscription

    func previewed() async throws -> FeedRulesPlan {
        editor.preview()
        await editor.task?.value
        return try XCTUnwrap(editor.plan)
    }
}
