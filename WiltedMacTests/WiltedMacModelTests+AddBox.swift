import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: - One add box

    /// Builds a store-backed model whose add box classifies against `document`
    /// and whose feed client is fed `feedXML` when a subscription follows.
    private func modelForPastedLink(
        directory: URL, document: String, feedXML: String = ""
    ) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(feedXML.utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: FixedBodyLoader(body: Data(document.utf8))), preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    /// The reported complaint: a podcast address pasted into the article box has
    /// to reach the subscription flow, not the article pipeline. Larder no longer
    /// subscribes on its own -- it moves the address to the page that owns feeds
    /// and shows it there, so the listener sees what they are about to follow.
    func testPastingAFeedAddressHandsItToTheSubscriptionComposer() async throws {
        let directory = temporaryDirectory("pasted-feed")
        let model = modelForPastedLink(
            directory: directory,
            document: "<?xml version=\"1.0\"?><rss><channel><title>Pasted show</title></channel></rss>",
            feedXML: "<rss><channel><title>Pasted show</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/show"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.subscriptions.isEmpty, "the handoff subscribes to nothing on its own")
        XCTAssertNil(model.preparation, "a feed must never reach the article pipeline")
        XCTAssertEqual(model.selectedNavigation, .feeds, "the listener is taken to the page that owns feeds")
        XCTAssertEqual(model.podcastFeedDraft, "https://podcasts.example.test/show")
        XCTAssertEqual(model.urlDraft, "", "the address moved rather than being left in both boxes")
        XCTAssertNil(model.linkDraftStatus)

        // Confirming in the composer it landed in is what subscribes.
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Pasted show"])
        XCTAssertEqual(model.podcastFeedDraft, "", "a completed subscription clears the box")
    }

    func testOversizedFeedPrefixReachesSubscriptionComposer() async throws {
        let directory = temporaryDirectory("oversized-pasted-feed")
        let feed = "<rss><channel><title>Large show</title></channel></rss>"
            + String(repeating: " ", count: PastedLinkClassifier.maximumSniffBytes)
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(feed.utf8))),
            pastedLinkClassifier: PastedLinkClassifier(loader: StrictPrefixBodyLoader(body: Data(feed.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/large-show"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.selectedNavigation, .feeds)
        XCTAssertEqual(model.podcastFeedDraft, "https://podcasts.example.test/large-show")
        XCTAssertNil(model.linkDraftStatus, "an oversized feed is reachable through its bounded prefix")

        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Large show"])
    }

    /// An address ending in .xml is unmistakable, so neither box may spend a
    /// round trip to learn what it already knows. The classifier here cannot
    /// fetch anything, so a subscription proves the shortcut ran in both.
    func testAnUnmistakableFeedAddressReachesTheComposerWithoutSniffing() async throws {
        let directory = temporaryDirectory("pasted-feed-extension")
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data("<rss><channel><title>Direct show</title></channel></rss>".utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/show.xml"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.selectedNavigation, .feeds)
        XCTAssertEqual(model.podcastFeedDraft, "https://podcasts.example.test/show.xml")
        XCTAssertTrue(model.subscriptions.isEmpty)

        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Direct show"])
    }

    /// A page that publishes a feed is still the article that was pasted. The
    /// feed is offered, and only subscribes when the offer is accepted.
    func testAPageThatPublishesAFeedOffersItRatherThanSubscribing() async throws {
        let directory = temporaryDirectory("pasted-advertised")
        let model = modelForPastedLink(
            directory: directory,
            document: """
            <!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" href="https://blog.example.test/Feed.xml">
            </head><body>Words</body></html>
            """,
            feedXML: "<rss><channel><title>Blog cast</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://blog.example.test/posts/one"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.advertisedFeed?.absoluteString, "https://blog.example.test/Feed.xml")
        XCTAssertTrue(model.subscriptions.isEmpty, "an advertised feed is an offer, not a subscription")

        model.subscribeToAdvertisedFeed()
        await model.waitForPodcastOperations()
        XCTAssertNil(model.advertisedFeed)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Blog cast"])
    }

    /// The Feeds composer refuses an incomplete address before it starts any
    /// work, so a typo never reads as a network problem.
    func testTheSubscriptionComposerRefusesAnIncompleteAddressWithoutChecking() async throws {
        let directory = temporaryDirectory("composer-invalid")
        let model = modelForPastedLink(
            directory: directory,
            document: "<rss><channel><title>Unused</title></channel></rss>",
            feedXML: "<rss><channel><title>Unused</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "podcasts.example.test/show"
        model.addPodcastFeedDraft()

        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertEqual(
            model.podcastFeedDraftStatus,
            "Enter a complete HTTPS podcast feed or show-page address."
        )
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    /// A show page is not a feed. The composer says which feed it found and
    /// waits, because following a site's whole feed is a separate decision from
    /// the address that was pasted.
    func testTheSubscriptionComposerOffersAShowPagesFeedBeforeFollowingIt() async throws {
        let directory = temporaryDirectory("composer-advertised")
        let model = modelForPastedLink(
            directory: directory,
            document: """
            <!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" href="https://blog.example.test/Feed.xml">
            </head><body>Words</body></html>
            """,
            feedXML: "<rss><channel><title>Blog cast</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "https://blog.example.test/posts/one"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.advertisedFeed?.absoluteString, "https://blog.example.test/Feed.xml")
        XCTAssertTrue(model.subscriptions.isEmpty, "an advertised feed is an offer, not a subscription")
        XCTAssertEqual(
            model.podcastFeedDraftStatus,
            "This page advertises one podcast feed. Confirm before subscribing."
        )

        model.subscribeToAdvertisedFeed()
        await model.waitForPodcastOperations()
        XCTAssertNil(model.advertisedFeed)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Blog cast"])
    }

    /// Subscribing to a feed already followed adds nothing, so the answer is the
    /// row that already exists rather than a second subscription or an error the
    /// listener cannot act on.
    func testSubscribingTwiceKeepsOneFeedAndPointsAtTheOneAlreadyFollowed() async throws {
        let directory = temporaryDirectory("composer-duplicate")
        let model = modelForPastedLink(
            directory: directory,
            document: "<rss><channel><title>Repeat show</title></channel></rss>",
            feedXML: "<rss><channel><title>Repeat show</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "https://podcasts.example.test/repeat"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Repeat show"])
        XCTAssertNil(model.selectedPodcastFeedID, "a first subscription points at nothing")

        // The same feed through an equivalent spelling of its address.
        model.podcastFeedDraft = "https://Podcasts.Example.test/repeat#latest"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.count, 1, "one feed, however many times it is offered")
        XCTAssertEqual(model.selectedPodcastFeedID, model.subscriptions.first?.id)
        XCTAssertEqual(model.podcastOperationMessage, "Already following Repeat show.")
    }

    /// A cancelled check still resumes; by then the listener may have started
    /// another. The cancelled one must write nothing, or it clears the live
    /// check's progress and replaces its answer with a stale one.
    func testACancelledSubscriptionCheckCannotWriteOverTheNextOne() async throws {
        let directory = temporaryDirectory("composer-cancel-race")
        let pageURL = URL(string: "https://pages.example.test/plain")!
        let feedURL = URL(string: "https://podcasts.example.test/gated")!
        let gate = GatedRoutingLoader(documents: [
            pageURL: Data("<!doctype html><html><body>Just words</body></html>".utf8),
            feedURL: Data("<rss><channel><title>Gated show</title></channel></rss>".utf8),
        ])
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data("<rss><channel><title>Gated show</title></channel></rss>".utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: gate),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = pageURL.absoluteString
        model.addPodcastFeedDraft()
        XCTAssertTrue(model.isCheckingPodcastSubscription)
        XCTAssertEqual(model.podcastFeedDraftStatus, WiltedMacModel.podcastCheckInProgressStatus)

        model.cancelPodcastSubscriptionCheck()
        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertEqual(model.podcastFeedDraftStatus, WiltedMacModel.podcastCheckCancelledStatus)

        model.podcastFeedDraft = feedURL.absoluteString
        model.addPodcastFeedDraft()
        XCTAssertTrue(model.isCheckingPodcastSubscription, "the next check starts on its own terms")

        // Both classifications complete now, the cancelled one first.
        await gate.release()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.map(\.title), ["Gated show"])
        XCTAssertEqual(model.podcastFeedDraftStatus, "Gated show added with 0 episodes.",
                       "the cancelled check must not report on the address that replaced it")
        XCTAssertFalse(model.isCheckingPodcastSubscription)
    }

    /// A pasted address that cannot be reached is reported in the box. Guessing
    /// would send it to a pipeline that fails for a reason the reader did not
    /// cause.
    func testAnUnreachableAddressIsReportedInTheBox() async throws {
        let directory = temporaryDirectory("pasted-unreachable")
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://unreachable.example.test/thing"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(
            model.linkDraftStatus,
            "Wilted could not reach that address. Check it, or retry when online."
        )
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertNil(model.preparation)
    }

    func testAnIncompleteAddressIsRefusedWithoutAnyFetch() async throws {
        let directory = temporaryDirectory("pasted-invalid")
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        for draft in ["", "example.com/thing", "http://example.com/thing"] {
            model.urlDraft = draft
            model.addPastedLink()
            XCTAssertEqual(model.linkDraftStatus, "Enter a complete HTTPS address.", "draft: \(draft)")
        }
    }

}
