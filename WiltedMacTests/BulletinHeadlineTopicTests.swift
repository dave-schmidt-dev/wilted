import Foundation
import WiltedLibrary
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Headlines about skipped topics are never read: sports by default, plus the listener's own words.
final class BulletinHeadlineTopicTests: XCTestCase {
    private let sports = HeadlineTopicFilter(skipSports: true)

    @MainActor
    private func makeStore(_ suffix: String) throws -> LocalLibraryStore {
        let directory = wiltedTemporaryDirectory(suffix)
        return try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
    }

    // MARK: Filter

    func testSportsAreRecognisedByTitleCategoryOrSection() {
        XCTAssertTrue(sports.skips(title: "Arsenal go top of the Premier League after late winner"))
        XCTAssertTrue(sports.skips(title: "NFL: Chiefs beat Bills in overtime"))
        XCTAssertTrue(sports.skips(title: "Djokovic through to Wimbledon final"))
        XCTAssertTrue(sports.skips(title: "Late winner settles derby", categories: ["Football"]))
        XCTAssertTrue(sports.skips(title: "Late winner settles derby",
                                   link: URL(string: "https://www.bbc.co.uk/sport/football/123")))
    }

    func testOrdinaryNewsIsNotMistakenForSports() {
        for title in ["Senate passes sweeping climate bill", "Golfo de México storm forces evacuations",
                      "Interest rates held as inflation eases", "Phoenix rises from the ashes of the old mill",
                      "Supporters rally outside parliament"] {
            XCTAssertFalse(sports.skips(title: title, link: URL(string: "https://news.example.test/world/1"),
                                        categories: ["World", "Politics"]), title)
        }
    }

    func testSportsSourceDetectionDoesNotDropMixedNewsSources() {
        XCTAssertTrue(HeadlineTopicFilter.isRecognizableSportsSource(
            title: "Sky Sports", url: URL(string: "https://feeds.example.test/rss")!))
        XCTAssertTrue(HeadlineTopicFilter.isRecognizableSportsSource(
            title: "League wire", url: URL(string: "https://feeds.example.test/football/rss.xml")!))
        XCTAssertFalse(HeadlineTopicFilter.isRecognizableSportsSource(
            title: "Local News, Weather and Sports", url: URL(string: "https://feeds.example.test/rss.xml")!))
        XCTAssertFalse(HeadlineTopicFilter.isRecognizableSportsSource(
            title: "World News", url: URL(string: "https://feeds.example.test/world/rss.xml")!))
    }

