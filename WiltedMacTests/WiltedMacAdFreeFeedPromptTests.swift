import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacAdFreeFeedPromptTests: XCTestCase {
    func testLooksAdFreeMatchesPrivateTitlesTokenAddressesAndCredentialedQuery() throws {
        let feedID = "feed-test"
        XCTAssertTrue(WiltedMacModel.looksAdFree(
            title: "Garden Hour Plus", feedURL: URL(string: "https://feeds.example.test/garden.xml"), feedID: feedID
        ))
        XCTAssertTrue(WiltedMacModel.looksAdFree(
            title: "Garden Hour Premium", feedURL: URL(string: "https://feeds.example.test/garden.xml"), feedID: feedID
        ))
        XCTAssertTrue(WiltedMacModel.looksAdFree(
            title: "Garden Hour",
            feedURL: URL(string: "https://feeds.example.test/f/9a8b7c6d5e4f3a2b1c0d9e8f7a6b/rss"),
            feedID: feedID
        ))
        XCTAssertTrue(WiltedMacModel.looksAdFree(
            title: "Garden Hour",
            feedURL: URL(string: "https://feeds.example.test/garden.xml?token=secret"),
            feedID: feedID
        ))
        XCTAssertFalse(WiltedMacModel.looksAdFree(
            title: "Garden Hour", feedURL: URL(string: "https://feeds.example.test/garden.xml"), feedID: feedID
        ))
    }

    func testFlaggedFeedPublishesPromptBeforeSaveAndExcludeStoresPreference() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-exclude"),
            title: "Garden Hour Plus", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL)
        let prompt = try await waitForAdFreePrompt(on: model)
        XCTAssertEqual(prompt.feedID, feedID.rawValue)
        XCTAssertEqual(prompt.title, "Garden Hour Plus")

        let store = try XCTUnwrap(model.store)
        do { let found = try await store.podcastFeed(for: feedID); XCTAssertNil(found) }
        do { let found = try await store.subscription(for: feedID); XCTAssertNil(found) }
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])

        model.answerAdFreeFeedPrompt(exclude: true)
        await model.waitForPodcastOperations()

        XCTAssertNil(model.pendingAdFreeFeedPrompt)
        XCTAssertTrue(WiltedMacAdFreeFeedPreference(preferences: preferences).isAdFree(feedID: feedID.rawValue))
        do { let found = try await store.podcastFeed(for: feedID); XCTAssertNotNil(found) }
        do { let found = try await store.subscription(for: feedID); XCTAssertNotNil(found) }
    }

    func testFlaggedFeedKeepRemovingAdsStoresNothingAndStillFollows() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/premium.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-keep"),
            title: "Garden Hour Premium", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL)
        _ = try await waitForAdFreePrompt(on: model)
        model.answerAdFreeFeedPrompt(exclude: false)
        await model.waitForPodcastOperations()

        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        let store = try XCTUnwrap(model.store)
        do { let found = try await store.subscription(for: feedID); XCTAssertNotNil(found) }
    }

    func testPlainFeedPublishesNoPrompt() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/public.xml"))
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-plain"),
            title: "Garden Hour", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL)
        await model.waitForPodcastOperations()

        XCTAssertNil(model.pendingAdFreeFeedPrompt)
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        XCTAssertFalse(model.subscriptions.isEmpty)
    }

    func testAlreadyFollowedFlaggedFeedPublishesNoPrompt() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/already.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let directory = wiltedTemporaryDirectory("ad-free-already")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { root in
                let store = try LocalLibraryStore(url: root)
                let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                try await store.save(feed: PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Garden Hour Plus", createdAt: now
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: now))
                return store
            },
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(Self.feedXML(
                title: "Garden Hour Plus", guid: "already-1"
            ).utf8))),
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(feedURL)
        await model.waitForPodcastOperations()

        XCTAssertNil(model.pendingAdFreeFeedPrompt)
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
    }

    func testArticleFeedPublishesNoPrompt() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/articles-plus.xml"))
        let xml = "<rss version=\"2.0\"><channel><title>Articles Plus</title>"
            + "<item><guid>a1</guid><title>Post one</title><link>https://feeds.example.test/post-1</link></item>"
            + "</channel></rss>"
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("ad-free-article"),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.startPodcastSubscriptionIntake(feedURL)
        await model.waitForPodcastOperations()

        XCTAssertNil(model.pendingAdFreeFeedPrompt)
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        XCTAssertFalse(model.subscriptions.isEmpty)
    }

    func testCancellingWhilePromptPendingClearsPromptStoresNothingAndDoesNotFollow() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/cancel-plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-cancel"),
            title: "Garden Hour Plus", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL)
        _ = try await waitForAdFreePrompt(on: model)
        model.cancelPodcastSubscriptionCheck()
        try await waitUntil("prompt cleared") { model.pendingAdFreeFeedPrompt == nil }
        await model.waitForPodcastOperations()

        XCTAssertNil(model.pendingAdFreeFeedPrompt)
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        let store = try XCTUnwrap(model.store)
        do { let found = try await store.podcastFeed(for: feedID); XCTAssertNil(found) }
        do { let found = try await store.subscription(for: feedID); XCTAssertNil(found) }
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    func testAnAddFromThePhoneNeverParksAQuestionOnTheMac() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/phone-plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-phone"),
            title: "Garden Hour Plus", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL, asksAboutAdFree: false)
        await model.waitForPodcastOperations()

        XCTAssertNil(model.pendingAdFreeFeedPrompt)
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        let store = try XCTUnwrap(model.store)
        do { let found = try await store.subscription(for: feedID); XCTAssertNotNil(found) }
    }

    func testAPhoneSubscribeOfAFlaggedFeedIsAddedWithoutAQuestion() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/phone-intent-plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let body = Data(Self.feedXML(title: "Garden Hour Plus", guid: "phone-intent-1").utf8)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("ad-free-phone-intent"),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: body)),
            pastedLinkClassifier: PastedLinkClassifier(loader: FixedBodyLoader(body: body)),
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        // The phone's own path: were it to ask, this would never return.
        let result = await model.subscribeFeed(feedURL)

        XCTAssertEqual(result, .added)
        XCTAssertNil(model.pendingAdFreeFeedPrompt)
        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        let store = try XCTUnwrap(model.store)
        do { let found = try await store.subscription(for: feedID); XCTAssertNotNil(found) }
    }

    func testACancelledAddCannotAnswerTheSameFeedAskedAgain() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/again-plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-again"),
            title: "Garden Hour Plus", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL)
        let first = try await waitForAdFreePrompt(on: model)
        model.cancelPodcastSubscriptionCheck()
        model.startPodcastSubscriptionIntake(feedURL)
        try await waitUntil("second ask") {
            model.pendingAdFreeFeedPrompt.map { $0 != first } ?? false
        }
        // The first add's cancellation is delivered late; give it every chance to misfire.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNotNil(model.pendingAdFreeFeedPrompt, "the cancelled add answered its successor's question")

        model.answerAdFreeFeedPrompt(exclude: true)
        await model.waitForPodcastOperations()

        XCTAssertTrue(WiltedMacAdFreeFeedPreference(preferences: preferences).isAdFree(feedID: feedID.rawValue))
        let store = try XCTUnwrap(model.store)
        do { let found = try await store.subscription(for: feedID); XCTAssertNotNil(found) }
    }

    func testChoosingExcludeWinsWhenTheAlertReportsItsDismissalFirst() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/order-plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-order"),
            title: "Garden Hour Plus", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL)
        _ = try await waitForAdFreePrompt(on: model)
        // An alert closes as its button runs; whichever is reported first, the button decides.
        model.adFreeFeedPromptWasDismissed()
        model.answerAdFreeFeedPrompt(exclude: true)
        await model.waitForPodcastOperations()

        XCTAssertTrue(WiltedMacAdFreeFeedPreference(preferences: preferences).isAdFree(feedID: feedID.rawValue))
    }

    func testDismissingTheQuestionWithoutChoosingKeepsAdRemovalAndFollows() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/dismiss-plus.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let model = await makeModel(
            directory: wiltedTemporaryDirectory("ad-free-dismiss"),
            title: "Garden Hour Plus", preferences: preferences
        )

        model.startPodcastSubscriptionIntake(feedURL)
        _ = try await waitForAdFreePrompt(on: model)
        model.adFreeFeedPromptWasDismissed()
        try await waitUntil("prompt cleared") { model.pendingAdFreeFeedPrompt == nil }
        await model.waitForPodcastOperations()

        XCTAssertEqual(WiltedMacAdFreeFeedPreference(preferences: preferences).feedIDs, [])
        let store = try XCTUnwrap(model.store)
        do { let found = try await store.subscription(for: feedID); XCTAssertNotNil(found) }
    }

    func testTwoAsksForTheSameFeedAreDifferentQuestions() {
        // A cancelled add answers only its own question; equal ones would let it answer the next.
        XCTAssertNotEqual(
            WiltedMacAdFreeFeedPrompt(feedID: "feed-a", title: "Garden Hour Plus"),
            WiltedMacAdFreeFeedPrompt(feedID: "feed-a", title: "Garden Hour Plus")
        )
    }

    func testTheQuestionWordingNamesTheShow() {
        XCTAssertEqual(WiltedMacAdFreeFeedPromptAlert.title, "This might be an ad-free feed")
        XCTAssertEqual(
            WiltedMacAdFreeFeedPromptAlert.message(showTitle: "Garden Hour Plus"),
            "It looks like Garden Hour Plus might be an ad-free feed. Would you like to exclude it from ad removal?"
        )
    }

    private func makeModel(
        directory: URL, title: String, preferences: UserDefaults
    ) async -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(Self.feedXML(
                title: title, guid: "\(title)-1"
            ).utf8))),
            preferences: preferences
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    private func waitForAdFreePrompt(on model: WiltedMacModel) async throws -> WiltedMacAdFreeFeedPrompt {
        try await waitUntil("ad-free prompt") { model.pendingAdFreeFeedPrompt != nil }
        return try XCTUnwrap(model.pendingAdFreeFeedPrompt)
    }

    private func waitUntil(_ label: String, attempts: Int = 200, _ condition: () -> Bool) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(label)")
        throw WaitTimeout(label: label)
    }

    private static func feedXML(title: String, guid: String) -> String {
        "<rss version=\"2.0\"><channel><title>\(title)</title>"
            + "<item><guid>\(guid)</guid><title>\(title) 1</title>"
            + "<pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>"
            + "<enclosure url=\"https://media.example.test/\(guid).mp3\" type=\"audio/mpeg\" /></item>"
            + "</channel></rss>"
    }
}

private struct WaitTimeout: Error {
    let label: String
}
