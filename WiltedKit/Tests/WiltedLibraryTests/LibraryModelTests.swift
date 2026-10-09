import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryModelTests: XCTestCase {
    private func id(_ digit: Character) throws -> ItemID {
        try ItemID(rawValue: "item-" + String(repeating: digit, count: 64))
    }

    private func slot(_ digit: Character, _ key: Double) throws -> QueueSlot {
        try QueueSlot(entryID: id(digit), sortKey: key)
    }

    func testAudiobookKindEntryDecodesOnExistingDecoder() throws {
        let payload = try AudiobookPayload(
            title: "Dune", durationSeconds: 10, chapters: [.init(title: "One", startSeconds: 0)],
            sourceFormat: .audio
        ).encoded()
        let entry = try LibraryEntry(
            id: id("a"), kind: .audiobook, sourceID: id("b"), title: "Dune", summary: "S",
            publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 10, payload: payload
        )
        let decoded = try JSONDecoder().decode(LibraryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.kind.rawValue, "audiobook")
        XCTAssertEqual(try JSONDecoder().decode(AudiobookPayload.self, from: decoded.payload).title, "Dune")
        XCTAssertEqual(LibraryKind.article.rawValue, "article")
        XCTAssertEqual(LibraryKind.articleFeed.rawValue, "article.feed")
    }

    func testSortKeyBetweenFirstAndLast() throws {
        XCTAssertEqual(QueueSlot.sortKey(after: nil, before: nil), 0)
        XCTAssertEqual(QueueSlot.sortKey(after: 1, before: 2), 1.5)
        let first = try XCTUnwrap(QueueSlot.sortKey(after: nil, before: 1))
        XCTAssertLessThan(first, 1)
        let last = try XCTUnwrap(QueueSlot.sortKey(after: 5, before: nil))
        XCTAssertGreaterThan(last, 5)
    }

    func testSortKeyRepeatedInsertionStaysOrderedThenReportsExhaustion() throws {
        var upper = 1.0
        for _ in 0..<40 {
            let key = try XCTUnwrap(QueueSlot.sortKey(after: 0, before: upper))
            XCTAssertTrue(key > 0 && key < upper)
            upper = key
        }
        XCTAssertNil(QueueSlot.sortKey(after: 1, before: 1))
        XCTAssertNil(QueueSlot.sortKey(after: 2, before: 1))
        XCTAssertNil(QueueSlot.sortKey(after: 1, before: 1.0.nextUp))
    }

    func testOrderingAndRebalance() throws {
        let slots = try [slot("b", 2), slot("a", 2), slot("c", -1)]
        XCTAssertEqual(QueueSlot.ordered(slots).map(\.entryID), try [id("c"), id("a"), id("b")])
        let rebalanced = QueueSlot.rebalanced(slots)
        XCTAssertEqual(rebalanced.map(\.sortKey), [0, 1, 2])
        XCTAssertEqual(rebalanced.map(\.entryID), try [id("c"), id("a"), id("b")])
        XCTAssertThrowsError(try QueueSlot(entryID: id("a"), sortKey: .infinity))
    }

    func testUnknownKindRoundTripsUnchanged() throws {
        let json = """
        {"id":"\(try id("a"))","kind":"weather.alert","sourceID":"\(try id("b"))","title":"T","summary":"S",\
        "publishedAt":0,"removal":"none","payload":"e30="}
        """
        let entry = try JSONDecoder().decode(LibraryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.kind.rawValue, "weather.alert")
        XCTAssertNotEqual(entry.kind, .podcastEpisode)
        let again = try JSONDecoder().decode(LibraryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(again, entry)
        XCTAssertThrowsError(try entry.podcastEpisodePayload())
    }

    func testOversizePayloadRejectedByInitAndDecode() throws {
        let limit = LibraryEntry.payloadLimitBytes
        func make(_ count: Int) throws -> LibraryEntry {
            try LibraryEntry(id: id("a"), kind: "x", sourceID: id("b"), title: "T", summary: "S",
                             publishedAt: Date(timeIntervalSince1970: 0), payload: Data(count: count))
        }
        XCTAssertNoThrow(try make(limit - 1))
        XCTAssertThrowsError(try make(limit))
        XCTAssertThrowsError(try make(limit + 1))
        let ok = try make(16)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ok)) as? [String: Any])
        object["payload"] = Data(count: limit).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryEntry.self, from: data))
    }

    func testPodcastEpisodePayloadRoundTripAndRemoval() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/one.mp3"))
        let entry = try LibraryEntry.podcastEpisode(
            id: id("a"), sourceID: id("b"), title: "One", summary: "S",
            publishedAt: Date(timeIntervalSince1970: 100), durationSeconds: 60,
            payload: PodcastEpisodePayload(enclosureURL: url, rssGUID: "g")
        )
        XCTAssertEqual(entry.kind, .podcastEpisode)
        XCTAssertEqual(try entry.podcastEpisodePayload().enclosureURL, url)
        let dismissed = try entry.with(removal: .dismissed)
        XCTAssertEqual(dismissed.removal, .dismissed)
        XCTAssertEqual(dismissed.payload, entry.payload)
        XCTAssertThrowsError(try LibraryEntry(id: id("a"), kind: "x", sourceID: id("b"), title: "T", summary: "S",
                                              publishedAt: .distantPast, durationSeconds: -1))
    }

    func testRemovedAtDecodesNilWhenAbsentAndRoundTripsWhenPresent() throws {
        let json = """
        {"id":"\(try id("a"))","kind":"podcast.episode","sourceID":"\(try id("b"))","title":"T","summary":"S",\
        "publishedAt":0,"removal":"retired","payload":"e30="}
        """
        let legacy = try JSONDecoder().decode(LibraryEntry.self, from: Data(json.utf8))
        XCTAssertNil(legacy.removedAt)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("removedAt"))

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = try legacy.with(removal: .dismissed, removedAt: when)
        XCTAssertEqual(dated.removedAt, when)
        let again = try JSONDecoder().decode(LibraryEntry.self, from: JSONEncoder().encode(dated))
        XCTAssertEqual(again, dated)
        XCTAssertNotEqual(dated, try legacy.with(removal: .dismissed))
    }

    func testApplyingRemovalKeepsDateWhileRemovedAndClearsItWhenLive() throws {
        let when = Date(timeIntervalSince1970: 500)
        let entry = try LibraryEntry(id: id("a"), kind: .podcastEpisode, sourceID: id("b"), title: "T", summary: "S",
                                     publishedAt: .distantPast, removal: .retired, removedAt: when)
        XCTAssertEqual(try entry.applyingRemoval(.dismissed).removedAt, when)
        XCTAssertNil(try entry.applyingRemoval(.none).removedAt)
    }

    func testIntentRoundTripAndListeningRecordMerge() throws {
        let intent = try LibraryIntent.requestMedia(entryID: id("a"), deviceID: "phone",
                                                    createdAt: Date(timeIntervalSince1970: 5), id: "req-1")
        XCTAssertEqual(try JSONDecoder().decode(LibraryIntent.self, from: JSONEncoder().encode(intent)), intent)
        XCTAssertThrowsError(try LibraryIntent.requestMedia(entryID: id("a"), deviceID: "phone", id: ""))
        let a = ListeningRecord(itemID: try id("a"), completedAt: nil, updatedAt: Date(timeIntervalSince1970: 1), deviceID: "d")
        let b = ListeningRecord(itemID: try id("b"), completedAt: nil, updatedAt: Date(timeIntervalSince1970: 1), deviceID: "d")
        XCTAssertThrowsError(try ListeningRecord.merge(a, b))
    }
}
