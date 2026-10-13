import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// History pages out of the library store through its view-owned loader:
/// one page at a time, search debounced, filters immediate, stale pages
/// dropped, and Restore followed by a reload that drops the restored row.
@MainActor
final class WiltedMacFeedHistoryPagingTests: XCTestCase {
    func testPageTwoOfA120RowHistoryShowsTheRightRowsAndTotal() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let feed = try WiltedMacHistoryStoreFixture.Feed("paging")
        let episodes = try (0..<120).map { try feed.episode("episode-\($0)", title: "Episode \($0)") }
        try await fixture.store.savePodcastEpisodes(episodes, admission: .backfill)
        for (index, episode) in episodes.enumerated() {
            let retired = try await fixture.store.retireEpisode(episode.itemID, at: fixture.at(Double(index)))
            XCTAssertTrue(retired)
        }
        let newestFirst = episodes.reversed().map(\.itemID.rawValue)

        let loader = WiltedMacFeedHistoryLoader(fetch: fixture.fetch)
        await loader.start(feedID: nil)
        XCTAssertEqual(loader.total, 120)
        XCTAssertEqual(loader.pageCount, 5)
        XCTAssertEqual(loader.rows.map(\.episodeID.rawValue), Array(newestFirst[0..<25]))

        loader.showPage(1)
        await loader.settle()
        XCTAssertEqual(loader.pageIndex, 1)
        XCTAssertEqual(loader.shownOffset, 25)
        XCTAssertEqual(loader.total, 120)
        XCTAssertEqual(loader.rows.map(\.episodeID.rawValue), Array(newestFirst[25..<50]))

