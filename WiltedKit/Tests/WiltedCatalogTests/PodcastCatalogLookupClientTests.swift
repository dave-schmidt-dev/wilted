import Foundation
import Testing
@testable import WiltedCatalog

@Suite("Apple podcast catalog lookup")
struct PodcastCatalogLookupClientTests {
    @Test func resolvesTheExactRequestedPodcastID() async throws {
        let client = PodcastCatalogLookupClient(loader: LookupLoader(body: """
        {"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"The AI Daily Brief","feedUrl":"https://anchor.fm/s/f7cac464/podcast/rss"}]}
        """))
        let show = try await client.lookup(collectionID: 1_680_633_614)
        #expect(show.title == "The AI Daily Brief")
        #expect(show.feedURL.absoluteString == "https://anchor.fm/s/f7cac464/podcast/rss")
    }

    @Test func rejectsMismatchedKindsIDsAndUnsafeFeedURLs() async {
        for body in [
            #"{"results":[{"collectionId":1,"kind":"podcast","collectionName":"Wrong","feedUrl":"https://feeds.test/rss"}]}"#,
            #"{"results":[{"collectionId":1680633614,"kind":"music","collectionName":"Wrong","feedUrl":"https://feeds.test/rss"}]}"#,
            #"{"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"Wrong","feedUrl":"http://feeds.test/rss"}]}"#
        ] {
            let client = PodcastCatalogLookupClient(loader: LookupLoader(body: body))
            await #expect(throws: PodcastCatalogLookupError.self) {
                try await client.lookup(collectionID: 1_680_633_614)
            }
        }
    }

    @Test func eachBadLookupResultRaisesItsOwnTypedError() async {
        let good = #""collectionId":1680633614,"kind":"podcast","collectionName":"Show","feedUrl":"https://feeds.test/rss""#
        let cases: [(String, Int, PodcastCatalogLookupError)] = [
            (#"{"results":[]}"#, 200, .resultNotFound),
            (#"{"results":[{"collectionId":1,"kind":"podcast","collectionName":"Wrong","feedUrl":"https://feeds.test/rss"}]}"#, 200, .resultNotFound),
            (#"{"results":[{"collectionId":1680633614,"kind":"podcast-episode","collectionName":"Wrong","feedUrl":"https://feeds.test/rss"}]}"#, 200, .resultNotFound),
            (#"{"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"Show","feedUrl":"http://feeds.test/rss"}]}"#, 200, .resultNotFound),
            (#"{"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"Show","feedUrl":"https://u:p@feeds.test/rss"}]}"#, 200, .resultNotFound),
            (#"{"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"  ","feedUrl":"https://feeds.test/rss"}]}"#, 200, .resultNotFound),
            (#"{"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"Show"}]}"#, 200, .resultNotFound),
            ("not json", 200, .invalidResponse),
            ("{\"results\":[{\(good)}]}", 503, .invalidResponse),
            ("{\"results\":[{\(good)}]}", 404, .invalidResponse),
        ]
        for (body, status, expected) in cases {
            let client = PodcastCatalogLookupClient(loader: LookupLoader(body: body, statusCode: status))
            await #expect(throws: expected, "\(status) \(body)") {
                try await client.lookup(collectionID: 1_680_633_614)
            }
        }
    }

    @Test func aTransportFailureIsATypedInvalidResponse() async {
        let client = PodcastCatalogLookupClient(loader: FailingLookupLoader())
        await #expect(throws: PodcastCatalogLookupError.invalidResponse) {
            try await client.lookup(collectionID: 1_680_633_614)
        }
    }

    @Test func refusesNonPositiveIDsWithoutALookup() async {
        let client = PodcastCatalogLookupClient(loader: FailingLookupLoader(recordsCalls: true))
        for id in [0, -5] {
            await #expect(throws: PodcastCatalogLookupError.invalidCollectionID) { try await client.lookup(collectionID: id) }
        }
    }

    @Test func rejectsRedirectedLookupResponses() async {
        let client = PodcastCatalogLookupClient(loader: LookupLoader(
            body: #"{"results":[]}"#, finalURL: URL(string: "https://unexpected.example.test/lookup")!
        ))
        await #expect(throws: PodcastCatalogLookupError.self) {
            try await client.lookup(collectionID: 1_680_633_614)
        }
    }

    @Test func enforcesTheResponseCapEvenForAnInjectedLoader() async {
        let client = PodcastCatalogLookupClient(loader: LookupLoader(body: String(repeating: "x", count: PodcastCatalogLookupClient.maximumResponseBytes + 1)))
        await #expect(throws: PodcastCatalogLookupError.responseTooLarge) {
            try await client.lookup(collectionID: 1_680_633_614)
        }
    }

    @Test func mapsAControlledTimeoutAndCancellation() async {
        let timedOut = PodcastCatalogLookupClient(loader: SuspendedLookupLoader(), timeout: .milliseconds(1))
        await #expect(throws: PodcastCatalogLookupError.timedOut) {
            try await timedOut.lookup(collectionID: 1_680_633_614)
        }

        let cancellable = PodcastCatalogLookupClient(loader: SuspendedLookupLoader(), timeout: .seconds(5))
        let task = Task { try await cancellable.lookup(collectionID: 1_680_633_614) }
        task.cancel()
        await #expect(throws: PodcastCatalogLookupError.cancelled) { try await task.value }
    }

    // MARK: Search

    private static let searchBody = """
    {"resultCount":4,"results":[
    {"collectionId":10,"kind":"podcast","collectionName":"  Alpha ","artistName":"A Host","feedUrl":"https://feeds.test/alpha","artworkUrl600":"https://img.test/alpha.jpg"},
    {"collectionId":11,"kind":"podcast","collectionName":"No Feed"},
    {"collectionId":12,"kind":"podcast","collectionName":"Plain HTTP","feedUrl":"http://feeds.test/http"},
    {"collectionId":13,"kind":"podcast","collectionName":"No Art","feedUrl":"https://feeds.test/noart"}
    ]}
    """

    @Test func searchReturnsShowsWithHTTPSFeedsAndDropsTheRest() async throws {
        let client = PodcastCatalogLookupClient(loader: LookupLoader(body: Self.searchBody))
        let shows = try await client.search(term: "alpha")
        #expect(shows.map(\.collectionID) == [10, 13])
        #expect(shows[0].title == "Alpha")
        #expect(shows[0].author == "A Host")
        #expect(shows[0].feedURL.absoluteString == "https://feeds.test/alpha")
        #expect(shows[0].artworkURL?.absoluteString == "https://img.test/alpha.jpg")
    }

    @Test func searchTreatsArtworkAsOptionalAndDropsUnsafeArtwork() async throws {
        let body = """
        {"results":[
        {"collectionId":1,"kind":"podcast","collectionName":"Plain art","feedUrl":"https://f.test/1","artworkUrl600":"http://img.test/1.jpg"},
        {"collectionId":2,"kind":"podcast","collectionName":"No art","feedUrl":"https://f.test/2"}
        ]}
        """
        let shows = try await PodcastCatalogLookupClient(loader: LookupLoader(body: body)).search(term: "x")
        #expect(shows.map(\.collectionID) == [1, 2])
        #expect(shows.allSatisfy { $0.artworkURL == nil })
    }

    @Test func searchSkipsNonPodcastsBlankTitlesCredentialedFeedsAndDuplicates() async throws {
        let body = """
        {"results":[
        {"collectionId":1,"kind":"song","collectionName":"Song","feedUrl":"https://f.test/1"},
        {"collectionId":2,"kind":"podcast","collectionName":"   ","feedUrl":"https://f.test/2"},
        {"collectionId":3,"kind":"podcast","collectionName":"Creds","feedUrl":"https://u:p@f.test/3"},
        {"collectionId":4,"kind":"podcast","collectionName":"Good","feedUrl":"https://f.test/4"},
        {"collectionId":4,"kind":"podcast","collectionName":"Good again","feedUrl":"https://f.test/4b"},
        {"kind":"podcast","collectionName":"No id","feedUrl":"https://f.test/5"}
        ]}
        """
        let shows = try await PodcastCatalogLookupClient(loader: LookupLoader(body: body)).search(term: "x")
        #expect(shows.map(\.title) == ["Good"])
    }

    @Test func searchBuildsABoundedHTTPSPodcastQuery() async throws {
        let loader = RecordingLoader(body: #"{"results":[]}"#)
        let client = PodcastCatalogLookupClient(loader: loader)
        let shows = try await client.search(term: "  hard core&history  ")
        #expect(shows.isEmpty)
        let url = try #require(loader.requests.first)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "itunes.apple.com")
        #expect(components.path == "/search")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["term"] == "hard core&history")
        #expect(items["media"] == "podcast")
        #expect(items["entity"] == "podcast")
        #expect(items["limit"] == String(PodcastCatalogLookupClient.defaultSearchLimit))
        #expect(url.absoluteString.contains("hard%20core%26history"))
    }

    @Test func searchClampsTheLimitToTheDocumentedRange() async throws {
        let loader = RecordingLoader(body: #"{"results":[]}"#)
        let client = PodcastCatalogLookupClient(loader: loader)
        _ = try await client.search(term: "x", limit: 0)
        _ = try await client.search(term: "x", limit: 5_000)
        let limits = loader.requests.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value }
        #expect(limits == ["1", "200"])
    }

    @Test func aBlankSearchTermMakesNoRequest() async throws {
        let loader = RecordingLoader(body: #"{"results":[]}"#)
        let client = PodcastCatalogLookupClient(loader: loader)
        for term in ["", "   ", "\n\t"] { #expect(try await client.search(term: term).isEmpty) }
        #expect(loader.requests.isEmpty)
    }

    @Test func searchRejectsARedirectedResponse() async {
        let client = PodcastCatalogLookupClient(loader: LookupLoader(
            body: Self.searchBody, finalURL: URL(string: "https://elsewhere.example.test/search")!
        ))
        await #expect(throws: PodcastCatalogLookupError.unsafeRedirect) { try await client.search(term: "alpha") }
    }

    @Test func searchMapsBadStatusMalformedBodyTransportOversizeAndTimeout() async {
        await #expect(throws: PodcastCatalogLookupError.invalidResponse) {
            try await PodcastCatalogLookupClient(loader: LookupLoader(body: Self.searchBody, statusCode: 503)).search(term: "x")
        }
        await #expect(throws: PodcastCatalogLookupError.invalidResponse) {
            try await PodcastCatalogLookupClient(loader: LookupLoader(body: "not json")).search(term: "x")
        }
        await #expect(throws: PodcastCatalogLookupError.invalidResponse) {
            try await PodcastCatalogLookupClient(loader: FailingLookupLoader()).search(term: "x")
        }
        await #expect(throws: PodcastCatalogLookupError.responseTooLarge) {
            try await PodcastCatalogLookupClient(loader: LookupLoader(body: String(repeating: "x", count: PodcastCatalogLookupClient.maximumResponseBytes + 1))).search(term: "x")
        }
        await #expect(throws: PodcastCatalogLookupError.timedOut) {
            try await PodcastCatalogLookupClient(loader: SuspendedLookupLoader(), timeout: .milliseconds(1)).search(term: "x")
        }
    }

    @Test func aCancelledSearchIsTypedCancellation() async {
        let client = PodcastCatalogLookupClient(loader: SuspendedLookupLoader(), timeout: .seconds(5))
        let task = Task { try await client.search(term: "x") }
        task.cancel()
        await #expect(throws: PodcastCatalogLookupError.cancelled) { try await task.value }
    }

    @Test func theDebounceStaysUnderTheDocumentedRateLimit() {
        // Apple documents roughly 20 calls per minute; one call per debounce
        // window of continuous typing must not blow through a typing burst.
        #expect(PodcastCatalogLookupClient.searchDebounce >= .milliseconds(500))
        #expect(PodcastCatalogLookupClient.defaultSearchLimit == 25)
    }

    @Test func spoofedOrMalformedAppleLinksYieldNoID() {
        for address in [
            "http://podcasts.apple.com/us/podcast/show/id1680633614",
            "https://user@podcasts.apple.com/us/podcast/show/id1680633614",
            "https://podcasts.apple.com@evil.test/us/podcast/show/id1680633614",
            "https://evilpodcasts.apple.com/us/podcast/show/id1680633614",
            "https://podcasts.apple.com/us/podcast/show/id16806x3614",
            "https://podcasts.apple.com/us/podcast/show/id01680633614",
            "https://podcasts.apple.com/us/podcast/show/id",
            "https://podcasts.apple.com/us/podcast/show/id-5",
            "https://podcasts.apple.com/us/podcast/show/1680633614",
            "https://podcasts.apple.com/us/album/show/id1680633614",
            "https://podcasts.apple.com/podcast/id1680633614",
        ] {
            #expect(PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: URL(string: address)!) == nil, "\(address)")
        }
    }

    @Test func acceptsLocaleAndQueryVariantsOnlyForTheExactAppleHost() {
        #expect(PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: URL(string: "https://podcasts.apple.com/us/podcast/the-ai-daily-brief/id1680633614?uo=4")!) == 1_680_633_614)
        #expect(PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: URL(string: "https://podcasts.apple.com/us/podcast/the-ai-daily-brief/idx1680633614")!) == nil)
        #expect(PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: URL(string: "https://podcasts.apple.com.evil.test/us/podcast/the-ai-daily-brief/id1680633614")!) == nil)
    }
}

private struct LookupLoader: PodcastFeedLoading {
    let body: String
    var finalURL: URL? = nil
    var statusCode = 200
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: finalURL ?? url, statusCode: statusCode, data: Data(body.utf8))
    }
}

private final class RecordingLoader: PodcastFeedLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    let body: String
    init(body: String) { self.body = body }
    var requests: [URL] { lock.withLock { recorded } }
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        lock.withLock { recorded.append(url) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(body.utf8))
    }
}

private struct FailingLookupLoader: PodcastFeedLoading {
    var recordsCalls = false
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        if recordsCalls { Issue.record("The lookup fetched \(url) for an invalid ID") }
        throw PodcastFeedClientError.transport("offline")
    }
}

private struct SuspendedLookupLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        try await Task.sleep(for: .seconds(30))
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data())
    }
}
