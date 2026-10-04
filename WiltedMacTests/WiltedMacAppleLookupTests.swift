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

    /// Every failed Apple show lookup shows a message and subscribes to nothing.
    func testFailedAppleShowLookupsShowAMessageAndCreateNoSubscription() async throws {
        let showLink = "https://podcasts.apple.com/us/podcast/the-ai-daily-brief/id1680633614"
        let cases: [(label: String, link: String, body: String, says: String)] = [
            ("missing result", showLink, #"{"results":[]}"#, "has no show at that link"),
            ("non-podcast kind", showLink, #"{"results":[{"collectionId":1680633614,"kind":"music","collectionName":"X","feedUrl":"https://f.test/rss"}]}"#, "has no show at that link"),
            ("id mismatch", showLink, #"{"results":[{"collectionId":7,"kind":"podcast","collectionName":"X","feedUrl":"https://f.test/rss"}]}"#, "has no show at that link"),
            ("non-https feed", showLink, #"{"results":[{"collectionId":1680633614,"kind":"podcast","collectionName":"X","feedUrl":"http://f.test/rss"}]}"#, "has no show at that link"),
            ("malformed body", showLink, "not json", "could not use"),
            ("non-numeric id", "https://podcasts.apple.com/us/podcast/the-ai-daily-brief/idnope", #"{"results":[]}"#, "supported Apple show address"),
        ]
        for testCase in cases {
            let directory = wiltedTemporaryDirectory("apple-show-lookup-failure")
            let model = WiltedMacModel(
                arguments: [], stateDirectoryOverride: directory,
                podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data())),
                pastedLinkClassifier: PastedLinkClassifier(
                    loader: FixedBodyLoader(body: Data()),
                    catalogLookupClient: PodcastCatalogLookupClient(loader: FixedBodyLoader(body: Data(testCase.body.utf8)))
                ),
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            addTeardownBlock { await model.close() }
            model.startStoreBootstrap()
            await model.waitForStoreBootstrap()

            model.podcastFeedDraft = testCase.link
            model.addPodcastFeedDraft(initialMetadataCount: 5)
            await model.waitForPodcastOperations()

            let status = try XCTUnwrap(model.podcastFeedDraftStatus, testCase.label)
            XCTAssertFalse(status.hasPrefix("Found"), testCase.label)
            XCTAssertTrue(status.contains(testCase.says), "\(testCase.label): \(status)")
            XCTAssertFalse(status.contains("could not reach"), "\(testCase.label) is not a connection failure")
            XCTAssertNil(model.advertisedFeed, testCase.label)
            XCTAssertTrue(model.subscriptions.isEmpty, testCase.label)
        }
    }
}