        // Feed details reads the same page through the one-feed scope, from page one.
        await loader.start(feedID: feed.id.rawValue)
        XCTAssertEqual(loader.pageIndex, 0)
        loader.showPage(1)
        await loader.settle()
        XCTAssertEqual(loader.rows.map(\.episodeID.rawValue), Array(newestFirst[25..<50]))
        XCTAssertEqual(loader.total, 120)
    }

    func testThreeKeystrokesWithin300MillisecondsIssueOneStoreQuery() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let feed = try WiltedMacHistoryStoreFixture.Feed("debounce")
        let fight = try feed.episode("fight", title: "MMA fight companion")
        let news = try feed.episode("news", title: "Morning news")
        try await fixture.store.savePodcastEpisodes([fight, news], admission: .backfill)
        _ = try await fixture.store.retireEpisodes([fight.itemID, news.itemID], at: fixture.at(1))
        let recorder = WiltedMacHistoryFetchRecorder(store: fixture.store)
        let loader = WiltedMacFeedHistoryLoader(fetch: recorder.fetch)
        await loader.start(feedID: nil)
        XCTAssertEqual(recorder.requests.count, 1)

        let typingStarted = ContinuousClock.now
        loader.setSearchText("m")
        try await Task.sleep(for: .milliseconds(20))
        loader.setSearchText("mm")
        try await Task.sleep(for: .milliseconds(20))
        loader.setSearchText("mma")
        XCTAssertLessThan(ContinuousClock.now - typingStarted, .milliseconds(300), "the keystrokes fell inside one debounce")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.requests.count, 1, "nothing is asked while typing continues")
        await loader.settle()
        XCTAssertEqual(recorder.requests.count, 2, "three keystrokes issue one store query")
        XCTAssertEqual(recorder.requests.last?.search, "mma")
        XCTAssertEqual(loader.rows.map(\.episodeID), [fight.itemID])
        XCTAssertEqual(loader.total, 1)

        // A filter change does not wait for the debounce.
        loader.setStatusFilter(.played)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.requests.count, 3, "a filter change loads at once")
        XCTAssertEqual(recorder.requests.last?.status, .played)
        await loader.settle()
        XCTAssertEqual(loader.rows, [])
        XCTAssertEqual(loader.total, 0)
        XCTAssertTrue(loader.isFiltered)
    }

    func testAStaleResponseNeverOverwritesANewerOne() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let feed = try WiltedMacHistoryStoreFixture.Feed("stale")
        let finished = try feed.episode("finished", title: "Finished")
        let passed = try feed.episode("passed", title: "Passed")
        try await fixture.store.savePodcastEpisodes([finished, passed], admission: .backfill)
        _ = try await fixture.store.completeAndRetireEpisode(listening: PodcastListeningState(
            episodeID: finished.itemID, completedAt: fixture.at(1), lastRevisionID: nil, updatedAt: fixture.at(1)
        ), at: fixture.at(2))
        _ = try await fixture.store.retireEpisode(passed.itemID, at: fixture.at(3))
        let recorder = WiltedMacHistoryFetchRecorder(store: fixture.store)
        let loader = WiltedMacFeedHistoryLoader(fetch: recorder.fetch)
        await loader.start(feedID: nil)

        recorder.holdStatus = .played
        loader.setStatusFilter(.played)
        await WiltedMacHeadless.eventually("the Played page to be held") { recorder.isHolding }
        loader.setStatusFilter(.skipped)
        await loader.settle()
        XCTAssertEqual(loader.rows.map(\.episodeID), [passed.itemID])

        recorder.release()
        await WiltedMacHeadless.eventually("the held Played page to return") { recorder.heldPageReturned }
        // Give the stale load its turn to publish, which it must not.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(loader.rows.map(\.episodeID), [passed.itemID], "the older Played page arrived last and was dropped")
        XCTAssertEqual(loader.statusFilter, .skipped)
        XCTAssertFalse(loader.isLoading)
    }

    func testRuleSkipReadsSkippedByRuleAndAppearsUnderTheSkippedFilter() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let feed = try WiltedMacHistoryStoreFixture.Feed("rule-skip")
        let companion = try feed.episode("companion", title: "MMA fight companion")
        let mainCard = try feed.episode("main-card", title: "Main card preview")
        let weighIn = try feed.episode("weigh-in", title: "Weigh-in show")
        try await fixture.store.savePodcastEpisodes([companion, mainCard, weighIn], admission: .backfill)
        try await fixture.seedRuleSkip(companion.itemID, at: 30)
        _ = try await fixture.store.retireEpisode(mainCard.itemID, at: fixture.at(20))
        _ = try await fixture.store.completeAndRetireEpisode(listening: PodcastListeningState(
            episodeID: weighIn.itemID, completedAt: fixture.at(9), lastRevisionID: nil, updatedAt: fixture.at(9)
        ), at: fixture.at(10))

        let loader = WiltedMacFeedHistoryLoader(fetch: fixture.fetch)
        await loader.start(feedID: feed.id.rawValue)
        let records = loader.rows.map { WiltedMacFeedHistoryRecord(row: $0, feedTitle: "Fight Night") }
        XCTAssertEqual(records.map(\.id), [companion, mainCard, weighIn].map(\.itemID.rawValue))
        XCTAssertEqual(records.map(\.status.rawValue), ["Skipped by rule", "Skipped", "Played"])
        XCTAssertEqual(records.first?.kind, .retired, "a rule skip restores like any retirement")

        loader.setStatusFilter(.skipped)
        await loader.settle()
        XCTAssertEqual(loader.rows.map(\.episodeID), [companion.itemID, mainCard.itemID],
                       "the Skipped filter includes rule skips")
        XCTAssertEqual(loader.rows.map(\.status), [.skippedByRule, .skipped])
        XCTAssertEqual(loader.total, 2)

        loader.setStatusFilter(.played)
        await loader.settle()
        XCTAssertEqual(loader.rows.map(\.episodeID), [weighIn.itemID])
    }

    func testRestoreRemovesTheRowFromTheReloadedPage() async throws {
        let model = await WiltedMacHeadless.model(self, [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared",
        ], suffix: "history-restore")
        addTeardownBlock { await model.close() }
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.decideFeedEpisodes(.skip, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)

        let loader = WiltedMacFeedHistoryLoader()
        loader.useStore(of: model)
        await loader.start(feedID: nil)
        XCTAssertFalse(loader.loadFailed)
        let row = try XCTUnwrap(loader.rows.first { $0.episodeID.rawValue == episode.id })
        let totalBefore = loader.total

        loader.restore(WiltedMacFeedHistoryRecord(row: row, feedTitle: episode.feedTitle), model: model)
        XCTAssertTrue(loader.restoringIDs.contains(episode.id), "the row reads Restoring until the reload lands")
        await loader.settle()
        XCTAssertFalse(loader.rows.contains { $0.episodeID.rawValue == episode.id })
        XCTAssertEqual(loader.total, totalBefore - 1)
        XCTAssertTrue(loader.restoringIDs.isEmpty)
        XCTAssertTrue(model.feedsEpisodes.contains { $0.id == episode.id }, "Restore still runs through the model")
        let store = try XCTUnwrap(model.store)
        let decision = try await store.episodeDecision(for: ItemID(rawValue: episode.id))
        XCTAssertEqual(decision?.decision, .keep, "Restore writes a manual Keep, so rules never re-skip it")
        XCTAssertEqual(decision?.source, .manual)
    }

    /// A store row the model does not hold (a feed it does not load, say)
    /// still restores, through the store's removal-agnostic restore.
    func testRestoreOfARowTheModelDoesNotHoldStillLeavesThePage() async throws {
        let model = await WiltedMacHeadless.model(self, [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared",
        ], suffix: "history-restore-unloaded")
        addTeardownBlock { await model.close() }
        let store = try XCTUnwrap(model.store)
        let orphan = try WiltedMacHistoryStoreFixture.Feed("unloaded").episode("orphan", title: "Unloaded episode")
        try await store.savePodcastEpisodes([orphan], admission: .backfill)
        _ = try await store.retireEpisode(orphan.itemID, at: Timestamp(Date()))
        XCTAssertFalse(model.episodes.contains { $0.id == orphan.itemID.rawValue })

        let loader = WiltedMacFeedHistoryLoader()
        loader.useStore(of: model)
        await loader.start(feedID: nil)
        let row = try XCTUnwrap(loader.rows.first { $0.episodeID == orphan.itemID })
        loader.restore(WiltedMacFeedHistoryRecord(row: row, feedTitle: nil), model: model)
        await loader.settle()
        XCTAssertFalse(loader.rows.contains { $0.episodeID == orphan.itemID })
        let decision = try await store.episodeDecision(for: orphan.itemID)
        XCTAssertEqual(decision?.decision, .keep)
        XCTAssertEqual(decision?.source, .manual)
    }
}

