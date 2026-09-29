import Foundation
import Testing
@testable import WiltedProducer

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

    @Test func acceptsLocaleAndQueryVariantsOnlyForTheExactAppleHost() {
        #expect(PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: URL(string: "https://podcasts.apple.com/us/podcast/the-ai-daily-brief/id1680633614?uo=4")!) == 1_680_633_614)
        #expect(PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: URL(string: "https://podcasts.apple.com/us/podcast/the-ai-daily-brief/idx1680633614")!) == nil)
        #expect(PodcastCatalogLookupClient.collectionID(fromApplePodcastURL: URL(string: "https://podcasts.apple.com.evil.test/us/podcast/the-ai-daily-brief/id1680633614")!) == nil)
    }
}

private struct LookupLoader: PodcastFeedLoading {
    let body: String
    var finalURL: URL? = nil
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: finalURL ?? url, statusCode: 200, data: Data(body.utf8))
    }
}

private struct SuspendedLookupLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        try await Task.sleep(for: .seconds(30))
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data())
    }
}
