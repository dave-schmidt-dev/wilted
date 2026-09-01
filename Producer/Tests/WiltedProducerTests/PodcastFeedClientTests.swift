import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Podcast feed client")
struct PodcastFeedClientTests {
    private let sourceURL = URL(string: "https://podcasts.example.test/feed.xml")!
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func loadsBoundedNamespacedMetadata() async throws {
        let result = try await client(xml: """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
          <title> Example Show </title><itunes:author> Presenter </itunes:author><itunes:image href="https://images.example.test/show.jpg" />
          <item><title>Episode one</title><guid> stable-guid </guid><pubDate>Tue, 14 Nov 2023 22:13:20 GMT</pubDate><itunes:duration>01:02:03</itunes:duration><itunes:author>Guest</itunes:author><enclosure url="https://cdn.example.test/one.mp3" type="audio/mpeg" length="42" /></item>
          <item><title>No media</title></item>
        </channel></rss>
        """).load(sourceURL)
        #expect(result.feed.title == "Example Show")
        #expect(result.feed.author == "Presenter")
        #expect(result.feed.artworkURL?.absoluteString == "https://images.example.test/show.jpg")
        #expect(result.episodes.count == 1)
        #expect(result.episodes[0].rssGUID == "stable-guid")
        #expect(result.episodes[0].durationSeconds == 3_723)
        #expect(result.episodes[0].enclosureByteCount == 42)
    }

    @Test func capturesPublishedTranscriptsAndPrefersTimedCaptions() async throws {
        let result = try await client(xml: """
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Show</title>
          <item><title>Episode</title>
            <podcast:transcript url="https://cdn.example.test/one.html" type="text/html" />
            <podcast:transcript url="https://cdn.example.test/one.srt" type="application/x-subrip" language="en" />
            <podcast:transcript url="https://cdn.example.test/one.vtt" type="text/vtt" language="en" rel="captions" />
            <enclosure url="https://cdn.example.test/one.mp3" type="audio/mpeg" />
          </item>
        </channel></rss>
        """).load(sourceURL)
        let sources = result.episodes[0].transcriptSources
        #expect(sources.count == 3)
        #expect(sources.map(\.mediaType) == ["text/html", "application/x-subrip", "text/vtt"])
        #expect(sources.map(\.carriesTiming) == [false, true, true])
        #expect(sources[2].isCaptions)
        #expect(sources[2].languageCode == "en")
        // Captions win over the SRT that appears first: captions are authored
        // against the audio clock by definition.
        #expect(result.episodes[0].timedTranscriptSource?.mediaType == "text/vtt")
    }