    @MainActor
    func testCategoryOnlySportsMarkerSurvivesCatalogRestartLocally() throws {
        let file = wiltedTemporaryDirectory("headline-sports-marker").appendingPathComponent("catalog.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "category-only", title: "Close contest ends after extra round", publisherID: "feed-1",
            publisherName: "Mixed Wire", link: URL(string: "https://story.example.test/extra-round"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let writer = WiltedMacHeadlineCatalogStore(fileURL: file, now: { now })
        let before = try writer.mergeRecent([story], classifiedSportsStoryIDs: [story.id], at: now)

        let reopened = WiltedMacHeadlineCatalogStore(fileURL: file, now: { now })
        let after = try reopened.pruneRecent(matching: { _ in false }, at: now)

        XCTAssertEqual(before.revision + 1, after.revision)
        XCTAssertTrue(after.recent.isEmpty, "category-only cached story is removed after restart")
        XCTAssertTrue(after.expiredIdentities.contains(where: { $0.id == story.id }))
    }

    func testListenerWordsMatchWholeWordsIgnoringCaseAndAccents() {
        let filter = HeadlineTopicFilter(skipSports: false, words: ["Royal family", "café"])
        XCTAssertTrue(filter.skips(title: "ROYAL FAMILY attends ceremony"))
        XCTAssertTrue(filter.skips(title: "New cafe opens downtown"))
        XCTAssertTrue(filter.skips(title: "Ceremony held", categories: ["Royal Family"]))
        XCTAssertFalse(filter.skips(title: "Royal visit to the family farm"), "a phrase needs its words together")
        XCTAssertFalse(filter.skips(title: "Cafeteria prices rise"), "a word matches whole words only")
        XCTAssertFalse(filter.skips(title: "NFL: Chiefs beat Bills"), "sports are not skipped when that is off")
    }

    // MARK: Producer

    func testASportsPostIsNeverReadAndIsCounted() async throws {
        let h = BulletinProducerHarness()
        h.settings.topics = HeadlineTopicFilter(skipSports: true)
        let producer = h.producer()
        await producer.poll()  // baseline
        h.items = [
            NewsHeadlineCandidate(id: "s1", feedTitle: "BBC News", title: "Premier League: Arsenal beat Chelsea",
                                  publishedAt: h.now.addingTimeInterval(-60)),
            NewsHeadlineCandidate(id: "s2", feedTitle: "BBC News", title: "Late winner settles derby",
                                  publishedAt: h.now.addingTimeInterval(-90),
                                  link: URL(string: "https://www.bbc.co.uk/sport/football/1")),
            NewsHeadlineCandidate(id: "n1", feedTitle: "BBC News", title: "Parliament approves new budget",
                                  publishedAt: h.now.addingTimeInterval(-300)),
        ]
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:n1"], "the older news post is read, not sport")
        let status = await producer.status
        XCTAssertEqual(status.skippedHeadlineCount, 2)
    }

    func testWithSportsAllowedAllEligiblePostsAreRead() async throws {
        let h = BulletinProducerHarness()
        let producer = h.producer()
        await producer.poll()
        h.items = [
            NewsHeadlineCandidate(id: "s1", feedTitle: "BBC News", title: "Premier League: Arsenal beat Chelsea",
                                  publishedAt: h.now.addingTimeInterval(-60)),
            NewsHeadlineCandidate(id: "n1", feedTitle: "BBC News", title: "Parliament approves new budget",
                                  publishedAt: h.now.addingTimeInterval(-300)),
        ]
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:s1", "headline:n1"])
        let status = await producer.status
        XCTAssertEqual(status.skippedHeadlineCount, 0)
    }

    // MARK: Settings

    func testSportsAreSkippedByDefaultIncludingInOlderSavedSettings() throws {
        XCTAssertTrue(WiltedAutomationSettings.defaults.skipSportsHeadlines)
        let legacy = #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true}"#
        let decoded = try JSONDecoder().decode(WiltedAutomationSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.skipSportsHeadlines)
        XCTAssertEqual(decoded.skippedHeadlineWords, [])
    }

    func testListenerWordsAreCleanedAndSurviveSaving() throws {
        let settings = WiltedAutomationSettings.defaults.updatingReports {
            $0.skipSportsHeadlines = false
            $0.skippedHeadlineWords = ["  royals ", "", "Royals", "crypto"]
        }
        XCTAssertEqual(settings.skippedHeadlineWords, ["royals", "crypto"])
        let round = try JSONDecoder().decode(WiltedAutomationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(round.skipSportsHeadlines)
        XCTAssertEqual(round.skippedHeadlineWords, ["royals", "crypto"])
    }

    func testTheSkippedCountReadsPlainly() {
        XCTAssertNil(WiltedMacReportsCard.skippedNote(0))
        XCTAssertEqual(WiltedMacReportsCard.skippedNote(1), "1 current headline is skipped by these topics.")
        XCTAssertEqual(WiltedMacReportsCard.skippedNote(4), "4 current headlines are skipped by these topics.")
    }

    // MARK: Feed categories

    @MainActor
    func testRecognizedSportsSourcesAreExcludedBeforeFetchButMixedFeedsStillLoad() async throws {
        actor RequestSpyLoader: PodcastFeedLoading {
            private var requested: [URL] = []

            func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
                requested.append(url)
                let xml = """
                <rss version="2.0"><channel><title>Wire</title>
                <item><guid>general-1</guid><title>Local council approves plan</title>
                <link>https://story.example.test/general</link><category>Local</category></item>
                <item><guid>category-only-1</guid><title>Close contest ends after extra round</title>
                <link>https://story.example.test/category-only</link><category>Sport</category></item>
                </channel></rss>
                """
                return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(xml.utf8))
            }

            func requestedURLs() -> [URL] { requested }
        }

        let sportsURL = URL(string: "https://feeds.example.test/rss/sports.xml")!
        let worldURL = URL(string: "https://feeds.example.test/world/rss.xml")!
        let mixedURL = URL(string: "https://feeds.example.test/local/rss.xml")!
        let store = try makeStore("sports-source-requests")
        for (url, title) in [
            (sportsURL, "Sports Wire"),
            (worldURL, "World Wire"),
            (mixedURL, "Local News, Weather and Sports")
        ] {
            let feed = try ArticleFeed(canonicalURL: url, title: title, createdAt: Timestamp(Date()))
            try await store.save(articleFeed: feed)
            try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(Date())))
            try await store.save(isNews: true, feedID: feed.itemID)
        }

