import Foundation
import WiltedCatalog
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The phone's Add flow against the in-memory transport, with a "mac" writer that advertises what it
/// applies and answers intents. Covers the send, the pending state, the outcome and the Mac gate.
@MainActor
final class LibraryAddTests: XCTestCase {
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let feed = URL(string: "https://feeds.example.com/show.xml")!
    private let page = URL(string: "https://example.com/story")!

    private func makeModel(timeout: TimeInterval = 90, now: @escaping @Sendable () -> Date = { Date() }) -> LibraryAppModel {
        let mirror = FileManager.default.temporaryDirectory.appendingPathComponent("add-mirror-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: mirror) }
        let suite = "library-add-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            store: FileLibraryStore(url: mirror), deviceID: "phone",
            decisionTiming: LibraryDecisionTiming(confirmationTimeout: timeout),
            preferences: UserDefaults(suiteName: suite)!, now: now, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func macAdvertises(_ actions: [String]?) async throws {
        try await mac.publishStats(LibraryStats(supportedIntentActions: actions))
    }

    private func intents() async throws -> [LibraryIntent] { try await mac.listIntents() }

    private func firstIntent() async throws -> LibraryIntent {
        let all = try await intents()
        return try XCTUnwrap(all.first)
    }

    private func macAnswers(_ intent: LibraryIntent, reason: String? = nil) async throws {
        let outcome = try reason.map { try IntentOutcome.rejected(for: intent, reason: $0) } ?? IntentOutcome.applied(for: intent)
        try await mac.publishIntentOutcome(outcome)
    }

    // MARK: Done-when cases

    func testSubscribeWritesOneSubscribeIntentAndShowsThePendingState() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let model = makeModel()
        await model.addToMac(.subscribe(feed), title: "The Show")
        await model.addToMac(.subscribe(feed), title: "The Show")  // a second press while one is waiting

        let sent = try await intents()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.action, .subscribe(feedURL: feed))
        XCTAssertEqual(sent.first?.deviceID, "phone")
        XCTAssertEqual(model.adds.count, 1)
        XCTAssertEqual(model.adds.first?.title, "The Show")
        XCTAssertEqual(model.addStatus(for: try XCTUnwrap(model.adds.first)).text, "Sent to your Mac")
        XCTAssertNil(model.addNotice)
        XCTAssertTrue(model.decisions.isEmpty, "an add is not a row decision")
    }

    func testARejectedOutcomeShowsItsReason() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let model = makeModel()
        await model.addToMac(.subscribe(feed), title: "The Show")
        try await macAnswers(firstIntent(), reason: "noAudio")
        await model.refresh()

