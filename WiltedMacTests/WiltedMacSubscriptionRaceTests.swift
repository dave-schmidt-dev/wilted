import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacSubscriptionRaceTests: XCTestCase {
    func testDuplicateRaisedCapDoesNotAdmitOlderEpisodes() async throws {
        let model = try await model(body: feedXML(title: "Duplicate", episodeCount: 26))
        model.startPodcastSubscriptionIntake(try XCTUnwrap(URL(string: "https://feeds.example.test/duplicate.xml")), initialMetadataCount: 5)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.episodes.count, 5)

        model.startPodcastSubscriptionIntake(try XCTUnwrap(URL(string: "https://feeds.example.test/duplicate.xml")), initialMetadataCount: 10)
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.episodes.count, 5)
        XCTAssertTrue(try XCTUnwrap(model.podcastFeedDraftStatus).contains("Already following"))
    }

    func testRetryAfterZeroRowAdmissionUsesTheOriginalBoundedWindow() async throws {
        let model = try await model(body: feedXML(title: "Retry", episodeCount: 26))
        let url = try XCTUnwrap(URL(string: "https://feeds.example.test/retry.xml"))
        model.podcastEpisodeAdmissionOperationForTesting = { _, _, _ in throw SubscriptionRaceFailure.expected }
        model.startPodcastSubscriptionIntake(url, initialMetadataCount: 5)
        await model.waitForPodcastOperations()
        XCTAssertTrue(model.episodes.isEmpty)

        model.podcastEpisodeAdmissionOperationForTesting = nil
        model.startPodcastSubscriptionIntake(url, initialMetadataCount: 5)
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.episodes.count, 5)
    }

    func testCancellingComposerCheckDoesNotCancelAnOwnedManualRefresh() async throws {
        let manualURL = try XCTUnwrap(URL(string: "https://feeds.example.test/manual.xml"))
        let checkURL = try XCTUnwrap(URL(string: "https://pages.example.test/check"))
        let loader = HeldSubscriptionLoader(documents: [
            manualURL: Data(feedXML(title: "Manual", episodeCount: 1).utf8),
            checkURL: Data("<html><body>Check</body></html>".utf8),
        ])
        let directory = wiltedTemporaryDirectory("subscription-race-manual")
        let feedID = try ItemID.derivePodcastFeed(from: manualURL)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { root in
                let store = try LocalLibraryStore(url: root)
                let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: manualURL, title: "Manual", createdAt: now))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: now))
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: loader),
            pastedLinkClassifier: PastedLinkClassifier(loader: loader), preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        addTeardownBlock { await loader.release() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.refreshPodcastFeeds()
        await loader.waitUntilHeld()

        model.podcastFeedDraft = checkURL.absoluteString
        model.addPodcastFeedDraft()
        model.cancelPodcastSubscriptionCheck()
        XCTAssertTrue(model.isRefreshingPodcasts)
        XCTAssertNotNil(model.podcastRefreshTask)

        await loader.release()
        await model.waitForPodcastOperations()
        XCTAssertFalse(model.isRefreshingPodcasts)
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Manual"])
    }

    private func model(body: String) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("subscription-race"),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(body.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    private func feedXML(title: String, episodeCount: Int) -> String {
        let items = (1...episodeCount).map { number in
            "<item><guid>\(title)-\(number)</guid><title>\(title) \(number)</title><pubDate>Mon, \(String(format: "%02d", number)) Jan 2024 12:00:00 GMT</pubDate><enclosure url=\"https://media.example.test/\(title)-\(number).mp3\" type=\"audio/mpeg\" /></item>"
        }.joined()
        return "<rss><channel><title>\(title)</title>\(items)</channel></rss>"
    }
}

private enum SubscriptionRaceFailure: Error { case expected }

private actor HeldSubscriptionLoader: PodcastFeedLoading {
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
