import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// A phone subscribe waits for a running refresh; a local subscription can take the single fetch
/// slot between that refresh ending and the phone request resuming. The phone request must still
/// run its own intake and never report the other request's outcome.
@MainActor
final class WiltedMacSubscribeFeedInterleavingTests: XCTestCase {
    func testPhoneSubscribeAnswersForItsOwnFeedWhenALocalSubscribeTakesTheSlotFirst() async throws {
        let followedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/followed.xml"))
        let feedA = try XCTUnwrap(URL(string: "https://feeds.example.test/a.xml"))
        let feedB = try XCTUnwrap(URL(string: "https://feeds.example.test/b.xml"))
        let documents = [followedURL: "Followed", feedA: "Feed A", feedB: "Feed B"].mapValues { Data(Self.feedXML($0).utf8) }
        let loader = HeldDocumentLoader(documents: documents)
        let followedID = try ItemID.derivePodcastFeed(from: followedURL)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("subscribe-interleave"),
            storeBootstrap: { root in
                let store = try LocalLibraryStore(url: root)
                let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                try await store.save(feed: PodcastFeed(itemID: followedID, canonicalURL: followedURL, title: "Followed", createdAt: now))
                try await store.save(subscription: PodcastSubscription(feedID: followedID, subscribedAt: now))
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: loader),
            pastedLinkClassifier: PastedLinkClassifier(loader: FixedBodyLoader(body: Data(Self.feedXML("Probe").utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        // A refresh owns the fetch slot and is held in the loader.
        model.refreshPodcastFeeds()
        await loader.waitUntilHeld()
        let refresh = try XCTUnwrap(model.podcastRefreshTask)

        // Polls the slot with main-actor yields, so it observes the freed slot in the job queued ahead of
        // the phone request's resumption: the local Add sheet's subscription for feed B wins the slot.
        var slotFree = false, bStarted = false
        let phone = Task { @MainActor in await model.subscribeFeed(feedA) }
        // The phone request must be parked on the refresh before the refresh may finish.
        let local = Task { @MainActor in
            while model.podcastRefreshTask != nil { await Task.yield() }
            slotFree = model.podcastRefreshTask == nil
            model.startPodcastSubscriptionIntake(feedB)
            bStarted = model.podcastRefreshTask != nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await loader.release()

        await local.value
        let result = await phone.value
        await model.waitForPodcastOperations()

        XCTAssertTrue(slotFree && bStarted, "the local request must win the slot for this to exercise the race")
        let ids = Set(model.subscriptions.map(\.id))
        XCTAssertTrue(ids.contains(try ItemID.derivePodcastFeed(from: feedA).rawValue), "the phone request's own feed is followed")
        XCTAssertTrue(ids.contains(try ItemID.derivePodcastFeed(from: feedB).rawValue), "B missing; ids=\(ids) result=\(result) status=\(String(describing: model.podcastFeedDraftStatus)) op=\(String(describing: model.podcastOperationMessage))")
        XCTAssertEqual(result, .added)
    }

    private static func feedXML(_ title: String) -> String {
        "<rss version=\"2.0\"><channel><title>\(title)</title><item><guid>\(title)-1</guid><title>\(title) 1</title>"
            + "<pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>"
            + "<enclosure url=\"https://media.example.test/\(title.replacingOccurrences(of: " ", with: "")).mp3\" type=\"audio/mpeg\" /></item></channel></rss>"
    }
}

/// Holds every load until released, then serves the per-URL document.
private actor HeldDocumentLoader: PodcastFeedLoading {
    private let documents: [URL: Data]
    private var released = false
    private var held = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(documents: [URL: Data]) { self.documents = documents }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        held = true
        let pending = observers
        observers.removeAll()
        for observer in pending { observer.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
        guard let body = documents[url] else { throw URLError(.fileDoesNotExist) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(body.prefix(maximumBytes)))
    }
}
