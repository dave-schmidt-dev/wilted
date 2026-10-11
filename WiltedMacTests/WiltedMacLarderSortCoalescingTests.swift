import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// A Larder sort request that arrives while an earlier one is still being written must win. The write
/// hook holds the first queue write open, so the second request lands exactly while one is in flight.
@MainActor
final class WiltedMacLarderSortCoalescingTests: XCTestCase {
    private actor WriteGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var writes = 0

        /// Counts the write; the first one waits for `open()`.
        func arrive() async {
            writes += 1
            guard writes == 1, !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private struct FailingWrite: Error {}

    private let feedURL = URL(string: "https://feeds.example.test/sort.xml")!
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    /// Episodes "a", "b", "c": published in that order, titled "Episode a" ... , queued [b, a, c].
    private func model(_ name: String) async throws -> (WiltedMacModel, LocalLibraryStore, [String]) {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        var ids: [ItemID] = []
        for (index, guid) in ["a", "b", "c"].enumerated() {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)),
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created))
            ids.append(id)
        }
        let queue = [ids[1], ids[0], ids[2]]
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: queue))
        await model.reloadLibraryRowsForTesting()
        await model.refreshPodcastQueueState()
        // The sort reads titles and publication dates from the model's episodes.
        for (index, guid) in ["a", "b", "c"].enumerated() {
            model.installEpisodeForTesting(WiltedMacEpisode(
                id: ids[index].rawValue, title: "Episode \(guid)", feedTitle: "Show", summary: "", artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready")))
        }
        XCTAssertNotNil(model.playback, "the sort writes through the playback controller")
        XCTAssertEqual(model.podcastQueueIDs, queue.map(\.rawValue))
        return (model, store, ids.map(\.rawValue))
    }

    private func durableQueue(_ store: LocalLibraryStore) async throws -> [String] {
        try await store.podcastQueueState().episodeIDs.map(\.rawValue)
    }

    private func waitForHeldWrite(_ gate: WriteGate) async {
        for _ in 0..<500 {
            if await gate.writes >= 1 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the first write never started")
    }

    private func settle(_ model: WiltedMacModel) async {
        await WiltedMacHeadless.eventually("the sort write settles") { !model.isApplyingLarderSort }
    }

    func testSortChangesDuringOneDelayedWriteLeaveQueueAndCaptionOnTheLastRequest() async throws {
        let (model, store, ids) = try await model("sort-coalescing")
        let (a, b, c) = (ids[0], ids[1], ids[2])
        let gate = WriteGate()
        model.larderSortWriteHookForTesting = { await gate.arrive() }

        model.larderSort = .age                    // younger first: [c, b, a]; its write is held open
        await waitForHeldWrite(gate)
        XCTAssertEqual(model.podcastQueueIDs, [c, b, a])
        model.larderSortDirection = .descending    // older first: [a, b, c]
        model.larderSort = .alphabetical           // descending titles: [c, b, a]
        model.larderSortDirection = .ascending     // the last request: [a, b, c]
        XCTAssertEqual(model.podcastQueueIDs, [a, b, c], "the local order follows every request")

        await gate.open()
        await settle(model)

        let durable = try await durableQueue(store)
        XCTAssertEqual(durable, [a, b, c], "the store holds the last request")
        XCTAssertEqual(model.podcastQueueIDs, durable)
        XCTAssertEqual(model.larderSort.displayName, "Alphabetical", "the caption names the last request")
        XCTAssertEqual(model.larderSortDirection, .ascending)
        let writes = await gate.writes
        XCTAssertEqual(writes, 2, "one write for the held request, one for the newest")
    }

    func testARequestThatEndsWhereTheHeldWriteStartedNeedsNoSecondWrite() async throws {
        let (model, store, ids) = try await model("sort-coalescing-same")
        let gate = WriteGate()
        model.larderSortWriteHookForTesting = { await gate.arrive() }

        model.larderSort = .age
        await waitForHeldWrite(gate)
        model.larderSortDirection = .descending
        model.larderSortDirection = .ascending
        await gate.open()
        await settle(model)

        let durable = try await durableQueue(store)
        XCTAssertEqual(durable, [ids[2], ids[1], ids[0]])
        XCTAssertEqual(model.podcastQueueIDs, durable)
        let writes = await gate.writes
        XCTAssertEqual(writes, 1)
    }

    func testAFailedWriteKeepsTheDurableOrderAndSaysSoWithoutRetrying() async throws {
        let (model, store, ids) = try await model("sort-coalescing-failure")
        let gate = WriteGate()
        model.larderSortWriteHookForTesting = {
            await gate.arrive()
            throw FailingWrite()
        }

        await gate.open()
        model.larderSort = .age
        await settle(model)

        XCTAssertEqual(model.podcastOperationMessage, "The Larder order could not be saved.")
        let durable = try await durableQueue(store)
        XCTAssertEqual(durable, [ids[1], ids[0], ids[2]], "the durable order is untouched")
        XCTAssertEqual(model.podcastQueueIDs, durable, "the list shows the order that is actually saved")
        XCTAssertEqual(model.larderSort, .custom, "the caption names the order the list shows")
        try await Task.sleep(for: .milliseconds(200))
        let writes = await gate.writes
        XCTAssertEqual(writes, 1, "a failed write is reported once, not retried forever")
    }

    func testUnknownStoredSortValuesFallBackToTheDefault() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set("Sideways", forKey: WiltedMacModel.larderSortPreferenceKey)
        preferences.set("upward", forKey: WiltedMacModel.larderSortDirectionPreferenceKey)
        let model = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertEqual(model.larderSort, .custom)
        XCTAssertEqual(model.larderSortDirection, .ascending)
    }

    private func book(_ id: String, title: String) -> WiltedMacEpisode {
        var book = WiltedMacEpisode(
            id: id, title: title, feedTitle: "Audiobook", summary: "Herbert", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 3_600, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Audiobook"))
        book.audiobook = WiltedMacAudiobookDetails(
            author: "Herbert", chapters: [WiltedMacChapter(title: "One", startSeconds: 0)],
            sourceFormat: "audio", volumeIndex: 0, volumeCount: 1)
        book.isReadyMediaAvailable = true
        return book
    }

    func testTheAudiobooksFilterShowsOnlyBooksAndLeavesPlayOrderUnchanged() async throws {
        let (model, _, ids) = try await model("kind-filter")
        model.installEpisodeForTesting(book("book-1", title: "Dune"))
        model.podcastQueueIDs.insert("book-1", at: 1)
        let queue = model.podcastQueueIDs
        XCTAssertEqual(model.larderKind, .all)
        XCTAssertTrue(Set(model.larderFilteredItems.map(\.id)).isSuperset(of: ids + ["book-1"]), "All shows every kind")

        model.larderKind = .audiobooks
        XCTAssertEqual(model.larderFilteredItems.map(\.id), ["book-1"])
        XCTAssertEqual(model.larderSections().flatMap(\.items).map(\.id), ["book-1"])
        XCTAssertEqual(model.podcastQueueIDs, queue, "a presentation filter never reorders what plays")

        model.larderKind = .podcasts
        XCTAssertFalse(model.larderFilteredItems.map(\.id).contains("book-1"))
        XCTAssertEqual(Set(model.larderFilteredItems.map(\.id)), Set(ids))
        XCTAssertEqual(model.podcastQueueIDs, queue)
    }

    func testThePlayingBookStaysVisibleUnderThePodcastsFilter() async throws {
        let (model, _, ids) = try await model("kind-filter-book-playing")
        model.installEpisodeForTesting(book("book-1", title: "Dune"))
        model.podcastQueueIDs.insert("book-1", at: 1)
        model.isPodcastPlayback = false
        model.currentPodcastEpisodeID = "book-1"

        model.larderKind = .podcasts
        let shown = model.larderFilteredItems.map(\.id)
        XCTAssertTrue(shown.contains("book-1"), "the playing audiobook is not hidden by Podcasts")
        XCTAssertEqual(Set(shown), Set(ids + ["book-1"]))
    }

    func testThePlayingPodcastStaysVisibleUnderTheAudiobooksFilter() async throws {
        let (model, _, ids) = try await model("kind-filter-podcast-playing")
        model.installEpisodeForTesting(book("book-1", title: "Dune"))
        model.podcastQueueIDs.insert("book-1", at: 1)
        model.isPodcastPlayback = false
        model.currentPodcastEpisodeID = ids[0]

        model.larderKind = .audiobooks
        let shown = model.larderFilteredItems.map(\.id)
        XCTAssertEqual(Set(shown), Set([ids[0], "book-1"]), "only the playing podcast joins the books")
    }

    func testAlphabeticalOrderingIgnoresLeadingTheAcrossLibraryRows() async throws {
        let (model, store, ids) = try await model("leading-the-sort")
        let queue = model.podcastQueueIDs
        let durableBefore = try await durableQueue(store)
        XCTAssertEqual(queue, [ids[1], ids[0], ids[2]], "the fixture deliberately queues b before a")
        XCTAssertEqual(durableBefore, queue, "establish the actual durable order before comparisons")
        let titles = ["Theory", "Beta", "The AI Daily Brief", "AI Daily Brief", "Episode 10", "Episode 2"]
        let rows = titles.enumerated().map { index, title in
            book("sort-\(index)", title: title)
        }
        for row in rows { model.installEpisodeForTesting(row) }
        let ascending = ["sort-2", "sort-3", "sort-1", "sort-5", "sort-4", "sort-0"]
        XCTAssertEqual(WiltedMacModel.sortedLarderEpisodes(rows, by: .title).map(\.id), ascending)
        model.larderSortDirection = .ascending
        XCTAssertEqual(model.sortedLarderEpisodeIDs(rows.map(\.id), by: .alphabetical), ascending)
        model.larderSortDirection = .descending
        XCTAssertEqual(model.sortedLarderEpisodeIDs(rows.map(\.id), by: .alphabetical),
                       ["sort-0", "sort-4", "sort-5", "sort-1", "sort-2", "sort-3"],
                       "equal keys retain the existing ascending ID tie-break in either direction")
        model.currentPodcastEpisodeID = "sort-1"
        XCTAssertEqual(model.sortedLarderEpisodeIDs(rows.map(\.id), by: .alphabetical)[1], "sort-1",
                       "the current item keeps its queue index")
        XCTAssertEqual(rows.map(\.title), titles, "display titles remain intact")
        XCTAssertEqual(model.podcastQueueIDs, queue)
        let durable = try await durableQueue(store)
        XCTAssertEqual(durable, durableBefore, "comparing presentation orders never applies a queue write")

        let showRows = [book("show-theory", title: "Theory"), book("show-ai", title: "The AI Daily Brief")].map { row in
            WiltedMacEpisode(id: row.id, title: "Same episode", feedTitle: row.title, summary: "", artworkURL: nil,
                             releasedAt: created.date, durationSeconds: 60, playbackSeconds: 0,
                             downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        }
        XCTAssertEqual(WiltedMacModel.sortedLarderEpisodes(showRows, by: .show).map(\.id), ["show-ai", "show-theory"])
        await model.close()
    }

    func testMixedArticleAndEpisodeAlphabeticalSortPreservesDirectionAndIDTies() {
        let episode = book("z-episode", title: "The AI Daily Brief")
        let article = WiltedMacArticle(id: "a-article", title: "AI Daily Brief", source: "Show",
                                      url: URL(string: "https://example.test/article")!, isReady: true,
                                      durationSeconds: 60, createdAt: created.date)
        let theory = book("theory", title: "Theory")
        let ready = section(.playable, [.episode(theory), .episode(episode), .article(article)])
        for direction in [WiltedMacLarderSortDirection.ascending, .descending] {
            let shown = WiltedMacEpisodePresentationSections.displaySections(
                [ready], grouping: .status, sort: .alphabetical, direction: direction)
            XCTAssertEqual(shown.flatMap(\.items).map(\.id),
                           direction == .ascending ? ["a-article", "z-episode", "theory"] : ["theory", "a-article", "z-episode"])
        }
        XCTAssertEqual(ready.items.map(\.title), ["Theory", "The AI Daily Brief", "AI Daily Brief"])
    }

    func testLoadedPodcastAndCombinedArticleSubscriptionsSortByOwnerDisplayTitle() async throws {
        let (model, store, _) = try await model("leading-the-feed-sort")
        for (index, title, alias) in [(0, "Zulu publisher", Optional("The AI Daily Brief")),
                                     (1, "Theory", nil), (2, "Beta", nil)] {
            let url = URL(string: "https://feeds.example.test/title-\(index).xml")!
            let id = try ItemID.derivePodcastFeed(from: url)
            try await store.save(feed: PodcastFeed(itemID: id, canonicalURL: url, title: title, createdAt: created))
            try await store.save(subscription: PodcastSubscription(feedID: id, subscribedAt: created, displayName: alias))
        }
        let loaded = try await model.loadLibrary(from: store).subscriptions
        XCTAssertEqual(loaded.map(\.title), ["The AI Daily Brief", "Beta", "Theory"])
        XCTAssertEqual(loaded.first?.publisherTitle, "Zulu publisher")
        let articleFeed = try ArticleFeed(canonicalURL: URL(string: "https://example.test/posts.xml")!,
                                         title: "Zulu posts", createdAt: created)
        let stored = PodcastSubscription(feedID: articleFeed.itemID, subscribedAt: created, displayName: "the Aardvark")
        let combined = WiltedMacModel.subscriptionRows(loaded, articleFeeds: [articleFeed], stored: [stored])
        XCTAssertEqual(combined.map(\.title), ["the Aardvark", "The AI Daily Brief", "Beta", "Theory"])
        XCTAssertEqual(combined.first?.publisherTitle, "Zulu posts")
        let fallback = WiltedMacModel.subscriptionRows(loaded, articleFeeds: [articleFeed],
            stored: [PodcastSubscription(feedID: articleFeed.itemID, subscribedAt: created)])
        XCTAssertEqual(fallback.last?.title, "Zulu posts", "a feed without an owner alias uses its publisher title")
        await model.close()
    }

    // MARK: One grouped list

    private func article(_ id: String, ready: Bool, minutes: Double = 5, savedAt: TimeInterval = 1_700_000_000) -> WiltedMacArticle {
        WiltedMacArticle(
            id: id, title: "Article \(id)", source: "blog.example.test",
            url: URL(string: "https://blog.example.test/\(id)")!, isReady: ready,
            durationSeconds: ready ? minutes * 60 : nil, createdAt: Date(timeIntervalSince1970: savedAt))
    }

    private func episodeRow(_ id: String, seconds: Double, published: TimeInterval = 1_700_000_000) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "Episode \(id)", feedTitle: "Show", summary: "", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: published), durationSeconds: seconds, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"))
    }

    private func section(_ group: WiltedMacLarderGroup, _ items: [WiltedMacLibraryItem]) -> WiltedMacLarderSection {
        WiltedMacLarderSection(
            id: "status-\(group.rawValue)", title: group.displayName, detail: nil, statusGroup: group, items: items)
    }

    func testStatusGroupsKeepTheFixedOrderReadyActiveDownloadedNotDownloaded() {
        var downloading = episodeRow("downloading", seconds: 60)
        downloading.downloadState = .downloading(received: 1, expected: 2)
        let synthesizing = article("synth", ready: false)
        // The model hands over Ready, Downloaded, Not downloaded, then articles still synthesizing.
        let source = [
            section(.playable, [.episode(episodeRow("ready", seconds: 60)), .article(article("prepared", ready: true))]),
            section(.downloaded, [.episode(episodeRow("near", seconds: 60))]),
            section(.available, [.episode(episodeRow("far", seconds: 60)), .episode(downloading)]),
            WiltedMacLarderSection(id: "status-synthesizing", title: "Active work", detail: nil, statusGroup: nil,
                                   items: [.article(synthesizing)]),
        ]
        let result = WiltedMacEpisodePresentationSections.displaySections(source, grouping: .status)
        XCTAssertEqual(result.map(\.title), ["Ready", "Active work", "Downloaded", "Not downloaded"])
        XCTAssertEqual(result[0].items.map(\.id), ["ready", "prepared"], "a prepared article is Ready")
        XCTAssertEqual(Set(result[1].items.map(\.id)), ["synth", "downloading"], "in-flight work is Active work")
        XCTAssertEqual(result[2].items.map(\.id), ["near"])
        XCTAssertEqual(result[3].items.map(\.id), ["far"])
    }

    func testAnArticleAndAnEpisodeInReadySortTogetherUnderAll() {
        let longEpisode = episodeRow("ep", seconds: 1_800)
        let shortArticle = article("short", ready: true, minutes: 5)
        let midArticle = article("mid", ready: true, minutes: 20)
        let ready = section(.playable, [.episode(longEpisode), .article(midArticle), .article(shortArticle)])

        let byLength = WiltedMacEpisodePresentationSections.displaySections(
            [ready], grouping: .status, sort: .length, direction: .ascending)
        XCTAssertEqual(byLength.first?.items.map(\.id), ["short", "mid", "ep"], "one comparator across row kinds")
        let longest = WiltedMacEpisodePresentationSections.displaySections(
            [ready], grouping: .status, sort: .length, direction: .descending)
        XCTAssertEqual(longest.first?.items.map(\.id), ["ep", "mid", "short"])

        let listening = WiltedMacEpisodePresentationSections.displaySections(
            [ready], grouping: .status, sort: .custom)
        XCTAssertEqual(listening.first?.items.map(\.id).first, "ep", "queued rows lead in listening order")
    }
}