    /// A transcript is an optional extra. One bad entry must cost that entry
    /// and nothing else -- refusing the feed would cost every episode in it.
    @Test func skipsUnusableTranscriptEntriesWithoutFailingTheFeed() async throws {
        let result = try await client(xml: """
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Show</title>
          <item><title>Episode</title>
            <podcast:transcript url="http://cdn.example.test/insecure.vtt" type="text/vtt" />
            <podcast:transcript url="https://cdn.example.test/no-type.vtt" />
            <podcast:transcript url="not a url at all" type="text/vtt" />
            <podcast:transcript url="https://cdn.example.test/good.vtt" type="text/vtt" language="not valid!" />
            <podcast:transcript url="https://cdn.example.test/good.vtt" type="text/vtt" />
            <podcast:transcript url="https://cdn.example.test/good.vtt" type="text/vtt" />
            <enclosure url="https://cdn.example.test/one.mp3" type="audio/mpeg" />
          </item>
        </channel></rss>
        """).load(sourceURL)
        #expect(result.episodes.count == 1)
        let sources = result.episodes[0].transcriptSources
        #expect(sources.map(\.url.absoluteString) == ["https://cdn.example.test/good.vtt"],
                "insecure, typeless, unparseable, bad-language, and duplicate entries all drop")
    }

    @Test func boundsPublishedTranscriptsPerEpisode() async throws {
        let tags = (0..<20).map {
            "<podcast:transcript url=\"https://cdn.example.test/\($0).vtt\" type=\"text/vtt\" />"
        }.joined()
        let result = try await client(xml: """
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Show</title>
          <item><title>Episode</title>\(tags)<enclosure url="https://cdn.example.test/one.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """).load(sourceURL)
        #expect(result.episodes[0].transcriptSources.count == PodcastEpisode.maximumTranscriptSources)
    }

    @Test func reportsNoTimedSourceWhenOnlyProseIsPublished() async throws {
        let result = try await client(xml: """
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Show</title>
          <item><title>Episode</title>
            <podcast:transcript url="https://cdn.example.test/one.html" type="text/html" />
            <enclosure url="https://cdn.example.test/one.mp3" type="audio/mpeg" />
          </item>
        </channel></rss>
        """).load(sourceURL)
        #expect(result.episodes[0].transcriptSources.count == 1)
        #expect(result.episodes[0].timedTranscriptSource == nil,
                "a web page is words without a clock, so nothing may be synchronised from it")
    }

    @Test func acceptsOptionalFieldsAndLowercasesMediaType() async throws {
        let result = try await client(xml: "<rss><channel><title>Show</title><item><title>Episode</title><enclosure url=\"https://cdn.example.test/one.m4a\" type=\"AUDIO/X-M4A; charset=binary\" /></item></channel></rss>").load(sourceURL)
        #expect(result.feed.author == nil)
        #expect(result.episodes[0].rssGUID == nil)
        #expect(result.episodes[0].enclosureMediaType == "audio/x-m4a")
    }

    @Test func rejectsInitialAndFinalNonHTTPSURLs() async {
        await expect(.invalidURL) {
            try await PodcastFeedClient(loader: StubLoader(response: .init(url: self.sourceURL, statusCode: 200, data: Data()))).load(URL(string: "http://podcasts.example.test/feed.xml")!)
        }
        await expect(.invalidURL) { try await client(finalURL: URL(string: "http://podcasts.example.test/feed.xml")!).load(self.sourceURL) }
    }

    @Test func preservesRedirectDowngradeFailure() async {
        await expect(.redirectDowngrade) { try await PodcastFeedClient(loader: RedirectDowngradeLoader()).load(self.sourceURL) }
    }

    @Test func rejectsBadStatusAndOversizedResponses() async {
        await expect(.invalidResponse(503)) { try await client(status: 503).load(self.sourceURL) }
        await expect(.responseTooLarge) {
            try await PodcastFeedClient(loader: StubLoader(response: .init(url: self.sourceURL, statusCode: 200, data: Data(repeating: 0, count: PodcastFeedClient.maximumFeedBytes + 1)))).load(self.sourceURL)
        }
    }

    @Test func URLSessionLoaderEnforcesDeclaredAndStreamedLimits() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let loader = URLSessionPodcastFeedLoader(configuration: configuration)
        await expect(.responseTooLarge) {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=header")!, maximumBytes: 1)
        }
        await expect(.responseTooLarge) {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=stream")!, maximumBytes: 1)
        }
    }

    @Test func URLSessionLoaderAllowsHTTPSRedirectsAndRejectsDowngrades() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let loader = URLSessionPodcastFeedLoader(configuration: configuration)
        let response = try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=redirect")!, maximumBytes: 1_024)
        #expect(response.url.query == "case=success")
        await expect(.redirectDowngrade) {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=downgrade")!, maximumBytes: 1_024)
        }
    }

    @Test func rejectsMalformedXMLAndExternalEntities() async {
        await expect(.malformedXML) { try await client(xml: "<rss><channel><title>broken</channel></rss>").load(self.sourceURL) }
        await expect(.externalEntity) { try await client(xml: "<!DOCTYPE rss [<!ENTITY xxe SYSTEM 'https://evil.example.test/a'>]><rss><channel><title>&xxe;</title></channel></rss>").load(self.sourceURL) }
        let longPrefix = "<!--\(String(repeating: "x", count: 65 * 1_024))-->"
        await expect(.externalEntity) {
            try await client(xml: "\(longPrefix)<!DOCTYPE rss [<!ENTITY xxe SYSTEM 'https://evil.example.test/a'>]><rss><channel><title>&xxe;</title></channel></rss>").load(self.sourceURL)
        }
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("<!DOCTYPE rss [<!ENTITY xxe SYSTEM 'https://evil.example.test/a'>]><rss><channel><title>&xxe;</title></channel></rss>".data(using: .utf16LittleEndian)!)
        let utf16Document = utf16
        await expect(.externalEntity) { try await client(data: utf16Document).load(self.sourceURL) }
    }

    @Test func allowsEntitySyntaxInsideCommentsAndCDATA() async throws {
        let result = try await client(xml: "<rss><channel><!-- <!DOCTYPE example> --><description><![CDATA[<!ENTITY example SYSTEM 'https://example.test/a'>]]></description><title>Show</title></channel></rss>").load(sourceURL)
        #expect(result.feed.title == "Show")
    }

    @Test func rejectsInvalidEnclosures() async {
        await expect(.invalidMetadata("enclosure URL")) { try await client(xml: feed(item: "<enclosure url=\"http://cdn.example.test/one.mp3\" type=\"audio/mpeg\" />")).load(self.sourceURL) }
        await expect(.unsupportedEnclosureMediaType("video/mp4")) { try await client(xml: feed(item: "<enclosure url=\"https://cdn.example.test/one.mp4\" type=\"video/mp4\" />")).load(self.sourceURL) }
    }

    @Test func rejectsInvalidDurationsAsMetadata() async {
        for duration in ["0", "-5", "nan", "inf", "10::20"] {
            await expect(.invalidMetadata("episode duration")) {
                try await client(xml: feed(item: "<itunes:duration>\(duration)</itunes:duration><enclosure url=\"https://cdn.example.test/one.mp3\" type=\"audio/mpeg\" />")).load(self.sourceURL)
            }
        }
    }

    @Test func mapsDomainValidationFailuresToInvalidMetadata() async {
        let path = String(repeating: "a", count: 4_100)
        await expectInvalidMetadata {
            try await client(xml: feed(item: "<enclosure url=\"https://cdn.example.test/\(path)\" type=\"audio/mpeg\" />")).load(self.sourceURL)
        }
    }

    /// Cover art advertised over plain HTTP is dropped, not fatal. Real feeds do
    /// this -- Mac Power Users did in the 2026-08-31 import survey -- and losing
    /// every episode of a podcast over its logo is the wrong trade. The insecure
    /// URL is still never kept, so nothing can later fetch it.
    @Test func dropsNonHTTPSArtworkAndKeepsTheFeed() async throws {
        let channel = try await client(xml: "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Show</title><itunes:image href=\"http://images.example.test/show.jpg\" /><item><title>Episode</title><enclosure url=\"https://cdn.example.test/one.mp3\" type=\"audio/mpeg\" /></item></channel></rss>").load(sourceURL)
        #expect(channel.feed.artworkURL == nil)
        #expect(channel.episodes.count == 1)

        let episode = try await client(xml: feed(item: "<itunes:image href=\"http://images.example.test/episode.jpg\" /><enclosure url=\"https://cdn.example.test/one.mp3\" type=\"audio/mpeg\" />")).load(sourceURL)
        #expect(episode.episodes.count == 1)
        #expect(episode.episodes[0].artworkURL == nil)
    }

    /// A feed longer than the episode ceiling is truncated to its newest
    /// episodes and reports the drop; it is never rejected outright. Two of the
    /// listener's 29 subscribed feeds exceeded the ceiling in the 2026-08-31
    /// survey, and rejecting them lost the entire podcast.
    @Test func keepsNewestEpisodesWhenAFeedExceedsTheCeiling() async throws {
        let overflow = 3
        let total = PodcastFeedClient.maximumEpisodeCount + overflow
        // Oldest first, so a client that merely takes the first N keeps the
        // wrong end of the feed and this test fails.
        let items = (0..<total).map { index in
            let published = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600)
            return "<item><title>Episode \(index)</title><guid>guid-\(index)</guid>"
                + "<pubDate>\(Self.rfc822.string(from: published))</pubDate>"
                + "<enclosure url=\"https://cdn.example.test/\(index).mp3\" type=\"audio/mpeg\" /></item>"
        }.joined()
        let result = try await client(xml: "<rss><channel><title>Show</title>\(items)</channel></rss>").load(sourceURL)

        #expect(result.episodes.count == PodcastFeedClient.maximumEpisodeCount)
        #expect(result.droppedEpisodeCount == overflow)
        #expect(result.episodes.first?.rssGUID == "guid-\(overflow)")
        #expect(result.episodes.last?.rssGUID == "guid-\(total - 1)")
        // Feed order survives truncation.
        let published = result.episodes.compactMap(\.publishedTime?.date)
        #expect(published == published.sorted())
    }

    /// An undated episode cannot claim to be recent, so it yields to every dated
    /// episode when the ceiling forces a choice.
    @Test func undatedEpisodesLoseToDatedOnesAtTheCeiling() async throws {
        let dated = (0..<PodcastFeedClient.maximumEpisodeCount).map { index in
            "<item><title>Dated \(index)</title><guid>dated-\(index)</guid>"
                + "<pubDate>\(Self.rfc822.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))))</pubDate>"
                + "<enclosure url=\"https://cdn.example.test/d\(index).mp3\" type=\"audio/mpeg\" /></item>"
        }.joined()
        let undated = "<item><title>Undated</title><guid>undated</guid>"
            + "<enclosure url=\"https://cdn.example.test/u.mp3\" type=\"audio/mpeg\" /></item>"
        let result = try await client(xml: "<rss><channel><title>Show</title>\(undated)\(dated)</channel></rss>").load(sourceURL)

        #expect(result.droppedEpisodeCount == 1)
        #expect(!result.episodes.contains { $0.rssGUID == "undated" })
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    @Test func mapsTaskCancellationToTypedCancellation() async {
        let task = Task {
            try await PodcastFeedClient(loader: WaitingLoader()).load(sourceURL)
        }
        task.cancel()
        await expect(.cancelled) { _ = try await task.value }
    }

    @Test func URLSessionLoaderDoesNotStartRequestAfterCancellation() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let gate = RequestStartGate()
        let loader = URLSessionPodcastFeedLoader(configuration: configuration) {
            await gate.waitForRelease()
        }
        FeedURLProtocol.resetCancellationRequestCount()
        let task = Task {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=cancel")!, maximumBytes: 1_024)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await expect(.cancelled) { _ = try await task.value }
        #expect(FeedURLProtocol.cancellationRequestCount == 0)
    }

    private func client(xml: String = "<rss><channel><title>Show</title></channel></rss>", status: Int = 200, finalURL: URL? = nil) -> PodcastFeedClient {
        client(data: Data(xml.utf8), status: status, finalURL: finalURL)
    }

    private func client(data: Data, status: Int = 200, finalURL: URL? = nil) -> PodcastFeedClient {
        PodcastFeedClient(loader: StubLoader(response: .init(url: finalURL ?? sourceURL, statusCode: status, data: data)), now: { fixedNow })
    }

    private func feed(item: String) -> String { "<rss><channel><title>Show</title><item><title>Episode</title>\(item)</item></channel></rss>" }

    private func expect<T: Sendable>(_ expected: PodcastFeedClientError, _ operation: @escaping @Sendable () async throws -> T) async {
        do { _ = try await operation(); Issue.record("Expected \(expected)") }
        catch let error as PodcastFeedClientError { #expect(error == expected) }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    private func expectInvalidMetadata<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async {
        do { _ = try await operation(); Issue.record("Expected invalid metadata") }
        catch PodcastFeedClientError.invalidMetadata { }
        catch { Issue.record("Unexpected error: \(error)") }
    }
}

private struct StubLoader: PodcastFeedLoading {
    let response: PodcastFeedHTTPResponse
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse { response }
}

private struct WaitingLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        try await Task.sleep(for: .seconds(10))
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data())
    }
}

private struct RedirectDowngradeLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        throw PodcastFeedClientError.redirectDowngrade
    }
}

private final class FeedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let cancellationRequests = RequestCounter()

    static var cancellationRequestCount: Int { cancellationRequests.value }
    static func resetCancellationRequestCount() { cancellationRequests.reset() }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "podcasts.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestCase = request.url?.query ?? ""
        if requestCase == "case=cancel" { Self.cancellationRequests.increment() }
        if requestCase == "case=redirect" || requestCase == "case=downgrade" {
            let target = URL(string: requestCase == "case=redirect"
                ? "https://podcasts.example.test/feed.xml?case=success"
                : "http://podcasts.example.test/feed.xml?case=success")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let isHeaderCase = requestCase == "case=header"
        let headers = isHeaderCase ? ["Content-Length": "2"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if requestCase == "case=success" {
            client?.urlProtocol(self, didLoad: Data("<rss><channel><title>Show</title></channel></rss>".utf8))
        } else if !isHeaderCase {
            client?.urlProtocol(self, didLoad: Data([0]))
            client?.urlProtocol(self, didLoad: Data([1]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}

private actor RequestStartGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
