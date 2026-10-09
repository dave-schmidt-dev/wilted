import Foundation
import Testing
@testable import WiltedCatalog

@Suite("Add query")
struct AddQueryTests {
    private let show = PodcastCatalogShow(collectionID: 1, title: "Show", feedURL: URL(string: "https://feeds.test/rss")!)

    @Test func emptyAndWhitespaceTextIsEmpty() {
        #expect(AddQuery.parse("") == .empty)
        #expect(AddQuery.parse("  \n\t ") == .empty)
        var query = AddQuery()
        #expect(query.begin("   ") == .none)
        #expect(query.state == .idle)
    }

    @Test func httpsLinkAndBareDomainBecomeLinks() {
        #expect(AddQuery.parse(" https://example.com/a?b=1 ") == .link(URL(string: "https://example.com/a?b=1")!))
        #expect(AddQuery.parse("example.com/feed.xml") == .link(URL(string: "https://example.com/feed.xml")!))
    }

    @Test func textWithSpaceAndNoSchemeIsASearch() {
        #expect(AddQuery.parse("the daily.show") == .search("the daily.show"))
        #expect(AddQuery.parse("https://example.com two") == .search("https://example.com two"))
        #expect(AddQuery.parse("Hard Fork") == .search("Hard Fork"))
    }

    @Test func dotlessOrNonDomainWordsAreSearches() {
        #expect(AddQuery.parse("serial") == .search("serial"))
        #expect(AddQuery.parse("Mr.") == .search("Mr."))
        #expect(AddQuery.parse("v1.2") == .search("v1.2"))
    }

    @Test func nonHTTPSAndCredentialLinksAreUnsupported() {
        for text in ["http://example.com/a", "ftp://example.com/a", "https://user:pw@example.com/a", "https://user@example.com"] {
            guard case .unsupported = AddQuery.parse(text) else {
                Issue.record("expected unsupported for \(text)")
                continue
            }
        }
    }

    @Test func linkClassifiesToArticleAndFeed() {
        let url = URL(string: "https://example.com/a")!
        var query = AddQuery()
        #expect(query.begin("https://example.com/a") == .classify(url, generation: 1))
        #expect(query.state == .classifying)
        query.apply(.init(generation: 1, outcome: .classified(.article)))
        #expect(query.state == .article(url))
        #expect(query.begin("https://example.com/a") == .classify(url, generation: 2))
        query.apply(.init(generation: 2, outcome: .classified(.podcastFeed)))
        #expect(query.state == .podcastFeed(url))
        _ = query.begin("https://example.com/a")
        query.apply(.init(generation: 3, outcome: .classified(.unsupported("Not a page"))))
        #expect(query.state == .unsupported("Not a page"))
    }

    @Test func searchMarksAlreadyFollowedShows() {
        var query = AddQuery()
        #expect(query.begin("hard fork") == .search("hard fork", generation: 1))
        #expect(query.state == .searching)
        query.apply(.init(generation: 1, outcome: .searched([show])), isFollowed: { $0.collectionID == 1 })
        #expect(query.state == .results([.init(show: show, alreadyFollowed: true)]))
    }

    @Test func unsupportedLinkNeedsNoRequest() {
        var query = AddQuery()
        #expect(query.begin("http://example.com") == .none)
        guard case .unsupported = query.state else { Issue.record("expected unsupported"); return }
    }

    @Test func staleGenerationAnswersAreDropped() {
        var query = AddQuery()
        _ = query.begin("first")
        _ = query.begin("second")
        query.apply(.init(generation: 1, outcome: .searched([show])))
        #expect(query.state == .searching)
        query.apply(.init(generation: 1, outcome: .failed))
        #expect(query.state == .searching)
        query.apply(.init(generation: 2, outcome: .searched([])))
        #expect(query.state == .results([]))
        // Clearing the text also invalidates anything in flight.
        _ = query.begin("third")
        _ = query.begin("")
        query.apply(.init(generation: 3, outcome: .searched([show])))
        #expect(query.state == .idle)
    }

    @Test func failureIsUnreachableAndCancelIsCancelled() {
        var query = AddQuery()
        _ = query.begin("show")
        query.apply(.init(generation: 1, outcome: .failed))
        #expect(query.state == .unreachable)
        _ = query.begin("show")
        query.cancel()
        #expect(query.state == .cancelled)
        query.apply(.init(generation: 2, outcome: .searched([show])))
        #expect(query.state == .cancelled)
    }

    @Test func runMapsClosuresToAnswers() async {
        struct Boom: Error {}
        let url = URL(string: "https://example.com/a")!
        let ok = await AddQuery.run(.classify(url, generation: 4), classify: { _ in .podcastFeed }, search: { _ in [] })
        #expect(ok == .init(generation: 4, outcome: .classified(.podcastFeed)))
        let found = await AddQuery.run(.search("x", generation: 5), classify: { _ in .article }, search: { _ in [show] })
        #expect(found == .init(generation: 5, outcome: .searched([show])))
        let failed = await AddQuery.run(.search("x", generation: 6), classify: { _ in .article }, search: { _ in throw Boom() })
        #expect(failed == .init(generation: 6, outcome: .failed))
        let cancelled = await AddQuery.run(.search("x", generation: 7), classify: { _ in .article }, search: { _ in throw CancellationError() })
        #expect(cancelled == .init(generation: 7, outcome: .cancelled))
    }

    @Test func cancelledAnswerSetsCancelled() {
        var query = AddQuery()
        _ = query.begin("show")
        query.apply(.init(generation: 1, outcome: .cancelled))
        #expect(query.state == .cancelled)
    }
}
