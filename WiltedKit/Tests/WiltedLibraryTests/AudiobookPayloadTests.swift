import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class AudiobookPayloadTests: XCTestCase {
    private func entryID(_ digit: Character) throws -> ItemID {
        try ItemID(rawValue: "item-" + String(repeating: digit, count: 64))
    }

    func testPayloadRoundTripsToIdenticalJSON() throws {
        let payload = AudiobookPayload(
            title: "Dune", author: "Frank Herbert", durationSeconds: 7_200.5,
            chapters: [.init(title: "One", startSeconds: 0), .init(title: "Two", startSeconds: 61.25)],
            sourceFormat: .epub, volumeIndex: 1, volumeCount: 3
        )
        let first = try payload.encoded()
        let decoded = try JSONDecoder().decode(AudiobookPayload.self, from: first)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(try decoded.encoded(), first)
        let json = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(json.hasPrefix(#"{"author":"Frank Herbert","chapters":"#), json)
    }

    func testFiveThousandLongChaptersStayUnderBudgetAndEntryAccepts() throws {
        let chapters = (0..<5_000).map {
            AudiobookChapter(title: String(repeating: "x", count: 500), startSeconds: Double($0) * 10)
        }
        let payload = AudiobookPayload.build(
            title: String(repeating: "T", count: 500), author: "A", durationSeconds: 50_000,
            chapters: chapters, sourceFormat: .audio
        )
        let data = try payload.encoded()
        XCTAssertLessThan(data.count, 48 * 1024)
        XCTAssertLessThanOrEqual(payload.chapters.count, 400)
        XCTAssertEqual(payload.chapters.first?.startSeconds, 0)
        XCTAssertTrue(payload.chapters.allSatisfy { $0.title.count <= 120 })
        XCTAssertEqual(payload.title.count, 120)
        // Merged chapters stay ordered by start time.
        XCTAssertEqual(payload.chapters.map(\.startSeconds), payload.chapters.map(\.startSeconds).sorted())
        let entry = try LibraryEntry(
            id: entryID("a"), kind: .audiobook, sourceID: entryID("b"), title: "T", summary: "S",
            publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 50_000, payload: data
        )
        XCTAssertEqual(entry.kind, .audiobook)
    }

    func testMultiByteTitlesStillFitByteBudget() throws {
        let chapters = (0..<400).map {
            AudiobookChapter(title: String(repeating: "\u{1F4D6}", count: 120), startSeconds: Double($0))
        }
        let payload = AudiobookPayload.build(
            title: "T", durationSeconds: 400, chapters: chapters, sourceFormat: .pdf
        )
        XCTAssertLessThanOrEqual(try payload.encoded().count, AudiobookPayload.maxEncodedBytes)
        XCTAssertFalse(payload.chapters.isEmpty)
    }

    func testChaptersUnderCapAreKeptAndNonFiniteValuesAreSanitized() throws {
        let payload = AudiobookPayload.build(
            title: "T", durationSeconds: .nan,
            chapters: [.init(title: "A", startSeconds: 0), .init(title: "B", startSeconds: .infinity)],
            sourceFormat: .audio
        )
        XCTAssertEqual(payload.chapters.map(\.title), ["A", "B"])
        XCTAssertEqual(payload.durationSeconds, 0)
        XCTAssertNoThrow(try payload.encoded())
    }
}