/// A fresh library store for History tests, and a page fetch that reads it.
@MainActor
struct WiltedMacHistoryStoreFixture {
    let store: LocalLibraryStore

    init(_ test: XCTestCase) throws {
        store = try LocalLibraryStore(
            url: test.wiltedTemporaryDirectory("history-store").appendingPathComponent("library.sqlite")
        )
    }

    var fetch: WiltedMacFeedHistoryLoader.Fetch {
        { [store] request in try await Self.page(store, request) }
    }

    static func page(
        _ store: LocalLibraryStore, _ request: WiltedMacFeedHistoryRequest
    ) async throws -> LocalLibraryStore.HistoryPage {
        try await store.historyPage(
            feedID: request.feedID.map { try ItemID(rawValue: $0) }, search: request.search,
            status: request.status, offset: request.offset, limit: request.limit
        )
    }

    func at(_ seconds: Double) -> Timestamp {
        Timestamp(Date(timeIntervalSince1970: 1_900_000_000 + seconds))
    }

    /// What a feed rule's skip leaves behind: a rule-sourced skip decision and a retirement.
    func seedRuleSkip(_ episodeID: ItemID, at seconds: Double) async throws {
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: episodeID, decision: .skip, source: .rule, ruleID: UUID(), decidedAt: at(seconds)
        ))
        _ = try await store.retireEpisode(episodeID, at: at(seconds))
    }

    struct Feed {
        let url: URL
        let id: ItemID

        init(_ slug: String) throws {
            url = URL(string: "https://podcasts.example.test/history-\(slug).xml")!
            id = try ItemID.derivePodcastFeed(from: url)
        }

        func episode(_ guid: String, title: String) throws -> PodcastEpisode {
            let enclosure = URL(string: "https://cdn.example.test/history-\(guid).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: url, rssGUID: guid, enclosureURL: enclosure),
                feedID: id, feedURL: url, rssGUID: guid, title: title,
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", durationSeconds: 1_800,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            )
        }
    }
}

/// Counts the store queries a loader issues, and can hold one status's page
/// until released so a newer page can land first.
@MainActor
final class WiltedMacHistoryFetchRecorder {
    let store: LocalLibraryStore
    private(set) var requests: [WiltedMacFeedHistoryRequest] = []
    var holdStatus: LocalLibraryStore.HistoryStatusFilter?
    private var held: CheckedContinuation<Void, Never>?
    private(set) var heldPageReturned = false

    init(store: LocalLibraryStore) {
        self.store = store
    }

    var isHolding: Bool { held != nil }

    var fetch: WiltedMacFeedHistoryLoader.Fetch {
        { [self] request in
            requests.append(request)
            let holds = holdStatus != nil && request.status == holdStatus
            if holds {
                holdStatus = nil
                await withCheckedContinuation { held = $0 }
            }
            let page = try await WiltedMacHistoryStoreFixture.page(store, request)
            if holds { heldPageReturned = true }
            return page
        }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