        let filter = HeadlineTopicFilter(skipSports: true)
        let selection = try await NewsHeadlineCandidateReader.selectHeadlineFeeds(in: store, topics: filter)
        XCTAssertEqual(Set(selection.feeds.map(\.canonicalURL)), Set([worldURL, mixedURL]))
        XCTAssertEqual(selection.excludedSportsFeedIDs.count, 1)

        let loader = RequestSpyLoader()
        let supply = try await NewsHeadlineCandidateReader.read(
            in: store, using: PodcastFeedClient(loader: loader), topics: filter)
        let requestedURLs = await loader.requestedURLs()
        XCTAssertEqual(Set(requestedURLs), Set([worldURL, mixedURL]))
        XCTAssertFalse(requestedURLs.contains(sportsURL), "sports-only source must be skipped before fetching")
        XCTAssertTrue(supply.candidates.contains(where: { $0.categories == ["Sport"] }),
                      "mixed-source candidates retain categories for catalog filtering")
    }

    @MainActor
    func testAutomaticRefreshDoesNotFetchRecognizedSportsHeadlineFeed() async throws {
        actor RequestSpyLoader: PodcastFeedLoading {
            private(set) var requestCount = 0

            func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
                requestCount += 1
                throw URLError(.unsupportedURL)
            }

            func count() -> Int { requestCount }
        }

        let url = URL(string: "https://feeds.example.test/sports/rss.xml")!
        let store = try makeStore("automatic-sports-feed-store")
        let feed = try ArticleFeed(canonicalURL: url, title: "Sky Sports News", createdAt: Timestamp(Date()))
        try await store.save(articleFeed: feed)
        try await store.save(isNews: true, feedID: feed.itemID)
        let loader = RequestSpyLoader()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("automatic-sports-feed"),
            podcastFeedClient: PodcastFeedClient(loader: loader),
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.updateAutomationSettings { settings in
            settings.updatingReports { $0.skipSportsHeadlines = true }
        }
        model.store = store

        let claimed = try await model.automaticRefresh(url, claimingNewest: 1)
        let requestCount = await loader.count()

        XCTAssertTrue(claimed.isEmpty)
        XCTAssertEqual(requestCount, 0, "automatic refresh excludes the known sports Headlines feed before loading it")
    }

    @MainActor
    func testMutedHeadlineCandidatesAreFilteredBeforeCatalogMerge() async throws {
        actor CandidateLoader: PodcastFeedLoading {
            func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
                let xml = """
                <rss version="2.0"><channel><title>Wire</title>
                <item><guid>new-story</guid><title>City council approves plan</title>
                <link>https://story.example.test/new-story</link></item>
                </channel></rss>
                """
                return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(xml.utf8))
            }
        }

        let now = Date()
        let url = URL(string: "https://feeds.example.test/local.xml")!
        let store = try makeStore("muted-headline-source")
        let feed = try ArticleFeed(canonicalURL: url, title: "Wire", createdAt: Timestamp(now))
        try await store.save(articleFeed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(now)))
        try await store.save(isNews: true, feedID: feed.itemID)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("muted-headline-model"),
            podcastFeedClient: PodcastFeedClient(loader: CandidateLoader()),
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.store = store

        let seed = try LibraryHeadlineStory(
            id: "existing-story", title: "An older local story", publisherID: feed.itemID.rawValue,
            publisherName: feed.title, link: URL(string: "https://story.example.test/existing"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        _ = try model.headlineCatalogStore.mergeRecent([seed], at: now)
        let muteResult = try model.headlineCatalogStore.setPublisherMuted(
            id: feed.itemID.rawValue, name: feed.title, isMuted: true,
            basedOnRevision: 0, commandID: "mute-wire", at: now)
        XCTAssertEqual(muteResult, .applied)

        let candidates = try await model.bulletinHub.newsCandidates()
        let projection = try model.headlineCatalogStore.projection(at: now)

        XCTAssertTrue(candidates.isEmpty, "muted source candidates are not returned to the producer")
        XCTAssertEqual(projection.recent.map(\.id), [seed.id], "muted source candidates never enter Recent")
    }

    @MainActor
    func testExplicitSportsHeadlineSubscriptionStillLoadsTheFeed() async throws {
        actor RequestSpyLoader: PodcastFeedLoading {
            private(set) var requestCount = 0

            func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
                requestCount += 1
                let xml = """
                <rss version="2.0"><channel><title>Sky Sports</title>
                <item><guid>story-1</guid><title>Late match result</title>
                <link>https://story.example.test/match</link><category>Sport</category></item>
                </channel></rss>
                """
                return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(xml.utf8))
            }

            func count() -> Int { requestCount }
        }

        let url = URL(string: "https://feeds.example.test/sports/rss.xml")!
        let store = try makeStore("explicit-sports-subscription")
        let loader = RequestSpyLoader()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("explicit-sports-model"),
            podcastFeedClient: PodcastFeedClient(loader: loader),
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.updateAutomationSettings { settings in
            settings.updatingReports { $0.skipSportsHeadlines = true }
        }

        let result = try await model.refreshArticleFeed(
            url: url, subscribing: true, store: store, isHeadlineSource: true)
        let requestCount = await loader.count()
        let isNews = try await store.isNews(feedID: result.feedID)

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(isNews)
    }

    @MainActor
    func testSportsToggleCleansCategoryOnlyCacheAndKeepsNotebookSave() async throws {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("headline-sports-toggle"),
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.updateAutomationSettings { settings in
            settings.updatingReports { $0.skipSportsHeadlines = false }
        }
        let state = model.headlineCatalogState
        let sportsCandidate = NewsHeadlineCandidate(
            id: "category-only-sports", feedTitle: "Mixed Wire", feedID: "feed-1",
            title: "Close contest ends after an extra round", publishedAt: now,
            link: URL(string: "https://story.example.test/extra-round"), categories: ["Sport"])
        let generalCandidate = NewsHeadlineCandidate(
            id: "general-news", feedTitle: "Mixed Wire", feedID: "feed-1",
            title: "Local council approves new plan", publishedAt: now,
            link: URL(string: "https://story.example.test/council"), categories: ["Local"])
        try state.mergeCandidates([sportsCandidate, generalCandidate], at: now)

        let savedSports = try XCTUnwrap(state.projection?.recent.first(where: { $0.id == sportsCandidate.id }))
        XCTAssertEqual(try model.headlineCatalogStore.setSaved(
            story: savedSports, isSaved: true, basedOnRevision: savedSports.savedRevision,
            commandID: "save-category-only-sports", at: now), .applied)
        state.refresh(at: now)

        model.updateAutomationSettings { settings in
            settings.updatingReports { $0.skipSportsHeadlines = true }
        }
        XCTAssertEqual(state.projection?.recent.map(\.id), [generalCandidate.id])
        XCTAssertEqual(state.projection?.saved.map(\.id), [sportsCandidate.id], "Notebook keeps saved sports stories")

        model.updateAutomationSettings { settings in
            settings.updatingReports { $0.skipSportsHeadlines = false }
        }
        try state.mergeCandidates([sportsCandidate, generalCandidate], at: now.addingTimeInterval(60))
        XCTAssertEqual(Set(state.projection?.recent.map(\.id) ?? []), [sportsCandidate.id, generalCandidate.id])
        XCTAssertEqual(state.projection?.saved.map(\.id), [sportsCandidate.id])
    }

    func testRSSAndAtomCategoriesAreRead() throws {
        let rss = """
        <rss version="2.0"><channel><title>Wire</title><item><title>Derby</title>
        <link>https://news.example.test/a</link><category>Sport</category><category>Football</category></item>
        </channel></rss>
        """
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Wire</title><entry><title>Derby</title>
        <link href="https://news.example.test/b"/><category term="Sport"/></entry></feed>
        """
        let feedURL = URL(string: "https://news.example.test/feed")!
        XCTAssertEqual(try ArticleFeedParser.parse(Data(rss.utf8), feedURL: feedURL).items.first?.categories,
                       ["Sport", "Football"])
        XCTAssertEqual(try ArticleFeedParser.parse(Data(atom.utf8), feedURL: feedURL).items.first?.categories, ["Sport"])
    }
}
