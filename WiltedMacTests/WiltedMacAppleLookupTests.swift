import Foundation
import XCTest
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacAppleLookupTests: XCTestCase {
    func testAppleShowLookupOffersTheNamedFeedWithoutSubscribing() async throws {
        let directory = wiltedTemporaryDirectory("apple-show-lookup")
        let lookupURL = try XCTUnwrap(
            URL(string: "https://itunes.apple.com/lookup?id=1680633614&entity=podcast")
        )
        let lookup = PodcastCatalogLookupClient(loader: FixedBodyLoader(body: Data(#"{"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"The AI Daily Brief","feedUrl":"https://anchor.fm/s/f7cac464/podcast/rss"}]}"#.utf8)))
        let classifier = PastedLinkClassifier(
            loader: FixedBodyLoader(body: Data()), catalogLookupClient: lookup
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data("<rss><channel><title>The AI Daily Brief</title></channel></rss>".utf8))),
            pastedLinkClassifier: classifier, preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "https://podcasts.apple.com/us/podcast/the-ai-daily-brief/id1680633614?uo=4"
        model.addPodcastFeedDraft(initialMetadataCount: 5)
        await model.waitForPodcastOperations()

        XCTAssertEqual(lookupURL.host, "itunes.apple.com")
        XCTAssertEqual(model.advertisedFeed?.absoluteString, "https://anchor.fm/s/f7cac464/podcast/rss")
        XCTAssertEqual(model.podcastFeedDraftStatus, "Found The AI Daily Brief. Confirm before subscribing.")
        XCTAssertTrue(model.subscriptions.isEmpty)
    }
}