        let add = try XCTUnwrap(model.adds.first)
        XCTAssertEqual(add.phase, .rejected("noAudio"))
        let status = model.addStatus(for: add)
        XCTAssertEqual(status.text, "That feed has no audio episodes, so your Mac did not add it.")
        XCTAssertEqual(status.tone, .failure)
    }

    func testAMacThatDoesNotAdvertiseTheActionGetsNoIntentAndTheUpdateMessage() async throws {
        let model = makeModel()
        // No stats at all: a Mac that predates the field.
        await model.addToMac(.subscribe(feed), title: "The Show")
        var sent = try await intents()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.addNotice, "Update Wilted on your Mac to add from iPhone")
        XCTAssertTrue(model.adds.isEmpty)

        // Stats that list one action do not unlock the other.
        try await macAdvertises(["subscribe"])
        await model.addToMac(.article(page), title: "A story")
        sent = try await intents()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.addNotice, "Update Wilted on your Mac to add from iPhone")
        XCTAssertEqual(model.macAddActions, ["subscribe"])
    }

    func testTheOutcomeOfAPendingAddIsFetchedWhileNoRowDecisionIsPending() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let model = makeModel()
        await model.addToMac(.article(page), title: "example.com/story")
        XCTAssertTrue(model.decisions.isEmpty)
        try await macAnswers(firstIntent())
        await model.refresh()

        let add = try XCTUnwrap(model.adds.first)
        XCTAssertEqual(add.phase, .applied)
        XCTAssertEqual(model.addStatus(for: add).text, "Added on your Mac")
        XCTAssertEqual(model.addStatus(for: add).tone, .positive)
        XCTAssertTrue(model.decisions.isEmpty)
    }

    // MARK: Around the edges

    func testASubscribeOutcomeSaysFollowing() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let model = makeModel()
        await model.addToMac(.subscribe(feed), title: "The Show")
        try await macAnswers(firstIntent())
        await model.refresh()
        XCTAssertEqual(model.addStatus(for: try XCTUnwrap(model.adds.first)).text, "Following on your Mac")
    }

    func testEveryReasonTheMacGivesHasWords() {
        let reasons = ["alreadyFollowed", "alreadyAdded", "notAPodcastFeed", "isAFeed", "noAudio", "failed",
                       "unsupportedAction", "expired", nil, "somethingNew"]
        let texts = reasons.map { LibraryAppModel.addRejectionText($0) }
        XCTAssertEqual(Set(texts).count, texts.count - 1, "the unknown and the missing reason share the opaque line")
        XCTAssertEqual(LibraryAppModel.addRejectionText("unsupportedAction"), "Update Wilted on your Mac to add from iPhone")
        XCTAssertEqual(LibraryAppModel.addRejectionText("somethingNew"), "Your Mac declined it.")
        XCTAssertTrue(texts.allSatisfy { !$0.isEmpty && !$0.contains("Reason") })
    }

    func testAnAddThatTheMacHasNotAnsweredInTimeSaysSo() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let clock = AddClock()
        let model = makeModel(timeout: 60, now: { clock.now })
        await model.addToMac(.subscribe(feed), title: "The Show")
        let add = try XCTUnwrap(model.adds.first)
        XCTAssertEqual(model.addStatus(for: add).text, "Sent to your Mac")
        clock.advance(61)
        XCTAssertEqual(model.addStatus(for: add).text, "Sent to your Mac. It has not answered yet; open Wilted on your Mac.")
        XCTAssertEqual(model.addStatus(for: add).tone, .caution)
    }

    func testFinishedAddsLeaveWhenDismissedAndWaitingOnesStay() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let model = makeModel()
        await model.addToMac(.subscribe(feed), title: "The Show")
        await model.addToMac(.article(page), title: "A story")
        let all = try await intents()
        let first = try XCTUnwrap(all.first { $0.action == .subscribe(feedURL: feed) })
        try await macAnswers(first)
        await model.refresh()
        model.clearFinishedAdds()
        XCTAssertEqual(model.adds.map(\.title), ["A story"])
    }

    func testAnUnreadableMacIsNotTheSameAsAnOldMac() async throws {
        let model = makeModel()
        await model.addToMac(.subscribe(feed), title: "The Show")  // no stats yet: old Mac
        XCTAssertEqual(model.addNotice, "Update Wilted on your Mac to add from iPhone")
        model.macAddCheckFailed = true
        XCTAssertEqual(model.addCapabilityNotice, "Wilted could not check your Mac. Try again in a moment.")
        model.macAddCheckFailed = false
        XCTAssertEqual(model.addCapabilityNotice, "Update Wilted on your Mac to add from iPhone")
    }

    func testALinkWithCredentialsOrNoHTTPSIsRefusedBeforeAnythingIsSent() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let model = makeModel()
        await model.addToMac(.article(URL(string: "http://example.com/a")!), title: "plain http")
        await model.addToMac(.subscribe(URL(string: "https://user:pass@example.com/feed")!), title: "login")
        let sent = try await intents()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.addNotice, "Only https links without a login can be added.")
        XCTAssertTrue(model.adds.isEmpty)
    }

    // MARK: Session

    private nonisolated static func show(_ id: Int, _ title: String, feed: String) -> PodcastCatalogShow {
        PodcastCatalogShow(collectionID: id, title: title, feedURL: URL(string: feed)!, author: "Author \(id)")
    }

    private func session(
        _ model: LibraryAppModel,
        search: @escaping LibraryAddSession.Search = { _ in [] },
        lookup: @escaping LibraryAddSession.Lookup = { _ in throw PodcastCatalogLookupError.resultNotFound }
    ) -> LibraryAddSession {
        model.makeAddSession(search: search, lookup: lookup, linkDebounce: .zero, searchDebounce: .zero)
    }

    func testTypingASearchListsShowsWithOneSubscribeEach() async throws {
        let model = makeModel()
        let add = session(model, search: { _ in
            [LibraryAddTests.show(1, "First Show", feed: "https://a.example.com/rss"), LibraryAddTests.show(2, "Second Show", feed: "https://b.example.com/rss")]
        })
        add.text = "show"
        await add.settle()
        XCTAssertEqual(add.rows.map(\.title), ["First Show", "Second Show"])
        XCTAssertEqual(add.rows.map(\.detail), ["Author 1", "Author 2"])
        XCTAssertEqual(add.rows.map(\.kind), [
            .show(feed: URL(string: "https://a.example.com/rss")!, following: false),
            .show(feed: URL(string: "https://b.example.com/rss")!, following: false)
        ])
    }

    func testAnApplePodcastsLinkResolvesWithLookupAndOffersSubscribe() async throws {
        let model = makeModel()
        let resolved = Self.show(1_234_567, "Looked Up", feed: "https://feeds.example.com/looked-up.xml")
        let add = session(model, lookup: { id in
            XCTAssertEqual(id, 1_234_567)
            return resolved
        })
        add.text = "https://podcasts.apple.com/us/podcast/looked-up/id1234567"
        await add.settle()
        XCTAssertEqual(add.rows.map(\.title), ["Looked Up"])
        XCTAssertEqual(add.rows.first?.kind, .show(feed: resolved.feedURL, following: false))
    }

    func testAnOtherLinkOffersArticleOrPodcastFeedAndTheChoiceIsTheUsers() async throws {
        let model = makeModel()
        let add = session(model)
        add.text = "https://example.com/story"
        await add.settle()
        XCTAssertEqual(add.rows.count, 1)
        XCTAssertEqual(add.rows.first?.kind, .link(page))
        XCTAssertEqual(add.rows.first?.title, "example.com/story")
    }

    func testAnApplePodcastsLinkWithoutAShowIDSaysSoInsteadOfAddingAnArticle() async throws {
        let model = makeModel()
        let add = session(model)
        add.text = "https://podcasts.apple.com/us/charts"
        await add.settle()
        XCTAssertTrue(add.rows.isEmpty)
        XCTAssertEqual(add.statusMessage, "That Apple Podcasts address is not a supported show link.")
    }

    func testASentRowStopsOfferingASecondPress() async throws {
        let model = makeModel()
        let add = session(model, search: { _ in [LibraryAddTests.show(1, "Known", feed: "https://feeds.example.com/show.xml")] })
        add.text = "known"
        await add.settle()
        XCTAssertEqual(add.rows.first?.kind, .show(feed: feed, following: false))
        // Once a send is waiting, the same row stops offering a second press.
        try await macAdvertises(["subscribe", "addArticle"])
        await add.send(try XCTUnwrap(add.rows.first))
        XCTAssertEqual(add.rows.first?.requestPhase, .sent)
        let sent = try await intents()
        XCTAssertEqual(sent.count, 1)
    }

    func testSendingALinkClearsTheFieldAndListsTheAddBelow() async throws {
        try await macAdvertises(["subscribe", "addArticle"])
        let model = makeModel()
        let add = session(model)
        add.text = "https://example.com/story"
        await add.settle()
        await add.send(try XCTUnwrap(add.rows.first), as: .article)
        XCTAssertEqual(add.text, "")
        XCTAssertTrue(add.rows.isEmpty)
        XCTAssertEqual(model.adds.first?.intent.action, .addArticle(url: page))
    }
}

private final class AddClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_700_000_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}
