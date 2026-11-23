import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The daily-report status line and Build now button in Settings > Reports.
@MainActor
final class WiltedMacReportsCardTests: XCTestCase {
    private static let articleFeed = "<rss version=\"2.0\"><channel><title>Article source</title>"
        + "<item><guid>a1</guid><title>Post one</title><link>https://feeds.example.test/post-one</link></item></channel></rss>"
    private static let audioFeed = "<rss version=\"2.0\"><channel><title>Podcast</title>"
        + "<item><guid>e1</guid><title>Episode one</title><pubDate>Mon, 29 Sep 2026 12:00:00 GMT</pubDate>"
        + "<enclosure url=\"https://media.example.test/e1.mp3\" type=\"audio/mpeg\" /></item></channel></rss>"

    private func bootedModel(_ name: String, feedXML: String) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(feedXML.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    func testNotPublishedReasonAppearsInTheCaption() async throws {
        let suite = WiltedMacTestPreferences.suiteName("reports-card-tests")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let model = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertNil(model.morningReport.state.caption(), "nothing to say before a run")
        await model.morningReport.buildNow()

        guard case let .notPublished(reason) = model.morningReport.state else {
            return XCTFail("a build without an open library publishes nothing")
        }
        let caption = try XCTUnwrap(model.morningReport.state.caption())
        XCTAssertEqual(caption, reason)
        XCTAssertFalse(caption.hasPrefix("Not published:"))
    }

    func testCaptionsForEachState() {
        let at = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(WiltedMorningReportState.published(title: "Morning", at: at).caption(timeStyle: { _ in "6:30 AM" }),
                       "Last report: 6:30 AM")
        XCTAssertEqual(WiltedMorningReportState.building(fraction: 0.5, detail: "Reading headlines").caption(),
                       "Building… 50% Reading headlines")
    }

    func testBuildNowIsDisabledWhileBuildingOrWhenTheDailyReportIsOff() {
        let building = WiltedMorningReportState.building(fraction: 0.2, detail: "Starting")
        let idle = WiltedMorningReportState.idle
        XCTAssertTrue(WiltedMorningReportState.buildNowDisabled(state: building, reportEnabled: true))
        XCTAssertTrue(WiltedMorningReportState.buildNowDisabled(state: idle, reportEnabled: false))
        XCTAssertFalse(WiltedMorningReportState.buildNowDisabled(state: idle, reportEnabled: true))
        XCTAssertFalse(WiltedMorningReportState.buildNowDisabled(
            state: .notPublished(reason: "x"), reportEnabled: true))
    }

    func testBuildNowHelpSaysWhyTheButtonIsDisabled() {
        let building = WiltedMorningReportState.building(fraction: 0.2, detail: "Starting")
        let idle = WiltedMorningReportState.idle
        XCTAssertEqual(WiltedMorningReportState.buildNowHelp(state: idle, reportEnabled: false),
                       "Turn on Daily report first")
        XCTAssertEqual(WiltedMorningReportState.buildNowHelp(state: building, reportEnabled: true),
                       "A report is being built")
        XCTAssertEqual(WiltedMorningReportState.buildNowHelp(state: idle, reportEnabled: true),
                       "Build today's report now")
    }

    func testInterruptionsOffNoteExplainsWhyTheControlsAreDisabled() {
        XCTAssertEqual(WiltedMacReportsCard.interruptionsOffNote(interruptionsEnabled: false),
                       "Turn on Read bulletins while playing to use alerts and headlines.")
        XCTAssertNil(WiltedMacReportsCard.interruptionsOffNote(interruptionsEnabled: true))
    }

    func testAddHeadlineFeedSavesItsChoiceBeforePostsReachTheInbox() async throws {
        let model = try await bootedModel("reports-add-headline-feed", feedXML: Self.articleFeed)
        let url = try XCTUnwrap(URL(string: "https://feeds.example.test/articles.xml"))
        model.podcastFeedDraft = "https://feeds.example.test/unfinished.xml"

        let added = await model.subscribeToHeadlineFeed(url)

        XCTAssertTrue(added)
        XCTAssertEqual(model.podcastFeedDraft, "https://feeds.example.test/unfinished.xml")
        let feedID = try ItemID.articleFeed(canonicalFeedURL: url)
        let store = try XCTUnwrap(model.store)
        let savedAsHeadlines = try await store.isNews(feedID: feedID)
        XCTAssertTrue(savedAsHeadlines)
        XCTAssertTrue(model.offeredArticles.isEmpty, "the first refresh never offers headline posts to Keep or Skip")
        XCTAssertTrue(model.subscriptions.contains(where: { $0.id == feedID.rawValue }))
    }

    func testPromotingHiddenArticleFeedPreservesDisabledSubscription() async throws {
        let model = try await bootedModel("reports-existing-headline-feed", feedXML: Self.articleFeed)
        let url = try XCTUnwrap(URL(string: "https://feeds.example.test/articles.xml"))
        model.startPodcastSubscriptionIntake(url)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.feedsOfferedArticles.count, 1)

        let subscription = try XCTUnwrap(model.subscriptions.first)
        model.setSubscription(subscription, enabled: false)
        await model.waitForPodcastOperations()
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()

        XCTAssertTrue(board.isArticleFeed(subscription.id))
        XCTAssertTrue(board.setNews(true, for: subscription.id))
        await board.settle()

        let feedID = try ItemID(rawValue: subscription.id)
        let store = try XCTUnwrap(model.store)
        let savedAsHeadlines = try await store.isNews(feedID: feedID)
        XCTAssertTrue(savedAsHeadlines)
        XCTAssertFalse(try XCTUnwrap(model.subscriptions.first).enabled)
        XCTAssertEqual(model.offeredArticles.count, 1, "the post stays stored while its feed is hidden")

        model.setSubscription(try XCTUnwrap(model.subscriptions.first), enabled: true)
        await model.waitForPodcastOperations()
        XCTAssertTrue(model.feedsOfferedArticles.isEmpty)
    }

    func testAddHeadlineFeedRefusesPodcastAudio() async throws {
        let model = try await bootedModel("reports-headline-feed-rejects-audio", feedXML: Self.audioFeed)
        let url = try XCTUnwrap(URL(string: "https://feeds.example.test/podcast.xml"))

        let added = await model.subscribeToHeadlineFeed(url)

        XCTAssertFalse(added)
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertEqual(model.podcastFeedDraftStatus, "This feed contains audio. Use an article feed for headlines.")
    }
}
