import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Article feed refresh")
struct ArticleFeedRefreshTests {
    private static let feedURL = URL(string: "https://blog.example.test/feed.xml")!

    private struct Fixture {
        let directory: URL
        let store: LocalLibraryStore
        let feed: ArticleFeed

        init() throws {
            directory = OwnedTestTemp.root.appending(path: "article-feed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try LocalLibraryStore(url: directory.appending(path: "library.sqlite"))
            feed = try ArticleFeed(canonicalURL: ArticleFeedRefreshTests.feedURL, title: "The Blog",
                                   createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        /// A preparation double: saves the article the way the coordinator does, under `canonical(link)`.
        func preparer(canonical: @escaping @Sendable (URL) -> URL, record: Recorder) -> ArticleFeedRefresh.Prepare {
            let store = store
            return { link in
                await record.add(link)
                let target = canonical(link)
                let id = try ItemID.derive(from: target)
                try await store.save(article: Article(itemID: id, canonicalURL: target, title: "Saved",
                                                      source: "blog.example.test", createdAt: Timestamp(Date())))
                return id
            }
        }
    }

    private actor Recorder {
        private(set) var links: [URL] = []
        func add(_ url: URL) { links.append(url) }
    }

    private static let xml = """
    <rss version="2.0"><channel><title>The Blog</title>
    <item><guid>g1</guid><title>First post</title><link>https://blog.example.test/p/1?utm=feed</link>
    <pubDate>Mon, 05 Jan 2026 12:00:00 GMT</pubDate></item>
    <item><guid>g2</guid><title>Second post</title><link>https://blog.example.test/p/2</link>
    <pubDate>Tue, 06 Jan 2026 12:00:00 GMT</pubDate></item>
    <item><title>No link</title></item>
    </channel></rss>
    """

    private func document() throws -> ArticleFeedDocument {
        try ArticleFeedParser.parse(Data(Self.xml.utf8), feedURL: Self.feedURL)
    }

    @Test func parserListsLinkedPostsNewestFirstAndSkipsUnlinkedOnes() throws {
        let doc = try document()
        #expect(doc.title == "The Blog")
        #expect(doc.items.map(\.title) == ["Second post", "First post"])
        #expect(doc.items.last?.link.absoluteString == "https://blog.example.test/p/1?utm=feed")
    }

    @Test func atomEntriesAreRead() throws {
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Blog</title>
        <entry><id>tag:a,1</id><title>Entry</title><link rel="alternate" href="/e/1"/>
        <published>2026-01-05T12:00:00Z</published></entry></feed>
        """
        let doc = try ArticleFeedParser.parse(Data(atom.utf8), feedURL: Self.feedURL)
        #expect(doc.items.map(\.link.absoluteString) == ["https://blog.example.test/e/1"])
        #expect(doc.items.first?.publishedAt != nil)
    }

    @Test func keptItemIsSavedWithItsFeedIDAndQueuedForPreparation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(articleFeed: fixture.feed)
        try await fixture.store.save(feedAutomationPolicy: FeedAutomationPolicy(autoKeep: .on), for: fixture.feed.itemID)
        let recorder = Recorder()
        let refresh = ArticleFeedRefresh(store: fixture.store)
        let result = try await refresh.refresh(
            feed: fixture.feed, document: document(),
            prepare: fixture.preparer(canonical: { $0 }, record: recorder)
        )

        #expect(await recorder.links.map(\.absoluteString).sorted()
                == ["https://blog.example.test/p/1?utm=feed", "https://blog.example.test/p/2"])
        #expect(result.prepared.count == 2)
        #expect(result.offered.isEmpty)
        let articles = try await fixture.store.articleIDs(forFeed: fixture.feed.itemID)
        #expect(articles.count == 2)
        for id in articles { #expect(try await fixture.store.feedID(forArticle: id) == fixture.feed.itemID) }
    }

    @Test func postsAreOfferedWhenNothingKeepsThemAndSkipRulesDecideThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(articleFeed: fixture.feed)
        let skipSecond = EpisodeMatchRule(field: .title, includePattern: "Second", action: .skip)
        try await fixture.store.replaceEpisodeMatchRules(EpisodeMatchRules(rules: [skipSecond]), for: fixture.feed.itemID)
        let recorder = Recorder()
        let refresh = ArticleFeedRefresh(store: fixture.store)
        let result = try await refresh.refresh(
            feed: fixture.feed, document: document(), prepare: fixture.preparer(canonical: { $0 }, record: recorder)
        )
        #expect(result.offered.map(\.title) == ["First post"])
        #expect(result.skipped.map(\.title) == ["Second post"])
        #expect(await recorder.links.isEmpty)

        let again = try await refresh.refresh(feed: fixture.feed, document: document(), prepare: nil)
        #expect(again.offered.map(\.title) == ["First post"])
        #expect(again.alreadyConsumedCount == 1)
    }

    @Test func itemWhoseCanonicalURLDiffersFromItsLinkIsOfferedOnceAndYieldsOneArticle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(articleFeed: fixture.feed)
        let single = try ArticleFeedParser.parse(Data(Self.xml.utf8), feedURL: Self.feedURL).items.filter { $0.title == "First post" }
        let doc = ArticleFeedDocument(title: "The Blog", author: nil, items: single)
        let recorder = Recorder()
        let canonical: @Sendable (URL) -> URL = { _ in URL(string: "https://blog.example.test/p/1")! }
        let refresh = ArticleFeedRefresh(store: fixture.store)

        // The reader keeps it by hand; the feed link carries tracking the page's canonical URL drops.
        let first = try await refresh.refresh(feed: fixture.feed, document: doc, prepare: nil)
        #expect(first.offered.count == 1)
        #expect(try await refresh.keep(single[0], feed: fixture.feed, prepare: fixture.preparer(canonical: canonical, record: recorder)))

        let second = try await refresh.refresh(
            feed: fixture.feed, document: doc, prepare: fixture.preparer(canonical: canonical, record: recorder)
        )
        #expect(second.offered.isEmpty)
        #expect(second.prepared.isEmpty)
        #expect(second.alreadyConsumedCount == 1)
        #expect(await recorder.links.count == 1)
        #expect(try await fixture.store.articles().count == 1)
        #expect(try await fixture.store.articleIDs(forFeed: fixture.feed.itemID).count == 1)
    }

    @Test func aFeedThatRepeatsAPostOffersItOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(articleFeed: fixture.feed)
        let first = try ArticleFeedParser.parse(Data(Self.xml.utf8), feedURL: Self.feedURL).items[0]
        let doc = ArticleFeedDocument(title: "The Blog", author: nil, items: [first, first])
        let result = try await ArticleFeedRefresh(store: fixture.store).refresh(feed: fixture.feed, document: doc, prepare: nil)
        #expect(result.offered.count == 1)
        #expect(result.alreadyConsumedCount == 1)
    }

    @Test func parserRefusesEntityDeclarationsAnywhereInThePayload() throws {
        let padding = String(repeating: " ", count: 20_000)
        let late = "<?xml version=\"1.0\"?>\(padding)<!DOCTYPE rss [<!ENTITY a \"aaaa\">]><rss version=\"2.0\"><channel><title>&a;</title></channel></rss>"
        #expect(throws: ArticleFeedParseError.externalEntity) {
            try ArticleFeedParser.parse(Data(late.utf8), feedURL: Self.feedURL)
        }
        let subsetOnly = "\(padding)<!DOCTYPE rss [ ]><rss version=\"2.0\"><channel><title>T</title></channel></rss>"
        #expect(throws: ArticleFeedParseError.externalEntity) {
            try ArticleFeedParser.parse(Data(subsetOnly.utf8), feedURL: Self.feedURL)
        }
    }

    @Test func pageThatIsAlreadyAnArticleIsNeverOffered() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(articleFeed: fixture.feed)
        let link = URL(string: "https://blog.example.test/p/2")!
        try await fixture.store.save(article: Article(itemID: ItemID.derive(from: link), canonicalURL: link, title: "Mine",
                                                      source: "blog.example.test", createdAt: Timestamp(Date())))
        let result = try await ArticleFeedRefresh(store: fixture.store)
            .refresh(feed: fixture.feed, document: document(), prepare: nil)
        #expect(result.offered.map(\.title) == ["First post"])
        #expect(result.alreadyConsumedCount == 1)
    }

    @Test func failedPreparationLeavesThePostUndecidedForTheNextRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(articleFeed: fixture.feed)
        try await fixture.store.save(feedAutomationPolicy: FeedAutomationPolicy(autoKeep: .on), for: fixture.feed.itemID)
        let refresh = ArticleFeedRefresh(store: fixture.store)
        let failing: ArticleFeedRefresh.Prepare = { _ in throw ArticlePreparationError.failed("offline") }
        let result = try await refresh.refresh(feed: fixture.feed, document: document(), prepare: failing)
        #expect(result.failed.count == 2)
        #expect(try await fixture.store.articles().isEmpty)
        let retry = try await refresh.refresh(feed: fixture.feed, document: document(), prepare: nil)
        #expect(retry.offered.count == 2)
    }

    @Test func newsFlagRoundTripsWithoutDisturbingThePolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(articleFeed: fixture.feed)
        #expect(try await fixture.store.isNews(feedID: fixture.feed.itemID) == false)
        try await fixture.store.save(isNews: true, feedID: fixture.feed.itemID)
        try await fixture.store.save(feedAutomationPolicy: FeedAutomationPolicy(autoKeep: .on), for: fixture.feed.itemID)
        #expect(try await fixture.store.isNews(feedID: fixture.feed.itemID))
        #expect(try await fixture.store.feedAutomationPolicy(for: fixture.feed.itemID).autoKeep == .on)
        #expect(try await fixture.store.articleFeeds().map(\.itemID) == [fixture.feed.itemID])
        #expect(try await fixture.store.podcastFeeds().isEmpty)
    }
}
