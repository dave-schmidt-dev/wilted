import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacSubscriptionIntakeTests: XCTestCase {
    func testInitialSubscriptionUsesSettingsMetadataCountWithoutQueueOrDownload() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/initial.xml"))
        let items = (1...26).map { index in
            """
            <item><guid>episode-\(index)</guid><title>Episode \(index)</title>
            <pubDate>Mon, \(String(format: "%02d", index)) Jan 2024 12:00:00 GMT</pubDate>
            <enclosure url="https://media.example.test/episode-\(index).mp3" type="audio/mpeg" /></item>
            """
        }.joined()
        let xml = "<rss version=\"2.0\"><channel><title>Initial count</title>\(items)</channel></rss>"
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(feedURL)
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.episodes.count, 5)
        XCTAssertTrue(model.podcastQueueIDs.isEmpty)
        XCTAssertTrue(model.episodes.allSatisfy { $0.downloadState == .notDownloaded })
        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertNil(model.podcastSubscriptionRequestID)
        XCTAssertNil(model.lastAutomationRefreshAt,
                     "subscribing records metadata, not a successful scheduled refresh")
    }

    func testInvalidInitialCountFailsBeforeStartingARequest() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-invalid")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader()),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(
            try XCTUnwrap(URL(string: "https://feeds.example.test/invalid.xml")), initialMetadataCount: 101
        )

        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertNil(model.podcastSubscriptionRequestID)
        XCTAssertNotNil(model.podcastFeedDraftStatus)
        XCTAssertNil(model.podcastRefreshTask)
    }

    func testCancelledInitialSubscriptionCannotPersistAfterItsRequestIsWithdrawn() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-cancel")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/cancel.xml"))
        let loader = NonCooperativeFeedLoader(documents: [feedURL: Data("<rss><channel><title>Cancelled</title><item><guid>cancelled</guid><title>Cancelled</title><pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate><enclosure url=\"https://media.example.test/cancelled.mp3\" type=\"audio/mpeg\" /></item></channel></rss>".utf8)])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: loader), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(feedURL)
        await loader.waitUntilHeld()
        XCTAssertTrue(model.isCheckingPodcastSubscription)
        XCTAssertNotNil(model.podcastSubscriptionRequestID)
        model.cancelPodcastSubscriptionCheck()
        await loader.release()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.podcastFeedDraftStatus, WiltedMacModel.podcastCheckCancelledStatus)
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertTrue(model.episodes.isEmpty)
    }

    func testInitialSubscriptionFailureLeavesNoRequestAndReportsRetryableError() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-failure")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(try XCTUnwrap(URL(string: "https://feeds.example.test/failure.xml")))
        await model.waitForPodcastOperations()

        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertNil(model.podcastSubscriptionRequestID)
        XCTAssertEqual(model.podcastFeedDraftStatus, "Podcast feed unavailable. Check the address or retry when online.")
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    func testFeedWithoutAudioEnclosuresPersistsNothingAndNamesTheArticleFeedRefusal() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-article-feed")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/articles.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let xml = "<rss version=\"2.0\"><channel><title>Articles only</title>"
            + "<item><guid>a1</guid><title>Post one</title><link>https://feeds.example.test/post-1</link></item>"
            + "<item><guid>a2</guid><title>Post two</title><link>https://feeds.example.test/post-2</link></item>"
            + "</channel></rss>"
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(feedURL)
        await model.waitForPodcastOperations()

        let store = try XCTUnwrap(model.store)
        let persistedFeed = try await store.podcastFeed(for: feedID)
        let persistedSubscription = try await store.subscription(for: feedID)
        let message = "Wilted can't follow article feeds yet; add single articles instead."
        XCTAssertNil(persistedFeed)
        XCTAssertNil(persistedSubscription)
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertEqual(model.podcastFeedDraftStatus, message)
        XCTAssertEqual(model.podcastOperationMessage, message)
        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertNil(model.podcastSubscriptionRequestID)
    }

    func testEpisodeAdmissionFailureKeepsTheDurableSubscriptionAndNamesThePartialResult() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-partial")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/partial.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let xml = "<rss><channel><title>Partial show</title><item><guid>partial</guid><title>Partial episode</title><pubDate>Mon, 29 Sep 2026 12:00:00 GMT</pubDate><enclosure url=\"https://media.example.test/partial.mp3\" type=\"audio/mpeg\" /></item></channel></rss>"
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let capture = SubscriptionAdmissionCapture()
        model.podcastEpisodeAdmissionOperationForTesting = { episodes, admission, limit in
            await capture.record(episodes: episodes, admission: admission, limit: limit)
            throw SubscriptionIntakeFailure.expected
        }
        model.podcastFeedDraft = feedURL.absoluteString

        model.startPodcastSubscriptionIntake(feedURL)
        await model.waitForPodcastOperations()

        let store = try XCTUnwrap(model.store)
        let persistedFeed = try await store.podcastFeed(for: feedID)
        let persistedSubscription = try await store.subscription(for: feedID)
        let persistedEpisodes = try await store.podcastEpisodes(for: feedID)
        let captured = await capture.value()
        XCTAssertEqual(persistedFeed?.title, "Partial show")
        XCTAssertNotNil(persistedSubscription)
        XCTAssertTrue(persistedEpisodes.isEmpty)
        XCTAssertEqual(captured.episodeCount, 1)
        XCTAssertEqual(captured.admission, .backfill)
        XCTAssertEqual(captured.limit, 5)
        XCTAssertEqual(model.podcastFeedDraft, feedURL.absoluteString)
        XCTAssertEqual(model.podcastFeedDraftStatus,
                       "Partial show was added, but its episode metadata could not be saved. Retry refresh.")
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertTrue(model.podcastQueueIDs.isEmpty)
        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertNil(model.podcastSubscriptionRequestID)
    }

    func testManualRefreshTotalFailureKeepsTheLastSuccessfulTimestamp() async throws {
        let directory = wiltedTemporaryDirectory("subscription-manual-failure")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-failure.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let preferences = WiltedMacTestPreferences.ephemeral()
        let previousSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        preferences.set(previousSuccess, forKey: WiltedMacModel.lastAutomationRefreshPreferenceKey)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Failure", createdAt: Timestamp(previousSuccess)))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(previousSuccess)))
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: FailingLoader()), preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.lastAutomationRefreshAt, previousSuccess)
        XCTAssertEqual(model.podcastOperationMessage, "Podcasts could not be refreshed. Check your connection and retry.")
        XCTAssertNil(model.podcastRefreshTask)
    }

    func testPartialManualRefreshPublishesSuccessfulRowsAndAdvancesTheObservedTimestamp() async throws {
        let directory = wiltedTemporaryDirectory("subscription-manual-partial")
        let successfulURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-success.xml"))
        let failingURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-missing.xml"))
        let successID = try ItemID.derivePodcastFeed(from: successfulURL)
        let failureID = try ItemID.derivePodcastFeed(from: failingURL)
        let xml = "<rss><channel><title>Success</title><item><guid>fresh</guid><title>Fresh</title><pubDate>Mon, 29 Sep 2026 12:00:00 GMT</pubDate><enclosure url=\"https://media.example.test/fresh.mp3\" type=\"audio/mpeg\" /></item></channel></rss>"
        let loader = GatedRoutingLoader(documents: [successfulURL: Data(xml.utf8)])
        await loader.release()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                let subscribedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                try await store.save(feed: PodcastFeed(itemID: successID, canonicalURL: successfulURL, title: "Success", createdAt: subscribedAt))
                try await store.save(feed: PodcastFeed(itemID: failureID, canonicalURL: failingURL, title: "Failure", createdAt: subscribedAt))
                try await store.save(subscription: PodcastSubscription(feedID: successID, subscribedAt: subscribedAt))
                try await store.save(subscription: PodcastSubscription(feedID: failureID, subscribedAt: subscribedAt))
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: loader), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertNil(model.lastAutomationRefreshAt)

        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.episodes.map(\.title), ["Fresh"])
        XCTAssertNotNil(model.lastAutomationRefreshAt)
        XCTAssertTrue(try XCTUnwrap(model.podcastOperationMessage).contains("1 feed could not be refreshed."))
        XCTAssertNil(model.podcastRefreshTask, "the finite refresh writer must drain before its test root closes")
    }

    func testSecondSubscriptionRequestKeepsTheActiveRequestVisibleAndUnchanged() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-busy")
        let first = try XCTUnwrap(URL(string: "https://feeds.example.test/busy-first.xml"))
        let second = try XCTUnwrap(URL(string: "https://feeds.example.test/busy-second.xml"))
        let loader = NonCooperativeFeedLoader(documents: [first: fixtureFeed(title: "First")])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: loader), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(first)
        await loader.waitUntilHeld()
        XCTAssertTrue(model.isCheckingPodcastSubscription)
        let activeRequest = try XCTUnwrap(model.podcastSubscriptionRequestID)
        model.startPodcastSubscriptionIntake(second)
        model.refreshPodcastFeeds()

        XCTAssertEqual(model.podcastSubscriptionRequestID, activeRequest)
        XCTAssertTrue(model.isCheckingPodcastSubscription)
        XCTAssertEqual(model.podcastFeedDraftStatus, "Adding podcast feed…",
                       "the in-flight request remains visibly active instead of a second request replacing it")
    }

    func testSubscriptionAttemptDuringManualRefreshReportsTheRefreshCollision() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-refresh-collision")
        let existingURL = try XCTUnwrap(URL(string: "https://feeds.example.test/current.xml"))
        let attemptedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/attempted.xml"))
        let existingID = try ItemID.derivePodcastFeed(from: existingURL)
        let currentAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let loader = NonCooperativeFeedLoader(documents: [existingURL: fixtureFeed(title: "Current")])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: PodcastFeed(itemID: existingID, canonicalURL: existingURL, title: "Current", createdAt: currentAt))
                try await store.save(subscription: PodcastSubscription(feedID: existingID, subscribedAt: currentAt))
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: loader), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.refreshPodcastFeeds()
        await loader.waitUntilHeld()
        XCTAssertTrue(model.isRefreshingPodcasts)
        model.podcastFeedDraft = attemptedURL.absoluteString
        model.startPodcastSubscriptionIntake(attemptedURL)

        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertNil(model.podcastSubscriptionRequestID)
        let status = try XCTUnwrap(model.podcastFeedDraftStatus)
        XCTAssertTrue(status.contains("feeds.example.test"))
        XCTAssertTrue(status.contains("5 initial episodes"))
        XCTAssertTrue(status.localizedCaseInsensitiveContains("try again"))
        XCTAssertEqual(model.podcastFeedDraft, attemptedURL.absoluteString)
    }

    func testCancelledOldSubscriptionCannotOverwriteTheReplacementRequest() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-stale")
        let oldURL = try XCTUnwrap(URL(string: "https://feeds.example.test/stale-old.xml"))
        let newURL = try XCTUnwrap(URL(string: "https://feeds.example.test/stale-new.xml"))
        let loader = NonCooperativeFeedLoader(documents: [
            oldURL: fixtureFeed(title: "Old"), newURL: fixtureFeed(title: "New"),
        ])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: loader), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(oldURL)
        await loader.waitUntilHeld()
        let oldRequest = try XCTUnwrap(model.podcastSubscriptionRequestID)
        model.cancelPodcastSubscriptionCheck()
        model.startPodcastSubscriptionIntake(newURL)
        let replacement = try XCTUnwrap(model.podcastSubscriptionRequestID)
        XCTAssertNotEqual(oldRequest, replacement)
        XCTAssertTrue(model.isCheckingPodcastSubscription)
        await loader.release()
        await model.waitForPodcastOperations()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(model.subscriptions.map(\.title), ["New"])
        XCTAssertEqual(model.episodes.map(\.title), ["New episode"])
        XCTAssertEqual(model.podcastFeedDraftStatus, "New added with 1 episode.")
        XCTAssertFalse(model.isCheckingPodcastSubscription)
    }

    func testManualRefreshWithNoEnabledFeedsCompletesWithoutAFeedRequest() async throws {
        let directory = wiltedTemporaryDirectory("subscription-manual-zero")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/disabled.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let disabledAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Disabled", createdAt: disabledAt))
                try await store.save(subscription: PodcastSubscription(
                    feedID: feedID, subscribedAt: disabledAt, enabled: false
                ))
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.podcastOperationMessage, "Podcast episodes are up to date.")
        XCTAssertNil(model.lastAutomationRefreshAt,
                     "an empty enabled-feed set does not count as a successful refresh")
        XCTAssertTrue(model.episodes.isEmpty)
    }

    func testCancelledManualRefreshPreservesThePriorSuccessfulTimestamp() async throws {
        let directory = wiltedTemporaryDirectory("subscription-manual-cancel")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual-cancel.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let prior = Date(timeIntervalSince1970: 1_700_000_000)
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set(prior, forKey: WiltedMacModel.lastAutomationRefreshPreferenceKey)
        let loader = NonCooperativeFeedLoader(documents: [feedURL: fixtureFeed(title: "Cancelled refresh")])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Cancelled refresh", createdAt: Timestamp(prior)))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(prior)))
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: loader), preferences: preferences
        )
        addTeardownBlock { await model.close() }
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.refreshPodcastFeeds()
        await loader.waitUntilHeld()
        XCTAssertTrue(model.isRefreshingPodcasts)
        model.cancelPodcastRefresh()
        XCTAssertNil(model.podcastRefreshTask)
        let completion = CloseCompletion()
        let close = Task { await model.close(); completion.finished = true }
        for _ in 0..<32 where !model.isClosingTemporaryState { await Task.yield() }
        XCTAssertTrue(model.isClosingTemporaryState)
        XCTAssertFalse(completion.finished, "close must drain the cancelled writer after its public pointer cleared")
        await loader.release()
        await close.value
        XCTAssertTrue(completion.finished)

        XCTAssertEqual(model.podcastOperationMessage, "Podcast refresh cancelled.")
        XCTAssertEqual(model.lastAutomationRefreshAt, prior)
        XCTAssertTrue(model.episodes.isEmpty)
    }

    func testCloseDrainsAHeldSubscriptionWriterBeforeFixtureTeardown() async throws {
        let directory = wiltedTemporaryDirectory("subscription-intake-close")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/close.xml"))
        let loader = NonCooperativeFeedLoader(documents: [feedURL: fixtureFeed(title: "Closing")])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: loader), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.startPodcastSubscriptionIntake(feedURL)
        await loader.waitUntilHeld()

        let completion = CloseCompletion()
        let close = Task { await model.close(); completion.finished = true }
        for _ in 0..<32 where !model.isClosingTemporaryState { await Task.yield() }
        XCTAssertTrue(model.isClosingTemporaryState)
        XCTAssertFalse(completion.finished, "close must wait for the held subscription writer")
        await loader.release()
        await close.value
        XCTAssertTrue(completion.finished)
    }

    func testCancelledManualRefreshCannotOverwriteItsReplacementSubscription() async throws {
        let directory = wiltedTemporaryDirectory("manual-refresh-replacement")
        let currentURL = try XCTUnwrap(URL(string: "https://feeds.example.test/current.xml"))
        let replacementURL = try XCTUnwrap(URL(string: "https://feeds.example.test/replacement.xml"))
        let currentID = try ItemID.derivePodcastFeed(from: currentURL)
        let currentAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let loader = NonCooperativeFeedLoader(documents: [
            currentURL: fixtureFeed(title: "Current"), replacementURL: fixtureFeed(title: "Replacement"),
        ])
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, storeBootstrap: { url in
            let store = try LocalLibraryStore(url: url)
            try await store.save(feed: PodcastFeed(itemID: currentID, canonicalURL: currentURL, title: "Current", createdAt: currentAt))
            try await store.save(subscription: PodcastSubscription(feedID: currentID, subscribedAt: currentAt))
            return store
        }, podcastFeedClient: PodcastFeedClient(loader: loader), preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }; addTeardownBlock { await loader.release() }
        model.startStoreBootstrap(); await model.waitForStoreBootstrap()
        model.refreshPodcastFeeds(); await loader.waitUntilHeld()
        model.cancelPodcastRefresh()
        model.startPodcastSubscriptionIntake(replacementURL)
        _ = try XCTUnwrap(model.podcastSubscriptionRequestID)
        await loader.release(); await model.waitForPodcastOperations()

        XCTAssertEqual(Set(model.subscriptions.map(\.title)), ["Current", "Replacement"])
        XCTAssertEqual(model.podcastFeedDraftStatus, "Replacement added with 1 episode.")
        XCTAssertNil(model.podcastSubscriptionRequestID)
        XCTAssertNil(model.podcastRefreshTask)
    }

    private func fixtureFeed(title: String) -> Data {
        Data("<rss><channel><title>\(title)</title><item><guid>\(title)</guid><title>\(title) episode</title><pubDate>Mon, 29 Sep 2026 12:00:00 GMT</pubDate><enclosure url=\"https://media.example.test/\(title).mp3\" type=\"audio/mpeg\" /></item></channel></rss>".utf8)
    }
}

private actor NonCooperativeFeedLoader: PodcastFeedLoading {
    private let documents: [URL: Data]
    private var released = false
    private var held = false
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    init(documents: [URL: Data]) { self.documents = documents }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        let pending = holdWaiters
        holdWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        held = true
        let pending = observers
        observers.removeAll()
        for observer in pending { observer.resume() }
        if !released { await withCheckedContinuation { holdWaiters.append($0) } }
        guard let body = documents[url] else { throw URLError(.fileDoesNotExist) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(body.prefix(maximumBytes)))
    }
}

private enum SubscriptionIntakeFailure: Error { case expected }

@MainActor private final class CloseCompletion { var finished = false }

private actor SubscriptionAdmissionCapture {
    private var captured: (episodeCount: Int, admission: LocalLibraryStore.PodcastEpisodeAdmission, limit: Int?)?
    func record(episodes: [PodcastEpisode], admission: LocalLibraryStore.PodcastEpisodeAdmission, limit: Int?) {
        captured = (episodes.count, admission, limit)
    }
    func value() -> (episodeCount: Int, admission: LocalLibraryStore.PodcastEpisodeAdmission, limit: Int?) {
        captured ?? (0, .incremental, nil)
    }
}
