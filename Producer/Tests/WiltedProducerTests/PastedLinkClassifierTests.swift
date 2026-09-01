import Foundation
import Testing
@testable import WiltedProducer

@Suite("Pasted link classifier")
struct PastedLinkClassifierTests {
    private let pageURL = URL(string: "https://example.test/posts/Why-Ads")!

    @Test func unambiguousFeedExtensionsSkipTheFetch() async throws {
        let loader = RefusingLoader()
        let classifier = PastedLinkClassifier(loader: loader)
        for address in ["https://a.test/feed.xml", "https://a.test/Feed.RSS", "https://a.test/x.atom"] {
            #expect(try await classifier.classify(URL(string: address)!) == .podcastFeed)
        }
    }

    /// The trap this rule exists to avoid: a path that merely reads like a feed.
    /// Sniffing the body sends it to the article pipeline where it belongs,
    /// instead of handing an HTML page to the XML parser.
    @Test func aPathThatOnlyLooksLikeAFeedIsStillSniffed() async throws {
        let kind = try await classifier(body: "<!doctype html><html><body>Feed your brain</body></html>")
            .classify(URL(string: "https://example.test/feed-your-brain")!)
        #expect(kind == .article)
    }

    @Test func recognizesEachFeedRootElement() async throws {
        for root in ["<rss version=\"2.0\"><channel></channel></rss>",
                     "<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>",
                     "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"></rdf:RDF>"] {
            let kind = try await classifier(body: "<?xml version=\"1.0\"?>\(root)").classify(pageURL)
            #expect(kind == .podcastFeed)
        }
    }

    /// A feed may name HTML in a namespace or an escaped payload, so presence
    /// of "<html" cannot outrank a feed root that appears before it.
    @Test func aFeedCarryingHTMLInItsPayloadIsStillAFeed() async throws {
        let kind = try await classifier(body: """
        <?xml version="1.0"?><rss><channel><item>
        <description>&lt;html&gt;<html>escaped page</html></description>
        </item></channel></rss>
        """).classify(pageURL)
        #expect(kind == .podcastFeed)
    }

    /// And the reverse: a page that mentions a feed format in its head is an
    /// article, because its own root element comes first.
    @Test func aPageAdvertisingAFeedStaysAnArticleAndOffersTheFeed() async throws {
        let kind = try await classifier(body: """
        <!doctype html><html><head>
        <link rel="stylesheet" href="/site.css">
        <link rel="alternate" type="application/rss+xml" title="Feed" href="/Posts/feed.xml">
        </head><body>Words</body></html>
        """).classify(pageURL)
        #expect(kind == .articleAdvertisingFeed(URL(string: "https://example.test/Posts/feed.xml")!))
    }

    /// The advertised href keeps its case. Lowercasing the document to compare
    /// tag names would silently break every case-sensitive feed path.
    @Test func theAdvertisedFeedURLKeepsItsPathCase() {
        let resolved = PastedLinkClassifier.advertisedFeedURL(
            inHTML: "<LINK REL=\"Alternate\" TYPE=\"Application/Atom+XML\" HREF=\"https://a.test/Feeds/MainFeed\">",
            baseURL: pageURL
        )
        #expect(resolved?.absoluteString == "https://a.test/Feeds/MainFeed")
    }

    /// `type=` must not be read out of `data-type=`, and an insecure or
    /// non-feed alternate is not an offer.
    @Test func ignoresAlternatesThatAreNotSecureFeeds() {
        let cases = [
            "<link rel=\"alternate\" data-type=\"application/rss+xml\" href=\"https://a.test/f.xml\">",
            "<link rel=\"alternate\" type=\"application/rss+xml\" href=\"http://a.test/insecure.xml\">",
            "<link rel=\"alternate\" type=\"text/html\" href=\"https://a.test/amp\">",
            "<link rel=\"preload\" type=\"application/atom+xml\" href=\"https://a.test/f.xml\">"
        ]
        for html in cases {
            #expect(PastedLinkClassifier.advertisedFeedURL(inHTML: html, baseURL: pageURL) == nil, "\(html)")
        }
    }

    @Test func rejectsAddressesThatAreNotPlainHTTPS() async {
        for address in ["http://a.test/feed.xml", "https://user:secret@a.test/feed.xml", "ftp://a.test/feed.xml"] {
            await expectInvalidURL(PastedLinkClassifier(loader: RefusingLoader()), URL(string: address)!)
        }
    }

    @Test func reportsAnUnreachableAddressRatherThanGuessing() async {
        let classifier = PastedLinkClassifier(loader: StatusLoader(statusCode: 404))
        do {
            _ = try await classifier.classify(pageURL)
            Issue.record("Expected the classifier to refuse a 404")
        } catch let error as PastedLinkClassifierError {
            #expect(error == .unreachable("status 404"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// Nothing recognizable is an article: the article pipeline reports what it
    /// finds, whereas the feed parser would fail on any non-XML body.
    @Test func anUnrecognizableBodyFallsBackToArticle() async throws {
        #expect(try await classifier(body: "plain text, no markup").classify(pageURL) == .article)
    }

    private func classifier(body: String) -> PastedLinkClassifier {
        PastedLinkClassifier(loader: BodyLoader(body: Data(body.utf8), url: pageURL))
    }

    private func expectInvalidURL(_ classifier: PastedLinkClassifier, _ url: URL) async {
        do {
            _ = try await classifier.classify(url)
            Issue.record("Expected \(url) to be refused")
        } catch let error as PastedLinkClassifierError {
            #expect(error == .invalidURL)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct BodyLoader: PodcastFeedLoading {
    let body: Data
    let url: URL
    func load(_ requested: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

private struct StatusLoader: PodcastFeedLoading {
    let statusCode: Int
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: statusCode, data: Data())
    }
}

/// Proves the extension short-circuit never reaches the network.
private struct RefusingLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        Issue.record("The classifier fetched \(url) when it should not have")
        throw PastedLinkClassifierError.unreachable("unexpected fetch")
    }
}
