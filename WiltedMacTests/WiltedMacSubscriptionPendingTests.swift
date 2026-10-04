import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// A feed row says what it is waiting on from the moment the listener acts, repeated taps make one
/// write, a refresh reports every feed and leaves no row mid-flight, and "Last refreshed" is one
/// persisted value read the same way on Feeds and the Larder.
@MainActor
final class WiltedMacSubscriptionPendingTests: XCTestCase {
    private actor PendingLoader: PodcastFeedLoading {
        private let documents: [URL: Data]
        private let failing: Set<URL>
        private var held: Bool
        private(set) var loads = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var observers: [CheckedContinuation<Void, Never>] = []

        init(documents: [URL: Data], failing: Set<URL> = [], held: Bool = true) {
            self.documents = documents
            self.failing = failing
            self.held = held
        }

        func waitUntilLoading() async {
            if loads > 0 { return }
            await withCheckedContinuation { observers.append($0) }
        }

        func release() {
            held = false
            waiters.forEach { $0.resume() }
            waiters = []
        }

        func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
            loads += 1
            observers.forEach { $0.resume() }
            observers = []
            if held { await withCheckedContinuation { waiters.append($0) } }
            guard !failing.contains(url), let body = documents[url] else { throw URLError(.cannotConnectToHost) }
            return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
        }
    }

    private actor WriteGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var writes = 0

        func arrive() async {
            writes += 1
            guard writes == 1, !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private let urls = [
        URL(string: "https://feeds.example.test/one.xml")!, URL(string: "https://feeds.example.test/two.xml")!,
    ]
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    private func xml(_ title: String) -> Data {
        Data("""
        <rss><channel><title>\(title)</title><item><guid>\(title)-1</guid><title>\(title) 1</title>\
        <pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>\
        <enclosure url="https://media.example.test/\(title)-1.mp3" type="audio/mpeg" /></item></channel></rss>
        """.utf8)
    }

    private func documents() -> [URL: Data] {
        Dictionary(uniqueKeysWithValues: zip(urls, ["One", "Two"]).map { ($0, xml($1)) })
    }

    /// A model with both feeds saved and subscribed.
    private func model(
        loader: PendingLoader, feeds: Int = 2, preferences: UserDefaults = WiltedMacTestPreferences.ephemeral()
    ) async throws -> WiltedMacModel {
        let seeded = Array(urls.prefix(feeds))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("subscription-pending"),
            storeBootstrap: { [created] root in
                let store = try LocalLibraryStore(url: root)
                for (index, url) in seeded.enumerated() {
                    let id = try ItemID.derivePodcastFeed(from: url)
                    try await store.save(feed: PodcastFeed(
                        itemID: id, canonicalURL: url, title: index == 0 ? "One" : "Two", createdAt: created))
                    try await store.save(subscription: PodcastSubscription(feedID: id, subscribedAt: created))
                }
                return store
            }, podcastFeedClient: PodcastFeedClient(loader: loader), preferences: preferences)
        addTeardownBlock { await loader.release() }
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.reloadLibraryRowsForTesting()
        XCTAssertEqual(model.subscriptions.count, feeds)
        return model
    }

    private func feedID(_ index: Int) throws -> String { try ItemID.derivePodcastFeed(from: urls[index]).rawValue }

    // MARK: - Writes

    func testPendingStateExistsBeforeTheWriteStartsAndRepeatedTapsWriteOnce() async throws {
        let model = try await model(loader: PendingLoader(documents: documents(), held: false), feeds: 1)
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let gate = WriteGate()
        model.subscriptionWriteHookForTesting = { await gate.arrive() }

        for _ in 0..<3 { model.setSubscription(subscription, enabled: false) }
        XCTAssertEqual(model.pendingFeedWrites[subscription.id], .updating(enabled: false),
                       "the row is pending before any write has run")
        XCTAssertEqual(model.feedRowStatus(subscription.id), "Saving…")
        XCTAssertTrue(model.isFeedWritePending(subscription.id))

        await gate.open()
        await WiltedMacHeadless.eventually("the write settles") { model.pendingFeedWrites.isEmpty }
        let writes = await gate.writes
        XCTAssertEqual(writes, 1, "three taps make one write")
        XCTAssertEqual(model.subscriptions.first?.enabled, false)
        XCTAssertNil(model.feedRowStatus(subscription.id))
        let durable = try await XCTUnwrap(model.store).subscriptions().first?.enabled
        XCTAssertEqual(durable, false)
    }

    func testADifferentValueAskedForWhileSavingIsWrittenOnceAfterwards() async throws {
        let model = try await model(loader: PendingLoader(documents: documents(), held: false), feeds: 1)
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let gate = WriteGate()
        model.subscriptionWriteHookForTesting = { await gate.arrive() }

        model.setSubscription(subscription, enabled: false)
        model.setSubscription(subscription, enabled: true)
        model.setSubscription(subscription, enabled: false)
        model.setSubscription(subscription, enabled: true)
        await gate.open()
        await WiltedMacHeadless.eventually("both writes settle") { model.pendingFeedWrites.isEmpty }

        let writes = await gate.writes
        XCTAssertEqual(writes, 2, "the one in flight, then the newest request")
        XCTAssertEqual(model.subscriptions.first?.enabled, true)
        let durable = try await XCTUnwrap(model.store).subscriptions().first?.enabled
        XCTAssertEqual(durable, true)
    }

    func testAFailedWriteSettlesTheRowAndSaysSo() async throws {
        struct Failure: Error {}
        let model = try await model(loader: PendingLoader(documents: documents(), held: false), feeds: 1)
        let subscription = try XCTUnwrap(model.subscriptions.first)
        model.subscriptionWriteHookForTesting = { throw Failure() }

        model.setSubscription(subscription, enabled: false)
        model.setSubscription(subscription, enabled: true)
        await WiltedMacHeadless.eventually("the failed write settles") { model.pendingFeedWrites.isEmpty }
        XCTAssertEqual(model.podcastOperationMessage, "One could not be updated.")
        XCTAssertTrue(model.queuedFeedEnabled.isEmpty)
        XCTAssertEqual(model.subscriptions.first?.enabled, true)
    }

    func testUnsubscribeWaitsForAPendingWriteInsteadOfRacingIt() async throws {
        let model = try await model(loader: PendingLoader(documents: documents(), held: false), feeds: 1)
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let gate = WriteGate()
        model.subscriptionWriteHookForTesting = { await gate.arrive() }
        model.setSubscription(subscription, enabled: false)

        do {
            try await model.commitUnsubscribe(subscription)
            XCTFail("a pending write must stop the removal")
        } catch is WiltedMacRemovalUnavailable {}
        await gate.open()
        await WiltedMacHeadless.eventually("the write settles") { model.pendingFeedWrites.isEmpty }

        try await model.commitUnsubscribe(subscription)
        XCTAssertTrue(model.pendingFeedWrites.isEmpty)
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    func testThreeRapidSubscribeTapsMakeOneRequestAndShowItAtOnce() async throws {
        let loader = PendingLoader(documents: documents())
        let model = try await model(loader: loader, feeds: 0)
        model.startPodcastSubscriptionIntake(urls[0], initialMetadataCount: 5)
        XCTAssertTrue(model.isCheckingPodcastSubscription, "the check is published before the request runs")
        XCTAssertEqual(model.podcastFeedDraftStatus, "Adding podcast feed…")
        model.startPodcastSubscriptionIntake(urls[0], initialMetadataCount: 5)
        model.startPodcastSubscriptionIntake(urls[0], initialMetadataCount: 5)
        XCTAssertEqual(model.podcastFeedDraftStatus, "Adding podcast feed…", "a duplicate does not overwrite it")

        await loader.waitUntilLoading()
        await loader.release()
        await model.waitForPodcastOperations()
        let loads = await loader.loads
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(model.subscriptions.count, 1)
    }

    // MARK: - Refresh

    private func assertNoRowIsMidRefresh(_ model: WiltedMacModel, _ what: String, line: UInt = #line) {
        for (id, state) in model.feedRefreshStates {
            XCTAssertTrue(state == .failed, "\(what): \(id) is \(state)", line: line)
        }
        XCTAssertFalse(model.isRefreshingPodcasts, what, line: line)
    }

    func testEveryRowIsQueuedThenRefreshingBeforeTheRequestAndSettlesAfterSuccess() async throws {
        let loader = PendingLoader(documents: documents())
        let model = try await model(loader: loader)
        model.refreshPodcastFeeds()
        await loader.waitUntilLoading()

        XCTAssertEqual(model.feedRefreshStates.count, 2)
        XCTAssertEqual(model.feedRefreshStates.values.filter { $0 == .refreshing }.count, 1, "one request is out")
        XCTAssertEqual(model.feedRefreshStates.values.filter { $0 == .queued }.count, 1, "the other waits")
        let waiting = try XCTUnwrap(model.feedRefreshStates.first { $0.value == .queued }?.key)
        XCTAssertEqual(model.feedRowStatus(waiting), "Waiting to refresh")

        await loader.release()
        await model.waitForPodcastOperations()
        assertNoRowIsMidRefresh(model, "after success")
        XCTAssertTrue(model.feedRefreshStates.isEmpty, "finished rows go back to idle")
        XCTAssertNotNil(model.lastPodcastRefreshAt)
    }

    func testAFailedFeedStaysMarkedAndNoRowIsLeftRefreshingAfterAPartialFailure() async throws {
        let loader = PendingLoader(documents: documents(), failing: [urls[1]], held: false)
        let model = try await model(loader: loader)
        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()

        assertNoRowIsMidRefresh(model, "after partial failure")
        XCTAssertEqual(model.feedRefreshStates, [try feedID(1): .failed])
        XCTAssertEqual(model.feedRowStatus(try feedID(1)), "Could not refresh. Retry Refresh.")
        XCTAssertNil(model.feedRowStatus(try feedID(0)))
        XCTAssertNotNil(model.lastPodcastRefreshAt, "one feed refreshed")
    }

    func testAnAllFailedRefreshMarksEveryFeedAndDoesNotMoveLastRefreshed() async throws {
        let loader = PendingLoader(documents: documents(), failing: Set(urls), held: false)
        let model = try await model(loader: loader)
        model.refreshPodcastFeeds()
        await model.waitForPodcastOperations()

        assertNoRowIsMidRefresh(model, "after failure")
        XCTAssertEqual(Set(model.feedRefreshStates.keys), [try feedID(0), try feedID(1)])
        XCTAssertNil(model.lastPodcastRefreshAt)
    }

    func testCancellingSettlesEveryRowAndLeavesLastRefreshedAlone() async throws {
        let loader = PendingLoader(documents: documents())
        let model = try await model(loader: loader)
        model.refreshPodcastFeeds()
        await loader.waitUntilLoading()
        XCTAssertFalse(model.feedRefreshStates.isEmpty)

        model.cancelPodcastRefresh()
        assertNoRowIsMidRefresh(model, "right after cancel")
        XCTAssertTrue(model.feedRefreshStates.isEmpty)
        await loader.release()
        await model.waitForPodcastOperations()
        assertNoRowIsMidRefresh(model, "after the cancelled request returns")
        XCTAssertTrue(model.feedRefreshStates.isEmpty, "a late answer does not repaint a settled row")
        XCTAssertNil(model.lastPodcastRefreshAt)
    }

    /// A cancel that lands while the refresh is still reading its subscriptions clears the operation, so the
    /// task's own cleanup skips settling; the task must not queue rows after that.
    func testCancellingBeforeTheSubscriptionReadsReturnLeavesNoRowQueued() async throws {
        let model = try await model(loader: PendingLoader(documents: documents(), held: false))
        model.refreshPodcastFeeds()
        model.cancelPodcastRefresh()
        await model.waitForPodcastOperations()

        assertNoRowIsMidRefresh(model, "after a cancel before the first read returned")
        XCTAssertTrue(model.feedRefreshStates.isEmpty, "no row stays Waiting to refresh")
        XCTAssertNil(model.lastPodcastRefreshAt)
    }

    // MARK: - Last refreshed

    func testLastRefreshedReadsTheSameOnFeedsAndLarderAndSurvivesAFreshModel() async throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let model = try await model(loader: PendingLoader(documents: documents(), held: false), feeds: 0, preferences: preferences)
        XCTAssertEqual(model.lastPodcastRefreshRelativeText(), "Never")
        let larderBefore = try WiltedMacHeadless.recognizedText(WiltedMacMenuView(model: model, paneMode: .side))
        XCTAssertFalse(larderBefore.contains { $0.contains("Last refreshed") }, "the Larder says nothing before a first refresh")

        let refreshed = Date().addingTimeInterval(-7_300)
        model.setLastAutomationRefresh(refreshed)
        let feeds = try WiltedMacHeadless.recognizedText(WiltedMacFeedsView(model: model))
        let larder = try WiltedMacHeadless.recognizedText(WiltedMacMenuView(model: model, paneMode: .side))
        for (name, shown) in [("Feeds", feeds), ("Larder", larder)] {
            XCTAssertTrue(shown.contains { $0.contains("Last refreshed: 2 hours ago") }, "\(name): \(shown)")
        }
        XCTAssertEqual(
            model.lastPodcastRefreshExactText,
            "Last refreshed " + refreshed.formatted(date: .complete, time: .standard))

        let fresh = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertEqual(fresh.lastPodcastRefreshAt, model.lastPodcastRefreshAt)
        XCTAssertEqual(fresh.lastPodcastRefreshRelativeText(), "2 hours ago")

        let components = try WiltedMacHeadless.viewSource("WiltedMacFeedsComponents.swift")
        XCTAssertTrue(components.contains(".accessibilityLabel(model.lastPodcastRefreshExactText)"))
        for view in ["WiltedMacFeedsView.swift", "WiltedMacMenuView.swift"] {
            XCTAssertTrue(try WiltedMacHeadless.viewSource(view).contains("WiltedMacLastRefreshedLabel(model: model"), view)
        }
    }
}
