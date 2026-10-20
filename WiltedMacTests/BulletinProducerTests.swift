import Foundation
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Everything the producer touches, scripted. Thread-safe because the producer calls it from its actor.
private final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var _settings = BulletinProducerSettings(
        interruptionsEnabled: true, alertsEnabled: true, headlinesEnabled: true, headlineMinimumGapMinutes: 30)
    private var _items: [NewsHeadlineCandidate] = []
    private var _published: LibraryBulletins?
    private var _publishCount = 0
    private var _fetchCount = 0
    private var _newsFetches = 0
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    private var _publishError: Error?
    private var _delays: [TimeInterval] = []

    var settings: BulletinProducerSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }
    var items: [NewsHeadlineCandidate] {
        get { lock.withLock { _items } }
        set { lock.withLock { _items = newValue } }
    }
    var published: LibraryBulletins? { lock.withLock { _published } }
    var publishCount: Int { lock.withLock { _publishCount } }
    var newsFetches: Int { lock.withLock { _newsFetches } }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    var publishError: Error? {
        get { lock.withLock { _publishError } }
        set { lock.withLock { _publishError = newValue } }
    }
    var delays: [TimeInterval] { lock.withLock { _delays } }

    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }

    func item(_ id: String, minutesAgo: Double = 1) -> NewsHeadlineCandidate {
        NewsHeadlineCandidate(id: id, feedTitle: "Wire", title: "Story \(id)",
                              publishedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    func producer() -> BulletinProducer {
        BulletinProducer(
            settings: { [self] in settings },
            newsItems: { [self] in
                lock.withLock { _newsFetches += 1 }
                return items
            },
            fetchPublished: { [self] in
                lock.withLock { _fetchCount += 1 }
                return published
            },
            publish: { [self] value in
                if let error = publishError { throw error }
                lock.withLock { _published = value; _publishCount += 1 }
            },
            sleep: { [self] seconds in
                lock.withLock { _delays.append(seconds) }
                try await Task.sleep(for: .seconds(3600))
            },
            now: { [self] in now })
    }
}

final class BulletinProducerTests: XCTestCase {
    private struct Boom: Error {}

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: Done-when

    func testInterruptionsOffPublishesBothFlagsFalseAndNoHeadlines() async throws {
        let h = Harness()
        let producer = h.producer()
        await producer.poll()
        h.items = [h.item("a")]
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.count, 1)
        XCTAssertEqual(h.published?.alertsEnabled, true)

        h.settings.interruptionsEnabled = false
        let fetchesBefore = h.newsFetches
        await producer.poll()
        XCTAssertEqual(h.published?.alertsEnabled, false)
        XCTAssertEqual(h.published?.headlinesEnabled, false)
        XCTAssertEqual(h.published?.headlines, [])
        XCTAssertEqual(h.newsFetches, fetchesBefore, "news feeds are not read while interruptions are off")
    }

    func testTwoNewsItemsWithinTheGapYieldOneHeadlineBulletin() async throws {
        let h = Harness()
        let producer = h.producer()
        await producer.poll()  // baseline
        h.items = [h.item("a", minutesAgo: 3), h.item("b", minutesAgo: 1)]
        await producer.poll()
        let headlines = try XCTUnwrap(h.published?.headlines)
        XCTAssertEqual(headlines.count, 1)
        XCTAssertEqual(headlines.first?.id, "headline:b", "the newest post wins")
        XCTAssertEqual(headlines.first?.kind, .headline)
        XCTAssertEqual(headlines.first?.text, "Wire. Story b")

        // A third post inside the gap is dropped for good, not held for later.
        h.advance(minutes: 10)
        h.items.append(h.item("c"))
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:b"])
        h.advance(minutes: 25)
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:b"], "c was seen inside the gap")

        h.items.append(h.item("d"))
        await producer.poll()
        XCTAssertEqual(Set(h.published?.headlines.map(\.id) ?? []), ["headline:b", "headline:d"])
    }

    func testAnUnchangedListIsNotRepublished() async throws {
        let h = Harness()
        let producer = h.producer()
        await producer.poll()
        XCTAssertEqual(h.publishCount, 1, "switches on, first write")
        await producer.poll()
        await producer.poll()
        XCTAssertEqual(h.publishCount, 1)
        h.settings.alertsEnabled = false
        await producer.poll()
        XCTAssertEqual(h.publishCount, 2)
        XCTAssertEqual(h.published?.alertsEnabled, false)
    }

    // MARK: More behaviour

    func testNothingIsPublishedForAChannelThatWasNeverOn() async throws {
        let h = Harness()
        h.settings.interruptionsEnabled = false
        let producer = h.producer()
        await producer.poll()
        XCTAssertEqual(h.publishCount, 0)
        XCTAssertEqual(h.newsFetches, 0)
        let publishedActive = await producer.status.publishedActive
        XCTAssertEqual(publishedActive, false)
    }

    func testExpiredHeadlinesAreDropped() async throws {
        let h = Harness()
        let producer = h.producer()
        await producer.poll()
        h.items = [h.item("a")]
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.count, 1)
        h.advance(minutes: 61)
        await producer.poll()
        XCTAssertEqual(h.published?.headlines, [])
        XCTAssertEqual(h.published?.alertsEnabled, true)
    }

    func testOldAndUndatedPostsDoNotBecomeHeadlinesOnTheFirstLook() async throws {
        let h = Harness()
        h.items = [h.item("old", minutesAgo: 600),
                   NewsHeadlineCandidate(id: "nodate", feedTitle: "Wire", title: "No date", publishedAt: nil)]
        let producer = h.producer()
        await producer.poll()
        XCTAssertEqual(h.published?.headlines, [])
        await producer.poll()
        XCTAssertEqual(h.published?.headlines, [], "undated posts seen at baseline stay seen")
    }

    func testHeadlinesOffPublishesNoHeadlines() async throws {
        let h = Harness()
        h.settings.headlinesEnabled = false
        h.items = [h.item("a")]
        let producer = h.producer()
        await producer.poll()
        await producer.poll()
        XCTAssertEqual(h.newsFetches, 0)
        XCTAssertEqual(h.published?.headlinesEnabled, false)
        XCTAssertEqual(h.published?.headlines, [])
    }

    func testARestartDoesNotAnnounceWhatTheServerAlreadyHolds() async throws {
        let h = Harness()
        let first = h.producer()
        await first.poll()
        h.items = [h.item("a")]
        await first.poll()
        XCTAssertEqual(h.published?.headlines.count, 1)
        let second = h.producer()
        await second.poll()
        XCTAssertEqual(h.publishCount, 2, "no write for the restart")
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:a"])
    }

    func testAFailedPublishBacksOffAndIsRetriedWithTheSameList() async throws {
        let h = Harness()
        h.publishError = Boom()
        let producer = h.producer()
        await producer.start()
        try await eventually("first failure") { h.delays.count == 1 }
        let status = await producer.status
        XCTAssertEqual(status.consecutiveFailures, 1)
        XCTAssertNotNil(status.lastError)
        XCTAssertEqual(h.delays.first, BulletinProducer.pollInterval * 2, "never sooner than the interval")
        await producer.stop()

        h.publishError = nil
        await producer.poll()
        XCTAssertEqual(h.publishCount, 1)
        let recovered = await producer.status
        XCTAssertEqual(recovered.consecutiveFailures, 0)
        XCTAssertNil(recovered.lastError)
    }

    func testAnUnreachableServerWaitsWithoutCountingAFailure() async throws {
        let h = Harness()
        h.publishError = BulletinProducerUnavailable(reason: "Library sync is not running")
        let producer = h.producer()
        await producer.start()
        try await eventually("first wait") { h.delays.count == 1 }
        let status = await producer.status
        XCTAssertEqual(status.consecutiveFailures, 0)
        XCTAssertEqual(status.waitingFor, "Library sync is not running")
        XCTAssertEqual(h.delays.first, BulletinProducer.unavailableRetry)
        await producer.stop()
    }

    func testStatusReportsPollingThenTheResult() async throws {
        let h = Harness()
        let seen = StatusLog()
        let producer = BulletinProducer(
            settings: { h.settings }, newsItems: { [] }, fetchPublished: { nil }, publish: { _ in },
            onStatus: { seen.add($0) }, now: { h.now })
        await producer.poll()
        let states = seen.values
        XCTAssertEqual(states.map(\.isPolling), [true, false])
        XCTAssertNotNil(states.last?.lastPollAt)
    }

    // MARK: Plain failure text

    func testDescribeGivesAFixedSentencePerCause() {
        let offline = URLError(
            .notConnectedToInternet,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://news.example.test/feed?token=SECRET-TOKEN"])
        XCTAssertEqual(BulletinProducer.describe(offline), "Could not check news: this Mac is offline.")
        XCTAssertEqual(BulletinProducer.describe(URLError(.timedOut)),
                       "Could not check news: the connection timed out.")
        XCTAssertEqual(BulletinProducer.describe(Boom()), "Could not check news.")
    }

    func testAnOfflinePollFailureIsAPlainSentenceInSettings() async throws {
        let h = Harness()
        h.publishError = URLError(
            .notConnectedToInternet,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://news.example.test/feed?token=SECRET-TOKEN"])
        let producer = h.producer()
        await producer.poll()
        let status = await producer.status
        XCTAssertEqual(status.lastError, "Could not check news: this Mac is offline.")
        let statusLine = await WiltedMacBulletinHub.statusLine(status)
        let line = try XCTUnwrap(statusLine)
        XCTAssertFalse(line.contains("Error Domain"), line)
        XCTAssertFalse(line.contains("NSURLErrorDomain"), line)
        XCTAssertFalse(line.contains("SECRET-TOKEN"), line)
        XCTAssertFalse(line.contains(".."), line)
    }

    // MARK: Account gate

    func testAccountGateForwardsBulletinsOnlyWhileOpen() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let inner = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let gate = WiltedMacLibraryAccountGate(open: false)
        let wrapped = WiltedMacAccountGatedLibraryTransport(inner: inner, gate: gate)
        let value = try LibraryBulletins(alertsEnabled: true, headlinesEnabled: false)
        do { try await wrapped.publishBulletins(value); XCTFail("closed gate published") }
        catch { XCTAssertEqual(error as? WiltedMacLibraryAccountError, .notApproved) }
        do { _ = try await wrapped.fetchBulletins(); XCTFail("closed gate read") }
        catch { XCTAssertEqual(error as? WiltedMacLibraryAccountError, .notApproved) }
        let held = try await inner.fetchBulletins()
        XCTAssertNil(held, "nothing reached the transport")

        gate.reopen()
        try await wrapped.publishBulletins(value)
        let read = try await wrapped.fetchBulletins()
        XCTAssertEqual(read, value)
        let stored = try await inner.fetchBulletins()
        XCTAssertEqual(stored, value)
    }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BulletinProducerStatus] = []
    func add(_ status: BulletinProducerStatus) { lock.withLock { items.append(status) } }
    var values: [BulletinProducerStatus] { lock.withLock { items } }
}
