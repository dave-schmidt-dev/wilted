import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryIntentTests: XCTestCase {
    private func item(_ name: String) throws -> ItemID { try ItemID(rawValue: "item-\(name)") }
    private let created = Date(timeIntervalSince1970: 1_000)

    private func allDecisions() throws -> [LibraryIntent] {
        let a = try item("a"), b = try item("b")
        return [
            try .keep(entryID: a, deviceID: "phone", createdAt: created, id: "k"),
            try .skip(entryID: a, deviceID: "phone", createdAt: created, id: "s"),
            try .markDone(entryID: a, deviceID: "phone", createdAt: created, id: "m"),
            try .removeFromLarder(entryID: a, deviceID: "phone", createdAt: created, id: "l"),
            try .restore(entryID: a, deviceID: "phone", createdAt: created, id: "r"),
            try .reorder(entryID: a, afterEntryID: b, deviceID: "phone", createdAt: created, id: "o1"),
            try .reorder(entryID: a, afterEntryID: nil, deviceID: "phone", createdAt: created, id: "o2"),
        ]
    }

    func testEveryDecisionIntentRoundTripsThroughJSON() throws {
        for intent in try allDecisions() {
            let data = try JSONEncoder().encode(intent)
            XCTAssertEqual(try JSONDecoder().decode(LibraryIntent.self, from: data), intent)
            XCTAssertTrue(intent.action.isDecision)
            XCTAssertEqual(intent.action.entryID, try item("a"))
            XCTAssertEqual(intent.createdAt, created)
        }
        let media = try LibraryIntent.requestMedia(entryID: item("a"), deviceID: "phone", id: "q")
        XCTAssertFalse(media.action.isDecision)
    }

    func testReorderKeepsItsAnchorAndTheFrontIsDistinct() throws {
        let intents = try allDecisions().filter { if case .reorder = $0.action { true } else { false } }
        XCTAssertEqual(intents[0].action, .reorder(entryID: try item("a"), afterEntryID: try item("b")))
        XCTAssertEqual(intents[1].action, .reorder(entryID: try item("a"), afterEntryID: nil))
        XCTAssertNotEqual(intents[0], intents[1])
    }

    func testInvalidIntentsAreRejectedByInitAndDecode() throws {
        let a = try item("a")
        XCTAssertThrowsError(try LibraryIntent.reorder(entryID: a, afterEntryID: a, deviceID: "phone"))
        XCTAssertThrowsError(try LibraryIntent.keep(entryID: a, deviceID: "", id: "x"))
        XCTAssertThrowsError(try LibraryIntent.keep(entryID: a, deviceID: "phone", id: ""))
        let good = try JSONEncoder().encode(LibraryIntent.reorder(entryID: a, afterEntryID: item("b"), deviceID: "phone", id: "x"))
        let forged = String(decoding: good, as: UTF8.self).replacingOccurrences(of: "item-b", with: "item-a")
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryIntent.self, from: Data(forged.utf8)))
    }

    /// Adding the add-flow actions must not change one byte of what an older Mac or phone reads.
    func testPreExistingActionsEncodeToTheirOriginalJSON() throws {
        let a = try item("a"), b = try item("b")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cases: [(LibraryIntent.Action, String)] = [
            (.requestMedia(entryID: a), #"{"requestMedia":{"entryID":"item-a"}}"#),
            (.mediaCached(entryID: a, revisionID: try RevisionID(rawValue: "rev-1"), deviceID: "phone"),
             #"{"mediaCached":{"deviceID":"phone","entryID":"item-a","revisionID":"rev-1"}}"#),
            (.keep(entryID: a), #"{"keep":{"entryID":"item-a"}}"#),
            (.skip(entryID: a), #"{"skip":{"entryID":"item-a"}}"#),
            (.markDone(entryID: a), #"{"markDone":{"entryID":"item-a"}}"#),
            (.removeFromLarder(entryID: a), #"{"removeFromLarder":{"entryID":"item-a"}}"#),
            (.restore(entryID: a), #"{"restore":{"entryID":"item-a"}}"#),
            (.reorder(entryID: a, afterEntryID: b), #"{"reorder":{"afterEntryID":"item-b","entryID":"item-a"}}"#),
            (.reorder(entryID: a, afterEntryID: nil), #"{"reorder":{"entryID":"item-a"}}"#),
        ]
        for (action, json) in cases {
            XCTAssertEqual(String(decoding: try encoder.encode(action), as: UTF8.self), json)
            XCTAssertEqual(try JSONDecoder().decode(LibraryIntent.Action.self, from: Data(json.utf8)), action)
        }
    }

    func testSubscribeAndAddArticleRoundTripWithNamespacedEntryIDs() throws {
        let feed = try XCTUnwrap(URL(string: "https://Example.com/feed.xml"))
        let page = try XCTUnwrap(URL(string: "https://example.com/post#top"))
        let subscribe = try LibraryIntent.subscribe(feedURL: feed, deviceID: "phone", createdAt: created, id: "sub")
        let article = try LibraryIntent.addArticle(url: page, deviceID: "phone", createdAt: created, id: "art")
        for intent in [subscribe, article] {
            let data = try JSONEncoder().encode(intent)
            XCTAssertEqual(try JSONDecoder().decode(LibraryIntent.self, from: data), intent)
            XCTAssertTrue(intent.action.isDecision)
        }
        XCTAssertEqual(subscribe.action.entryID, try ItemID.derivePodcastFeed(from: feed))
        XCTAssertEqual(article.action.entryID, try ItemID.derive(from: page))
        XCTAssertNotEqual(subscribe.action.entryID, article.action.entryID)
    }

    func testAddIntentsRejectNonHTTPSAndCredentialedURLsAtInitAndDecode() throws {
        let bad = ["http://example.com/feed.xml", "ftp://example.com/f", "https://user:pw@example.com/f",
                   "https://user@example.com/f", "https:///nohost"]
        for text in bad {
            let url = try XCTUnwrap(URL(string: text), text)
            XCTAssertThrowsError(try LibraryIntent.subscribe(feedURL: url, deviceID: "phone", id: "x"), text)
            XCTAssertThrowsError(try LibraryIntent.addArticle(url: url, deviceID: "phone", id: "x"), text)
        }
        let good = try LibraryIntent.subscribe(feedURL: XCTUnwrap(URL(string: "https://example.com/f")), deviceID: "phone", id: "x")
        let forged = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
            .replacingOccurrences(of: "https:", with: "http:")
        XCTAssertTrue(forged.contains("http:"))
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryIntent.self, from: Data(forged.utf8)))
    }

    func testOutcomeRoundTripAndValidation() throws {
        let intent = try LibraryIntent.keep(entryID: item("a"), deviceID: "phone", createdAt: created, id: "k")
        let applied = try IntentOutcome.applied(for: intent, at: Date(timeIntervalSince1970: 2_000))
        let rejected = try IntentOutcome.rejected(for: intent, reason: IntentOutcome.reasonUnknownEntry, at: Date(timeIntervalSince1970: 2_000))
        for outcome in [applied, rejected] {
            XCTAssertEqual(try JSONDecoder().decode(IntentOutcome.self, from: JSONEncoder().encode(outcome)), outcome)
            XCTAssertEqual(outcome.intentID, "k")
            XCTAssertEqual(outcome.deviceID, "phone")
        }
        XCTAssertTrue(applied.isApplied)
        XCTAssertNil(applied.reason)
        XCTAssertFalse(rejected.isApplied)
        XCTAssertEqual(rejected.reason, "unknownEntry")
        XCTAssertThrowsError(try IntentOutcome(intentID: "k", deviceID: "phone", disposition: .rejected, decidedAt: created))
        XCTAssertThrowsError(try IntentOutcome(intentID: "k", deviceID: "phone", disposition: .rejected, reason: "", decidedAt: created))
        XCTAssertThrowsError(try IntentOutcome(intentID: "k", deviceID: "phone", disposition: .applied, reason: "x", decidedAt: created))
        XCTAssertThrowsError(try IntentOutcome(intentID: "", deviceID: "phone", disposition: .applied, decidedAt: created))
    }

    func testOnlyTheWriterMayPublishOutcomesAndTheFirstOutcomeStands() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let intent = try LibraryIntent.skip(entryID: item("a"), deviceID: "phone", createdAt: created, id: "s")
        try await phone.send(intent: intent)
        let forged = try IntentOutcome.applied(for: intent, at: created)
        do {
            try await phone.publishIntentOutcome(forged)
            XCTFail("a follower must not publish outcomes")
        } catch let error as LibraryTransportError {
            guard case .ownershipViolation = error else { return XCTFail("\(error)") }
        }
        let outcomes = try await phone.intentOutcomes()
        XCTAssertTrue(outcomes.isEmpty)

        let first = try IntentOutcome.rejected(for: intent, reason: IntentOutcome.reasonNotApplicable, at: created)
        try await mac.publishIntentOutcome(first)
        try await mac.publishIntentOutcome(forged)
        let seen = try await phone.intentOutcomes()
        XCTAssertEqual(seen, [first])
    }

    func testOutcomesAreListedOldestFirst() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        for (id, seconds) in [("late", 30.0), ("early", 10.0), ("mid", 20.0)] {
            let intent = try LibraryIntent.keep(entryID: item("a"), deviceID: "phone", createdAt: created, id: id)
            try await mac.publishIntentOutcome(.applied(for: intent, at: Date(timeIntervalSince1970: seconds)))
        }
        let listed = try await mac.intentOutcomes().map(\.intentID)
        XCTAssertEqual(listed, ["early", "mid", "late"])
    }

    func testIntentsExpireAfterSevenDaysAndAreRejectedNotApplied() throws {
        let intent = try LibraryIntent.markDone(entryID: item("a"), deviceID: "phone", createdAt: created, id: "m")
        let edge = created.addingTimeInterval(IntentRetention.maximumAge)
        XCTAssertEqual(IntentRetention.maximumAge, 7 * 86_400)
        XCTAssertFalse(IntentRetention.isExpired(intent, now: edge))
        XCTAssertNil(try IntentRetention.expiryOutcome(for: intent, now: edge))
        let late = edge.addingTimeInterval(1)
        XCTAssertTrue(IntentRetention.isExpired(intent, now: late))
        let outcome = try XCTUnwrap(IntentRetention.expiryOutcome(for: intent, now: late))
        XCTAssertEqual(outcome.disposition, .rejected)
        XCTAssertEqual(outcome.reason, IntentOutcome.reasonExpired)
        XCTAssertEqual(outcome.intentID, "m")
        XCTAssertEqual(outcome.decidedAt, late)
    }

    func testAPhoneMayDeleteOnlyItsOwnIntentsThatHaveAnOutcomeRegardlessOfAge() throws {
        let old = Date(timeIntervalSince1970: 0)
        let answered = try LibraryIntent.keep(entryID: item("a"), deviceID: "phone", createdAt: old, id: "answered")
        let waiting = try LibraryIntent.skip(entryID: item("b"), deviceID: "phone", createdAt: old, id: "waiting")
        let other = try LibraryIntent.keep(entryID: item("c"), deviceID: "tablet", createdAt: old, id: "other")
        let outcomes = [try IntentOutcome.applied(for: answered), try IntentOutcome.applied(for: other)]
        let deletable = IntentRetention.deletableIntents([answered, waiting, other], deviceID: "phone", outcomes: outcomes)
        XCTAssertEqual(deletable.map(\.id), ["answered"])
        XCTAssertTrue(IntentRetention.deletableIntents([waiting], deviceID: "phone", outcomes: []).isEmpty)
    }

    func testTransportDefaultsDoNotPretendToSupportOutcomes() async throws {
        struct Bare: LibraryTransport {
            func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
                LibraryChangeBatch(generationID: "g", changes: [], token: nil)
            }
            func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { LibraryPushResult() }
            func send(intent: LibraryIntent) async throws {}
            func listIntents() async throws -> [LibraryIntent] { [] }
            func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
            func fetchDeviceRecords() async throws -> LibraryDeviceRecords { LibraryDeviceRecords() }
        }
        let bare = Bare()
        let outcomes = try await bare.intentOutcomes()
        XCTAssertTrue(outcomes.isEmpty)
        let intent = try LibraryIntent.keep(entryID: item("a"), deviceID: "phone", id: "k")
        do {
            try await bare.publishIntentOutcome(.applied(for: intent))
            XCTFail("the default must throw")
        } catch { XCTAssertTrue(error is LibraryTransportError) }
    }
}

final class UnsupportedIntentTests: XCTestCase {
    func testAnUnsupportedPlaceholderIsADecisionAndNeverEncodes() throws {
        let placeholder = try LibraryIntent.unsupported(id: "u", deviceID: "phone", createdAt: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(placeholder.action.isDecision)
        XCTAssertThrowsError(try JSONEncoder().encode(placeholder))
    }

    func testAnUnknownActionStillFailsLibraryIntentDecode() {
        let json = #"{"action":{"teleport":{}},"createdAt":1,"deviceID":"phone","id":"x"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryIntent.self, from: Data(json.utf8)))
    }
}
